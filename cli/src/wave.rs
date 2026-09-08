//! The wave: claim-free, lease-free, and otherwise Kalam's.
//!
//! This is the one part of the CLI that is a **second implementation** of something the platform
//! already has. Kalam expresses the loop as an Orion workflow of JSONLogic; this expresses it as
//! Rust. Nothing can make those one artifact, so the honest description is "a faithful copy of the
//! wave", and what keeps the copy faithful is that both sides take the same input — a `match.json`
//! is the rows `K_WAVE` reads out of Postgres, so `conform --against-stack` is a diff rather than
//! a translation.
//!
//! # The five things that are Kalam's and not the engine's
//!
//! Each is drawn from `kalam/scripts/gen-kalam.py`. Get one wrong and a local result disagrees
//! with a ladder result **silently**, which is the whole failure mode this file exists to avoid.
//!
//! 1. **`actions` uses the explicit `{m, seat, action}` form**, never the positional one. The
//!    positional form is only correct if every live seat is played, and a forfeited seat is not
//!    sent to the loader at all — so positions stop aligning the moment anyone forfeits.
//! 2. **A forfeited seat is omitted from the play call entirely.** Omission *is* the no-op: the
//!    engine plays the no-op for any seat it is given nothing for, so there is no empty row to
//!    keep aligned and the loader is never asked to run a model whose action is discarded.
//! 3. **Strikes are cumulative across the match, not consecutive** — five missed clocks in a
//!    match, not five in a row. The stricter reading, and the one a competitor cannot game by
//!    hiccupping every fourth turn.
//! 4. **A forfeited seat's rank is `engine_rank + seat_count`**, so two forfeited seats cannot tie
//!    with a seat that played. The engine's own ranks go into the replay envelope untouched, so an
//!    audit can still see what the game thought happened.
//! 5. **`refs` are a flat list**, each carrying its own `m` and `seat`, echoed by the engine and
//!    never inspected. The strike counters ride on them because that is where they have to live.

use std::collections::BTreeMap;

use serde_json::{json, Value};

use crate::cartridge::{Cartridge, Fault};
use crate::matchfile::{MatchFile, Row};
use crate::registry::Game;

pub struct Outcome {
    pub id: String,
    pub reason: String,
    pub turns: u64,
    pub ranks: Vec<i64>,
    pub scores: Vec<i64>,
    pub strikes: Vec<u64>,
    pub map_id: String,
    pub envelope: Value,
}

/// One seat, as it travels: out through `observe`, onto the play row, back on the loader's echoed
/// `ref`, and into the next turn. Neither the engine nor the loader looks inside one.
#[derive(Clone)]
struct Ref {
    m: usize,
    seat: u64,
    weights_hash: String,
    adapter_hash: String,
    strikes: u64,
    forfeited: bool,
}

impl Ref {
    fn to_json(&self) -> Value {
        json!({
            "m": self.m, "seat": self.seat,
            "weights_hash": self.weights_hash, "adapter_hash": self.adapter_hash,
            "strikes": self.strikes, "forfeited": self.forfeited,
        })
    }
}

pub struct Report {
    pub outcomes: Vec<Outcome>,
    pub turns_played: u64,
    pub play_calls: u64,
    /// Seat-turns: one model evaluated for one seat on one turn. The unit a budget is spent in,
    /// and not the same as a play call -- a wave of eight matches asks for sixteen of these at
    /// once, which is the whole point of batching and would make a per-call mean meaningless.
    pub seat_turns: u64,
    pub total_ops: u64,
    pub total_play_ms: u64,
}

