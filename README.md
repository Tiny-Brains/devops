# devops

Deployment for [TinyBrains](https://github.com/Tiny-Brains): the compose stack, the environment
template, the database init scripts, the Orion image and its instance config. Everything that
names a host, a port, a secret or a topology lives here; the application repos carry only their
package — `Tiny-Brains/soma` (the REST surface), `Tiny-Brains/jodi` (a version's life cycle:
admit, pair, count, withdraw), `Tiny-Brains/kalam` (the wave that plays matches) — plus
`Tiny-Brains/axon` (the Model Loader, the one process that is not Orion) and `Tiny-Brains/web`
(the shell).

## Layout

```
docker-compose.yml        db, redis, soma, kalam-1(+2), loader, orion-ui, web,
                          axon-1(+2), axon-admission, minio
.env.example              copy to .env and fill in the blanks
orion/Dockerfile          upstream orion-server 1.7.0, verified -- nothing baked in
orion/entrypoint.sh       one script, both roles: it asks the mounted config what it needs
orion/soma.toml.tmpl      Soma + Jodi, CLUSTER MODE over Postgres and Redis
orion/kalam.toml.tmpl     one replica: no cluster, local SQLite, the wave's numbers
orion/orion.local.toml    host development -- not committed, see .gitignore
loader/                   one-shot: declares the deployment facts, then installs each package
                          into the server that runs it
db-init/                  run once on a fresh volume: Orion's state database, then the seed
scripts/                  check-configs.sh, plus the things still done by hand -- see "Useful"
```

## Two Orion units, and why each one must be what it is

Layer 07 split the one server in two, and **neither half is a scaling choice**:

| Unit | Shape | Why |
|---|---|---|
| `soma` | cluster mode, N ≥ 1, shared `orion_state` + Redis | Jodi's four clocks are cluster-wide singletons, and a `forbid` singleton is a **row in the state database**. Two Orions over one `orion_state` are one scheduler; two over two are two `tb-count` clocks folding the same matches — which the fence makes safe but not *once* |
| `kalam-N` | one Orion each, **no cluster**, local SQLite | the mirror image. Put N replicas over one shared state and the `wave` singleton becomes fleet-wide, so **exactly one replica ever plays** and the other N−1 poll a held row looking perfectly healthy. Verified here: two replicas run **two concurrent waves** |

Kalam loses nothing by it, because its fence is not Orion's — it is the leased claim on `matches`.

**A replica's Orion state is disposable**: a SQLite file on the container filesystem with no volume
behind it, holding the loaded package and nothing else. **So re-running `loader` is part of
recreating a replica** — `docker compose up -d --force-recreate kalam-1` gives you a replica with
no `tb-wave` channel, which is *ready*, claims nothing, and is invisible capacity. The loader
asserts `tb.ants` is loaded on every replica for exactly that reason.

The compose file builds from `./orion`, `./loader`, `../axon` and `../web`, and mounts `../soma`,
`../jodi`, `../kalam` and `../ants` read-only, so the repos sit side by side:

```
tinybrains/
  devops/     this repo
  soma/  jodi/  kalam/     Orion packages: definitions, plugins, a load script -- no image
  axon/       the Model Loader
  ants/       the cartridge; kalam vendors its build
  web/        the shell
```

## Running it

```bash
cp .env.example .env      # then fill in the blanks
docker compose up --build
open http://localhost:5173
```

`.env` needs a GitHub OAuth App, a session key and a database password:

```bash
openssl rand -hex 32      # SOMA_SESSION_SECRET
openssl rand -hex 16      # POSTGRES_PASSWORD
```

Create the OAuth App at **github.com/settings/developers → New OAuth App**:

| Field | Value |
|---|---|
| Homepage URL | `http://localhost:5173` |
| Authorization callback URL | `http://localhost:5173/v1/auth/github/callback` |

The callback URL must match `OAUTH_REDIRECT_URI` exactly, and must be an address the *browser* can
reach — it is where GitHub returns the user, not a container-internal name.

### What comes up

```
db               postgres:16   two databases: `soma` (the data) and `orion_state` (Orion's own)
redis                          cluster mode's shared backend: dedup, caches, per-channel rate limits
soma             :8080         orion-server 1.7.0, CLUSTER MODE: the REST surface and Jodi's four clocks
kalam-1          :8082         orion-server 1.7.0, single instance, local SQLite: the wave
axon-1           :9092         the Model Loader, replica role -- a SIDECAR in kalam-1's network
                               namespace, so the wave reaches it at 127.0.0.1:9090
loader           one-shot      declares the deployment facts, installs each package into the server
                               that runs it, asserts tb.ants is loaded on every replica, exits 0
web              :5173         nginx: the built SPA, and /v1 proxied to soma
orion-ui         :8081         Orion's operations console 1.6.0, reading soma's admin API
axon-admission   :9091         the same binary in its admission role -- fetches by URL, verifies
minio            :9000/:9001   the object store: replays, written by the wave through a presigned PUT

--profile fleet adds:
kalam-2          :8083         a second replica -- what the two failure walks need
axon-2           :9093         its sidecar
```

With the fleet profile, tell the loader about the second replica or it will only install into the
first:

```bash
KALAM_ORION_ADMINS=http://kalam-1:8080/api/v1/admin,http://kalam-2:8080/api/v1/admin \
  docker compose --profile fleet up -d
```

**Two servers, and `devops/` is what decides that.** `soma/`, `jodi/` and `kalam/` are separate
repos that each ship a self-contained Orion package and know nothing of the topology. Soma and
Jodi load into `soma`; Kalam loads into each `kalam-N`. They are kept apart by their tags — each
load script sweeps `pkg:soma`, `pkg:jodi` or `pkg:kalam` and re-creates only its own, and the
loader additionally sweeps whatever a server must **not** run, which is what made the split
survivable on a database that already held all three. That day the old README said would come —
"Kalam gets a service here with a config of its own, and neither repo changes" — is this one, and
neither repo changed.

**One loader, and it runs on every `up`.** A fresh database used to need three hand-run scripts,
in order, before a match would play; each was an idempotent statement, so now the `loader` runs
them every time and there is no order to remember: the `kalam` role's password,
`games.active_engine_digest` and the live season's copy of it (plus a re-stamp of `pending` rows) — a *patch*; with `ENGINE_RELEASE=1` a *release*, which is refused while a season is live (layer 06 §5.3) — `games.manifest` with
`games.reference_observations`, and the replay bucket. Then it installs soma, jodi and kalam by
running each repo's own `scripts/load-package.sh`. After editing any package:

```bash
docker compose run --rm loader          # setup + load
docker compose run --rm loader load     # the packages only
docker compose run --rm loader setup    # the database facts and the bucket only
```

**Nobody types the engine digest.** Three things must agree on it — the plugin Orion loads, keyed
by sha256 over the component; `[vars] engine_digest`, which the claim filters on; and
`games.active_engine_digest`, which pair stamps on every row — and a mismatch is not an error
anywhere: the wave claims nothing, for ever. So `orion`'s entrypoint and the `loader` both derive
it from `kalam/plugins/tb-ants/tb-ants.wasm`. `KALAM_ENGINE_DIGEST` in `.env` is optional, for
rehearsing a rolling deploy, and the loader refuses one that disagrees with the file.

**The two `axon`s are one binary in two roles, and they share one store.** That is a correctness
property rather than a saving: the admission instance mirrors what it verified under the bytes'
hash, and the replica fetches by that hash. Two stores would mean admission succeeds and every
match the version is then paired for fails at the residency barrier — quietly, and a long way from
the cause. They cannot be one process: a replica's fetch allowlist is empty whatever the
environment says, and admission answers `/play` with a 404, so a confusion of roles is loud. Only
the admission instance may reach the public internet.

**The drain is short here, on purpose.** A Kalam replica of its own drains for the length of the
longest match (~19 minutes) so a stop finishes the wave in hand — and Orion's
`shutdown_drain_secs` is a fixed period, so a replica pays it on every stop. On the one local
server that would make every `docker compose down` a twenty-minute wait, so the config sets
seconds: an interrupted wave's rows stay `running` until their five-minute lease lapses and are
then replayed from turn zero. `ORION_SHUTDOWN_*` and `ORION_STOP_GRACE` in `.env` raise it.

**`orion-ui` is Orion's own console, not part of Soma** — live dashboards, a system map of the
channels and connectors, workflow DAGs, trace drill-downs, and a Data Console for firing test
requests. It reads the same admin API the loader writes to, so it is also the easiest way to see
why a channel is quarantined.

> **It has no authentication.** Orion's admin API is unauthenticated by default, so anyone who can
> reach `:8081` (or `:8080` directly) can create, edit and delete channels and workflows. Every
> port publishes on `127.0.0.1` only; do not bind either anywhere routable without `admin_auth`.

`web` publishes **5173** rather than 80 so the OAuth callback URL is identical whether you run the
compose stack or `npm run dev` in the shell repo. One OAuth App serves both.

The `/v1` proxy is the load-bearing part. Soma sets `soma_session` as an HttpOnly cookie with no
`Domain` attribute, so it belongs to whichever host the browser believes answered. Proxying keeps
everything on one origin, which is why no CORS is involved.

### First boot only

The database schema and its seed are applied by `/docker-entrypoint-initdb.d`, which Postgres
runs **once**, when the volume is created. After changing `soma/migrations/`, reset the volume:

```bash
docker compose down -v && docker compose up --build
```

or keep your sign-in with `scripts/resync-dev-schema.sh`, which refuses a volume holding any
match or rating row. The packages are not in that category — the loader re-creates every
connector, workflow, plugin and channel on each run.

### Useful

```bash
open http://localhost:5173           # the app
open http://localhost:8081           # Orion's console
docker compose logs -f orion
docker compose logs loader           # what was declared and loaded, and /health afterwards
docker compose exec db psql -U soma -d soma
curl -s localhost:5173/v1/games | jq
curl -s localhost:8080/health | jq '{status, channels, plugins}'
curl -s localhost:9091/healthz | jq  # the admission loader: mode, dialect, evaluator digest
```

Still by hand, and both say why in their headers:

```bash
scripts/seed-baselines.sh       # real weights for the three seeded baselines -- needs cargo, and
                                # goes away when the baselines are real submissions
scripts/resync-dev-schema.sh    # rebuild the schema on a scratch volume, keeping the accounts
```

## How the config gets its values

`orion/soma.toml.tmpl` and `orion/kalam.toml.tmpl` are passed to `orion-server -c` unchanged;
`ORION_CONFIG_TEMPLATE` picks which. Orion substitutes every `${NAME:-default}` in the file from
the container's environment before parsing, and resolves `env://` values after, so no file in the
container ever holds a credential. Each package's connectors name their own credentials as `env://`
too — `SOMA_DB_URL`, `JODI_DB_URL` on `soma`, `KALAM_DB_URL` on each replica, the `R2_*` four, the
GitHub pair — resolved by the server, which is why they are on the Orion services and none on the
loader.

`orion/entrypoint.sh` serves **both roles from one script**, and it does not take a role argument:
it asks the mounted config what it needs by looking for the substitutions the file actually
contains. So `SOMA_COOKIE_SECURE` is normalised to a bare `true`/`false` only for a config that
reads it, and `KALAM_ENGINE_DIGEST` is derived from the vendored component only for a config that
reads *that*. A config that stops referencing a value stops paying for it.

**A value in two files must be asserted, not remembered.** The split put three of them there, and
each fails silently: `forfeit_strikes` = `strike_ceiling`, the rating prior, and the engine digest
being derived rather than typed. `scripts/check-configs.sh` asserts all three and parses both
templates through `orion-server`. Run it before shipping a config change.

Two values bite:

- **Cookies over plain http.** Browsers refuse to store a `Secure` cookie from an `http://` origin,
  silently. The compose stack sets `SOMA_COOKIE_SECURE=0`; anything behind TLS sets `1`.
- **The callback URL.** `OAUTH_REDIRECT_URI` lands in `[vars] oauth_redirect_uri`, which the sign-in
  channel reads. It must equal the OAuth App's callback URL exactly, and Orion accepts plain `http`
  there only on a loopback host — anything else quarantines the channel at load.

Check the config without starting anything, from the image (the host's `orion-server` may be older):

```bash
scripts/check-configs.sh     # both templates: the cross-file equalities, then a real parse
```

**Versions.** `ORION_VERSION` (default `1.7.0`) is the server binary the orion image downloads;
`ORION_UI_VERSION` (default `1.6.0`) is the console image. The two are pinned separately because
the console does not release in lockstep with the server.

## Running without Docker

`.env.local` and `orion/orion.local.toml` hold the host-development values: `orion-server` on your
PATH, Postgres on localhost, the shell's dev server proxying `/v1` to `:8080`. Both are ignored by
git; `.env.example` and the two `orion/*.toml.tmpl` are the committed shapes — each template is
valid TOML with its defaults applied, so it doubles as the example. The steps are in `Tiny-Brains/soma`'s
README.
