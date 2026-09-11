# devops

DevOps defines how TinyBrains runs locally: a Docker Compose stack, Orion images and configuration,
database initialization, and a package loader. It assembles independently versioned repositories
into API services, match replicas, model loaders, storage, and a browser application.

## The name

**DevOps** describes the deployment and operations work this repository contains.

## Scope

**It owns**

- Service placement, container networking, published ports, and lifecycle settings.
- The checksum-verified Orion image and separate API/clock and match-replica configurations.
- Environment wiring, credentials, shared stores, and cross-package configuration checks.
- Database initialization and repeatable registration of deployment facts.
- Loading packages into their intended Orion instances.

**It does not**

- Define platform tables; [Soma](https://github.com/Tiny-Brains/soma) owns migrations.
- Implement matchmaking or execution; [Jodi](https://github.com/Tiny-Brains/jodi) and [Kalam](https://github.com/Tiny-Brains/kalam) ship those packages.
- Implement inference, games, or UI; [Axon](https://github.com/Tiny-Brains/axon), [Ants](https://github.com/Tiny-Brains/ants), and [Web](https://github.com/Tiny-Brains/web) supply them.
- Provide a cloud orchestrator, autoscaler, or completed production rollout pipeline.

## Where it sits

```text
[Browser] --> [Web /v1 proxy] --> [Orion: Soma + Jodi] --> [Axon: admission]
                                         |                       |
                                        SQL                 mirror assets
                                         v                       v
                              [platform Postgres]          [shared stores]
                                         ^                       ^
                                        SQL                assets + replays
                                         |                       |
                                [Orion: Kalam replica] <--> [Axon sidecar]

Soma + Jodi: shared Postgres Orion state + Redis
Each Kalam: independent disposable SQLite state; its own sidecar
```

| Direction | Party | Over | What moves |
|---|---|---|---|
| reads | Application repositories | Build contexts and read-only mounts | Packages, migrations, fixtures, and image source |
| writes | Postgres | Initialization and loader SQL | Seed data, role password, game manifest, engine identity |
| calls | Orion admin APIs | Loader HTTP | Package replacement and post-load checks |
| writes | Object store | S3-compatible API | Bucket creation and development fixture assets |

Jodi creates and counts match rows; Kalam claims and finishes them in the same database.
Orion state is a separate concern: sharing it coordinates Jodi's clocks, while isolating it keeps
Kalam's wave singleton local to each replica. All Axons use one model bucket; replays use another.

## Interface

[docker-compose.yml](docker-compose.yml) is the runnable topology. Published host ports bind to
127.0.0.1; they are local access points, not a production ingress configuration.

| Unit | Host port | Image or build source | Role |
|---|---|---|---|
| db | None | postgres:16-alpine | Platform database and Orion cluster-state database |
| redis | None | redis:7-alpine | Shared Orion cluster backend |
| soma | 8080 | compose/orion/, ORION_VERSION | Soma routes and Jodi clocks in cluster mode |
| kalam-1 | 8082 | compose/orion/, ORION_VERSION | Independent match-wave scheduler |
| axon-1 | None | Axon repository | Replica loader in kalam-1's network namespace |
| axon-admission | 9091 | Axon repository | Submission verification and model mirroring |
| loader | None; one-shot | compose/loader/ | Registration, package installation, and checks |
| web | 5173 | Web repository | nginx serving the SPA and /v1 proxy |
| orion-ui | 8081 | ghcr.io/goplasmatic/orion-ui, ORION_UI_VERSION | Operations console |
| minio | 9000, 9001 | Pinned minio/minio release in Compose | S3 endpoint and storage console |
| kalam-2, axon-2 | 8083 for Orion | Same builds; fleet profile | Second independent replica and sidecar |

The loader registers the engine, manifests, role password, buckets, and packages. Database seed
scripts run only on fresh volumes; re-running the loader does not replay migrations.

With the stack running, check the public API:

```sh
curl --fail --silent --show-error http://localhost:5173/v1/games
```

## Run it, test it

A DevOps-only clone cannot build this stack: Compose uses sibling build contexts and package mounts.
Check out these repositories under one parent directory before starting.

| Checkout directory | Repository | Required for |
|---|---|---|
| soma | https://github.com/Tiny-Brains/soma | Schema and API definitions |
| jodi | https://github.com/Tiny-Brains/jodi | Clocks and plugins |
| kalam | https://github.com/Tiny-Brains/kalam | Wave and vendored engine |
| axon | https://github.com/Tiny-Brains/axon | Service image and fixtures |
| ants | https://github.com/Tiny-Brains/ants | Cartridge mount |
| web | https://github.com/Tiny-Brains/web | Browser image |
| devops | This repository | Compose working directory |

Needs Docker with Compose v2 and a POSIX shell; SQL checks also need Python 3. From this repo root:

```sh
test -e .env || cp .env.example .env
```

Fill its required values using the table below. Generate SOMA_SESSION_SECRET with
`openssl rand -hex 32`; register a GitHub OAuth App with homepage `http://localhost:5173` and
callback `http://localhost:5173/v1/auth/github/callback`, matching OAUTH_REDIRECT_URI exactly.

Start the stack, then open http://localhost:5173:

```sh
docker compose up --build -d
```

Check configuration consistency and inspect startup results:

```sh
./scripts/check/configs.sh
docker compose ps -a
docker compose logs loader
```

There is no aggregate test suite. Inspect the loader exit status and plugin/quarantine output.
check/configs.sh checks priors, strikes, engine identity, topology, and drain defaults; it skips
Orion parsing without a local image, so exit zero alone does not prove both templates were parsed.

Reload edited packages with `docker compose run --rm loader`. For two replicas, set
KALAM_ORION_ADMINS to both admin URLs listed in .env.example before running
`docker compose --profile fleet up --build -d`, then rerun the loader if either replica was recreated.
`scripts/dev/seed-baselines.sh` populates development model fixtures; initial SQL hashes alone are not
runnable assets. `scripts/dev/resync-dev-schema.sh` is a guarded pre-release development repair, not a
production migration tool, and refuses populated ladder data.

## What a deployment owes it

[.env.example](.env.example) lists required inputs and optional overrides. Secrets belong in the
ignored .env file locally or the deployment's secret store; the template's development credentials
must be replaced for a deployed environment.

| Variable or setting | Purpose | Missing or inconsistent value |
|---|---|---|
| GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET | OAuth identifier and secret credential | Compose requires them; incorrect registration breaks sign-in |
| SOMA_SESSION_SECRET | Secret session/state key | Compose refuses a missing value; short or inconsistent keys break auth |
| POSTGRES_USER, POSTGRES_DB, POSTGRES_PASSWORD | Database identity and secret password | Missing password stops Compose; incorrect values break connections |
| KALAM_DB_PASSWORD | Secret restricted-role password | Must match the URL used by replicas |
| APP_URL, OAUTH_REDIRECT_URI, SOMA_COOKIE_SECURE | Browser origin and cookie policy | Incorrect values break the OAuth round trip |
| R2_ENDPOINT, R2_BUCKET, R2_ACCESS_KEY, R2_SECRET_KEY | Replay location and secret credentials | Signing/upload fails; the bucket must be browser-accessible for replay reads |
| AXON_STORE_BUCKET, R2_REGION | Shared model bucket and signing region | A split store or wrong signature prevents residency |
| REDIS_URL | Soma cluster backend | Cluster startup needs a reachable Redis |
| KALAM_ORION_ADMINS | Comma-separated active replica admin URLs | Omitted replicas receive no package; nonexistent replicas stall loading |
| ORION_VERSION, ORION_UI_VERSION | Server and console image versions | Defaults apply; compatibility must be checked when changed |
| AXON_MEMORY_BUDGET_BYTES, AXON_IDLE_TTL_S | Loader residency tuning | Defaults apply; undersizing refuses models |
| KALAM_1_ENGINE_DIGEST, KALAM_2_ENGINE_DIGEST | Optional engine pins | Loader rejects a pin inconsistent with the vendored file |
| KALAM_SHUTDOWN_DRAIN_SECS, KALAM_SHUTDOWN_FORCE_SECS, KALAM_CRON_SHUTDOWN_SECS, KALAM_STOP_GRACE | Replica shutdown policy | Too-short outer deadlines interrupt waves |
| SOMA_SHUTDOWN_DRAIN_SECS, SOMA_SHUTDOWN_FORCE_SECS, SOMA_CRON_SHUTDOWN_SECS, SOMA_STOP_GRACE | API/clock shutdown policy | In-flight work may be cut short |
| SEASON_GAP_DAYS | Season-opening policy | Default applies; must reach the Soma container |
| GITHUB_TOKEN | Read-only token the repository-ownership check calls GitHub with | Optional, and a bad default: unset means 60 requests an hour for the whole server, and model creation refuses once that runs out. `check/configs.sh` says so |

The templates contain application `[vars]` and provisional policy values. A rollout needs new capacity ready
before changing the active digest, then drain old replicas; the local loader's pending-row restamping
is a development convenience, not that rollout protocol.

## Layout

```text
docker-compose.yml            services, networks, mounts, profiles, and volumes
.env.example                  configuration contract without private credentials

compose/                      everything the Compose file builds or mounts
  orion/Dockerfile            checksum-verified upstream Orion image
  orion/entrypoint.sh         instance startup and derived engine identity
  orion/soma.toml.tmpl        clustered Soma/Jodi runtime and policy
  orion/kalam.toml.tmpl       independent wave runtime and policy
  loader/Dockerfile           package-loader image
  loader/run.sh               registration, package loading, and health checks
  db-init/                    fresh-volume database initialization and seed

scripts/                      grouped by what they do to a stack
  setup/admin-key.sh          mints the Orion admin credential into .env
  setup/trust-keygen.sh       mints the Ed25519 plugin trust root for this machine
  setup/sign-plugins.sh       signs every plugin component with it
  deploy/declare-engine.sh    the engine cutover, with its fleet preflight
  dev/seed-baselines.sh       development model-store fixtures
  dev/resync-dev-schema.sh    guarded development schema repair
  check/configs.sh            cross-template assertions and the Orion parse check
  check/claim-load.sh         what a claim costs under N concurrent pollers
  check/autoscale.sh          drives the autoscaler query against staged ladders

cli/                          the `tinybrains` binary: run a match on a laptop, any game
games/registry.toml           which games exist, and where their artifacts come from
docs/                         architecture, decisions, deployment, Orion notes
```

`scripts/deploy/` is mounted into the loader container at `/deploy`, so a deploy step runs where
the database and the admin API are both reachable:

```sh
docker compose run --rm --no-deps --entrypoint /deploy/declare-engine.sh loader
```

### The local loop

`cli/` builds `tinybrains`, one binary that plays a wave on a laptop with no Compose, no database
and no season. It loads the cartridge component through wasmtime, evaluates adapters and ONNX
graphs through **axon as a library**, and writes the same replay envelope Kalam writes.

```sh
cargo install --path cli               # or --git this repository
tinybrains games                       # what is registered, at which digest
tinybrains matches/quick.json          # play it; one replay per row
tinybrains view replays/quick.json     # watch it
tinybrains check model.onnx adapter.json   # would it be admitted?
```

`check` runs admission's own two calls -- `inspect` and `validate`, in the same crate -- against
the game's committed reference observations, and reports the worst-case adapter cost as a
percentage of the budget. It says on every run that it is necessary and not sufficient: there is no
download allowlist here, and the size class is reported rather than decided, because the class
table is platform policy that lives in Jodi.

It lives here rather than in a game repository because **it knows no game**. It knows five function
names, `cartridge.json`, and the replay envelope; every board, preset, seat count and limit is read
from the manifest. Adding a second game is an entry in `games/registry.toml` and no Rust at all,
which is the claim `ants/docs/cartridge.md` makes about the platform and this is where it is tested.

A seat can also be **scripted** rather than modelled: `"script": ["E", "E", "-"]` reads its orders
instead of inferring them, never reaches the loader, and still goes through the cartridge. That is
how the book's teaching replays are made -- "two ants walk into the same square" has to happen
exactly, and no model can be relied on to do it. A lesson costs no ONNX and no model store, and
still demonstrates the rules rather than a drawing of them.

Its input is a wave, not a set of flags. `match.json` is `K_WAVE`'s rows plus the Orion `[vars]`
they run under, so a real claim can be dumped to a file and replayed on a laptop. The one local
addition is that a seat may name `weights`/`adapter` as a path or a URL instead of the two hashes;
a file that uses only hashes is byte-compatible with what the database holds.

**What is identical to production**, and this is the point: the component (same file, same digest),
axon (same crate, same `evaluator_digest`), `cartridge.json`, the boards, and the envelope. What
differs is config — a directory model store instead of S3, a file instead of a presigned PUT, and
rows from a file instead of a claim under a lease.

**Where it is a copy and not the thing**: the wave loop. Kalam expresses it as an Orion workflow of
JSONLogic and `cli/src/wave.rs` expresses it as Rust; nothing makes those one artifact, and its
docstring names the five behaviours it has to copy exactly. So the agreement is checked rather than
argued:

```sh
tinybrains conform replays/some-match.json
```

That rebuilds the match from the envelope alone — its board, its seed, its seats — plays it here,
and diffs every field and every turn of the action stream. It has been run against a replay this
stack wrote: identical, all 150 turns. A difference in the deltas is the one that matters, because
ranks and scores can agree while the match that produced them differs.

### Plugin signing

Every Orion here sets `[plugins.trust] public_keys`, so no plugin loads without a detached Ed25519
signature over its component digest — the ASCII `sha256:<64 hex>`, not the bytes — checked when the
upload arrives and again by every node that loads it. A fresh checkout mints its own root:

```
./scripts/setup/trust-keygen.sh   writes keys/ (ignored) and TB_TRUST_PUBLIC_KEY into .env
./scripts/setup/sign-plugins.sh   writes <component>.sig beside each plugin
docker compose run --rm loader load
```

Re-run `setup/sign-plugins.sh` after any plugin or engine rebuild. A stale or
missing signature is not silent: the node reports `degraded`, names the plugin and the digest under
`plugins.failed_to_load` with `stage: "signature"`, and quarantines the channels whose workflows
needed it. The private half never lives here — a deployment signs with its own key from its
orchestrator's secret store and sets only the public half.

## What must stay true

- **The CLI knows no game.** `cli/` never links an engine crate and never names a cartridge's types; a second game is a registry entry. If that stops being true the seam has quietly moved.
- **A local result and a ladder result are the same match.** `tinybrains conform` is the check, and `cli/src/wave.rs` is the only place a copy of Kalam's loop is allowed to live.

- **Jodi shares scheduler state; Kalam replicas do not.** `check/configs.sh` checks the cluster split so a fleet does not accidentally share one wave lock.
- **Admission and play use the same model store.** Compose wires the same bucket into both roles; review must preserve that equality.
- **Engine identity comes from the deployed bytes.** Entrypoint and loader derivation prevent an apparently healthy replica from claiming no compatible work.
- **Disposable Orion state requires package initialization.** The loader checks the required plugin and rejects quarantined channels, but does not yet explicitly assert tb-wave presence.
- **Shutdown deadlines allow the intended drain.** The config check compares server force and cron defaults; deployment overrides and container grace must also agree.
- **Schema ownership stays in Soma.** Initialization applies its migrations rather than maintaining a deployment-only schema copy.

## Status

**Baselines are ordinary entries, 11 September 2026 — decision 28 is taken.** A baseline is paced,
rated, share-capped and settled like any version; its tag and its seat opposite every trial are all
that set it apart. `scripts/check/autoscaler.sql` follows, and prepares again: it had drifted to
`FROM models … md.model_id`, a column the entry/version split took away.

**Trained baselines are on the ladder, 10 September 2026.** Three artifacts from
`Tiny-Brains/ants-baselines` are seeded, resident on both fleet replicas, and rated: a match between
two of them ran 523 turns with zero strikes, uploaded its replay and folded into ratings. The
roster in `30-seed.sql` is a `(handle, class)` list and `scripts/dev/seed-baselines.sh` reads the
`metrics.json` each artifact carries, so a seeded baseline is indistinguishable from an admitted
version. It can also create a baseline an existing volume lacks, which is what avoids `down -v`.

**The engine was cut over** to `sha256:f17b51b6c92b` -- ants' observer-relative fix -- across both
replicas, the game row and the live season. Two silent failures surfaced doing it and are now
documented in CLAUDE.md: the loader visits only `KALAM_ORION_ADMINS`, so a fleet replica can come up
READY with no wave channel; and restarting a `kalam-N` orphans its `axon-N` sidecar's network
namespace while both keep reporting healthy.

**Baselines infrastructure, 10 September 2026.** `tinybrains env` hosts the cartridge as a batched
training environment over JSON Lines -- a pool of independent waves, refilled in place, with the
per-turn score `finish` answers for a live match. Measured on an M2 Pro at **4,900 seat-turns/s**
with real colonies (22 ants a seat by turn 300) and 4,100/s through a Python client, against a gate
of 3,000. It is not the referee and says so on startup. `tinybrains adapt` writes an adapter's `in`
tensors as `.npy` so a trainer's own encoder can be diffed against the ladder's rather than trusted.

**Decision 46, 10 September 2026 — no compute cap**, recorded in `docs/decisions.md` with the
measurements that argued it. The loader's manifest gate no longer requires `budgets.flop_caps`;
`30-seed.sql` writes `infer_us` and names the baselines repo `Tiny-Brains/ants-baselines` (the org
was wrong, and admission pastes that string into a URL). `tinybrains` reports attributed inference
time — mean and worst per seat-turn, against the deadline divided by the seats in a call — where it
used to sum `elapsed_ms` and overstate the cost by roughly the wave size, and **the replay envelope's
`seats` array now records `infer_us_total`, `infer_us_max` and `seat_turns` per seat**, so a replay
carries what each model cost and not only what it scored. `conform` reads an explicit field
allowlist that excludes `seats`, so a non-reproducible number there cannot fail a determinism check.
Two seats sharing one `weights_hash` batch into one group and are charged an equal share of it,
which is why the committed fixtures — one Micro trunk read two ways — report the same cost. **A stale vendored engine
was found and fixed**: `kalam/plugins/tb-ants/tb-ants.wasm` was `254549b4`, `ants` ships `1555f081`,
so `check/configs.sh` was failing on the committed tree and local play and the fleet were running
different engines. Re-vendored and re-signed.

**10 September 2026.** Compose defines the API/clock split, sidecars, shared storage, and second replica. `scripts/check/configs.sh` passes consistency checks
and parses both templates with the pinned Orion image. A fresh full-stack startup,
live OAuth, real R2, mixed-engine rollout, cloud deployment, autoscaling, TLS, admin authentication,
and plugin trust enforcement are not verified by that result; the production deployment work remains open.

## More

- Local references: [Compose topology](docker-compose.yml), [environment contract](.env.example), and [runtime templates](compose/orion/).
- Design docs: [`docs/architecture.md`](docs/architecture.md) (the whole-system map), [`docs/decisions.md`](docs/decisions.md), [`docs/deployment.md`](docs/deployment.md), [`docs/orion-notes.md`](docs/orion-notes.md).
- [The competitor guide](https://github.com/Tiny-Brains/docs) — the reader-facing half: the rules, the model format, the adapter dialect, submitting, ranking and seasons. The platform section is the high-level design for someone new to the codebase.
- Application repositories: [Soma](https://github.com/Tiny-Brains/soma), [Jodi](https://github.com/Tiny-Brains/jodi), [Kalam](https://github.com/Tiny-Brains/kalam), [Axon](https://github.com/Tiny-Brains/axon), [Ants](https://github.com/Tiny-Brains/ants), [Web](https://github.com/Tiny-Brains/web).
- Apache-2.0: see [LICENSE](LICENSE).
