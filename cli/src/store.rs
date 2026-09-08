//! The local content-addressed store, and the two ways bytes get into it.
//!
//! Models go where **axon** expects them, because axon is the thing that reads them: the layout is
//! `axon::store::key`, the digest is `axon::store::digest`, and the directory is handed to a real
//! `DirStore`. This is the one config difference between here and the fleet — `AXON_STORE_DIR`
//! against `AXON_STORE_S3_*` — and it is a difference in where the bytes are, not in what reads
//! them.
//!
//! One deliberate local permission: **there is no host allowlist here.** Admission-mode axon
//! restricts where a submission may be downloaded from; a competitor testing on their own machine
//! points at a file on disk. So "it loaded locally" is not "it will be admitted", and the CLI says
//! so rather than letting the difference be discovered at submission.

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

/// Where model bytes live, in axon's own layout.
pub fn models_dir() -> Result<PathBuf, String> {
    let d = root()?.join("models");
    std::fs::create_dir_all(&d).map_err(|e| format!("{}: {e}", d.display()))?;
    Ok(d)
}

/// `sha256:<64 hex>` over some bytes — axon's function, so a hash computed here and a hash
/// computed by the fleet are the same string for the same file.
pub fn digest(bytes: &[u8]) -> String {
    axon::store::digest(bytes)
}

/// Put bytes in the store under their own digest, and answer it.
pub fn put(kind: axon::store::Kind, bytes: &[u8]) -> Result<String, String> {
    use axon::store::Store;
    let hash = digest(bytes);
    let store = axon::store::DirStore::new(models_dir()?);
    if !store.has(kind, &hash) {
        store
            .put(kind, &hash, bytes)
            .map_err(|e| format!("cannot store {hash}: {e:?}"))?;
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
    let resp = ureq::get(url)
        .call()
        .map_err(|e| format!("GET {url} failed: {e}"))?;
    let mut buf = Vec::new();
    std::io::Read::read_to_end(&mut resp.into_reader(), &mut buf)
        .map_err(|e| format!("GET {url}: {e}"))?;
    Ok(buf)
}
