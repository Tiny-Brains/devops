# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`devops` is **the deployment surface** for TinyBrains: the Compose topology, the Orion image and its
two instance configs, database initialization, the package loader, and `cli/` (the `tinybrains`
binary). Soma, Jodi and Kalam are separate repos that each ship a self-contained Orion package and
know nothing about the topology — **this repo decides how many servers there are and which package
goes in which.**

It is one of ten repos checked out side by side under `tinybrains/`; see `../CLAUDE.md` for the
platform-wide map. Compose still reaches siblings for the packages it mounts, but every path is now
a variable (`SOMA_DIR`, `JODI_DIR`, `KALAM_DIR`, `AXON_DIR`) rather than a hard-coded `../`, and the
cartridge no longer comes from a checkout at all — see the `ants-artifacts` note below.

`docs/architecture.md` is the system map, `docs/deployment.md` the topology and deploy order,
`docs/decisions.md` the numbered decisions referenced throughout, `docs/orion-notes.md` the Orion
1.7.0 gotchas found while building this. Update `README.md`'s Status block and
`../design/tracker.md` when work lands.

## Commands

```sh
# the stack (needs .env, see .env.example)
docker compose up --build -d                     # http://localhost:5173, Orion admin 8080, orion-ui 8081
docker compose run --rm loader                   # reload packages after editing soma/jodi/kalam
docker compose --profile fleet up --build -d     # adds kalam-2 + axon-2 (set KALAM_ORION_ADMINS first)
docker compose logs loader                       # the one place a failed package load is visible
docker compose down -v                           # the only way to re-run compose/db-init/

# first run on a fresh checkout, in this order
./scripts/setup/admin-key.sh                     # ORION_ADMIN_KEY -> .env
./scripts/setup/trust-keygen.sh                  # keys/ (ignored) + TB_TRUST_PUBLIC_KEY -> .env
./scripts/setup/sign-plugins.sh                  # <component>.sig beside each plugin

# checks (there is no test suite; these are the tests)
./scripts/check/configs.sh                       # cross-template equalities + real orion-server parse
./scripts/check/claim-load.sh [secs]             # what a claim costs under N pollers; needs db up
./scripts/check/autoscale.sh                     # drives the autoscaler query against staged ladders

# development fixtures / repair
./scripts/dev/seed-baselines.sh                  # real weights+adapters for the seeded baselines
./scripts/dev/resync-dev-schema.sh               # rebuild schema, keep users+sessions; refuses real ladders

# a deploy step, run where the DB and admin API are both reachable
docker compose run --rm --no-deps --entrypoint /deploy/declare-engine.sh loader

# the CLI
cd cli && cargo build                            # or: cargo install --path cli
tinybrains games                                 # what is registered, at which digest
tinybrains matches/quick.json                    # play a wave; one replay per row
tinybrains view replays/quick.json               # watch it (serves the cartridge's own viz bundle)
tinybrains check model.onnx adapter.json         # would this be admitted?
tinybrains conform replays/quick.json            # replay a recorded match here and diff
tinybrains adapt adapter.json --out tensors      # the tensors the adapter actually produces
tinybrains env --waves 4 --matches-per-wave 16   # the cartridge as a training env, JSON Lines
```

`cli/` has **no tests** — `tinybrains conform` is the check (see Architecture). Run it from a
directory holding a `games.toml`, or set `TINYBRAINS_REGISTRY`; `TINYBRAINS_HOME` moves the model
cache off `~/.cache/tinybrains`.

Compose refuses to start without `POSTGRES_PASSWORD`, `SOMA_SESSION_SECRET`, `GITHUB_CLIENT_ID`,
`GITHUB_CLIENT_SECRET`, `ORION_ADMIN_KEY` and `TB_TRUST_PUBLIC_KEY`. `web`'s `/docs` mount needs
`mdbook build` run in `../docs` first; without it `/docs` 404s and nothing else is affected.

## Layout

`compose/` holds everything `docker-compose.yml` builds or mounts (`orion/`, `loader/`, `db-init/`).
`scripts/` is grouped by what a script does to a stack: `setup/` mints credentials, `deploy/` changes
a running system, `dev/` is local-only fixtures and repair, `check/` asserts without changing.
`scripts/deploy/` is mounted into the loader container at `/deploy`, which is why deploy steps are
addressed as `/deploy/<name>.sh` and not by their repo path.

## Architecture

**Two Orion units, and the split is not a scaling choice in either direction.** An Orion singleton
is a *row in the state database*, so "cluster-wide" means "state-database-wide". `soma` runs Soma's
routes and Jodi's four clocks in **cluster mode** over shared `orion_state` + Redis — two of them
over two state databases would be two `tb-count` clocks folding the same matches. Each `kalam-N` is
its own Orion, single instance, local SQLite, **no `[cluster]` block** (decision 41) — put N
replicas over one shared state and the `wave` singleton becomes fleet-wide, so exactly one replica
ever plays while the other N-1 poll a held row looking perfectly healthy. Kalam's fence is the
leased claim on `matches`, not Orion's, so nothing is lost.

