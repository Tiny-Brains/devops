//! Which games exist, and where their artifacts are.
//!
//! devops already *is* the game registry: `loader/run.sh` writes `games.slug`, `manifest`,
//! `active_engine_digest` and `reference_observations` from each cartridge's committed artifacts.
//! This is the same four things in a file, so the CLI can resolve a game with no database and no
//! network — and so the digest a competitor plays against is *the same string* the ladder pins in
//! `games.active_engine_digest` and `seasons.engine_digest`.
//!
//! An entry resolves one of two ways:
//!
//!   * **`path`** — a checkout beside this one. What a cartridge author uses: the board they just
//!     generated and the component they just built, with no release and no upload. The digest is
//!     whatever the file hashes to and is reported rather than pinned, because it changes on every
//!     build and pinning it would only ever be wrong.
//!   * **`release`** — the published artifacts, fetched once and cached under
//!     `~/.cache/tinybrains/cartridges/<digest>/`. Pinned: a file whose digest does not match what
//!     the registry declares is refused, not used.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

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
    #[serde(default)]
    pub viewer: Option<Artifact>,
    #[serde(default)]
    pub reference: Option<Artifact>,
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
    /// The component, and the digest it actually hashes to — which is what a replica would load
    /// and what a match row must name for anything to claim it.
    pub component: PathBuf,
    pub engine_digest: String,
    /// `cartridge.json`: presets, seats, limits, budgets, and the board catalogue.
    pub manifest: serde_json::Value,
    /// Where the boards live as files, when the game ships them. `None` for a release entry until
    /// the viewer/maps artifacts are published.
    pub maps_dir: Option<PathBuf>,
    pub source: String,
}

impl Registry {
    pub fn load(path: &Path) -> Result<Registry, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        toml::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
    }

    /// Where the registry lives: `$TINYBRAINS_REGISTRY`, else `games/registry.toml` beside the
    /// devops checkout this binary was built from, else the installed copy in the cache.
    pub fn find() -> Result<PathBuf, String> {
        if let Ok(p) = std::env::var("TINYBRAINS_REGISTRY") {
            return Ok(PathBuf::from(p));
        }
        let built_in = Path::new(env!("CARGO_MANIFEST_DIR")).join("../games/registry.toml");
        if built_in.exists() {
            return Ok(built_in);
        }
        let cached = store::root()?.join("registry.toml");
        if cached.exists() {
            return Ok(cached);
        }
        Err("no games registry -- set TINYBRAINS_REGISTRY to a registry.toml".to_string())
    }

    pub fn resolve(&self, slug: &str, registry_path: &Path) -> Result<Game, String> {
        let entry = self.games.get(slug).ok_or_else(|| {
            let known: Vec<&str> = self.games.keys().map(String::as_str).collect();
            format!("no game '{slug}' in the registry (it has: {})", known.join(", "))
        })?;
        let base = registry_path.parent().unwrap_or(Path::new("."));

        if let Some(rel) = &entry.path {
            let checkout = base.join(rel);
            let component = checkout.join("tb-ants.wasm");
            // A cartridge names its own component; the manifest is the one file whose name the
            // platform fixes, so the component is found through it rather than guessed.
            let component = if component.exists() {
                component
            } else {
                find_component(&checkout)?
            };
            let manifest_path = checkout.join("cartridge.json");
            let manifest: serde_json::Value = serde_json::from_str(
                &std::fs::read_to_string(&manifest_path)
                    .map_err(|e| format!("cannot read {}: {e}", manifest_path.display()))?,
            )
            .map_err(|e| format!("{}: {e}", manifest_path.display()))?;
            let bytes = std::fs::read(&component)
                .map_err(|e| format!("cannot read {}: {e}", component.display()))?;
            let maps = checkout.join("maps");
            return Ok(Game {
                slug: slug.to_string(),
                name: entry.name.clone(),
                engine_digest: store::digest(&bytes),
                component,
                manifest,
                maps_dir: maps.is_dir().then_some(maps),
                source: format!("checkout {}", checkout.display()),
            });
        }

        let (repo, release) = match (&entry.repo, &entry.release) {
            (Some(r), Some(v)) => (r, v),
            _ => {
                return Err(format!(
                    "game '{slug}' declares neither a `path` checkout nor a `repo` + `release`"
                ))
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
        let manifest: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(&manifest_path)
                .map_err(|e| format!("cannot read {}: {e}", manifest_path.display()))?,
        )
        .map_err(|e| format!("{}: {e}", manifest_path.display()))?;

        Ok(Game {
            slug: slug.to_string(),
            name: entry.name.clone(),
            engine_digest: component.sha256.clone(),
            component: component_path,
            manifest,
            maps_dir: None,
            source: format!("{repo}@{release}"),
        })
    }
}

fn find_component(checkout: &Path) -> Result<PathBuf, String> {
    let entries = std::fs::read_dir(checkout)
        .map_err(|e| format!("cannot read {}: {e}", checkout.display()))?;
    for e in entries.flatten() {
        let p = e.path();
        if p.extension().and_then(|x| x.to_str()) == Some("wasm") {
            return Ok(p);
        }
    }
    Err(format!("no .wasm component in {} -- run its build first", checkout.display()))
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
    let bytes = crate::store::fetch_url(&url)?;
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
    pub fn catalogue(&self) -> Vec<&serde_json::Value> {
        self.manifest
            .get("maps")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().collect())
            .unwrap_or_default()
    }

    /// A limit from the manifest, so no number the game owns is ever typed into this binary.
    pub fn limit(&self, key: &str, dflt: u64) -> u64 {
        self.manifest
            .get("limits")
            .and_then(|l| l.get(key))
            .and_then(|v| v.as_u64())
            .unwrap_or(dflt)
    }

    pub fn budget(&self, key: &str, dflt: u64) -> u64 {
        self.manifest
            .get("budgets")
            .and_then(|b| b.get(key))
            .and_then(|v| v.as_u64())
            .unwrap_or(dflt)
    }
}
