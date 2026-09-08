//! `match.json` — the rows Kalam claims, in a file.
//!
//! Not a convenience format invented for the CLI. `kalam/scripts/gen-kalam.py`'s `K_WAVE` reads
//! the claimed rows out of Postgres and hands them to the workflow as `data.rows`; that JSON, plus
//! the Orion `[vars]` the wave runs under, is the entire input to a match. So it is the entire
//! input here, which is what lets a real claim be dumped to a file and replayed on a laptop, and
//! what makes a conformance run a diff rather than a translation.
//!
//! # The one local addition
//!
//! A seat may name its model as `weights` / `adapter` — a path or a URL — instead of
//! `weights_hash` / `adapter_hash`. The bytes are read, hashed into the store, and the hash fields
//! filled in before anything else runs. A file that uses only hashes is byte-compatible with what
//! the database holds.
//!
//! Everything a competitor would otherwise ask for separately falls out of that. Self-play is the
//! same two hashes in both seats; an older version is a different path; a downloaded release is a
//! URL; a baseline is a hash. There is no fifth feature to build.

use std::path::{Path, PathBuf};

use serde_json::Value;

pub struct MatchFile {
    pub game: String,
    pub engine_digest: Option<String>,
    pub vars: Value,
    pub rows: Vec<Row>,
    /// Paths inside the file resolve against the file's own directory, so a match file and the
    /// models it names travel together.
    pub base: PathBuf,
}

pub struct Row {
    pub id: String,
    pub seed: u64,
    pub preset: String,
    pub seat_count: u64,
    /// A catalogue id, an inline board, or null for "let the seed choose".
    pub map: Value,
    pub seats: Vec<Seat>,
}

pub struct Seat {
    pub seat: u64,
    pub weights_hash: String,
    pub adapter_hash: String,
    /// What to call this seat in output and in the replay. The path or name it was written as,
    /// because `sha256:1a3f…` tells a competitor nothing about which of their models lost.
    pub label: String,
}

impl MatchFile {
    pub fn load(path: &Path) -> Result<MatchFile, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        let doc: Value = serde_json::from_str(&text)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        let base = path.parent().unwrap_or(Path::new(".")).to_path_buf();

        let rows_json = doc
            .get("rows")
            .and_then(|v| v.as_array())
            .ok_or_else(|| format!("{}: no `rows` array", path.display()))?;
        if rows_json.is_empty() {
            return Err(format!("{}: `rows` is empty -- a wave of no matches", path.display()));
        }

        let mut rows = Vec::with_capacity(rows_json.len());
        for (i, r) in rows_json.iter().enumerate() {
            rows.push(Row::parse(r, i, &base)?);
        }

        Ok(MatchFile {
            game: doc.get("game").and_then(|v| v.as_str()).unwrap_or("ants").to_string(),
            engine_digest: doc
                .get("engine_digest")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            vars: doc.get("vars").cloned().unwrap_or(Value::Null),
            rows,
            base,
        })
    }

    /// A tuning number, from the file if it names one and from the game's own manifest otherwise.
    /// No limit the game owns is ever typed into this binary.
    pub fn var(&self, key: &str, dflt: u64) -> u64 {
        self.vars.get(key).and_then(|v| v.as_u64()).unwrap_or(dflt)
    }
}

impl Row {
    fn parse(r: &Value, index: usize, base: &Path) -> Result<Row, String> {
        // `m` is the index and `id` only names the output, so both are optional locally. In the
        // database they are a column and a uuid; here, defaulting them is the difference between
        // a file someone writes by hand and one only a query could produce.
        let id = r
            .get("id")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .unwrap_or_else(|| format!("match-{index}"));
        let seed = r
            .get("seed")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| format!("row '{id}': no `seed`"))?;
        let preset = r
            .get("preset")
            .and_then(|v| v.as_str())
            .ok_or_else(|| format!("row '{id}': no `preset`"))?
            .to_string();

        let seats_json = r
            .get("seats")
            .and_then(|v| v.as_array())
            .ok_or_else(|| format!("row '{id}': no `seats` array"))?;
        let mut seats = Vec::with_capacity(seats_json.len());
        for (i, s) in seats_json.iter().enumerate() {
            seats.push(Seat::parse(s, i, &id, base)?);
        }

        let seat_count = r
            .get("seat_count")
            .and_then(|v| v.as_u64())
            .unwrap_or(seats.len() as u64);
        if seat_count as usize != seats.len() {
            return Err(format!(
                "row '{id}': seat_count is {seat_count} but {} seats are named",
                seats.len()
            ));
        }

        Ok(Row { id, seed, preset, seat_count, map: r.get("map").cloned().unwrap_or(Value::Null), seats })
    }
}

impl Seat {
    fn parse(s: &Value, index: usize, row: &str, base: &Path) -> Result<Seat, String> {
        let seat = s.get("seat").and_then(|v| v.as_u64()).unwrap_or(index as u64);
        let here = format!("row '{row}' seat {seat}");

        // The production form, first: a seat that names hashes is already what the database holds.
        let by_hash = (
            s.get("weights_hash").and_then(|v| v.as_str()),
            s.get("adapter_hash").and_then(|v| v.as_str()),
        );
        if let (Some(w), Some(a)) = by_hash {
            return Ok(Seat {
                seat,
                weights_hash: w.to_string(),
                adapter_hash: a.to_string(),
                label: s
                    .get("label")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&short(w))
                    .to_string(),
            });
        }

        // The local superset: a path or a URL, read and hashed into the store.
        let w = s
            .get("weights")
            .and_then(|v| v.as_str())
            .ok_or_else(|| format!("{here}: needs `weights_hash` + `adapter_hash`, or `weights` + `adapter`"))?;
        let a = s
            .get("adapter")
            .and_then(|v| v.as_str())
            .ok_or_else(|| format!("{here}: has `weights` but no `adapter`"))?;

        let wb = crate::store::bytes_of(w, base).map_err(|e| format!("{here}: {e}"))?;
        let ab = crate::store::bytes_of(a, base).map_err(|e| format!("{here}: {e}"))?;
        let weights_hash = crate::store::put(axon::store::Kind::Weights, &wb)
            .map_err(|e| format!("{here}: {e}"))?;
        let adapter_hash = crate::store::put(axon::store::Kind::Adapter, &ab)
            .map_err(|e| format!("{here}: {e}"))?;

        Ok(Seat {
            seat,
            weights_hash,
            adapter_hash,
            label: s
                .get("label")
                .and_then(|v| v.as_str())
                .map(str::to_string)
                .unwrap_or_else(|| name_of(w)),
        })
    }
}

fn short(hash: &str) -> String {
    hash.chars().take(19).collect()
}

/// A seat's default name: the file it was loaded from, without the extension.
fn name_of(spec: &str) -> String {
    Path::new(spec)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or(spec)
        .to_string()
}
