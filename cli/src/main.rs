mod cartridge;
mod cmd;
mod env;
mod matchfile;
mod registry;
mod serve;
mod store;
mod wave;

pub const USAGE: &str = "\
tinybrains -- run a TinyBrains match locally

  tinybrains <match.json> [--out DIR] [-v]   play a wave; write one replay per row
  tinybrains run <match.json> [...]          the same, spelled out
  tinybrains games                           what is registered, and at which digest
  tinybrains maps [GAME]                     the boards a game is played on
  tinybrains maps export [GAME] [DIR]        write those boards out as files
  tinybrains view <replay.json>              watch it in a browser
  tinybrains check <model.onnx> <adapter>    would this be admitted?  [--json]
  tinybrains adapt <adapter.json> [...]      dump the tensors an adapter produces
  tinybrains conform <replay.json>           replay a recorded match here, and diff
  tinybrains env [...]                       the cartridge as a training environment

Options
  --out DIR      where replays go (default: ./replays)
  --game SLUG    which game (default: the file's `game`, else ants)
  -v, --verbose  print every strike and forfeit as it happens
";

fn main() {
    if let Err(e) = dispatch() {
        eprintln!("tinybrains: {e}");
        std::process::exit(1);
    }
}

fn dispatch() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args[0] == "-h" || args[0] == "--help" {
        print!("{USAGE}");
        return Ok(());
    }
    match args[0].as_str() {
        "games" => cmd::games::run(),
        "maps" => cmd::maps::run(&args[1..]),
        "run" => cmd::play::run(&args[1..]),
        "conform" => cmd::conform::run(&args[1..]),
        "env" => cmd::env::run(&args[1..]),
        "view" => cmd::view::run(&args[1..]),
        "check" => cmd::check::run(&args[1..]),
        "adapt" => cmd::adapt::run(&args[1..]),
        other if other.ends_with(".json") => cmd::play::run(&args),
        other => Err(format!("unknown command '{other}'\n\n{USAGE}")),
    }
}
