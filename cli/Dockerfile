# syntax=docker/dockerfile:1

# The `tinybrains` CLI as an ARTIFACT IMAGE: one binary that plays a wave on a laptop.
#
# WHY THIS EXISTS. Three repositories need this binary and none of them should need a Rust
# toolchain to get it: `docs` regenerates the book's lesson replays with it, and `drill` and
# `ants-baselines` are competitor-facing and run it to play matches. Until now the only way to get
# it was `cargo install --path ../devops/cli`, which also requires a checkout of `axon` two levels
# up, because this crate links the evaluator AS A LIBRARY rather than over HTTP -- so the component,
# the evaluator digest and the replay envelope are the same artifacts the fleet uses.
#
# AXON ARRIVES AS A NAMED BUILD CONTEXT, for exactly that reason. `Cargo.toml` names it
# `path = "../../axon"`, which is outside this build context; a named context reaches it without
# giving the build a docker socket or making this directory's parent the context. Compose passes
# `${AXON_DIR}`. When axon is published and this crate can name a git revision instead, the
# additional context goes away and `cargo install --git` starts working for everyone else too.

ARG RUST_VERSION=1.98.1
ARG BUSYBOX_VERSION=1.37-musl

# ---- build -------------------------------------------------------------------
#
# Trixie, not bookworm: `ort`'s prebuilt aarch64-linux onnxruntime is compiled against a newer
# libstdc++ than Debian 12 ships. axon's own Dockerfile carries the same note, and the two must move
# together, because this binary links that crate.
FROM rust:${RUST_VERSION}-trixie AS build

# The checkout's own shape, because `path = "../../axon"` is resolved relative to this crate: from
# /src/devops/cli that is /src/axon, and putting either one anywhere else silently fails to resolve.
WORKDIR /src/devops/cli
COPY --from=axon . /src/axon
COPY . .

RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/src/devops/cli/target,sharing=locked \
    cargo build --release --locked --bin tinybrains \
 && cp target/release/tinybrains /usr/local/bin/tinybrains

# ---- the carrier -------------------------------------------------------------
#
# The binary alone, so a consumer does `COPY --from=cli /artifacts/bin/tinybrains /usr/local/bin/`
# and needs nothing else. It is dynamically linked against trixie's libstdc++ through `ort`, so a
# consumer stage has to be trixie-based too -- which is why this carrier ships the binary rather
# than pretending to be a runnable image.
FROM busybox:${BUSYBOX_VERSION}
LABEL org.opencontainers.image.title="tinybrains CLI" \
      org.opencontainers.image.source="https://github.com/Tiny-Brains/devops" \
      org.opencontainers.image.description="one binary that plays a wave on a laptop: the cartridge through wasmtime, adapters and ONNX through axon as a library"

COPY --from=build /usr/local/bin/tinybrains /artifacts/bin/tinybrains

CMD ["sh", "-c", "cp -a /artifacts/. /out/"]
