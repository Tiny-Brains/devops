use std::path::PathBuf;

use crate::cmd::open_game;
use crate::store;

pub fn run(args: &[String]) -> Result<(), String> {
    let export = args.first().map(|s| s == "export").unwrap_or(false);
    let rest = if export { &args[1..] } else { args };
    let slug = rest.first().filter(|s| !s.starts_with('-')).map(String::as_str);
    let game = open_game(slug)?;

    if !export {
        println!("{}  {} boards", game.slug, game.catalogue().len());
        for m in game.catalogue() {
            println!(
                "  {:<12} {:<9} {:>3}x{:<3} {} seats  food {:<3} {}",
                m["id"].as_str().unwrap_or("?"),
                m["preset"].as_str().unwrap_or("?"),
                m["rows"].as_u64().unwrap_or(0),
                m["cols"].as_u64().unwrap_or(0),
                m["players"].as_u64().unwrap_or(0),
                m["food_target"].as_u64().unwrap_or(0),
                store::short(m["sha256"].as_str().unwrap_or("")),
            );
        }
        return Ok(());
    }

    let dir = PathBuf::from(rest.get(1).cloned().unwrap_or_else(|| "maps".to_string()));
    let src = game
        .maps_dir
        .as_ref()
        .ok_or("this game's boards are not available as files from where it resolved")?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;

    let mut n = 0;
    for m in game.catalogue() {
        let id = m["id"].as_str().unwrap_or_default();
        let want = m["sha256"].as_str().unwrap_or_default();
        let from = src.join(format!("{id}.json"));
        let bytes = std::fs::read(&from).map_err(|e| format!("{}: {e}", from.display()))?;
        // The catalogue's digest is over the file as committed, so a mismatch is a stale checkout.
        let got = store::digest(&bytes);
        if got != want {
            return Err(format!(
                "{}\n  catalogue says {want}\n  the file is    {got}\n\
                 the checkout and its manifest disagree -- rebuild the cartridge",
                from.display()
            ));
        }
        std::fs::write(dir.join(format!("{id}.json")), &bytes)
            .map_err(|e| format!("{}: {e}", dir.display()))?;
        n += 1;
    }
    println!("wrote {n} boards to {}", dir.display());
    Ok(())
}
