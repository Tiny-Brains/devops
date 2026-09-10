//! The training environment: `worldgen`, `observe`, `step`, `finish` — and deliberately nothing
//! else.
//!
//! **This is not the referee, and the difference is the whole point.** `wave.rs` is a second
//! implementation of Kalam's wave and is kept honest by `tinybrains conform`; this is not a third.
//! It has no strikes, no turn deadline, no forfeits, no model loader and no replay envelope,
//! because a training loop has no use for any of them — and because a copy that carried half of
//! Kalam's rules would be a copy that drifts. What it has is the four cartridge functions and a
//! pool that keeps them busy.
//!
//! Three consequences follow, and a trainer must know all three:
//!
//! 1. **A policy that trains here can still fail at play.** The deadline and the strike ceiling are
//!    real and are applied by Kalam, not here. `tinybrains check` and a real `tinybrains <match>`
//!    are the gates; this is not one.
//! 2. **Actions are positional**, over the live seats in the order `observe` returned them. That is
//!    the game protocol's own rule (`ants/docs/protocol.md` §1), and it is *correct here* precisely
//!    because a training env never forfeits a seat: every live seat is played every turn, so the
//!    positional form never misaligns. Kalam needs the explicit `{m, seat, action}` form because it
//!    omits forfeited seats entirely; needing it is the symptom of a rule this file does not have.
//! 3. **Scores are visible to the trainer and never to the policy.** `finish` answers live scores
//!    for a match that has not ended — only `map` is gated on `done` — so an exact per-turn reward
//!    costs one extra invocation and no change to the cartridge. Handing that to a value function
//!    while the policy sees only the fog-filtered view is asymmetric actor-critic, not a hole in
//!    the fog: nothing on this path reaches a model's input.
//!
//! **Nothing here knows what game it is running.** Five function names, `cartridge.json` for the
//! presets and the seat counts, and JSON in both directions.

use serde_json::{json, Value};

use crate::cartridge::{Cartridge, Fault};
use crate::registry::Game;

/// A preset as the manifest declares it. Seats are a property of the board, so `players` is passed
/// to `worldgen` to be *checked* rather than to be obeyed.
#[derive(Clone)]
pub struct Preset {
    pub name: String,
    pub players: u64,
}

pub struct Config {
    /// Independent waves held at once. Each is its own `wave_state` and advances on its own clock,
    /// which is what keeps the live-seat count from collapsing when one wave runs long.
    pub waves: usize,
    pub matches_per_wave: usize,
    pub max_turns: u64,
    /// The root seed. Every board and every food respawn descends from it, so a run is reproducible
    /// from this number and the action stream and nothing else.
    pub seed: u64,
    /// Cycled across wave slots. One `worldgen` call is one preset, so a mixed pool mixes by wave.
    pub presets: Vec<Preset>,
    /// Training only. The ladder cannot name a board — pairing assigns the seed and the seed picks
    /// the board — so this is a facility a competitor has locally and never in a rated match.
    pub map: Option<String>,
    pub scores_every_turn: bool,
}

/// One wave slot. It is refilled in place when every match in it has ended, so `w` identifies a
/// slot for the life of the process and `ep` identifies a match.
struct Wave {
    state: Value,
    preset: String,
    seeds: Vec<u64>,
    /// Monotonic per match, across refills: the only stable key for a trajectory. `(w, m)` is not
    /// one, because a refill reuses both.
    eps: Vec<u64>,
    map_ids: Vec<String>,
    done: Vec<bool>,
    turn: u64,
}

pub struct Pool<'a> {
    game: &'a Game,
    cart: &'a Cartridge,
    cfg: Config,
    waves: Vec<Wave>,
    next_seed: u64,
    next_ep: u64,
    /// Live seats per wave slot as of the last `observe`, which is how a flat action list is cut
    /// back into per-wave calls. Held rather than recomputed: `step` must split exactly the way
    /// `observe` joined, and deriving it twice is how the two would come to disagree.
    last_counts: Vec<usize>,
    pub steps: u64,
    pub seat_turns: u64,
    pub episodes: u64,
}

