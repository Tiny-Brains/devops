//! Which games exist, and where their artifacts are.
//!
//! The same four things `loader/run.sh` writes onto the `games` row, in a file, so the CLI resolves
//! a game with no database and no network -- and the digest a competitor plays against is the same
//! string the ladder pins.
//!
//! An entry resolves by `path` (a sibling checkout; the digest is whatever the file hashes to) or
//! by `release` (published artifacts, cached under `~/.cache/tinybrains/cartridges/<digest>/` and
//! refused if they do not hash to what the registry declares).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;

use crate::store;

#[derive(Debug, Deserialize)]
pub struct Registry {
    #[serde(default)]
    pub games: BTreeMap<String, GameEntry>,
}

#[derive(Debug, Deserialize)]
pub struct GameEntry {
    pub name: String,
    /// A checkout to read artifacts from, relative to the registry file. Wins over `release`.
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub repo: Option<String>,
    #[serde(default)]
    pub release: Option<String>,
    #[serde(default)]
    pub component: Option<Artifact>,
    #[serde(default)]
    pub manifest: Option<Artifact>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Artifact {
    pub file: String,
    pub sha256: String,
}

/// A game, resolved to files on this machine.
pub struct Game {
    pub slug: String,
    pub name: String,
    pub component: PathBuf,
    pub engine_digest: String,
    /// `cartridge.json`: presets, seats, limits, budgets, and the board catalogue.
    pub manifest: Value,
    /// Where the boards live as files, when the game ships them.
    pub maps_dir: Option<PathBuf>,
    pub source: String,
}

impl Registry {
    pub fn load(path: &Path) -> Result<Registry, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        toml::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
    }

    /// `games.toml` in the working directory first: a project carries its own games the way it
    /// carries its own matches, so a clone of `drill` needs no environment variable.
    pub fn find() -> Result<PathBuf, String> {
        if let Ok(p) = std::env::var("TINYBRAINS_REGISTRY") {
            return Ok(PathBuf::from(p));
        }
        let built_in = Path::new(env!("CARGO_MANIFEST_DIR")).join("../games/registry.toml");
        let cached = store::root().map(|r| r.join("registry.toml"));
        let candidates = [
            Some(PathBuf::from("games.toml")),
            Some(PathBuf::from("tinybrains.toml")),
            Some(built_in),
            cached.ok(),
        ];
        candidates.into_iter().flatten().find(|p| p.exists()).ok_or_else(|| {
            "no games registry.\n\
                 A project carries its own as `games.toml`; clone drill for one that works,\n\
                 or point TINYBRAINS_REGISTRY at a registry.toml."
                .to_string()
        })
    }

    pub fn resolve(&self, slug: &str, registry_path: &Path) -> Result<Game, String> {
        let entry = self.games.get(slug).ok_or_else(|| {
            let known: Vec<&str> = self.games.keys().map(String::as_str).collect();
            format!("no game '{slug}' in the registry (it has: {})", known.join(", "))
        })?;
        let base = registry_path.parent().unwrap_or(Path::new("."));

        if let Some(rel) = &entry.path {
            let checkout = base.join(rel);
            let component = find_component(&checkout)?;
            let bytes = std::fs::read(&component)
                .map_err(|e| format!("cannot read {}: {e}", component.display()))?;
            let maps = checkout.join("maps");
            return Ok(Game {
                slug: slug.to_string(),
                name: entry.name.clone(),
                engine_digest: store::digest(&bytes),
                component,
                manifest: read_json(&checkout.join("cartridge.json"))?,
                maps_dir: maps.is_dir().then_some(maps),
                source: format!("checkout {}", checkout.display()),
            });
        }

        let (repo, release) = match (&entry.repo, &entry.release) {
            (Some(r), Some(v)) => (r, v),
            _ => {
                return Err(format!(
                    "game '{slug}' declares neither a `path` checkout nor a `repo` + `release`"
                ));
            }
        };
        let component = entry
            .component
            .as_ref()
            .ok_or_else(|| format!("game '{slug}' declares no component artifact"))?;
        let manifest = entry
            .manifest
            .as_ref()
            .ok_or_else(|| format!("game '{slug}' declares no manifest artifact"))?;

        let component_path = fetch(repo, release, component)?;
        let manifest_path = fetch(repo, release, manifest)?;

        Ok(Game {
            slug: slug.to_string(),
            name: entry.name.clone(),
            engine_digest: component.sha256.clone(),
            component: component_path,
            manifest: read_json(&manifest_path)?,
            maps_dir: None,
            source: format!("{repo}@{release}"),
        })
    }
}

fn read_json(path: &Path) -> Result<Value, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
}

/// The component by extension, never by name: this binary knows no game.
fn find_component(checkout: &Path) -> Result<PathBuf, String> {
    let entries = std::fs::read_dir(checkout)
        .map_err(|e| format!("cannot read {}: {e}", checkout.display()))?;
    let mut found: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|x| x.to_str()) == Some("wasm"))
        .collect();
    found.sort();
    found.into_iter().next().ok_or_else(|| {
        format!("no .wasm component in {} -- run its build first", checkout.display())
    })
}

/// Fetch one release artifact into the cache, keyed by its declared digest, and refuse anything
/// that does not hash to it.
fn fetch(repo: &str, release: &str, art: &Artifact) -> Result<PathBuf, String> {
    let hex = art
        .sha256
        .strip_prefix("sha256:")
        .ok_or_else(|| format!("{}: sha256 must be 'sha256:<64 hex>'", art.file))?;
    let dir = store::root()?.join("cartridges").join(hex);
    let path = dir.join(&art.file);
    if path.exists() {
        return Ok(path);
    }
    let url = format!("https://github.com/{repo}/releases/download/{release}/{}", art.file);
    let bytes = store::fetch_url(&url)?;
    let got = store::digest(&bytes);
    if got != art.sha256 {
        return Err(format!(
            "{url}\n  declared {}\n  actual   {got}\nrefusing to use it",
            art.sha256
        ));
    }
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    std::fs::write(&path, &bytes).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(path)
}

impl Game {
    /// The boards this game publishes, from `cartridge.json`'s catalogue.
    pub fn catalogue(&self) -> Vec<&Value> {
        self.manifest
            .get("maps")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().collect())
            .unwrap_or_default()
    }

    pub fn limit(&self, key: &str, dflt: u64) -> u64 {
        self.number("limits", key, dflt)
    }

    pub fn budget(&self, key: &str, dflt: u64) -> u64 {
        self.number("budgets", key, dflt)
    }

    /// No number the game owns is ever typed into this binary.
    fn number(&self, table: &str, key: &str, dflt: u64) -> u64 {
        self.manifest.get(table).and_then(|t| t.get(key)).and_then(|v| v.as_u64()).unwrap_or(dflt)
    }
}
