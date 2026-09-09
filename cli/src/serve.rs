//! `view` — serve the game's viewer and one replay, on loopback.
//!
//! A replay carries its own board, so the page needs the envelope and the cartridge's viewer
//! bundle and nothing else: no database, no API, no season. The bundle is the game's, fetched the
//! same way its component is, so what a competitor watches locally is the same viewer the web
//! application and the book embed.
//!
//! The server is deliberately tiny and deliberately loopback-only. It exists to put a file in a
//! browser, and a viewer that needed a real web server would have put one more thing between a
//! competitor and their first replay.

use std::io::{BufRead, BufReader, Write};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};

pub fn serve(viz: &Path, replay_json: &str, open: bool) -> Result<(), String> {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .map_err(|e| format!("cannot bind loopback: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| e.to_string())?
        .port();
    let url = format!("http://127.0.0.1:{port}/");

    println!("{url}");
    println!("(ctrl-c when you are done)");
    if open {
        let _ = std::process::Command::new(opener()).arg(&url).status();
    }

    for stream in listener.incoming() {
        let mut s = match stream {
            Ok(s) => s,
            Err(_) => continue,
        };
        if let Err(e) = respond(&mut s, viz, replay_json) {
            // A browser closing a connection mid-response is ordinary, not an error worth the
            // user's attention; anything else is printed and the server keeps serving.
            if !e.contains("Broken pipe") {
                eprintln!("  {e}");
            }
        }
    }
    Ok(())
}

fn opener() -> &'static str {
    if cfg!(target_os = "macos") {
        "open"
    } else if cfg!(target_os = "windows") {
        "explorer"
    } else {
        "xdg-open"
    }
}

fn respond(s: &mut TcpStream, viz: &Path, replay_json: &str) -> Result<(), String> {
    let mut reader = BufReader::new(s.try_clone().map_err(|e| e.to_string())?);
    let mut line = String::new();
    reader.read_line(&mut line).map_err(|e| e.to_string())?;
    let path = line.split_whitespace().nth(1).unwrap_or("/").to_string();
    // Drain the headers so the client's write completes before we answer.
    loop {
        let mut h = String::new();
        if reader.read_line(&mut h).map_err(|e| e.to_string())? <= 2 {
            break;
        }
    }

    match path.as_str() {
        "/" => send(s, "text/html; charset=utf-8", PAGE.as_bytes()),
        "/replay.json" => send(s, "application/json", replay_json.as_bytes()),
        p => {
            // Everything else is the viewer bundle. Path traversal is refused rather than
            // sanitised: there is exactly one directory this server may read from.
            let rel = p.trim_start_matches('/');
            if rel.contains("..") {
                return send(s, "text/plain", b"no");
            }
            let file = viz.join(rel);
            match std::fs::read(&file) {
                Ok(bytes) => send(s, mime(&file), &bytes),
                Err(_) => {
                    let body = format!("not found: {rel}");
                    s.write_all(
                        format!(
                            "HTTP/1.1 404 Not Found\r\nContent-Length: {}\r\n\r\n{body}",
                            body.len()
                        )
                        .as_bytes(),
                    )
                    .map_err(|e| e.to_string())
                }
            }
        }
    }
}

fn mime(p: &Path) -> &'static str {
    match p.extension().and_then(|e| e.to_str()) {
        Some("js") => "text/javascript; charset=utf-8",
        Some("json") => "application/json",
        // The transpiled core module is fetched with `compileStreaming`, which insists on this
        // type and fails with a message about the MIME type rather than about the module.
        Some("wasm") => "application/wasm",
        Some("css") => "text/css; charset=utf-8",
        _ => "application/octet-stream",
    }
}

fn send(s: &mut TcpStream, ctype: &str, body: &[u8]) -> Result<(), String> {
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nCache-Control: no-store\r\n\r\n",
        body.len()
    );
    s.write_all(head.as_bytes()).map_err(|e| e.to_string())?;
    s.write_all(body).map_err(|e| e.to_string())?;
    s.flush().map_err(|e| e.to_string())
}

/// Where a game's viewer bundle is, from a resolved game.
pub fn viz_dir(game: &crate::registry::Game) -> Result<PathBuf, String> {
    let from_checkout = game
        .component
        .parent()
        .map(|d| d.join("viz").join("dist"))
        .filter(|d| d.join("viz.js").exists());
    from_checkout.ok_or_else(|| {
        format!(
            "{} ships no built viewer.\n\
             From a cartridge checkout that is `viz/build.sh`; from a release it is the `viewer` \
             artifact, which this game does not declare yet.",
            game.slug
        )
    })
}

const PAGE: &str = r##"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TinyBrains replay</title>
<style>
  html,body { margin:0; height:100%; background:#f7f7f3; }
  @media (prefers-color-scheme: dark) { html,body { background:#141613; } }
  #app { height:100%; display:flex; }
  #app > .tb-viz { flex:1; border:0; }
  #boot { font:14px/1.6 ui-sans-serif,system-ui,sans-serif; color:#6e736c; padding:24px; }
</style>
</head>
<body>
<div id="app"><div id="boot">decoding the match…</div></div>
<script type="module">
  // The viewer is the cartridge's own bundle, served from viz/dist. The page is a page.
  import { mount, optsFromHash } from "./viz.js";
  try {
    const replay = await (await fetch("./replay.json")).json();
    document.getElementById("boot")?.remove();
    // A link can point at a moment: #turn=84, or #from=40&to=60&autoplay=1. A replay is evidence,
    // and evidence gets cited by turn rather than described.
    await mount("#app", replay, { autoplay: false, ...optsFromHash() });
  } catch (e) {
    document.getElementById("app").innerHTML =
      '<div id="boot">' + String(e && e.message || e) + "</div>";
  }
</script>
</body>
</html>
"##;
