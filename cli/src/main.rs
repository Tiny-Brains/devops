//! tinybrains — run a TinyBrains match on your own machine.
//!
//! One binary, any game. It loads the cartridge component through wasmtime, evaluates adapters and
//! ONNX graphs through axon as a library, and writes the same replay envelope Kalam writes — none
//! of which are re-implementations: the component is the file the ladder plays, axon is the crate
//! the fleet runs, and the envelope is the one the viewer reads.
//!
//! What it is *not* is the wave. `wave.rs` is a second implementation of a loop Orion expresses as
//! a workflow, and its docstring names the five behaviours it has to copy exactly. Until
//! conformance runs against a live stack, "the same as production" is a claim about artifacts and
//! not about that loop.

mod cartridge;
mod conform;
mod matchfile;
mod registry;
mod store;
mod wave;

use std::path::PathBuf;

const USAGE: &str = "\
tinybrains -- run a TinyBrains match locally

  tinybrains <match.json> [--out DIR] [-v]   play a wave; write one replay per row
  tinybrains run <match.json> [...]          the same, spelled out
  tinybrains games                           what is registered, and at which digest
  tinybrains maps [GAME]                     the boards a game is played on
  tinybrains maps export [GAME] [DIR]        write those boards out as files
  tinybrains conform <replay.json>           replay a recorded match here, and diff

Options
  --out DIR      where replays go (default: ./replays)
  --game SLUG    which game (default: the file's `game`, else ants)
  -v, --verbose  print every strike and forfeit as it happens
";

fn main() {
    if let Err(e) = real_main() {
        eprintln!("tinybrains: {e}");
        std::process::exit(1);
    }
}

fn real_main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args[0] == "-h" || args[0] == "--help" {
        print!("{USAGE}");
        return Ok(());
    }

    match args[0].as_str() {
        "games" => cmd_games(),
        "maps" => cmd_maps(&args[1..]),
        "run" => cmd_run(&args[1..]),
        "conform" => cmd_conform(&args[1..]),
        // The shorthand the design asks for: `tinybrains match.json`. Anything that is not a known
        // verb and looks like a file is one.
        other if other.ends_with(".json") => cmd_run(&args),
        other => Err(format!("unknown command '{other}'\n\n{USAGE}")),
    }
}

// ---------------------------------------------------------------- games

fn open_game(slug: Option<&str>) -> Result<registry::Game, String> {
    let path = registry::Registry::find()?;
    let reg = registry::Registry::load(&path)?;
    let slug = match slug {
        Some(s) => s.to_string(),
        None => reg
            .games
            .keys()
            .next()
            .cloned()
            .ok_or("the registry lists no games")?,
    };
    reg.resolve(&slug, &path)
}

