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
| soma | 8080 | orion/, ORION_VERSION | Soma routes and Jodi clocks in cluster mode |
| kalam-1 | 8082 | orion/, ORION_VERSION | Independent match-wave scheduler |
| axon-1 | None | Axon repository | Replica loader in kalam-1's network namespace |
| axon-admission | 9091 | Axon repository | Submission verification and model mirroring |
| loader | None; one-shot | loader/ | Registration, package installation, and checks |
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
./scripts/check-configs.sh
docker compose ps -a
docker compose logs loader
```

There is no aggregate test suite. Inspect the loader exit status and plugin/quarantine output.
check-configs.sh checks priors, strikes, engine identity, topology, and drain defaults; it skips
Orion parsing without a local image, so exit zero alone does not prove both templates were parsed.

Reload edited packages with `docker compose run --rm loader`. For two replicas, set
KALAM_ORION_ADMINS to both admin URLs listed in .env.example before running
`docker compose --profile fleet up --build -d`, then rerun the loader if either replica was recreated.
`scripts/seed-baselines.sh` populates development model fixtures; initial SQL hashes alone are not
runnable assets. `scripts/resync-dev-schema.sh` is a guarded pre-release development repair, not a
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

The templates contain application `[vars]` and provisional policy values. A rollout needs new capacity ready
before changing the active digest, then drain old replicas; the local loader's pending-row restamping
is a development convenience, not that rollout protocol.

## Layout

```text
docker-compose.yml     services, networks, mounts, profiles, and volumes
.env.example           configuration contract without private credentials
orion/Dockerfile        checksum-verified upstream Orion image
orion/entrypoint.sh     instance startup and derived engine identity
orion/soma.toml.tmpl    clustered Soma/Jodi runtime and policy
orion/kalam.toml.tmpl   independent wave runtime and policy
loader/Dockerfile       package-loader image
loader/run.sh           registration, package loading, and health checks
db-init/                fresh-volume database initialization and seed
scripts/check-configs.sh shared configuration assertions and optional parser checks
scripts/trust-keygen.sh  mints the Ed25519 plugin trust root for this machine
scripts/sign-plugins.sh  signs every plugin component with it
scripts/declare-engine.sh the engine cutover: deploy step 6, with its fleet preflight
scripts/seed-baselines.sh development model-store fixtures
scripts/resync-dev-schema.sh guarded development schema repair
```

### Plugin signing

Every Orion here sets `[plugins.trust] public_keys`, so no plugin loads without a detached Ed25519
signature over its component digest — the ASCII `sha256:<64 hex>`, not the bytes — checked when the
upload arrives and again by every node that loads it. A fresh checkout mints its own root:

```
./scripts/trust-keygen.sh     writes keys/ (ignored) and TB_TRUST_PUBLIC_KEY into .env
./scripts/sign-plugins.sh     writes <component>.sig beside each plugin
docker compose run --rm loader load
```

Re-run `sign-plugins.sh` after any plugin rebuild or `kalam/scripts/vendor-engine.sh`. A stale or
missing signature is not silent: the node reports `degraded`, names the plugin and the digest under
`plugins.failed_to_load` with `stage: "signature"`, and quarantines the channels whose workflows
needed it. The private half never lives here — a deployment signs with its own key from its
orchestrator's secret store and sets only the public half.

## What must stay true

- **Jodi shares scheduler state; Kalam replicas do not.** check-configs.sh checks the cluster split so a fleet does not accidentally share one wave lock.
- **Admission and play use the same model store.** Compose wires the same bucket into both roles; review must preserve that equality.
- **Engine identity comes from the deployed bytes.** Entrypoint and loader derivation prevent an apparently healthy replica from claiming no compatible work.
- **Disposable Orion state requires package initialization.** The loader checks the required plugin and rejects quarantined channels, but does not yet explicitly assert tb-wave presence.
- **Shutdown deadlines allow the intended drain.** The config check compares server force and cron defaults; deployment overrides and container grace must also agree.
- **Schema ownership stays in Soma.** Initialization applies its migrations rather than maintaining a deployment-only schema copy.

## Status

**8 September 2026.** Compose defines the API/clock split, sidecars, shared storage, and second replica. `scripts/check-configs.sh` passes consistency checks
and parses both templates with the pinned Orion image. A fresh full-stack startup,
live OAuth, real R2, mixed-engine rollout, cloud deployment, autoscaling, TLS, admin authentication,
and plugin trust enforcement are not verified by that result; the production deployment work remains open.

## More

- Local references: [Compose topology](docker-compose.yml), [environment contract](.env.example), and [runtime templates](orion/).
- Design docs: [`docs/architecture.md`](docs/architecture.md) (the whole-system map), [`docs/decisions.md`](docs/decisions.md), [`docs/deployment.md`](docs/deployment.md), [`docs/orion-notes.md`](docs/orion-notes.md).
- [The competitor guide](https://github.com/Tiny-Brains/docs) — the reader-facing half: the rules, the model format, the adapter dialect, submitting, ranking and seasons. The platform section is the high-level design for someone new to the codebase.
- Application repositories: [Soma](https://github.com/Tiny-Brains/soma), [Jodi](https://github.com/Tiny-Brains/jodi), [Kalam](https://github.com/Tiny-Brains/kalam), [Axon](https://github.com/Tiny-Brains/axon), [Ants](https://github.com/Tiny-Brains/ants), [Web](https://github.com/Tiny-Brains/web).
- Apache-2.0: see [LICENSE](LICENSE).
