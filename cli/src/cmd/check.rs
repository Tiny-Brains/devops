//! Admission's own `inspect` and `validate`, in the same crate, against the game's reference
//! observations. Necessary and not sufficient: no download allowlist here, and the size class is
//! reported rather than decided because that table is Jodi's policy.

use serde_json::{json, Value};

use crate::cmd::{axon_config, game_and_rest, open_game, reference_observations};
use crate::store;

pub fn run(args: &[String]) -> Result<(), String> {
    let (slug, files) = game_and_rest(args)?;
    if files.len() != 2 {
        return Err("which model?\n\n  tinybrains check out/model.onnx out/adapter.json".to_string());
    }
    let game = open_game(slug.as_deref())?;
    let observations = reference_observations(&game)?;

    let cwd = std::path::PathBuf::from(".");
    let wb = store::bytes_of(&files[0], &cwd)?;
    let ab = store::bytes_of(&files[1], &cwd)?;
    let weights = store::put(axon::store::Kind::Weights, &wb)?;
    let adapter = store::put(axon::store::Kind::Adapter, &ab)?;

    println!("{} against {}'s reference set", files[0], game.slug);
    println!("    weights          {weights}");
    println!("    adapter          {adapter}");
    println!();

    // Admission mode: a replica answers NO_SUCH_CALL for both of these, deliberately.
    let axon = axon::server::Axon::new(axon_config(axon::config::Mode::Admission)?);
    let ok = gate(
        &axon,
        &weights,
        &adapter,
        &observations,
        game.budget("adapter_ops_max", 1_000_000),
        // Stricter than admission, which allows more per observation than a turn does.
        game.limit("turn_ms", 1000),
    )?;

    println!();
    println!("This is not admission. It has no download allowlist and does not decide a size class,");
    println!("so a pass here is necessary and not sufficient.");
    if !ok {
        return Err("check failed".to_string());
    }
    Ok(())
}

fn gate(
    axon: &axon::server::Axon,
    weights_hash: &str,
    adapter_hash: &str,
    observations: &[Value],
    budget_ops: u64,
    deadline_ms: u64,
) -> Result<bool, String> {
    let models = json!([{ "weights_hash": weights_hash, "adapter_hash": adapter_hash }]);

    // Hold it first: a model that will not load is a different failure from one that misbehaves.
    let hold: axon::api::LoadRequest =
        serde_json::from_value(json!({ "models": models, "wait_ms": 60000 }))
            .map_err(|e| e.to_string())?;
    let held = serde_json::to_value(axon.load(hold)).map_err(|e| e.to_string())?;
    let state = held["models"][0]["state"].as_str().unwrap_or("?");
    if state != "resident" {
        return Err(format!(
            "the loader would not hold it: {state} {}\n  fault: {}",
            held["models"][0]["reason"].as_str().unwrap_or(""),
            held["models"][0]["fault"].as_str().unwrap_or("unstated"),
        ));
    }

    let req: axon::api::InspectRequest = serde_json::from_value(
        json!({ "weights_hash": weights_hash, "adapter_hash": adapter_hash }),
    )
    .map_err(|e| e.to_string())?;
    let ins = match axon.inspect(req) {
        Ok(r) => serde_json::to_value(r).map_err(|e| e.to_string())?,
        Err(e) => {
            return Err(format!(
                "inspect refused: {}",
                serde_json::to_value(e).unwrap_or_default()
            ))
        }
    };
    report_graph(&ins);

    println!();
    println!(
        "validate  ({} reference observations, budget {budget_ops}, deadline {deadline_ms} ms)",
        observations.len()
    );
    let req: axon::api::ValidateRequest = serde_json::from_value(json!({
        "weights_hash": weights_hash,
        "adapter_hash": adapter_hash,
        "budget_ops": budget_ops,
        "deadline_ms": deadline_ms,
        "observations": observations,
    }))
    .map_err(|e| e.to_string())?;
    let val = serde_json::to_value(axon.validate(req)).map_err(|e| e.to_string())?;
    let ok = report_validation(&val, observations.len(), budget_ops);

    let unload: axon::api::UnloadRequest =
        serde_json::from_value(json!({ "models": models })).map_err(|e| e.to_string())?;
    axon.unload(unload);
    Ok(ok)
}

fn strings(v: &Value) -> Vec<&str> {
    v.as_array()
        .map(|a| a.iter().filter_map(|x| x.as_str()).collect())
        .unwrap_or_default()
}

fn report_graph(ins: &Value) {
    println!("graph");
    println!("    opset            {}", ins["opset"]);
    println!("    parameters       {}", ins["params"]);
    println!(
        "    size metric      {} bytes  (zstd of weights + adapter -- the platform classifies it, this does not)",
        ins["size_metric_bytes"]
    );
    println!("    operators        {}", strings(&ins["ops"]).join(", "));
    let bad = strings(&ins["unsupported_ops"]);
    if !bad.is_empty() {
        println!("    UNSUPPORTED      {}", bad.join(", "));
    }
    for key in ["inputs", "outputs"] {
        let ports: Vec<String> = ins[key]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|p| format!("{}{}", p["name"].as_str().unwrap_or("?"), p["shape"]))
                    .collect()
            })
            .unwrap_or_default();
        println!("    {key:<16} {}", ports.join(" "));
    }
}

fn report_validation(val: &Value, observations: usize, budget_ops: u64) -> bool {
    if val["ok"].as_bool().unwrap_or(false) {
        let used = val["ops_max"].as_u64().unwrap_or(0);
        let pct = used * 100 / budget_ops.max(1);
        println!("    PASSED");
        println!("    worst case       {used} operations, {pct}% of the budget");
        // The worst case is what admission refuses, so the mean is not the number to watch.
        if pct > 80 {
            println!("    little headroom -- a busier board than any of these would exceed it");
        }
        // Reported, never a gate: there is no compute cap (devops decision 46), and wall clock
        // belongs to whichever machine ran it. It is here because the TURN DEADLINE is what a
        // graph too expensive to play runs into, and this is the only local sight of it.
        let us = val["infer_us_max"].as_u64().unwrap_or(0);
        println!(
            "    slowest graph    {:.2} ms of inference  (measured here, not a threshold: no \
             class caps compute)",
            us as f64 / 1000.0
        );
        return true;
    }
    println!("    FAILED  {}", val["reason"].as_str().unwrap_or("unstated"));
    if let Some(d) = val["detail"].as_str() {
        println!("    detail           {d}");
    }
    if let Some(i) = val["failing_case"].as_u64() {
        println!("    failing case     observation {i} of {observations}");
    }
    // Too expensive is not the same as wrong; collapsing them sends someone to re-read the dialect
    // for a budget problem (jodi/docs/admission.md §13).
    match val["over_budget"].as_bool() {
        Some(true) => println!("    the adapter is too expensive, not incorrect"),
        Some(false) => println!("    the adapter is incorrect, not merely expensive"),
        None => {}
    }
    false
}
