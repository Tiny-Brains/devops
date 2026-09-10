//! `tinybrains adapt` — run an adapter's `in` program and write out the tensors it produced.
//!
//! **This exists because an adapter is half of what plays, and until now nothing could show you
//! what it actually produced.** `check` reports shapes; a competitor training in Python encodes
//! observations twice — once in `adapter.json` for the ladder and once in numpy for the trainer —
//! and two implementations of one encoding is the classic way to ship a model that scores worse in
//! the arena than it did in training. This is the tool that lets the two be *diffed* rather than
//! believed: dump the ladder's own answer, and assert your encoder equals it.
//!
//! `.npy` because that is the one array format every trainer already reads, and because writing it
//! needs no dependency: a header and the same bytes `Tensor::to_bytes` already packs for ORT.
//!
//! It knows no game. The adapter is the dialect's, the observations are the cartridge's.

use std::path::PathBuf;

use serde_json::{json, Value};

use crate::cmd::{open_game, reference_observations};

pub fn run(args: &[String]) -> Result<(), String> {
    let mut obs_file: Option<PathBuf> = None;
    let mut out = PathBuf::from("tensors");
    let mut rest: Vec<String> = Vec::new();
    let mut slug: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--obs" => {
                i += 1;
                obs_file = Some(PathBuf::from(args.get(i).ok_or("--obs needs a file")?));
            }
            "--out" => {
                i += 1;
                out = PathBuf::from(args.get(i).ok_or("--out needs a directory")?);
            }
            "--game" => {
                i += 1;
                slug = Some(args.get(i).ok_or("--game needs a slug")?.clone());
            }
            other if !other.starts_with('-') => rest.push(other.to_string()),
            other => return Err(format!("unknown option '{other}'\n\n{}", crate::USAGE)),
        }
        i += 1;
    }
    if rest.len() != 1 {
        return Err("which adapter?\n\n  tinybrains adapt adapter.json [--obs FILE] [--out DIR]"
            .to_string());
    }

    let bytes = std::fs::read(&rest[0]).map_err(|e| format!("{}: {e}", rest[0]))?;
    let adapter = axon::dialect::Adapter::parse(&bytes)
        .map_err(|e| format!("{}: {e}", rest[0]))?;

    let game = open_game(slug.as_deref())?;
    let (observations, source) = match &obs_file {
        Some(p) => (load_observations(p)?, p.display().to_string()),
        None => (reference_observations(&game)?, format!("{}'s reference set", game.slug)),
    };
    let budget = game.budget("adapter_ops_max", 1_000_000);

    println!("{} against {} ({} observation{})",
        rest[0],
        source,
        observations.len(),
        if observations.len() == 1 { "" } else { "s" });
    println!("    dialect          {}", adapter.dialect);
    println!("    evaluator        {}", axon::dialect::evaluator_digest());
    println!();

    std::fs::create_dir_all(&out).map_err(|e| format!("{}: {e}", out.display()))?;
    let mut cases = Vec::new();
    for (i, obs) in observations.iter().enumerate() {
        let (ports, ops) = adapter.run_in(obs, budget);
        let ports = ports.map_err(|e| format!("observation {i}: {e}"))?;

        let dir = out.join(format!("case-{i}"));
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        let mut wrote = Vec::new();
        for (name, t) in &ports {
            let path = dir.join(format!("{name}.npy"));
            std::fs::write(&path, npy(t)?).map_err(|e| format!("{}: {e}", path.display()))?;
            wrote.push(json!({
                "name": name.to_string(),
                "dtype": t.dtype.name(),
                "shape": t.shape,
                "file": path.display().to_string(),
            }));
        }
        // The observation beside its tensors: an encoder under test needs the input that produced
        // them, and a caller who passed --obs should not have to split the file again themselves.
        std::fs::write(
            dir.join("observation.json"),
            serde_json::to_vec(obs).map_err(|e| e.to_string())?,
        )
        .map_err(|e| format!("{}: {e}", dir.display()))?;

        println!(
            "    case {i:<3} {:>9} ops ({:>3}% of budget)  {}",
            ops,
            ops * 100 / budget.max(1),
            ports
                .iter()
                .map(|(n, t)| format!("{n}{:?}:{}", t.shape, t.dtype.name()))
                .collect::<Vec<_>>()
                .join(" ")
        );
        cases.push(json!({ "case": i, "ops_in": ops, "tensors": wrote }));
    }

    let manifest = json!({
        "adapter": rest[0],
        "game": game.slug,
        "engine_digest": game.engine_digest,
        "evaluator_digest": axon::dialect::evaluator_digest(),
        "dialect_version": axon::dialect::DIALECT_VERSION,
        "budget_ops": budget,
        "source": source,
        "cases": cases,
    });
    let mpath = out.join("manifest.json");
    std::fs::write(&mpath, serde_json::to_vec_pretty(&manifest).map_err(|e| e.to_string())?)
        .map_err(|e| format!("{}: {e}", mpath.display()))?;

    println!();
    println!("wrote {} case{} to {}", cases.len(),
        if cases.len() == 1 { "" } else { "s" }, out.display());
    println!("these are the ladder's own tensors -- diff your trainer's encoder against them");
    Ok(())
}

/// NPY v1.0. The header is padded so the data starts 64-byte aligned, which is what numpy itself
/// writes and what `np.load` with `mmap_mode` expects.
fn npy(t: &axon::dialect::Tensor) -> Result<Vec<u8>, String> {
    let descr = match t.dtype.name() {
        "int8" => "|i1",
        "uint8" => "|u1",
        "int16" => "<i2",
        "int32" => "<i4",
        "float32" => "<f4",
        other => return Err(format!("no numpy descriptor for dtype '{other}'")),
    };
    // A rank-1 shape needs the trailing comma or Python reads a parenthesised expression.
    let shape = match t.shape.len() {
        0 => "()".to_string(),
        1 => format!("({},)", t.shape[0]),
        _ => format!(
            "({})",
            t.shape.iter().map(|d| d.to_string()).collect::<Vec<_>>().join(", ")
        ),
    };
    let head = format!("{{'descr': '{descr}', 'fortran_order': False, 'shape': {shape}, }}");
    let mut pad = 64 - ((10 + head.len() + 1) % 64);
    if pad == 64 {
        pad = 0;
    }
    let header = format!("{head}{}\n", " ".repeat(pad));

    let mut out = Vec::with_capacity(10 + header.len() + t.len() * t.dtype.bytes());
    out.extend_from_slice(b"\x93NUMPY\x01\x00");
    out.extend_from_slice(&(header.len() as u16).to_le_bytes());
    out.extend_from_slice(header.as_bytes());
    out.extend_from_slice(&t.to_bytes());
    Ok(out)
}

/// One observation, a bare array of them, or the cartridge's `{"observations": [...]}` envelope.
fn load_observations(path: &std::path::Path) -> Result<Vec<Value>, String> {
    let text =
        std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let doc: Value = serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(match doc {
        Value::Array(a) => a,
        Value::Object(ref o) if o.contains_key("observations") => {
            doc["observations"].as_array().cloned().unwrap_or_default()
        }
        other => vec![other],
    })
}