fn cmd_games() -> Result<(), String> {
    let path = registry::Registry::find()?;
    let reg = registry::Registry::load(&path)?;
    println!("registry {}", path.display());
    println!("evaluator {} (dialect {})", axon::dialect::evaluator_digest(), axon::dialect::DIALECT_VERSION);
    println!();
    for slug in reg.games.keys() {
        match reg.resolve(slug, &path) {
            Ok(g) => {
                let presets: Vec<String> = g
                    .manifest
                    .get("presets")
                    .and_then(|p| p.as_array())
                    .map(|a| {
                        a.iter()
                            .map(|p| {
                                format!(
                                    "{} ({} seats, {} boards)",
                                    p["name"].as_str().unwrap_or("?"),
                                    p["players"].as_u64().unwrap_or(0),
                                    p["maps"].as_u64().unwrap_or(0)
                                )
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                println!("{}  {}", slug, g.name);
                println!("    engine  {}", g.engine_digest);
                println!("    from    {}", g.source);
                println!("    presets {}", presets.join(", "));
                println!("    boards  {}", g.catalogue().len());
            }
            Err(e) => println!("{slug}  UNRESOLVED: {e}"),
        }
    }
    Ok(())
}

// ---------------------------------------------------------------- maps

fn cmd_maps(args: &[String]) -> Result<(), String> {
    let export = args.first().map(|s| s == "export").unwrap_or(false);
    let rest = if export { &args[1..] } else { args };
    let slug = rest.first().filter(|s| !s.starts_with('-')).map(String::as_str);
    let game = open_game(slug)?;

    if !export {
        println!("{}  {} boards", game.slug, game.catalogue().len());
        for m in game.catalogue() {
            println!(
                "  {:<12} {:<9} {:>3}x{:<3} {} seats  food {:<3} {}",
                m["id"].as_str().unwrap_or("?"),
                m["preset"].as_str().unwrap_or("?"),
                m["rows"].as_u64().unwrap_or(0),
                m["cols"].as_u64().unwrap_or(0),
                m["players"].as_u64().unwrap_or(0),
                m["food_target"].as_u64().unwrap_or(0),
                &m["sha256"].as_str().unwrap_or("")[..19.min(m["sha256"].as_str().unwrap_or("").len())],
            );
        }
        return Ok(());
    }

    let dir = PathBuf::from(
        rest.get(1).cloned().unwrap_or_else(|| "maps".to_string()),
    );
    let src = game
        .maps_dir
        .as_ref()
        .ok_or("this game's boards are not available as files from where it resolved")?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;

    let mut n = 0;
    for m in game.catalogue() {
        let id = m["id"].as_str().unwrap_or_default();
        let want = m["sha256"].as_str().unwrap_or_default();
        let from = src.join(format!("{id}.json"));
        let bytes = std::fs::read(&from).map_err(|e| format!("{}: {e}", from.display()))?;
        // The catalogue's digest is over the file exactly as committed, so an export that does not
        // match is a stale checkout and is said so rather than written out.
        let got = store::digest(&bytes);
        if got != want {
            return Err(format!(
                "{}\n  catalogue says {want}\n  the file is    {got}\n\
                 the checkout and its manifest disagree -- rebuild the cartridge",
                from.display()
            ));
        }
        std::fs::write(dir.join(format!("{id}.json")), &bytes)
            .map_err(|e| format!("{}: {e}", dir.display()))?;
        n += 1;
    }
    println!("wrote {n} boards to {}", dir.display());
    Ok(())
}

// ---------------------------------------------------------------- run

fn cmd_run(args: &[String]) -> Result<(), String> {
    let mut file: Option<PathBuf> = None;
    let mut out = PathBuf::from("replays");
    let mut slug: Option<String> = None;
    let mut verbose = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--out" => {
                i += 1;
                out = PathBuf::from(args.get(i).ok_or("--out needs a directory")?);
            }
            "--game" => {
                i += 1;
                slug = Some(args.get(i).ok_or("--game needs a slug")?.clone());
            }
            "-v" | "--verbose" => verbose = true,
            other if !other.starts_with('-') => file = Some(PathBuf::from(other)),
            other => return Err(format!("unknown option '{other}'\n\n{USAGE}")),
        }
        i += 1;
    }
    let file = file.ok_or("which match file?\n\n  tinybrains matches/quick.json")?;

    let mf = matchfile::MatchFile::load(&file)?;
    wave::check_uniform(&mf.rows)?;
    let game = open_game(Some(slug.as_deref().unwrap_or(&mf.game)))?;

    // A file may pin the engine it was recorded against. If it does and we have another, say so:
    // the same seeds on a different engine are a different match, and silently playing it would
    // make a comparison meaningless.
    if let Some(want) = &mf.engine_digest {
        if want != &game.engine_digest {
            eprintln!(
                "warning: {} names engine {want}\n         but {} resolves to {}\n\
                 \x20        the same seeds on a different engine are a different match",
                file.display(),
                game.slug,
                game.engine_digest
            );
        }
    }

    let cart = cartridge::Cartridge::open(&game.component).map_err(|e| e.to_string())?;
    let axon = axon_replica()?;

    println!(
        "{} on {} -- {} match{}, preset {}, engine {}",
        game.slug,
        game.name,
        mf.rows.len(),
        if mf.rows.len() == 1 { "" } else { "es" },
        mf.rows[0].preset,
        &game.engine_digest[..19]
    );

    let report = wave::run(&game, &cart, &mf, &axon, verbose)?;

    std::fs::create_dir_all(&out).map_err(|e| format!("{}: {e}", out.display()))?;
    println!();
    for o in &report.outcomes {
        let path = out.join(format!("{}.json", o.id));
        std::fs::write(
            &path,
            serde_json::to_vec(&o.envelope).map_err(|e| e.to_string())?,
        )
        .map_err(|e| format!("{}: {e}", path.display()))?;

        let seats: Vec<String> = mf
            .rows
            .iter()
            .find(|r| r.id == o.id)
            .map(|r| {
                r.seats
                    .iter()
                    .enumerate()
                    .map(|(i, s)| {
                        format!(
                            "{}={}",
                            s.label,
                            o.ranks.get(i).copied().unwrap_or(0)
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        println!(
            "{:<14} {:<10} {:>4} turns  board {:<10} ranks {}  scores {:?}{}",
            o.id,
            o.reason,
            o.turns,
            o.map_id,
            seats.join(" "),
            o.scores,
            if o.strikes.iter().any(|&s| s > 0) {
                format!("  strikes {:?}", o.strikes)
            } else {
                String::new()
            }
        );
        println!("{:<14} -> {}", "", path.display());
    }

    if report.play_calls > 0 {
        println!();
        println!(
            "{} turns, {} play calls, mean {} ops and {} ms per seat-turn",
            report.turns_played,
            report.play_calls,
            report.total_ops / report.play_calls.max(1),
            report.total_play_ms / report.play_calls.max(1),
        );
    }
    // Local runs are more permissive than admission: any path or URL loads here, and no class cap
    // is enforced. Say so, rather than letting it be discovered at submission.
    println!("this is not an admission check -- `tinybrains check` is the gate");
    Ok(())
}

/// A replica-mode axon over the local model store. The one config difference from the fleet.
fn axon_replica() -> Result<axon::server::Axon, String> {
    let dir = store::models_dir()?;
    let cfg = axon::config::Config {
        mode: axon::config::Mode::Replica,
        bind: "127.0.0.1:0".to_string(),
        auth_token: None,
        memory_budget_bytes: 4 << 30,
        max_weights_bytes: 256 << 20,
        max_adapter_bytes: 4 << 20,
        default_idle_ttl_s: 900,
        threads: 1,
        adapter_threads: 1,
        max_in_flight: 1,
        store: axon::config::StoreSpec::Dir(dir),
        // Empty, exactly as on a replica: only an admission instance reaches the internet, and
        // this process is not one. A URL in a match file is fetched by the CLI before the loader
        // is asked for anything, so the loader still never reaches out.
        fetch_allow_hosts: Vec::new(),
    };
    Ok(axon::server::Axon::new(cfg))
}

// ---------------------------------------------------------------- conform

/// Rebuild a recorded match from its own envelope, play it here, and diff.
///
/// This is the mechanism behind the only claim in this binary that cannot be argued from
/// artifacts: `wave.rs` copies a loop Orion expresses as a workflow, and copies drift. A replay
/// carries its board, its seed and its seats, so it is a complete description of a match — which
/// makes agreement checkable rather than assumed.
fn cmd_conform(args: &[String]) -> Result<(), String> {
    let path = args
        .first()
        .filter(|a| !a.starts_with('-'))
        .ok_or("which replay?\n\n  tinybrains conform replays/quick-0.json")?;
    let recorded: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(path).map_err(|e| format!("cannot read {path}: {e}"))?,
    )
    .map_err(|e| format!("{path}: {e}"))?;

    let spec = conform::match_file_for(&recorded)?;
    let tmp = std::env::temp_dir().join(format!("tinybrains-conform-{}.json", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec(&spec).map_err(|e| e.to_string())?)
        .map_err(|e| format!("{}: {e}", tmp.display()))?;

    let mf = matchfile::MatchFile::load(&tmp)?;
    let _ = std::fs::remove_file(&tmp);
    let game = open_game(Some(&recorded.get("game").and_then(|v| v.as_str()).unwrap_or("ants")))?;

    // A different engine is not a failed conformance run, it is a meaningless one: the same seeds
    // on another engine are another match. Say which, and stop.
    if let Some(want) = recorded.get("engine_digest").and_then(|v| v.as_str()) {
        if want != game.engine_digest {
            return Err(format!(
                "this replay was played on engine\n  {want}\nand {} resolves to\n  {}\n\
                 The same seeds on a different engine are a different match, so there is nothing \
                 to compare. Check out the cartridge at that digest and try again.",
                game.slug, game.engine_digest
            ));
        }
    }

    println!(
        "replaying {} -- seed {}, preset {}, board {}",
        path,
        recorded["seed"],
        recorded["preset"].as_str().unwrap_or("?"),
        recorded["map_id"].as_str().unwrap_or("?"),
    );

    let cart = cartridge::Cartridge::open(&game.component).map_err(|e| e.to_string())?;
    let axon = axon_replica()?;
    let report = wave::run(&game, &cart, &mf, &axon, false)?;
    let played = &report.outcomes[0].envelope;

    let diffs = conform::compare(&recorded, played);
    println!();
    if diffs.is_empty() {
        let n = recorded["deltas"].as_array().map(|a| a.len()).unwrap_or(0);
        println!("IDENTICAL -- every field, and all {n} turns of the action stream.");
        println!("The local wave and the recorded one made the same match from the same input.");
        return Ok(());
    }
    println!("DIFFERS in {} place(s):", diffs.len());
    for d in &diffs {
        println!("  {}", d.field);
        println!("    recorded {}", d.platform);
        println!("    here     {}", d.local);
    }
    println!();
    println!(
        "A difference in the action stream is the one that matters: ranks and scores can agree \
         while the match that produced them differs. wave.rs names the five behaviours it has to \
         copy from Kalam -- start there."
    );
    Err("conformance failed".to_string())
}
