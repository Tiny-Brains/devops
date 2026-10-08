# devops

**Every environment this platform runs, and everything it takes to run one: the compose files, the
edge config, the setup scripts, and each environment's own settings and keys.** The six repos
beside this directory build artifacts; this one deploys them.

**This directory is a git repository (`Tiny-Brains/devops`), and it tracks the tooling only.** The
compose files, the setup scripts, the edge config and the templates are versioned; `dev/`, `qa/` and
`prod/` — the environments themselves, their `.env` files and their keys — are not, and `.gitignore`
is written to deny by default so that a rule which forgets a file leaves it out rather than in.

Read `.gitignore` before adding anything, and ask what a file would contain **on the production
machine**, not on this one. A secret kept out is recoverable; a secret in a remote's history is not.

`tinybrains/` itself is still not a repository, and `backup/` beside this one is still untracked.

## Quick start

```sh
./tb dev web up -d --build     # the local platform: Postgres, Redis, MinIO, Soma, the site
./tb dev runner up -d --build  # a runner for it
```

Everything goes through `tb`, which takes an environment and a target and passes the rest to
`docker compose`:

```
./tb <dev|qa|prod> <web|runner> <docker compose args...>
./tb prod web --profile console up -d      # the operations console
./tb qa   runner --profile admit up -d     # a QA runner and its admitting runner
./tb prod web logs -f soma
./tb qa   web --show                       # print the command instead of running it
```

**Use it rather than `docker compose` by hand.** Three things must agree on every invocation — the
compose file, the `--env-file` and the compose PROJECT — and the one that is silent when it is wrong
is the project: two projects sharing a name is one *replacing* the other, which is how a QA runner
takes production's containers. `scripts/lib.sh` holds all three, once.

## Layout

```
devops/
  tb                    the one command
  scripts/
    lib.sh              which environment, and where its files are
    setup/              init, admin-key, admin-user, trust-keygen, sign-plugins,
                        qa-secrets, qa-db, qa-refresh
  compose/
    web.yml   web.prod.yml   web.qa.yml
    runner.yml   runner.prod.yml        (prod and QA share this one, under different projects)
    caddy/Caddyfile  caddy/conf.d/      the production edge, which also serves the QA hostname
    orion-ui/                           the console's nginx template
    monitoring.yml  monitoring/         Grafana, Prometheus, Loki, Tempo, Alloy -- opt-in per environment
  examples/             one .env template per compose file
  dev/  qa/  prod/      each: web/.env, kalam/.env, and the keys that environment signs with
```

One directory per environment, and inside it one per service — the same shape as the checkouts, so
a path reads as "which environment, which service".

## What is NOT here, and stays in its repo

- **`Dockerfile`** — each image is built from its own repo's source by that repo's own
  `.github/workflows/release.yml`. A workflow cannot build a checkout it does not have.
- **`web/nginx.conf`** — `COPY`d into the web image, and one half of the `/v1` proxy contract with
  `vite.config.ts`. Application config, not deployment.
- **`soma/migrations/`** and **`soma/scripts/cutover/`** — the schema and the procedure that moves a
  database between two versions of it. Both are soma's knowledge of its own bytes.
- **`web/scripts/check/configs.sh`** — a check, not a deployment step. It *reads* `compose/` and
  `dev/` from here (`DEVOPS_DIR`), and says so when it cannot find them rather than passing.

## Setting an environment up

```sh
scripts/setup/init.sh                      # dev: writes dev/web/.env from examples/, mints secrets
scripts/setup/trust-keygen.sh              # this machine's Ed25519 trust root
scripts/setup/sign-plugins.sh              # sign the plugin components the images carry
scripts/setup/admin-user.sh <github-login> # add an admin
```

Each takes `--env dev|qa|prod` (or `TB_ENV=`), defaulting to `dev`. **That default is load-bearing:**
before the compose move each script found one `.env` relative to a repo root, which worked only
because there was one environment per checkout. There are now three per machine, and `admin-key.sh`
in particular used to ignore the file it was told to use and rewrite the default one.