**Packages come from images, not checkouts — two of four converted.** `ants` and `jodi` ship
artifact images; `<pkg>-artifacts` one-shots copy them into `ants-pkg` and `jodi-pkg`, and the loader
mounts those where it used to mount the sibling directories. `soma` and `kalam` are still bind
mounts. `JODI_REF` works exactly as `ANTS_REF` does: unset it builds from `JODI_DIR`, set to a tag
it pins.

**Plugin signatures live in `keys/signatures/`, not beside the components.** A signature belongs to
whoever holds the trust key, and a package that ships as an immutable image several deployments can
share cannot carry one. `scripts/setup/sign-plugins.sh` reads components out of the package volumes
(and out of the sibling checkouts that are not converted yet), writes `<component>.sig` into
`keys/signatures/`, and compose mounts that at `/sig` with `PLUGIN_SIG_DIR=/sig`. Each package's
`load-package.sh` honours it, falling back to beside the component when unset. This also ended this
repo writing `.sig` files into `../jodi` and `../kalam`.

**A package volume holds the whole package, including its `load-package.sh`.** Rebuild the artifact
image AND re-run its `-artifacts` one-shot after editing anything in a converted package — a stale
volume runs the script it was populated with, which fails like a bug in the change you just made.
Found on 10 September 2026: a patched `load-package.sh` that never reached the volume loaded the
plugins unsigned, and a node with trust keys refuses that with a bare 400.

**The cartridge's artifacts come from an image, not a checkout.** `ants` stopped committing its
build output on 10 September 2026; it ships an artifact image carrying the component, its manifests,
the board catalogue, the reference observations and the viewer under `/artifacts/`. The
`ants-artifacts` one-shot copies that into the `ants-pkg` volume, and the loader mounts the volume
where it used to mount `../ants` — so `games.reference_observations` is now the engine's own set
rather than axon's single worst-case fixture standing in for it. `ANTS_REF` selects what runs:
unset, it builds `tinybrains/ants:dev` from `ANTS_DIR`; set to a published tag it pins the engine
digest as a deployment decision and needs no ants checkout at all. Kalam still loads its own
vendored copy — that conversion has not landed yet, so two copies of the component still exist.

**The engine digest agrees in three places by derivation, never by typing.** `compose/orion/
entrypoint.sh` derives `KALAM_ENGINE_DIGEST` from `../kalam/plugins/tb-ants/tb-ants.wasm`;
`compose/loader/run.sh` derives the same value and writes `games.active_engine_digest` and the live
season's copy. The plugin Orion keys by sha256, the claim filter, and the column must all match —
and **a mismatch is not an error anywhere**: the wave claims nothing, for ever, and every replica
stays healthy and idle. `scripts/deploy/declare-engine.sh` is the deploy-time version, and its
preflight refuses to declare a digest no replica carries.

