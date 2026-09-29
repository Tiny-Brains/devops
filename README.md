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
    setup/              init, admin-key, admin-user, trust-keygen, sign-plugins, qa-secrets, qa-db
  compose/
    web.yml   web.prod.yml   web.qa.yml
    runner.yml   runner.prod.yml        (prod and QA share this one, under different projects)
    caddy/Caddyfile  caddy/conf.d/      the production edge, which also serves the QA hostname
    orion-ui/                           the console's nginx template
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

## Invariants

- **A setup script writes THROUGH a path, not over it.** They used to replace an env file with
  `mv`; if a path is ever a symlink again, that silently breaks the link and the copies drift. They
  `cat` into it instead, and a new writer must too.
- **`grep -v` exits 1 when every line matched**, which under `set -e` aborts a script mid-rewrite.
  Every read-modify-write here ends `|| true` for that reason.
- **QA and production share one Postgres server and therefore one `runner_gate` role.** Its password
  is cluster-wide and soma's bootstrap resets it on every start, so `qa/web/.env` and `prod/web/.env`
  must carry the same `RUNNER_GATE_DB_PASSWORD`. `qa-db.sh` refuses to run when they differ.
- **QA and production must not share a Redis.** Soma's clocks are Orion cluster singletons and
  `[cluster] redis_url` has no key prefix: one Redis across both elects one pair clock over four
  nodes, and production's ladder goes quietly idle.
- **Nothing here syncs.** A value changed on the VM is not changed here. When two copies of one
  environment disagree, **the machine that runs it wins** — `prod/` on a laptop is a reference copy
  and is probably stale.

## Which machine holds what

| | Runs | Its state |
|---|---|---|
| **this laptop** | the dev stack and a dev runner | `dev/` is real; `qa/` and `prod/` are reference copies |
| **`tinybrains-host`** (GCP) | production, and QA beside it | `prod/` and `qa/` are real, and authoritative |
| **the Mac mini** | the production and QA runners | `prod/kalam/` and `qa/kalam/`, with keys copied from the VM |

## Backing it up

`backup/` holds the encrypted archives (`gpg`, passphrase in the login Keychain). This directory is
what they are made from. Nothing here is committed, so an un-backed-up file exists in exactly one
place.
