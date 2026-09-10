//! Rebuild a recorded match from its own envelope, play it here, and diff.
//!
//! `wave.rs` copies a loop Orion expresses as a workflow, and copies drift. A replay carries its
//! board, its seed and its seats, which makes the agreement checkable rather than assumed.

use serde_json::{json, Value};

use crate::cartridge::Cartridge;
use crate::cmd::{axon_replica, game_and_rest, open_game};
use crate::matchfile::MatchFile;
use crate::store::short;
use crate::wave;

struct Diff {
    field: String,
    platform: String,
    local: String,
}

pub fn run(args: &[String]) -> Result<(), String> {
    let (slug, rest) = game_and_rest(args)?;
    let path = rest
        .first()
        .ok_or("which replay?\n\n  tinybrains conform replays/quick-0.json")?;
    let recorded: Value = serde_json::from_str(
        &std::fs::read_to_string(path).map_err(|e| format!("cannot read {path}: {e}"))?,
    )
    .map_err(|e| format!("{path}: {e}"))?;

    let spec = match_file_for(&recorded)?;
    let tmp = std::env::temp_dir().join(format!("tinybrains-conform-{}.json", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec(&spec).map_err(|e| e.to_string())?)
        .map_err(|e| format!("{}: {e}", tmp.display()))?;
    let mf = MatchFile::load(&tmp);
    let _ = std::fs::remove_file(&tmp);
    let mf = mf?;

    let game = open_game(Some(
        slug.as_deref()
            .or_else(|| recorded.get("game").and_then(Value::as_str))
            .unwrap_or("ants"),
    ))?;

    // A different engine is not a failed run, it is a meaningless one.
    if let Some(want) = recorded.get("engine_digest").and_then(Value::as_str) {
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

    let cart = Cartridge::open(&game.component).map_err(|e| e.to_string())?;
    let axon = axon_replica()?;
    let report = wave::run(&game, &cart, &mf, &axon, false)?;
    let played = &report.outcomes[0].envelope;

    let diffs = compare(&recorded, played);
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

fn match_file_for(env: &Value) -> Result<Value, String> {
    let seats = env.get("seats").and_then(Value::as_array).ok_or_else(|| {
        "this replay does not name its seats, so the match cannot be rebuilt.\n\
         Envelopes written before seats were carried can be viewed but not re-run."
            .to_string()
    })?;
    if seats.is_empty() {
        return Err("this replay names no seats".to_string());
    }

    let mut out_seats = Vec::new();
    for s in seats {
        let w = s["weights_hash"]
            .as_str()
            .ok_or("a seat in this replay has no weights_hash")?;
        let a = s["adapter_hash"]
            .as_str()
            .ok_or("a seat in this replay has no adapter_hash")?;
        out_seats.push(json!({
            "seat": s["seat"],
            "weights_hash": w,
            "adapter_hash": a,
            "label": s.get("label").and_then(Value::as_str).unwrap_or(short(w)),
        }));
    }

    Ok(json!({
        "vars": { "max_turns": env.get("max_turns").and_then(Value::as_u64).unwrap_or(1000) },
        "rows": [{
            "id": env.get("match_id").and_then(Value::as_str).unwrap_or("conform"),
            "seed": env["seed"],
            "preset": env["preset"],
            "seat_count": out_seats.len(),
            // Verbatim rather than by id: an envelope must reproduce even when the catalogue has
            // moved on, which is why it carries a board at all.
            "map": env["map"],
            "seats": out_seats,
        }],
    }))
}

fn compare(platform: &Value, local: &Value) -> Vec<Diff> {
    let mut out = Vec::new();
    let mut note = |field: &str, a: &Value, b: &Value| {
        if a != b {
            out.push(Diff {
                field: field.to_string(),
                platform: brief(a),
                local: brief(b),
            });
        }
    };

    for f in [
        "seed", "preset", "map", "map_id", "engine_digest", "evaluator_digest", "dialect_version",
        "reason", "turns", "engine_ranks", "scores",
    ] {
        note(f, &platform[f], &local[f]);
    }

    let empty = Vec::new();
    let pd = platform["deltas"].as_array().unwrap_or(&empty);
    let ld = local["deltas"].as_array().unwrap_or(&empty);
    if pd.len() != ld.len() {
        note("deltas.len", &json!(pd.len()), &json!(ld.len()));
    }
    // The FIRST divergence only: after one turn differs every later turn differs for free.
    for (i, (a, b)) in pd.iter().zip(ld.iter()).enumerate() {
        if a != b {
            out.push(Diff {
                field: format!("deltas[{i}] (turn {})", a["t"]),
                platform: brief(a),
                local: brief(b),
            });
            break;
        }
    }
    out
}

fn brief(v: &Value) -> String {
    let s = match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    match s.char_indices().nth(46) {
        Some(_) => {
            let cut = s.char_indices().nth(45).map(|(i, _)| i).unwrap_or(s.len());
            format!("{}…", &s[..cut])
        }
        None => s,
    }
}
