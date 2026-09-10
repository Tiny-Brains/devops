use std::path::PathBuf;

use crate::cartridge::Cartridge;
use crate::cmd::{axon_replica, open_game};
use crate::matchfile::MatchFile;
use crate::store::short;
use crate::wave;

pub fn run(args: &[String]) -> Result<(), String> {
    let mut file: Option<PathBuf> = None;
    let mut out = PathBuf::from("replays");
    let mut slug: Option<String> = None;
    let mut verbose = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--out" => {
                i += 1;
                out = PathBuf::from(args.get(i).ok_or("--out needs a directory")?);
            }
            "--game" => {
                i += 1;
                slug = Some(args.get(i).ok_or("--game needs a slug")?.clone());
            }
            "-v" | "--verbose" => verbose = true,
            other if !other.starts_with('-') => file = Some(PathBuf::from(other)),
            other => return Err(format!("unknown option '{other}'\n\n{}", crate::USAGE)),
        }
        i += 1;
    }
    let file = file.ok_or("which match file?\n\n  tinybrains matches/quick.json")?;

    let mf = MatchFile::load(&file)?;
    wave::check_uniform(&mf.rows)?;
    let game = open_game(Some(slug.as_deref().unwrap_or(&mf.game)))?;

    // The same seeds on a different engine are a different match, so a silent play would make any
    // comparison meaningless.
    if let Some(want) = &mf.engine_digest {
        if want != &game.engine_digest {
            eprintln!(
                "warning: {} names engine {want}\n         but {} resolves to {}",
                file.display(),
                game.slug,
                game.engine_digest
            );
        }
    }

    let cart = Cartridge::open(&game.component).map_err(|e| e.to_string())?;
    let axon = axon_replica()?;

    println!(
        "{} on {} -- {} match{}, preset {}, engine {}",
        game.slug,
        game.name,
        mf.rows.len(),
        if mf.rows.len() == 1 { "" } else { "es" },
        mf.rows[0].preset,
        short(&game.engine_digest)
    );

    let report = wave::run(&game, &cart, &mf, &axon, verbose)?;

    std::fs::create_dir_all(&out).map_err(|e| format!("{}: {e}", out.display()))?;
    println!();
    for o in &report.outcomes {
        let path = out.join(format!("{}.json", o.id));
        let bytes = serde_json::to_vec(&o.envelope).map_err(|e| e.to_string())?;
        std::fs::write(&path, bytes).map_err(|e| format!("{}: {e}", path.display()))?;

        let seats: Vec<String> = mf
            .rows
            .iter()
            .find(|r| r.id == o.id)
            .map(|r| {
                r.seats
                    .iter()
                    .enumerate()
                    .map(|(i, s)| format!("{}={}", s.label, o.ranks.get(i).copied().unwrap_or(0)))
                    .collect()
            })
            .unwrap_or_default();
        println!(
            "{:<14} {:<10} {:>4} turns  board {:<10} ranks {}  scores {:?}{}",
            o.id,
            o.reason,
            o.turns,
            o.map_id,
            seats.join(" "),
            o.scores,
            if o.strikes.iter().any(|&s| s > 0) {
                format!("  strikes {:?}", o.strikes)
            } else {
                String::new()
            }
        );
        println!("{:<14} -> {}", "", path.display());
    }

    if report.play_calls > 0 {
        let st = report.seat_turns.max(1);
        println!();
        println!(
            "{} turns in {} batched play call{}, {} seat-turns: mean {} ops, {} ms",
            report.turns_played,
            report.play_calls,
            if report.play_calls == 1 { "" } else { "s" },
            report.seat_turns,
            report.total_ops / st,
            report.total_play_ms / st,
        );
        let cap = mf.var("budget_ops", game.budget("adapter_ops_max", 1_000_000));
        println!(
            "adapter budget {}: mean run used {}%",
            cap,
            (report.total_ops / st) * 100 / cap.max(1)
        );
    }
    println!("this is not an admission check -- `tinybrains check` is the gate");
    Ok(())
}