impl<'a> Pool<'a> {
    pub fn open(game: &'a Game, cart: &'a Cartridge, cfg: Config) -> Result<Pool<'a>, String> {
        if cfg.presets.is_empty() {
            return Err(format!("{} declares no presets", game.slug));
        }
        let mut pool = Pool {
            game,
            cart,
            waves: Vec::new(),
            next_seed: cfg.seed,
            next_ep: 0,
            last_counts: vec![0; cfg.waves],
            steps: 0,
            seat_turns: 0,
            episodes: 0,
            cfg,
        };
        for w in 0..pool.cfg.waves {
            let fresh = pool.worldgen(w)?;
            pool.waves.push(fresh);
        }
        Ok(pool)
    }

    /// A fresh wave in slot `w`. Seeds advance monotonically so no two matches in a run share one,
    /// and the preset follows the slot so a mixed pool stays mixed after a refill.
    fn worldgen(&mut self, w: usize) -> Result<Wave, String> {
        let preset = self.cfg.presets[w % self.cfg.presets.len()].clone();
        let seeds: Vec<u64> = (0..self.cfg.matches_per_wave)
            .map(|_| {
                let s = self.next_seed;
                self.next_seed += 1;
                s
            })
            .collect();
        let eps: Vec<u64> = (0..self.cfg.matches_per_wave)
            .map(|_| {
                let e = self.next_ep;
                self.next_ep += 1;
                e
            })
            .collect();

        let mut req = json!({
            "seeds": seeds,
            "preset": preset.name,
            "players": preset.players,
            "max_turns": self.cfg.max_turns,
        });
        if let Some(id) = &self.cfg.map {
            req["map"] = json!(id);
        }
        let out = self.invoke("worldgen", &req)?;

        Ok(Wave {
            state: out["wave_state"].clone(),
            preset: preset.name,
            seeds,
            eps,
            map_ids: strings(&out["map_ids"]),
            done: vec![false; self.cfg.matches_per_wave],
            turn: 0,
        })
    }

    /// Every live seat in the pool, and — when asked for — every live match's current score.
    ///
    /// The order is the order `step` will read actions in: wave slot, then the cartridge's own
    /// order within a wave. Both sides derive it from `wave_state`, which is what the protocol
    /// requires of a positional action list.
    pub fn observe(&mut self) -> Result<(Vec<Value>, Vec<Value>), String> {
        let mut seats = Vec::new();
        let mut scores = Vec::new();

        for w in 0..self.waves.len() {
            // `refs` is empty on purpose. Kalam needs it to attach a seat's identity to a view
            // because an Orion `map` body cannot join back to the caller's rows; this loop has the
            // rows in hand, and every view already carries its own `m` and `seat`.
            let obs = self.invoke_wave(w, "observe", &json!({ "refs": [] }))?;
            let views = obs["views"].as_array().cloned().unwrap_or_default();

            for r in self.live_scores(w)? {
                scores.push(r);
            }

            let wave = &self.waves[w];
            for v in &views {
                let m = v["m"].as_u64().unwrap_or(0) as usize;
                seats.push(json!({
                    "w": w,
                    "m": m,
                    "ep": wave.eps.get(m).copied().unwrap_or(0),
                    "seat": v["seat"],
                    "turn": wave.turn,
                    "obs": v["view"],
                }));
            }
            self.last_counts[w] = views.len();
        }
        Ok((seats, scores))
    }

    /// Advance every wave one turn, and refill any that finished.
    ///
    /// `actions` is positionally aligned with the last `observe`. An element is either the compact
    /// form — one character per ant, in `mine`'s order, exactly as a replay delta writes it — or
    /// the protocol's own array of strings. The compact form is four times smaller on the wire and
    /// is not an invention: `ants/src/replay.rs` already writes a turn that way.
    pub fn step(&mut self, actions: &[Value]) -> Result<Vec<Value>, String> {
        let want: usize = self.last_counts.iter().sum();
        if actions.len() != want {
            return Err(format!(
                "{} actions for {want} live seats -- a step is positionally aligned with the \
                 seats the last observe returned",
                actions.len()
            ));
        }

        let mut ended = Vec::new();
        let mut at = 0;
        for w in 0..self.waves.len() {
            let n = self.last_counts[w];
            if n == 0 {
                continue;
            }
            let acts: Vec<Value> = actions[at..at + n].iter().map(expand).collect();
            at += n;
            self.seat_turns += n as u64;

            let out = self.invoke_wave(w, "step", &json!({ "actions": acts }))?;
            self.waves[w].state = out["wave_state"].clone();
            self.waves[w].turn += 1;

            let just: Vec<usize> = out["ended"]
                .as_array()
                .map(|a| a.iter().filter_map(Value::as_u64).map(|x| x as usize).collect())
                .unwrap_or_default();
            if !just.is_empty() {
                for r in self.ended_rows(w, &just)? {
                    ended.push(r);
                    self.episodes += 1;
                }
                for m in just {
                    if let Some(d) = self.waves[w].done.get_mut(m) {
                        *d = true;
                    }
                }
            }

            // A wave is refilled only when every match in it has ended: `wave_state` is one opaque
            // value for the whole wave, so a finished match cannot be spliced out and replaced.
            // That is why the pool holds several waves — one long match stalls its own slot and
            // nothing else.
            if self.waves[w].done.iter().all(|&d| d) {
                let fresh = self.worldgen(w)?;
                self.waves[w] = fresh;
                self.last_counts[w] = 0;
            }
        }
        self.steps += 1;
        Ok(ended)
    }

    /// The current score of every match still running in one wave.
    ///
    /// This is the whole reason a dense reward needs no cartridge change: `f_finish` gates only
    /// `map` on `done` and answers `scores`, `ranks` and `turns` for a live match as readily as for
    /// a finished one. The cost is one extra invocation a turn — it unpacks `wave_state` again —
    /// which `--scores end` declines for a trainer that only wants the terminal signal.
    fn live_scores(&self, w: usize) -> Result<Vec<Value>, String> {
        if !self.cfg.scores_every_turn {
            return Ok(Vec::new());
        }
        let wave = &self.waves[w];
        Ok(self
            .results(w)?
            .into_iter()
            .filter(|r| !r["done"].as_bool().unwrap_or(false))
            .map(|r| {
                let m = r["m"].as_u64().unwrap_or(0) as usize;
                json!({
                    "w": w, "m": m,
                    "ep": wave.eps.get(m).copied().unwrap_or(0),
                    "turns": r["turns"],
                    "scores": r["scores"],
                })
            })
            .collect())
    }

    /// The full result of the matches that ended on this step, in the order they were named.
    fn ended_rows(&self, w: usize, just: &[usize]) -> Result<Vec<Value>, String> {
        let wave = &self.waves[w];
        Ok(self
            .results(w)?
            .into_iter()
            .filter(|r| just.contains(&(r["m"].as_u64().unwrap_or(0) as usize)))
            .map(|r| {
                let m = r["m"].as_u64().unwrap_or(0) as usize;
                json!({
                    "w": w, "m": m,
                    "ep": wave.eps.get(m).copied().unwrap_or(0),
                    "turns": r["turns"],
                    "scores": r["scores"],
                    "ranks": r["ranks"],
                    "reason": r["reason"],
                    "preset": wave.preset,
                    "seed": wave.seeds.get(m).copied().unwrap_or(0),
                    "map_id": wave.map_ids.get(m).cloned().unwrap_or_default(),
                })
            })
            .collect())
    }

    /// `finish` over one wave. `map` never leaves this function: it is tens of kilobytes, it exists
    /// so a replay envelope can stand alone, and a training loop has no replay.
    fn results(&self, w: usize) -> Result<Vec<Value>, String> {
        let fin = self.invoke_wave(w, "finish", &json!({}))?;
        Ok(fin["results"].as_array().cloned().unwrap_or_default())
    }

    fn invoke_wave(&self, w: usize, name: &str, extra: &Value) -> Result<Value, String> {
        let mut req = extra.clone();
        req["wave_state"] = self.waves[w].state.clone();
        self.invoke(name, &req)
    }

    fn invoke(&self, name: &str, req: &Value) -> Result<Value, String> {
        self.cart
            .invoke(&format!("tb.{}.{}", self.game.slug, name), req)
            .map_err(|e: Fault| format!("the cartridge refused: {e}"))
    }
}

