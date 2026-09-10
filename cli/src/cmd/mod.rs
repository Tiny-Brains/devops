pub mod check;
pub mod conform;
pub mod games;
pub mod maps;
pub mod play;
pub mod view;

use crate::registry::{Game, Registry};
use crate::store;

pub fn open_game(slug: Option<&str>) -> Result<Game, String> {
    let path = Registry::find()?;
    let reg = Registry::load(&path)?;
    let slug = match slug {
        Some(s) => s.to_string(),
        None => reg.games.keys().next().cloned().ok_or("the registry lists no games")?,
    };
    reg.resolve(&slug, &path)
}

/// Replica mode over the local model store: the one config difference from the fleet.
pub fn axon_replica() -> Result<axon::server::Axon, String> {
    Ok(axon::server::Axon::new(axon_config(axon::config::Mode::Replica)?))
}

pub fn axon_config(mode: axon::config::Mode) -> Result<axon::config::Config, String> {
    Ok(axon::config::Config {
        mode,
        bind: "127.0.0.1:0".to_string(),
        auth_token: None,
        memory_budget_bytes: 4 << 30,
        max_weights_bytes: 256 << 20,
        max_adapter_bytes: 4 << 20,
        default_idle_ttl_s: 900,
        threads: 1,
        max_in_flight: 1,
        store: axon::config::StoreSpec::Dir(store::models_dir()?),
        // Empty as on a replica. A URL in a match file is fetched by the CLI before the loader is
        // asked for anything, so the loader still never reaches out.
        fetch_allow_hosts: Vec::new(),
    })
}

/// `--game SLUG`, plus the positional arguments, for the commands that take nothing else.
pub fn game_and_rest(args: &[String]) -> Result<(Option<String>, Vec<String>), String> {
    let mut slug = None;
    let mut rest = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--game" => {
                i += 1;
                slug = Some(args.get(i).ok_or("--game needs a slug")?.clone());
            }
            other if !other.starts_with('-') => rest.push(other.to_string()),
            other => return Err(format!("unknown option '{other}'\n\n{}", crate::USAGE)),
        }
        i += 1;
    }
    Ok((slug, rest))
}