**Axon is one binary in two roles that must share one store.** `axon-admission` accepts URLs from
allowlisted hosts and mirrors verified bytes under their hash *inside* `/load`; each `axon-N` fetches
by hash and its fetch allowlist is empty whatever the environment says. Two stores means admission
succeeds and every match the version is then paired for fails at the residency barrier, quietly and
far from the cause. `axon-N` shares its replica's network namespace (`network_mode:
service:kalam-N`), so the wave reaches it at `127.0.0.1:9090` — the committed default in
`kalam/connectors/model-loader.json`, so no URL is substituted and the package is byte-for-byte the
same on every replica. The cost is that an axon sidecar publishes no ports of its own.

**The loader is a one-shot (`restart: "no"`) and the only writer of deployment facts.** `setup` is
four idempotent statements — role passwords, the engine digest, `games.manifest` +
`reference_observations`, the two buckets. `load` sweeps each target of the package tags it must
*not* run, then installs each package by running that repo's own `scripts/load-package.sh`. One call
reaches every node of the soma cluster (an admin mutation advances a shared config epoch), but
`KALAM_ORION_ADMINS` is visited one entry at a time because each replica has its own state database
and there is no epoch bus between them. It then asserts the plugin is actually loaded: **`/readyz`
goes green before packages load**, so a replica whose load failed is READY, has no wave channel,
claims nothing, and is invisible capacity that no dashboard reports.

**Packages coordinate only through the shared Postgres schema.** Jodi inserts queued rows; Kalam
claims them under a lease and writes results; Jodi's count clock folds them. Nothing in this repo
should make one package call another.

**`cli/` knows no game.** It never links an engine crate and never names a cartridge's types: it
knows five function names, `cartridge.json`, and the replay envelope, and resolves a game from
`games/registry.toml` (a sibling checkout, digest *reported*; or a release, digest *pinned* and
refused on mismatch). It hosts the cartridge through wasmtime and evaluates adapters through **axon
as a library**, so the component, the evaluator digest and the envelope are the same artifacts the
fleet uses. Adding a second game is a registry entry and no Rust.

**`cli/src/env.rs` is a training environment and deliberately not a third wave loop.** It has the
four cartridge functions and a pool that refills them, and none of Kalam's rules: no deadline, no
strike ceiling, no forfeits, no model loader, no replay envelope. That is what lets it not be a copy
that drifts -- and it is why its actions are *positional*, which is only correct because a training
env never forfeits a seat. Needing the explicit `{m, seat, action}` form is the symptom of a rule it
does not have. It reads live scores out of `finish` every turn, which the cartridge answers for an
unfinished match; that is the trainer's reward channel and never reaches a model's input.

**`cli/src/wave.rs` is the one place a second implementation is allowed.** Kalam expresses the wave
loop as an Orion workflow of JSONLogic; this expresses it as Rust, and its docstring names the five
behaviours it must copy exactly (explicit `{m, seat, action}` form, forfeited seats omitted entirely,
cumulative strikes, forfeit rank = `engine_rank + seat_count`, flat `refs`). Copies drift, so the
agreement is **checked rather than argued**: `tinybrains conform <replay>` rebuilds a match from its
envelope alone, plays it locally, and diffs every field and every turn of the action stream. A
difference in `deltas` is the one that matters — ranks and scores can agree while the match that
produced them differed.

**Plugin trust is a signature over the digest *string*.** `[plugins.trust] public_keys` non-empty
means every upload must carry a detached Ed25519 signature over the ASCII `sha256:<64 hex>`, not
over the component bytes — verified when the upload arrives and again by every node that loads it.
That is why a release pipeline can sign without holding the component, and why the private half
never lives here.

## What breaks if you forget it

- **`docker-compose.yml` and `.env.example` must stay at the repo root.** Compose takes its *project
  directory* from the compose file's location and auto-loads `.env` from there; moving the file into
  `compose/` would silently stop `.env` being read.
- **`kalam.toml.tmpl` must never grow a `[cluster]` block, and `soma.toml.tmpl` must keep one.** Both
  directions fail silently; `scripts/check/configs.sh` asserts them.
- **Values that live in two files:** Jodi's `forfeit_strikes` == Kalam's `strike_ceiling` (or count
  judges a trial by a rule the wave did not play by), and `prior_mu`/`prior_sigma` in
  `soma.toml.tmpl` == the numbers in `compose/db-init/30-seed.sql` (a baseline's first fold reads
  `[vars]` as its own prior). The check script asserts both.
- **Re-run `scripts/setup/sign-plugins.sh` after any plugin or engine rebuild**, including
  `kalam/scripts/vendor-engine.sh`. A stale signature brings the node up `degraded` with quarantined
  channels.
- **Kalam vendors the cartridge, so two committed copies of one component exist and can drift.**
  When they do nothing errors — the ladder plays a component `ants` does not ship, with a viewer
  built against the other. `scripts/check/configs.sh` compares them; it has caught this before, from
  an edit that changed no behaviour at all.
- **Restarting a `kalam-N` orphans its `axon-N`, and both keep reporting healthy.** The sidecar
  joins the replica's network namespace (`network_mode: service:kalam-N`), and a `docker compose
  restart` of the replica leaves the sidecar holding the OLD namespace. Its healthcheck curls its
  own localhost, so it stays green; the replica gets connection refused at `127.0.0.1:9090` and
  fails every row of every wave. **Recreate the pair together** — `docker compose up -d
  --force-recreate kalam-N axon-N` — or recreate the sidecar after restarting the replica. Found on
  10 September 2026 by restarting kalam-1 for the engine cutover and then wondering why the loader
  had vanished.
- **`axon` is a *path* dependency of `cli/`.** A field removed from `axon::config::Config` breaks the
  CLI build and nothing in axon's own tests notices, so build `cli/` after changing axon.
- **Schema changes live in `soma/migrations/` only.** `compose/db-init/` runs once per volume, so a
  pre-release rewrite strands existing dev stacks — it surfaces as `relation "clocks" does not exist`
  on every count tick. `scripts/dev/resync-dev-schema.sh` is the answer.
- **`scripts/check/autoscaler.sql` has three unreferenced CTEs (`pool`, `played`, `depth`) on
  purpose.** They are verbatim from jodi's `tb-pair-run.json`; the file's whole point is that what
  runs is what pair computes. Do not tidy them away.
- **`docker-compose.yml` uses YAML anchors for the replica pairs.** After editing them, confirm the
  resolved graph is unchanged: `docker compose --profile fleet config` and diff the `services:`
  blocks — the `x-*` fragments are echoed but ignored.
- **The published ports all bind `127.0.0.1`,** and the Orion admin plane is behind them. Do not bind
  any of them to a routable address.