pub fn run(
    game: &Game,
    cart: &Cartridge,
    mf: &MatchFile,
    axon: &axon::server::Axon,
    verbose: bool,
) -> Result<Report, String> {
    let max_turns = mf.var("max_turns", game.limit("max_turns", 1000));
    let turn_ms = mf.var("turn_ms", game.limit("turn_ms", 1000));
    let budget_ops = mf.var("budget_ops", game.budget("adapter_ops_max", 1_000_000));
    let strike_ceiling = mf.var("strike_ceiling", 5);

    // ---- hold every distinct model the wave needs, in one call, before anything is played.
    let mut models: Vec<Value> = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for row in &mf.rows {
        for s in &row.seats {
            if seen.insert((s.weights_hash.clone(), s.adapter_hash.clone())) {
                models.push(json!({
                    "weights_hash": s.weights_hash, "adapter_hash": s.adapter_hash
                }));
            }
        }
    }
    let hold: axon::api::LoadRequest =
        serde_json::from_value(json!({ "models": models, "wait_ms": 60000 }))
            .map_err(|e| format!("load request: {e}"))?;
    let held = axon.load(hold);
    let reply = serde_json::to_value(&held).map_err(|e| e.to_string())?;
    for m in reply["models"].as_array().cloned().unwrap_or_default() {
        if m["state"] != "resident" {
            return Err(format!(
                "the loader would not hold a model: {} {}\n  weights {}\n  adapter {}",
                m["state"].as_str().unwrap_or("?"),
                m["reason"].as_str().unwrap_or(""),
                m["weights_hash"].as_str().unwrap_or("?"),
                m["adapter_hash"].as_str().unwrap_or("?"),
            ));
        }
    }

    // ---- open the wave. One worldgen with every seed, which is what makes this a wave and not
    // a loop over matches: one batched play call per turn serves every match a model is in.
    let seeds: Vec<u64> = mf.rows.iter().map(|r| r.seed).collect();
    let maps: Vec<Value> = mf.rows.iter().map(|r| r.map.clone()).collect();
    let mut world = json!({
        "seeds": seeds,
        "preset": mf.rows[0].preset,
        "players": mf.rows[0].seat_count,
        "max_turns": max_turns,
    });
    if maps.iter().any(|m| !m.is_null()) {
        world["maps"] = Value::Array(maps);
    }
    let opened = cart.invoke(&f(game, "worldgen"), &world).map_err(fault)?;
    let mut state = opened["wave_state"].clone();
    let map_ids: Vec<String> = opened["map_ids"]
        .as_array()
        .map(|a| a.iter().map(|v| v.as_str().unwrap_or("").to_string()).collect())
        .unwrap_or_default();

    let mut refs: Vec<Ref> = Vec::new();
    for (m, row) in mf.rows.iter().enumerate() {
        for s in &row.seats {
            refs.push(Ref {
                m,
                seat: s.seat,
                weights_hash: s.weights_hash.clone(),
                adapter_hash: s.adapter_hash.clone(),
                strikes: 0,
                forfeited: false,
            });
        }
    }

    let mut deltas: BTreeMap<usize, Vec<Value>> = BTreeMap::new();
    let mut report = Report {
        outcomes: Vec::new(),
        turns_played: 0,
        play_calls: 0,
        seat_turns: 0,
        total_ops: 0,
        total_play_ms: 0,
    };

    // ---- the loop.
    loop {
        let obs = cart
            .invoke(
                &f(game, "observe"),
                &json!({
                    "wave_state": state,
                    "refs": refs.iter().map(Ref::to_json).collect::<Vec<_>>(),
                }),
            )
            .map_err(fault)?;
        let views = obs["views"].as_array().cloned().unwrap_or_default();
        if views.is_empty() {
            break;
        }

        // Rule 2: a forfeited seat is not sent at all.
        let playing: Vec<&Value> = views
            .iter()
            .filter(|v| !v["ref"]["forfeited"].as_bool().unwrap_or(false))
            .collect();

        let mut acts: Vec<Value> = Vec::new();
        if !playing.is_empty() {
            let rows: Vec<Value> = playing
                .iter()
                .map(|v| {
                    json!({
                        "weights_hash": v["ref"]["weights_hash"],
                        "adapter_hash": v["ref"]["adapter_hash"],
                        "observation": v["view"],
                        "ref": v["ref"],
                    })
                })
                .collect();
            let req: axon::api::PlayRequest = serde_json::from_value(json!({
                "rows": rows, "deadline_ms": turn_ms, "budget_ops": budget_ops
            }))
            .map_err(|e| format!("play request: {e}"))?;
            let played = serde_json::to_value(axon.play(req)).map_err(|e| e.to_string())?;
            report.play_calls += 1;

            for r in played["rows"].as_array().cloned().unwrap_or_default() {
                report.seat_turns += 1;
                report.total_ops += r["ops"].as_u64().unwrap_or(0);
                report.total_play_ms += r["elapsed_ms"].as_u64().unwrap_or(0);
                let m = r["ref"]["m"].as_u64().unwrap_or(0) as usize;
                let seat = r["ref"]["seat"].as_u64().unwrap_or(0);
                let action = r.get("action").cloned().unwrap_or(Value::Null);
                let missed = action.is_null();

                // Rule 1: the explicit form. A seat that is simply absent plays the no-op.
                if !missed {
                    acts.push(json!({ "m": m, "seat": seat, "action": action }));
                }
                // Rule 3: cumulative, and the ceiling forfeits the seat for the rest of the match.
                if let Some(rf) = refs.iter_mut().find(|x| x.m == m && x.seat == seat) {
                    if missed {
                        rf.strikes += 1;
                        if rf.strikes >= strike_ceiling {
                            rf.forfeited = true;
                        }
                        if verbose {
                            eprintln!(
                                "  match {m} seat {seat}: no action ({}) -- strike {}{}",
                                r["error"].as_str().unwrap_or("?"),
                                rf.strikes,
                                if rf.forfeited { ", forfeited" } else { "" }
                            );
                        }
                    }
                }
            }
        }

        let stepped = cart
            .invoke(&f(game, "step"), &json!({ "wave_state": state, "actions": acts }))
            .map_err(fault)?;
        state = stepped["wave_state"].clone();
        report.turns_played += 1;
        for d in stepped["replay_delta"].as_array().cloned().unwrap_or_default() {
            let m = d["m"].as_u64().unwrap_or(0) as usize;
            deltas.entry(m).or_default().push(d);
        }
    }

    // ---- results. Every match has ended, so one `finish` answers the whole wave.
    let fin = cart
        .invoke(&f(game, "finish"), &json!({ "wave_state": state }))
        .map_err(fault)?;
    let results = fin["results"].as_array().cloned().unwrap_or_default();

    for (m, row) in mf.rows.iter().enumerate() {
        let r = results
            .iter()
            .find(|r| r["m"].as_u64() == Some(m as u64))
            .ok_or_else(|| format!("the engine returned no result for match {m}"))?;
        let engine_ranks: Vec<i64> = r["ranks"]
            .as_array()
            .map(|a| a.iter().map(|v| v.as_i64().unwrap_or(0)).collect())
            .unwrap_or_default();
        let scores: Vec<i64> = r["scores"]
            .as_array()
            .map(|a| a.iter().map(|v| v.as_i64().unwrap_or(0)).collect())
            .unwrap_or_default();

        // Rule 4: forfeits rank last, and not all at the same last.
        let seat_count = row.seat_count as i64;
        let mut ranks = engine_ranks.clone();
        let mut strikes = vec![0u64; row.seats.len()];
        for rf in refs.iter().filter(|x| x.m == m) {
            let i = rf.seat as usize;
            if i < ranks.len() {
                if rf.forfeited {
                    ranks[i] = engine_ranks[i] + seat_count;
                }
            }
            if i < strikes.len() {
                strikes[i] = rf.strikes;
            }
        }

        let map_id = map_ids.get(m).cloned().unwrap_or_default();
        let envelope = json!({
            "match_id": row.id,
            "seed": row.seed,
            "preset": row.preset,
            "map_id": r["map_id"],
            "map": r["map"],
            "max_turns": max_turns,
            "engine_digest": game.engine_digest,
            "evaluator_digest": axon::dialect::evaluator_digest(),
            "dialect_version": axon::dialect::DIALECT_VERSION,
            // The engine's own ranks, before forfeits are applied.
            "engine_ranks": engine_ranks,
            "scores": scores,
            "reason": r["reason"],
            "turns": r["turns"],
            // Local only, and absent from Kalam's envelope: which model sat where. The platform
            // joins that from `match_seats`; on a laptop there is no row to join to, and a replay
            // nobody can attribute is a replay nobody can learn from.
            "seats": row.seats.iter().map(|s| json!({
                "seat": s.seat, "label": s.label,
                "weights_hash": s.weights_hash, "adapter_hash": s.adapter_hash,
            })).collect::<Vec<_>>(),
            "deltas": deltas.get(&m).cloned().unwrap_or_default(),
        });

        report.outcomes.push(Outcome {
            id: row.id.clone(),
            reason: r["reason"].as_str().unwrap_or("?").to_string(),
            turns: r["turns"].as_u64().unwrap_or(0),
            ranks,
            scores,
            strikes,
            map_id,
            envelope,
        });
    }

    let unload: axon::api::UnloadRequest =
        serde_json::from_value(json!({ "models": models })).map_err(|e| e.to_string())?;
    axon.unload(unload);

    Ok(report)
}

fn f(game: &Game, name: &str) -> String {
    // The five function names live in the cartridge's own namespace, which is how two games avoid
    // colliding. `tb.<slug>.<label>` is the platform's convention, not this binary's knowledge of
    // any particular game.
    format!("tb.{}.{}", game.slug, name)
}

fn fault(e: Fault) -> String {
    format!("the cartridge refused: {e}")
}

/// Rows in one file must share a preset and a seat count, exactly as a claimed wave does: the
/// claim fills a wave from rows sharing the first row's preset, and `worldgen` takes one preset
/// for the whole call.
pub fn check_uniform(rows: &[Row]) -> Result<(), String> {
    let first = &rows[0];
    for r in rows.iter().skip(1) {
        if r.preset != first.preset {
            return Err(format!(
                "a wave is one preset: row '{}' is '{}' and row '{}' is '{}'.\n\
                 Split them into two files, or run them one after the other.",
                first.id, first.preset, r.id, r.preset
            ));
        }
        if r.seat_count != first.seat_count {
            return Err(format!(
                "a wave is one seat count: '{}' has {} and '{}' has {}",
                first.id, first.seat_count, r.id, r.seat_count
            ));
        }
    }
    Ok(())
}