Production and QA have their own sections in the guides: `examples/web.prod.env.example` and
`examples/web.qa.env.example` explain every blank, and `scripts/setup/qa-secrets.sh` and
`qa-db.sh` do the parts that must not be done by hand.

## QA

**QA is the candidate release running on production's rows, and it owns everything else.** Its own
VM, its own Cloud SQL instance, its own buckets, Redis, GitHub OAuth App, trust key and edge. It
runs `compose/web.prod.yml` — the same topology production runs, which is the only thing a QA stack
is for — under the project `tinybrains-qa`.

**The one connection to production is a backup.** `scripts/setup/qa-refresh.sh` restores
production's own automatic Cloud SQL backup onto QA's instance. That is an operation between two
managed instances: production does no extra work, QA opens no connection to production's database,
and QA holds no credential of production's.

| | QA | production |
|---|---|---|
| VM | `tinybrains-qa-host` 35.184.95.2 | `tinybrains-host` 35.254.81.10 |
| Cloud SQL | `tinybrains-qa-pg` 10.60.0.5 | `tinybrains-pg` 10.60.0.3 |
| buckets | `tinybrains-{models,replays}-qa` | `tinybrains-{models,replays}` |
| trust key | its own | its own |
| VM identity | `tinybrains-qa-vm`, Cloud SQL only | default compute SA |

**Every deploy is one command**, on QA's machine:

```sh
# qa/web/.env: SOMA_IMAGE and WEB_IMAGE to the candidate, both from ONE ants release
TB_ENV=qa scripts/setup/sign-plugins.sh      # signs with QA's own key, after a new image
scripts/setup/qa-refresh.sh --yes --up
```

Run `qa-refresh.sh` with no flags first — it prints every step and every refusal and changes
nothing.

