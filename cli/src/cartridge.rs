//! The cartridge, hosted.
//!
//! A plugin component's world is tiny and imports nothing:
//!
//! ```wit
//! invoke: func(function: string, input: string) -> result<string, plugin-error>;
//! ```
//!
//! That is the whole ABI, so hosting one is a wasmtime `Engine`, a `Component` and a call. No
//! WASI, no filesystem, no clock — the same sandbox Orion gives it, for the same reason: a
//! cartridge that could read a file could disagree with itself between two hosts.
//!
//! **Nothing in this file knows what game it is running.** It knows five function names live
//! behind one entry point and that both sides of the call are JSON. Everything game-shaped —
//! presets, seats, boards, limits — is read from `cartridge.json`, the same document the platform
//! registers. That is the property the whole CLI rests on, and it is cheap to keep: this module
//! never names Ants and never links its crate.

use std::path::Path;

use serde_json::Value;
use wasmtime::component::{Component, Linker};
use wasmtime::{Config, Engine, Store};

wasmtime::component::bindgen!({
    path: "wit",
    world: "plugin",
});

/// A refusal the cartridge chose to make, or the host failing to reach one.
#[derive(Debug)]
pub struct Fault {
    pub code: String,
    pub message: String,
}

impl std::fmt::Display for Fault {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl Fault {
    fn host(message: impl Into<String>) -> Fault {
        Fault { code: "HOST".to_string(), message: message.into() }
    }
}

pub struct Cartridge {
    engine: Engine,
    component: Component,
    linker: Linker<()>,
}

impl Cartridge {
    /// Compile a component once. Compilation is per digest per process in Orion too, and
    /// instantiation is microseconds — so a wave compiles once and instantiates per call.
    pub fn open(path: &Path) -> Result<Cartridge, Fault> {
        let mut cfg = Config::new();
        cfg.wasm_component_model(true);
        let engine = Engine::new(&cfg).map_err(|e| Fault::host(format!("wasmtime: {e}")))?;
        let bytes = std::fs::read(path)
            .map_err(|e| Fault::host(format!("cannot read {}: {e}", path.display())))?;
        let component = Component::from_binary(&engine, &bytes)
            .map_err(|e| Fault::host(format!("{} is not a component: {e}", path.display())))?;
        let linker = Linker::new(&engine);
        Ok(Cartridge { engine, component, linker })
    }

    /// One call. A fresh instance every time, because the sandbox keeps nothing between
    /// invocations and a host that reused one would be testing a cartridge the platform will
    /// never run.
    pub fn invoke(&self, function: &str, input: &Value) -> Result<Value, Fault> {
        let mut store = Store::new(&self.engine, ());
        let plugin = Plugin::instantiate(&mut store, &self.component, &self.linker)
            .map_err(|e| Fault::host(format!("instantiate: {e}")))?;
        let text = serde_json::to_string(input)
            .map_err(|e| Fault::host(format!("input is not serialisable: {e}")))?;

        match plugin
            .orion_plugin_functions()
            .call_invoke(&mut store, function, &text)
            .map_err(|e| Fault::host(format!("trap in {function}: {e}")))?
        {
            Ok(out) => serde_json::from_str(&out)
                .map_err(|e| Fault::host(format!("{function} did not return JSON: {e}"))),
            Err(e) => Err(Fault { code: e.code, message: e.message }),
        }
    }
}
