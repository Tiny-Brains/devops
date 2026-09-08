# devops

Deployment for [TinyBrains](https://github.com/Tiny-Brains): the compose stack, the environment
template, the database init scripts and Soma's instance config. Everything that names a host, a
port, a secret or a topology lives here; the application repos — `Tiny-Brains/soma` (the backend,
an Orion package) and `Tiny-Brains/web` (the shell) — carry only what builds them.

## Layout

```
docker-compose.yml        db, soma, orion-ui, web
.env.example              copy to .env and fill in the four blanks
db-init/                  run once on a fresh volume: Orion's state database, then the seed row
soma/orion.toml.tmpl      Soma's instance config for the container; orion-server reads it as is
soma/orion.toml.example   the same for a deployed instance, with literal values
soma/orion.local.toml     host development — not committed, see .gitignore
```

The compose file builds from `../soma` and `../web` and mounts `../soma/migrations`, so the three
repos sit side by side:

```
tinybrains/
  devops/     this repo
  soma/       Tiny-Brains/soma
  web/        Tiny-Brains/web
```

## Running it

```bash
cp .env.example .env      # then fill in the four blanks
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
soma             :8080         orion-server 1.7.0 + the Soma package AND Jodi's four clocks
jodi             one-shot      loads the pkg:jodi definitions into soma, then exits 0
web              :5173         nginx: the built SPA, and /v1 proxied to soma
orion-ui         :8081         Orion's operations console 1.6.0, reading soma's admin API
kalam            :8082         a match-player replica: its own orion-server on local SQLite
axon             :9090         the Model Loader beside the replica -- fetches by hash, plays
axon-admission   :9091         the same binary in its admission role -- fetches by URL, verifies
minio            :9000/:9001   the object store: replays, written by kalam through a presigned PUT
```

**Two servers, and `devops/` is what decides that.** `soma/`, `jodi/` and `kalam/` are separate
repos that each ship a self-contained Orion package and know nothing of the topology. Today Soma's
orion-server also runs Jodi's four clocks, because Jodi writes Soma's tables and there is no reason
yet for a third server; the day Soma's REST surface must scale independently, Jodi gets a service
here and neither repo changes.

**The two `axon`s are one binary in two roles, and they share one store.** That is a correctness
property rather than a saving: the admission instance mirrors what it verified under the bytes'
hash, and the replica fetches by that hash. Two stores would mean admission succeeds and every
match the version is then paired for fails at the residency barrier — quietly, and a long way from
the cause. Only the admission instance may reach the public internet; the replica's fetch allowlist
is empty whatever the environment says.

**Two numbers have to be declared, and neither is typed by hand.** `games.active_engine_digest`,
written by `scripts/engine-digest.sh`, is what makes a Kalam replica and the queue agree on an
engine. And `games.manifest` with `games.reference_observations`, written by
`scripts/seed-cartridge.sh`, is what admission validates a submission against — without them
`tb-admit` releases every claim with `MANIFEST_INCOMPLETE` rather than rejecting anyone.

**`orion-ui` is Orion's own console, not part of Soma** — live dashboards, a system map of the
channels and connectors, workflow DAGs, trace drill-downs, and a Data Console for firing test
requests. It is the same admin API `soma/scripts/load-package.sh` writes to, so it is also the
easiest way to see why a channel is quarantined.

> **It has no authentication.** Orion's admin API is unauthenticated by default, so anyone who can
> reach `:8081` can create, edit and delete channels and workflows. All four services publish on
> `127.0.0.1` only; do not bind this one anywhere routable without enabling `admin_auth`.

`web` publishes **5173** rather than 80 so the OAuth callback URL is identical whether you run the
compose stack or `npm run dev` in the shell repo. One OAuth App serves both.

The `/v1` proxy is the load-bearing part. Soma sets `soma_session` as an HttpOnly cookie with no
`Domain` attribute, so it belongs to whichever host the browser believes answered. Proxying keeps
everything on one origin, which is why no CORS is involved.

### First boot only

The database schema and its seed row are applied by `/docker-entrypoint-initdb.d`, which Postgres
runs **once**, when the volume is created. After changing `soma/migrations/`, reset the volume:

```bash
docker compose down -v && docker compose up --build
```

The Soma *package* is not in that category — `soma/scripts/load-package.sh` re-creates every
connector, workflow and channel on each container start, so a definition edit needs only
`docker compose up -d --build soma`.

### Useful

```bash
open http://localhost:5173          # the app
open http://localhost:8081          # Orion's console
docker compose logs -f soma
docker compose exec db psql -U soma -d soma
curl -s localhost:5173/v1/games | jq
curl -s localhost:9091/healthz | jq  # the admission loader: mode, dialect, evaluator digest
```

**After a fresh volume, in this order:**

```bash
scripts/engine-digest.sh     # declare the engine, or the replica claims nothing for ever
scripts/seed-cartridge.sh    # register the cartridge, or admission cannot verify anything
scripts/seed-baselines.sh    # give the baselines real weights (deleted once they have releases)
```

## How Soma's config gets its values

`soma/orion.toml.tmpl` is passed to `orion-server -c` unchanged. Orion substitutes every
`${NAME:-default}` in it from the container's environment before parsing, and resolves
`[storage] url = "env://ORION_STATE_DB_URL"` after, so no file in the container ever holds a
credential. The container entrypoint (in the soma repo) checks the required variables and
normalises one: `SOMA_COOKIE_SECURE` becomes a bare `true`/`false` for `[vars] cookie_secure`.

Two values bite:

- **Cookies over plain http.** Browsers refuse to store a `Secure` cookie from an `http://` origin,
  silently. The compose stack sets `SOMA_COOKIE_SECURE=0`; anything behind TLS sets `1`.
- **The callback URL.** `OAUTH_REDIRECT_URI` lands in `[vars] oauth_redirect_uri`, which the sign-in
  channel reads. It must equal the OAuth App's callback URL exactly, and Orion accepts plain `http`
  there only on a loopback host — anything else quarantines the channel at load.

Check a config without starting anything:

```bash
orion-server -c soma/orion.toml.tmpl validate-config      # defaults applied
SOMA_COOKIE_SECURE=false orion-server -c soma/orion.toml.tmpl validate-config
```

**Versions.** `ORION_VERSION` (default `1.7.0`) is the server binary the soma image downloads;
`ORION_UI_VERSION` (default `1.6.0`) is the console image. The two are pinned separately because
the console does not release in lockstep with the server.

## Running without Docker

`.env.local` and `soma/orion.local.toml` hold the host-development values: `orion-server` on your
PATH, Postgres on localhost, the shell's dev server proxying `/v1` to `:8080`. Both are ignored by
git; `soma/orion.toml.example` and `.env.example` are the committed shapes. The steps are in
`Tiny-Brains/soma`'s README.