**What the refresh does, and why in that order.** It stops QA; restores production's latest
successful backup onto QA's instance, which replaces that instance *whole*, every database and
every role, because roles are cluster-wide and a backup carries the cluster; resets the passwords QA
connects with, since the restore just overwrote them with production's; runs the candidate's own
migrations over the result (soma's `scripts/cutover/`, skipped when the digests already agree);
copies production's models bucket into QA's so a copied submission is a model that loads; and brings
the stack up. Replays are not copied — a QA match writes its own.

**Why QA has a machine and an instance of its own**, rather than sharing production's as it first
did: it shared one `db-f1-micro`, and the first time QA ran what it is for — a full copy of the
ladder with its five clocks over 10k matches — the shared vCPU was gone and *production* logged 75
slow statements a minute and timed its own clocks out. Sharing the VM was worse than a resource
question: production's caddy owns 80/443, so QA's hostname could only be served by editing
production's edge, and a QA web container on both compose networks resolved `soma` to
**production's**, serving QA's build over the live API.

**Why the data is copied rather than seeded.** A QA stack on an empty database tests the code and
none of the data. The rows that break a release are the ones a season has accumulated, and running
the release's migration over them here is the rehearsal for running it on production.

## Monitoring

**Opt-in, per environment.** An environment whose `web/.env` carries the line `TB_MONITORING=1` gets
`compose/monitoring.yml` layered over its site stack by `tb`. It adds Prometheus (15 days or 1 GB),
Loki (72 h), Tempo (24 h), one Alloy collecting all of it, and Grafana with four dashboards
(Overview, Soma, Host and containers, Logs) and alert rules that post to one Discord channel, each
message tagged with `GRAFANA_ENV`. Every container has a hard memory limit sized for an e2-small;
together they use about 650 MB.

It changes what Soma records through `ORION_*` settings only: a second, unauthenticated `/metrics`
on the compose network (the console follows it there through `ORION_METRICS_URL`), and OpenTelemetry
spans to Tempo. **How much it traces is the env file's choice, and the default is the minimum**:

| `web/.env` | default (production) | QA |
|---|---|---|
| `TRACE_ERRORS_ONLY` | `true` -- a trace row for failed runs only | `false` -- every request on the 139 channels that do not pin their own policy |
| `OTEL_SAMPLE_RATE` | `0.01` | `1.0` |
| `TRACE_DEBUG_PROFILE` | `false` | `true` (`X-Orion-Profile: 1`; lets any caller probe timings) |

Trace rows are batched either way, and shed rather than slowing a request when the database falls
behind (`orion_trace_dropped_total{reason="overflow"}`).

**Grafana is `https://<SITE_HOST>:3443`, behind the site's GitHub sign-in**, exactly as the console is:
`grafana-gate` asks Soma's `/v1/admin-check` with the session cookie, so only a site admin gets in,
and all of them as one Grafana user, `site-admin`. Signing in returns you to the site, not to Grafana
(Soma's sign-in returns only to `APP_URL` and `CONSOLE_URL`); open `:3443` again.

Turning it on, on the environment's machine:

```sh
# <env>/web/.env:  TB_MONITORING=1, GRAFANA_ENV=<env>, GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 24),
#                  GRAFANA_DISCORD_WEBHOOK_URL=<the channel's webhook>, ORION_RUST_LOG=info,
#                  LOG_MAX_SIZE=20m, LOG_MAX_FILE=5, and the tracing lines above if not the minimum
cp compose/caddy/conf.d/grafana.caddy.example compose/caddy/conf.d/grafana.caddy
./tb <env> web --profile console up -d     # recreates soma, caddy and the rest once; starts monitoring
```

and open tcp:3443 to that VM alone, with a firewall rule on a tag only it carries
(`tinybrains-qa-grafana`, `tinybrains-prod-grafana`) -- never `tinybrains-web`, which both VMs carry.
Turning it off is the reverse: drop `TB_MONITORING=1` and `./tb <env> web --profile console up -d
--remove-orphans`.

## Invariants

- **A setup script writes THROUGH a path, not over it.** They used to replace an env file with
  `mv`; if a path is ever a symlink again, that silently breaks the link and the copies drift. They
  `cat` into it instead, and a new writer must too.
- **`grep -v` exits 1 when every line matched**, which under `set -e` aborts a script mid-rewrite.
  Every read-modify-write here ends `|| true` for that reason.
- **QA has a Postgres server of its own, and the reason is CPU, not connections.** The two shared
  one `db-f1-micro` until QA first ran a full copy of production's ladder on it: QA's five clocks
  against 10k matches took the instance down to seconds per query, and *production* -- the same
  instance -- logged 75 slow statements a minute and timed its own clocks out. Connections were
  never the binding constraint; the shared vCPU was. `tinybrains-qa-pg` is QA's.
- **Where QA and production DO share a server, they share the `runner_gate` role.** Roles are
  cluster-wide and soma's bootstrap resets that password on every start, so both `.env` files must
  then carry the same `RUNNER_GATE_DB_PASSWORD` or a QA bring-up rewrites production's.
  `qa-db.sh` compares the two hosts and only enforces it when they are one.
- **QA and production must not share a Redis.** Soma's clocks are Orion cluster singletons and
  `[cluster] redis_url` has no key prefix: one Redis across both elects one pair clock over four
  nodes, and production's ladder goes quietly idle.
- **A relative path in a compose file is resolved against `compose/`, not against `devops/`.** That
  is `RUNNER_SIG_DIR`, and it is the one variable in these files that names a host directory: every
  environment's value begins `../<env>/`. A path that does not exist is not an error — Docker
  creates it, empty, and the node then stops at its boot apply with no signature for a plugin it
  must load.
- **Nothing here syncs.** A value changed on the VM is not changed here. When two copies of one
  environment disagree, **the machine that runs it wins** — `prod/` on a laptop is a reference copy
  and is probably stale.

## Which machine holds what

| | Runs | Its state |
|---|---|---|
| **this laptop** | the dev stack and a dev runner | `dev/` is real; `qa/` and `prod/` are reference copies |
| **`tinybrains-host`** (GCP) | production, and QA beside it (on its own Cloud SQL) | `prod/` and `qa/` are real, and authoritative |
| **the Mac mini** | the production and QA runners | `prod/kalam/` and `qa/kalam/`, with keys copied from the VM |

## Backing it up

`backup/secrets/` holds the encrypted archives (`gpg`, passphrase in the login Keychain). This directory is
what they are made from. Nothing here is committed, so an un-backed-up file exists in exactly one
place.
