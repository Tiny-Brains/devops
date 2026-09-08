//! `check` — the admission gate, locally.
//!
//! Admission runs `inspect` and `validate` against the game's reference observations before a
//! version is allowed to play. This runs the same two calls, in the same crate, against the same
//! observations — so a competitor finds out here rather than from a rejection.
//!
//! **It is a necessary condition and not a sufficient one**, and it says so on every run. Two
//! things differ from admission by design: this machine has no download allowlist, so a model that
//! loads here may still be refused for where its bytes came from; and the size class is *reported*
//! rather than decided, because the class table is platform policy that lives in Jodi and a
//! threshold change must not require a new binary here.

use serde_json::{json, Value};

use crate::registry::Game;

pub fn run(
    game: &Game,
    axon: &axon::server::Axon,
    weights_hash: &str,
    adapter_hash: &str,
    observations: &[Value],
    budget_ops: u64,
    deadline_ms: u64,
) -> Result<bool, String> {
    // Hold it first: inspect and validate both read bytes, and a model that will not load is a
    // different failure from one that loads and misbehaves.
    let hold: axon::api::LoadRequest = serde_json::from_value(json!({
        "models": [{ "weights_hash": weights_hash, "adapter_hash": adapter_hash }],
        "wait_ms": 60000
    }))
    .map_err(|e| e.to_string())?;
    let held = serde_json::to_value(axon.load(hold)).map_err(|e| e.to_string())?;
    let state = held["models"][0]["state"].as_str().unwrap_or("?");
    if state != "resident" {
        // `fault` distinguishes the model's problem from the loader's, which is the difference
        // between "fix your file" and "this machine could not hold it".
        return Err(format!(
            "the loader would not hold it: {state} {}\n  fault: {}",
            held["models"][0]["reason"].as_str().unwrap_or(""),
            held["models"][0]["fault"].as_str().unwrap_or("unstated"),
        ));
    }

    let req: axon::api::InspectRequest = serde_json::from_value(json!({
        "weights_hash": weights_hash, "adapter_hash": adapter_hash
    }))
    .map_err(|e| e.to_string())?;
    let ins = match axon.inspect(req) {
        Ok(r) => serde_json::to_value(r).map_err(|e| e.to_string())?,
        Err(e) => return Err(format!("inspect refused: {}", serde_json::to_value(e).unwrap_or_default())),
    };

    println!("graph");
    println!("    opset            {}", ins["opset"]);
    println!("    parameters       {}", ins["params"]);
    println!(
        "    size metric      {} bytes  (zstd of weights + adapter -- the platform classifies it, this does not)",
        ins["size_metric_bytes"]
    );
    let ops: Vec<&str> = ins["ops"].as_array().map(|a| a.iter().filter_map(|v| v.as_str()).collect()).unwrap_or_default();
    println!("    operators        {}", ops.join(", "));
    let bad: Vec<&str> = ins["unsupported_ops"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();
    if !bad.is_empty() {
        println!("    UNSUPPORTED      {}", bad.join(", "));
    }
    for (label, key) in [("inputs", "inputs"), ("outputs", "outputs")] {
        let ports: Vec<String> = ins[key]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|p| format!("{}{}", p["name"].as_str().unwrap_or("?"), p["shape"]))
                    .collect()
            })
            .unwrap_or_default();
        println!("    {label:<16} {}", ports.join(" "));
    }

    println!();
    println!("validate  ({} reference observations, budget {budget_ops}, deadline {deadline_ms} ms)",
             observations.len());
    let req: axon::api::ValidateRequest = serde_json::from_value(json!({
        "weights_hash": weights_hash,
        "adapter_hash": adapter_hash,
        "budget_ops": budget_ops,
        "deadline_ms": deadline_ms,
        "observations": observations,
    }))
    .map_err(|e| e.to_string())?;
    let val = serde_json::to_value(axon.validate(req)).map_err(|e| e.to_string())?;

    let ok = val["ok"].as_bool().unwrap_or(false);
    if ok {
        let used = val["ops_max"].as_u64().unwrap_or(0);
        println!("    PASSED");
        println!(
            "    worst case       {used} operations, {}% of the budget",
            used * 100 / budget_ops.max(1)
        );
        // The worst case is what admission refuses, so the mean is not the number to watch.
        if used * 100 / budget_ops.max(1) > 80 {
            println!("    little headroom -- a busier board than any of these would exceed it");
        }
    } else {
        println!("    FAILED  {}", val["reason"].as_str().unwrap_or("unstated"));
        if let Some(d) = val["detail"].as_str() {
            println!("    detail           {d}");
        }
        if let Some(i) = val["failing_case"].as_u64() {
            println!("    failing case     observation {i} of {}", observations.len());
        }
        // The distinction jodi/docs/admission.md §13 asks for: too expensive is not the same as
        // wrong, and collapsing them sends someone to re-read the dialect for a budget problem.
        match val["over_budget"].as_bool() {
            Some(true) => println!("    the adapter is too expensive, not incorrect"),
            Some(false) => println!("    the adapter is incorrect, not merely expensive"),
            None => {}
        }
    }

    let unload: axon::api::UnloadRequest = serde_json::from_value(json!({
        "models": [{ "weights_hash": weights_hash, "adapter_hash": adapter_hash }]
    }))
    .map_err(|e| e.to_string())?;
    axon.unload(unload);
    Ok(ok)
}
