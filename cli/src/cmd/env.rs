//! `tinybrains env` — the cartridge as a batched environment, over JSON Lines.
//!
//! **stdout is the protocol.** Every diagnostic goes to stderr, because a stray `println!` here is
//! a parse error in somebody's trainer rather than a cosmetic bug.
//!
//! One JSON object per line in each direction. The first line out is `hello`, which carries the
//! engine and evaluator digests the run is against — a model card that cannot name the engine it
//! was trained on is a model card that cannot be reproduced.
//!
//! ```jsonc
//! ← {"ok":true,"hello":{"game":"ants","engine_digest":"sha256:…","presets":[…],"waves":4,…}}
//! → {"op":"observe"}
//! ← {"ok":true,"turn":0,"seats":[{"w":0,"m":0,"ep":0,"seat":0,"turn":0,"obs":{…}},…],
//!    "scores":[{"w":0,"m":0,"ep":0,"turns":0,"scores":[0,0]},…],"ended":[]}
//! → {"op":"step","actions":["NNE-","-W",…]}      // positional, one entry per seat above
//! ← {"ok":true,"turn":1,"seats":[…],"scores":[…],
//!    "ended":[{"ep":3,"ranks":[1,2],"scores":[4,-1],"reason":"lone_survivor","turns":312,…}]}
//! → {"op":"close"}
//! ```
//!
//! Every error is fatal: one `{"ok":false,"error":…}` line, then exit 1. A training loop that has
//! lost track of the seat order has no correct way to continue, and a recoverable-looking failure
//! is how a run ends up quietly training on misaligned actions.

use std::io::{BufRead, Write};

use serde_json::{Value, json};

use crate::cartridge::Cartridge;
use crate::cmd::open_game;
use crate::env::{Config, Pool, presets_of};
use crate::store::short;

pub fn run(args: &[String]) -> Result<(), String> {
    let mut slug: Option<String> = None;
    let mut preset: Option<String> = None;
    let mut map: Option<String> = None;
    let mut waves = 4usize;
    let mut matches_per_wave = 16usize;
    let mut max_turns: Option<u64> = None;
    let mut seed = 1u64;
    let mut scores_every_turn = true;

    // Every option this command takes has a value, so the step is always two and the arms differ
    // only in where the value lands.
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--game" => slug = Some(value(args, i)?),
            "--preset" => preset = Some(value(args, i)?),
            "--map" => map = Some(value(args, i)?),
            "--waves" => waves = num(&value(args, i)?)? as usize,
            "--matches-per-wave" => matches_per_wave = num(&value(args, i)?)? as usize,
            "--max-turns" => max_turns = Some(num(&value(args, i)?)?),
            "--seed" => seed = num(&value(args, i)?)?,
            "--scores" => match value(args, i)?.as_str() {
                "every" => scores_every_turn = true,
                "end" => scores_every_turn = false,
                other => return Err(format!("--scores is 'every' or 'end', not '{other}'")),
            },
            other => return Err(format!("unknown option '{other}'\n\n{}", crate::USAGE)),
        }
        i += 2;
    }
    if waves == 0 || matches_per_wave == 0 {
        return Err("--waves and --matches-per-wave must both be at least 1".to_string());
    }

    let game = open_game(slug.as_deref())?;
    let cart = Cartridge::open(&game.component).map_err(|e| e.to_string())?;
    let presets = presets_of(&game, preset.as_deref())?;
    let max_turns = max_turns.unwrap_or_else(|| game.limit("max_turns", 1000));

    let cfg = Config {
        waves,
        matches_per_wave,
        max_turns,
        seed,
        presets: presets.clone(),
        map: map.clone(),
        scores_every_turn,
    };
    let mut pool = Pool::open(&game, &cart, cfg)?;

    eprintln!(
        "{} on {} -- {} wave{} x {} matches, preset{} {}, engine {}",
        game.slug,
        game.name,
        waves,
        if waves == 1 { "" } else { "s" },
        matches_per_wave,
        if presets.len() == 1 { "" } else { "s" },
        presets.iter().map(|p| p.name.as_str()).collect::<Vec<_>>().join(","),
        short(&game.engine_digest)
    );
    eprintln!("this is not the referee: no deadline, no strikes, no forfeits");

    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    say(
        &mut out,
        &json!({
            "ok": true,
            "hello": {
                "game": game.slug,
                "engine_digest": game.engine_digest,
                "evaluator_digest": axon::dialect::evaluator_digest(),
                "dialect_version": axon::dialect::DIALECT_VERSION,
                "presets": presets.iter()
                    .map(|p| json!({ "name": p.name, "players": p.players }))
                    .collect::<Vec<_>>(),
                "limits": game.manifest.get("limits").cloned().unwrap_or(Value::Null),
                "budgets": game.manifest.get("budgets").cloned().unwrap_or(Value::Null),
                "waves": waves,
                "matches_per_wave": matches_per_wave,
                "max_turns": max_turns,
                "seed": seed,
                "map": map,
                "scores": if scores_every_turn { "every" } else { "end" },
            }
        }),
    )?;

    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let line = line.map_err(|e| format!("stdin: {e}"))?;
        if line.trim().is_empty() {
            continue;
        }
        match turn(&mut pool, &line) {
            Ok(None) => break,
            Ok(Some(reply)) => say(&mut out, &reply)?,
            Err(e) => {
                // Report on the protocol channel before dying, so a trainer blocked on a read sees
                // the reason rather than a closed pipe.
                let _ = say(&mut out, &json!({ "ok": false, "error": e }));
                return Err(e);
            }
        }
    }

    eprintln!(
        "{} steps, {} seat-turns, {} episodes finished",
        pool.steps, pool.seat_turns, pool.episodes
    );
    Ok(())
}

/// One request. `Ok(None)` means the client asked to stop.
fn turn(pool: &mut Pool, line: &str) -> Result<Option<Value>, String> {
    let req: Value = serde_json::from_str(line).map_err(|e| format!("not JSON: {e}"))?;
    let op = req["op"].as_str().unwrap_or("");

    let ended = match op {
        "observe" => Vec::new(),
        "step" => {
            let actions = req["actions"]
                .as_array()
                .ok_or("step needs an `actions` array, positionally aligned with the last seats")?;
            pool.step(actions)?
        }
        "close" => return Ok(None),
        "" => return Err("every request needs an `op`".to_string()),
        other => return Err(format!("unknown op '{other}' (observe, step, close)")),
    };

    let (seats, scores) = pool.observe()?;
    Ok(Some(json!({
        "ok": true,
        "turn": pool.steps,
        "seats": seats,
        "scores": scores,
        "ended": ended,
    })))
}

fn say(out: &mut impl Write, v: &Value) -> Result<(), String> {
    let mut line = serde_json::to_vec(v).map_err(|e| e.to_string())?;
    line.push(b'\n');
    out.write_all(&line).map_err(|e| format!("stdout: {e}"))?;
    out.flush().map_err(|e| format!("stdout: {e}"))
}

fn value(args: &[String], i: usize) -> Result<String, String> {
    args.get(i + 1).cloned().ok_or_else(|| format!("{} needs a value", args[i]))
}

fn num(s: &str) -> Result<u64, String> {
    s.parse().map_err(|_| format!("'{s}' is not a whole number"))
}
