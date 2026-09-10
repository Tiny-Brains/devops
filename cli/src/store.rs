//! The local content-addressed store. Models go where axon expects them -- its layout, its digest
//! function, a real `DirStore` -- so a hash computed here and one computed by the fleet match.
//!
//! There is no host allowlist here, deliberately: a competitor testing locally points at a file on
//! disk. "It loaded locally" is therefore not "it will be admitted".

use std::path::{Path, PathBuf};

/// `~/.cache/tinybrains`, or `$TINYBRAINS_HOME`.
pub fn root() -> Result<PathBuf, String> {
    if let Ok(p) = std::env::var("TINYBRAINS_HOME") {
        return Ok(PathBuf::from(p));
    }
    dirs::cache_dir()
        .map(|d| d.join("tinybrains"))
        .ok_or_else(|| "no cache directory -- set TINYBRAINS_HOME".to_string())
}

pub fn models_dir() -> Result<PathBuf, String> {
    let d = root()?.join("models");
    std::fs::create_dir_all(&d).map_err(|e| format!("{}: {e}", d.display()))?;
    Ok(d)
}

pub fn digest(bytes: &[u8]) -> String {
    axon::store::digest(bytes)
}

/// `sha256:` plus the first twelve hex characters -- enough to tell two digests apart on one line.
pub fn short(hash: &str) -> &str {
    &hash[..19.min(hash.len())]
}

pub fn put(kind: axon::store::Kind, bytes: &[u8]) -> Result<String, String> {
    use axon::store::Store;
    let hash = digest(bytes);
    let store = axon::store::DirStore::new(models_dir()?);
    if !store.has(kind, &hash) {
        store.put(kind, &hash, bytes).map_err(|e| format!("cannot store {hash}: {e:?}"))?;
    }
    Ok(hash)
}

/// Read a local file, or fetch a URL. The one place a `weights`/`adapter` value becomes bytes.
pub fn bytes_of(spec: &str, base: &Path) -> Result<Vec<u8>, String> {
    if spec.starts_with("http://") || spec.starts_with("https://") {
        return fetch_url(spec);
    }
    let p = if Path::new(spec).is_absolute() { PathBuf::from(spec) } else { base.join(spec) };
    std::fs::read(&p).map_err(|e| format!("cannot read {}: {e}", p.display()))
}

pub fn fetch_url(url: &str) -> Result<Vec<u8>, String> {
    let resp = ureq::get(url).call().map_err(|e| format!("GET {url} failed: {e}"))?;
    let mut buf = Vec::new();
    std::io::Read::read_to_end(&mut resp.into_reader(), &mut buf)
        .map_err(|e| format!("GET {url}: {e}"))?;
    Ok(buf)
}
