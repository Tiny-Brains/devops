//! `conform` — the only thing that keeps this binary honest.
//!
//! `wave.rs` is a second implementation of a loop Orion expresses as a workflow of JSONLogic.
//! Nothing can make those one artifact, so "the local runner agrees with the ladder" is a claim
//! that has to be *checked* rather than argued, and this is the check: take a replay the platform
//! wrote, rebuild the match from the envelope alone, play it here, and diff.
//!
//! It works because the envelope is self-sufficient in both senses. It carries the board, so the
//! world can be rebuilt without a catalogue; and it names its seats by hash, so the same models
//! can be held. Everything else — seed, preset, turn limit, engine digest — was already there.
//!
//! A difference in `deltas` is the one that matters. Ranks and scores can agree while the match
//! that produced them differs, so the comparison is turn by turn: the action stream is what the
//! two implementations actually decided, and it is where a strike rule copied wrongly shows up.

use serde_json::{json, Value};

pub struct Diff {
    pub field: String,
    pub platform: String,
    pub local: String,
}

/// Build the match file that would reproduce this envelope.
pub fn match_file_for(env: &Value) -> Result<Value, String> {
    let seats = env
        .get("seats")
        .and_then(|v| v.as_array())
        .ok_or_else(|| {
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
            "label": s.get("label").and_then(|v| v.as_str()).unwrap_or(&w[..19.min(w.len())]),
        }));
    }

    Ok(json!({
        "vars": {
            "max_turns": env.get("max_turns").and_then(|v| v.as_u64()).unwrap_or(1000),
        },
        "rows": [{
            "id": env.get("match_id").and_then(|v| v.as_str()).unwrap_or("conform"),
            "seed": env["seed"],
            "preset": env["preset"],
            "seat_count": out_seats.len(),
            // The board, verbatim from the envelope rather than by id: an envelope must reproduce
            // even when the catalogue has moved on, which is the whole reason it carries one.
            "map": env["map"],
            "seats": out_seats,
        }],
    }))
}

/// Compare what the platform recorded with what this machine just played.
pub fn compare(platform: &Value, local: &Value) -> Vec<Diff> {
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

    for f in ["seed", "preset", "map_id", "engine_digest", "evaluator_digest",
              "dialect_version", "reason", "turns", "engine_ranks", "scores"] {
        note(f, &platform[f], &local[f]);
    }
    note("map", &platform["map"], &local["map"]);

    // The action stream, turn by turn. Reported as the FIRST divergence rather than as a count,
    // because after one turn differs every later turn differs for free and the first one is the
    // only one that says anything.
    let empty = Vec::new();
    let pd = platform["deltas"].as_array().unwrap_or(&empty);
    let ld = local["deltas"].as_array().unwrap_or(&empty);
    if pd.len() != ld.len() {
        note("deltas.len", &json!(pd.len()), &json!(ld.len()));
    }
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
    if s.len() > 46 {
        format!("{}…", &s[..45])
    } else {
        s
    }
}