/// One seat's orders, from either wire form. A character that is not a direction is a hold, which
/// is also what the engine does with an unrecognised order — so a trainer emitting `.` or a space
/// gets the hold it meant rather than a refusal it has to handle.
fn expand(a: &Value) -> Value {
    match a {
        Value::String(s) => Value::Array(
            s.chars()
                .map(|c| match c {
                    'N' | 'E' | 'S' | 'W' => json!(c.to_string()),
                    _ => json!("-"),
                })
                .collect(),
        ),
        other => other.clone(),
    }
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .map(|a| a.iter().map(|x| x.as_str().unwrap_or("").to_string()).collect())
        .unwrap_or_default()
}

/// The presets a game declares, as the pool cycles them. `players` comes from the manifest and is
/// passed through to be checked against the board, never to choose a seat count.
pub fn presets_of(game: &Game, only: Option<&str>) -> Result<Vec<Preset>, String> {
    let all: Vec<Preset> = game
        .manifest
        .get("presets")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|p| {
                    Some(Preset {
                        name: p.get("name")?.as_str()?.to_string(),
                        players: p.get("players").and_then(Value::as_u64).unwrap_or(2),
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    let Some(name) = only else { return Ok(all) };
    let found: Vec<Preset> = all.into_iter().filter(|p| p.name == name).collect();
    if found.is_empty() {
        return Err(format!("{} has no preset '{name}'", game.slug));
    }
    Ok(found)
}
