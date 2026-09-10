use serde_json::Value;

use crate::cmd::open_game;
use crate::serve;

pub fn run(args: &[String]) -> Result<(), String> {
    let mut path: Option<String> = None;
    let mut open = true;
    let mut slug: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--no-open" => open = false,
            "--game" => {
                i += 1;
                slug = Some(args.get(i).ok_or("--game needs a slug")?.clone());
            }
            other if !other.starts_with('-') => path = Some(other.to_string()),
            other => return Err(format!("unknown option '{other}'\n\n{}", crate::USAGE)),
        }
        i += 1;
    }
    let path = path.ok_or("which replay?\n\n  tinybrains view replays/quick-0.json")?;
    let text = std::fs::read_to_string(&path).map_err(|e| format!("cannot read {path}: {e}"))?;
    let replay: Value = serde_json::from_str(&text).map_err(|e| format!("{path}: {e}"))?;

    let game = open_game(Some(
        slug.as_deref().or_else(|| replay.get("game").and_then(Value::as_str)).unwrap_or("ants"),
    ))?;
    let viz = serve::viz_dir(&game)?;

    // A viewer built against another engine re-simulates a match this one did not play: it would
    // look right and be wrong.
    let built = std::fs::read_to_string(viz.join("engine.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v["engine_digest"].as_str().map(str::to_string));
    if let (Some(built), Some(played)) =
        (built.as_deref(), replay.get("engine_digest").and_then(Value::as_str))
        && built != played
    {
        eprintln!(
            "warning: this replay was played on\n           {played}\n\
                 \x20        and the viewer was built against\n           {built}\n\
                 \x20        it will re-simulate with the wrong engine -- rebuild viz/"
        );
    }

    println!(
        "{} -- seed {}, board {}, {} turns, {}",
        path,
        replay["seed"],
        replay["map_id"].as_str().unwrap_or("?"),
        replay["turns"],
        replay["reason"].as_str().unwrap_or("?")
    );
    serve::serve(&viz, &text, open)
}
