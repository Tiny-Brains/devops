# Orion 1.7.0 — what building TinyBrains found

The facts each build turned up that no design document had written down. Each cost time once; this
file is so that none costs it twice. They belong to no single package, which is why they live here.

The generator docstrings in [`jodi`](https://github.com/Tiny-Brains/jodi),
[`kalam`](https://github.com/Tiny-Brains/kalam) and [`soma`](https://github.com/Tiny-Brains/soma)
carry the same facts where they apply.

---

## 1. The schema and Jodi

| Finding | What it means |
|---|---|
| **`[plugins] cache_dir` cannot be set.** It is reserved in 1.7.0 and a *non-empty* value is refused at startup | Early design notes for both packages said "set a `cache_dir`"; they are wrong for this version, and compiled artifacts are held in memory. Both instance configs say so where the key would go |
| **Every task needs a `name`.** A workflow whose tasks carry only `id` is refused at create with `REQUIRED` per task | Jodi's count and pair task lists were written without one. The generated workflows add it; a hand-written one will be refused, which is the good failure |
| **`db_write` returns only `rows_affected`,** as the layers assumed — confirmed by every fenced statement in count and pair halting correctly on zero | The design's core idempotence argument survives contact |
| **A plugin component reaches Orion base64-encoded in a JSON body, not as an argument.** 100 KiB of wasm is ~133 KiB of text, and passing it as an argv entry is "Argument list too long" on any shell | Both load scripts write it to a temp file and use `jq --rawfile` / Python. The manifest is authored as TOML and *generated* as JSON, because the images have `jq` and no TOML parser |
| **`orion-plugin-sdk` is on crates.io at the pinned version.** No path dependency into a sibling checkout is needed | Both plugins build from this repository alone. The SDK is wasm-only in `Cargo.toml`, so the pure logic stays host-testable — which is the only reason the TrueSkill maths could be checked against a reference at all |
| **`compose/db-init/` runs once per volume, so a pre-release schema rewritten in place strands every existing dev stack** | It surfaces as `relation "clocks" does not exist` on every count tick, which looks like a bug in count. `devops/scripts/dev/resync-dev-schema.sh` is the answer, and it rebuilds from the migrations rather than maintaining a delta |
| **Two packages in one orion-server are kept apart by their tag, not by the server.** Each load script sweeps `pkg:soma` or `pkg:jodi` and re-creates only its own; an *active* workflow is immutable, so loading is delete-by-tag then create | This is what made the repo split cost nothing: `jodi/scripts/load-package.sh` deletes nothing of Soma's and Soma's deletes nothing of Jodi's, even loaded into the same server. Sweeping by tag rather than by the files present also means a channel a package stops shipping does not linger active and keep ticking |
| **Plugins load before the workflows that name them, and `allow_private_urls` is a deployment property rather than a package one** | A workflow naming `tb.rating.trueskill` with no plugin behind it is *quarantined* at load — it loads, and then fails on its tick — so the arithmetic has to exist before the clock. Orion's SSRF guard refuses a compose service name or a VPC host unless the connector opts in, so the load script rewrites that flag in rather than the package shipping it. Plugin uploads land as drafts and are activated by a PATCH, exactly as workflows are; Orion compiles and probes the component before writing the draft row, so a `201` has already proved it loads |

## 2. Kalam and the wave workflow

Eleven more, found while building the wave workflow. The first is the one
that cost the most and is the one to remember.

| Finding | What it means |
|---|---|
| **`metadata.vars` is ROOT scope, exactly as `data` is.** A `[vars]` value read inside a `map` or `filter` body is `null` | Combined with `{">=": [0, null]}` being **true**, reading `strike_ceiling` inside the strike map forfeits every seat on turn 0. The next turn sends the loader nothing and the wave dies at `step` with "0 actions for 10 live seats" — an error naming neither the variable nor the cause. The spike's finding 2.6 was about `data`; it is about vars too, and the consequence is worse because the failure is *plausible*. Every such accumulator is now a `reduce` with the value in its seat, and the workflow's first task halts loudly if any var is missing |
| **`http_call` has no `url` field**: `path` is always appended to the connector's base | So a presigned URL cannot be used directly — `base + url` is what gets fetched. The replay `PUT` reduces the presigned URL to a path with `substr(url, length(base))` |
| **`force_path_style` on a storage connector is what makes that subtraction exact** | Without it the presigned URL is virtual-hosted (`bucket.host/key`), and the prefix to strip is a string neither side is configured with. With it the URL is `endpoint/bucket/key` and the prefix is exactly the endpoint |
| **`storage_presign` returns a plain string**, not an object; and `storage_presign` and `storage_head` are Orion's *only* storage task functions | Orion carries no bytes by design, so a replay write is presign + an ordinary `http_call`. That is why Kalam ships a second blob connector |
| **`http_call` parses the reply as JSON unless told otherwise** | An S3 `PUT` answers with an empty body, so the task fails on "EOF while parsing a value" *after the write succeeded*. `response_format: "text"` |
| **An http connector's `url` may not be an `env://` reference** — `VALIDATION_ERROR: must use http or https scheme, got 'env'`. A storage connector's `endpoint` may | `kalam/connectors/model-loader.json` as shipped could never load. The load script substitutes both URLs from the environment now, as it already did for the SSRF flag |
| **A plugin is *archived*, not deleted, and cannot be archived while an active workflow calls its functions** | The load script's delete-by-tag sweep was a silent no-op for plugins, so the *second* load of a package 409s. It works on a fresh server, which is why this hides until the first redeploy |
| **`{"now": []}` exists** and returns an ISO-8601 instant | Which is where `played_ms` comes from: the workflow captures the wave's start and Postgres does the subtraction |
| **`{"merge": [A, B]}` concatenates two computed arrays** (while `{"merge": <one expression>}` flattens nothing) | Both behaviours are load-bearing: one appends the carried-forward forfeited refs, the other is why flattening a list of lists needs a `reduce` |
| **A REST channel needs top-level `name`, `methods` and `route_pattern`**, and `config.response.mode` is `envelope` or `shaped` | Kalam's original channel sketch had none of them. The same class of error as "every task needs a `name`" |
| **A cron occurrence's data is unreadable**: it returns nowhere, and a trace record carries no per-task detail (and drops it above `queue.max_result_size_bytes`, which a wave exceeds at 4.2 MB) | So a wave that goes wrong can only be diagnosed by *which* task failed. Kalam's config now mounts a development-only REST path so the same workflow can be driven by hand and its `data` read — without which the two bugs above would still be unfound |

The cron spellings recorded during the schema build were **confirmed against the 1.7.0 source**, not assumed:
`transport_config` takes `schedule`, `timezone`, `misfire_policy` (`skip`/`latest`/`catch_up`) and
`concurrency: {policy, key}`, all under `deny_unknown_fields`; `metadata.trigger` carries `type`,
`occurrence_id`, `scheduled_for`, `started_at`, `timezone`, `attempt` and `singleton_key`. A cron
channel is `channel_type: "async"`, `protocol: "cron"`.

## 3. Admission

Orion's `http_call` warns and continues on a `4xx` without
writing its output, and only a `5xx` is an error — so every stage tests whether its output *exists*
rather than reading a status code, and the best-effort GitHub call needs no branch at all.
`temp_data` survives a loop sweep, so every per-item slot must be cleared as the item is taken; the
one that matters is `resident`, which gates the verdict. datalogic has **no regex** — `match` is a
`switch`. Orion refuses `env://` in a connector URL, and caps a workflow description at 2048
characters. And the release-existence call was dropped rather than fixed: a missing tag 404s both
asset URLs, and `ASSET_MISSING` naming the exact URL beats the `RELEASE_NOT_FOUND` it replaced.

## 4. The three that cost the most

`metadata.vars` is root scope like
`data`, so a `[vars]` value read inside a `map` body is `null` — and `{">=": [0, null]}` is true, so
reading the strike ceiling there forfeits every seat on turn 0 and kills the wave a turn later at
`step`, naming neither the variable nor the cause. Drain is three numbers and the smallest wins, and
`[server] shutdown_drain_secs` is a fixed period rather than a maximum, so it is exactly what every
scale-down costs.

> **The rule drawn from that measurement was wrong, corrected in [`deployment.md`](deployment.md) §6.1 from
> `orion-server`'s source.** "All three must exceed the longest match" tells an operator to raise
> `shutdown_drain_secs`, which is the one number paid unconditionally, and leaves at its default the
> one that would have helped. The cron worker is a *supervised task*, and `main.rs` drains the
> supervised tasks under `server.shutdown_force_timeout_secs` — so the bound on a wave is
> `min(cron.shutdown_timeout_secs, server.shutdown_force_timeout_secs)`, an inner deadline under an
> outer one, and the cron key can only ever make it shorter. That is why cron at 2 700 with the
> server keys at 30 measured 30. `shutdown_drain_secs` exists for a load balancer's in-flight
> requests and buys a cron-only replica nothing.

And a cron occurrence's data is readable nowhere — not in its return, not in its
trace — which is why Kalam's config now mounts a development-only REST path: without it the two
bugs above would still be unfound. §2 above has the full list.

## 5. Rating and seasons

| Finding | What it means |
|---|---|
| **A version alone in its weight class never settles.** The demand view judged `played` as the smaller of a version's two ladder counts, and a class ladder with nobody else in the class is never fed | It was `placement` for ever: cap `burst`, demand never fell, and the local stack's one Micro version played 4,430 matches against Nano baselines with sigma 0.70. A class ladder now counts only when another active version of the class is in the season; the close predicate inherits the rule |
| **A `finished` row count has not folded yet is in flight**, and the demand view did not count it | In the ten seconds between Kalam finishing a burst and count folding it, `played` was still 0 and `in_flight` was 0, and pair inserted a second burst. `finished` is in the in-flight set now |
| **The 2048-character workflow description cap bites on a revision too**, and the load script sweeps before it re-creates | Appending a paragraph to `soma-submissions-create`'s description pushed it over; the package load stopped there, after the sweep and before the channels, so every Soma endpoint was gone until it was fixed. Keep descriptions short; the reasoning belongs in the design document |
| **Two REST channels may share a `route_pattern` when their methods do not overlap** (`definitions/check.rs`, `duplicate.route_pattern`) | `GET` and `POST /v1/games/{game}/seasons` are two channels, two workflows |
| **`db_write` reports only `rows_affected`, so a statement that must report success ends on the write that means it** | The season create is one statement whose CTEs insert the season, carry the baselines and seed them, and whose *last* statement is the roster bump: one row on success, zero when refused. Soma then reads the season back. Whether `db_read` accepts a data-modifying CTE was never needed |
| **`psql -v var=… -c "…"` does not expand `:'var'`**; only a script on stdin does, as the loader's comment already said | A one-line `-c` that looks right fails with a syntax error at the colon. Every hand-driven statement went through a heredoc |
| **A shell `$(psql … RETURNING …)` capture includes the `INSERT 0 1` tag** | A user id captured that way was 47 characters, and the JWT built from it failed at the query's `uuid` cast; Orion's error named the length, which is what found it. Capture with `-At -c "SELECT …"` |

---

## 6. The deploy step

| Finding | What it means |
|---|---|
| **`/health` reports each loaded plugin's DIGEST, not merely its name** — `.plugins.loaded[] \| {plugin, version, digest}` | Decision 44 says the digest is declared *last, once the new replicas exist and are loaded*, and that precondition is now **checkable rather than assumed**: `declare-engine.sh` refuses to flip the column unless at least one replica's `/health` reports `tb.ants` at the digest being declared. It is a strictly tighter gate than the loader's `health()`, which asserts only that a plugin of that *name* loaded — a replica carrying the wrong engine passes the name check and claims nothing |
| **A plugin version bump does not change the component digest.** `ants` at 1.0.0 and 1.0.1 — `Cargo.toml`, `plugin.toml`, `cargo test`, `cargo build --release`, `wasm-tools component new` — produce `tb-ants.wasm` byte for byte identical, `sha256:f6ee986b…` both times | The engine's identity on the platform is the **content hash**, and `plugin.toml`'s `version` is independent of it. Two consequences. The build is reproducible across a version change, which is what the determinism guard wants. And **a "new engine version" is not a new engine**: a deploy that bumps the version and expects a rolling cutover gets one digest, one queue, and no roll at all. Only a source change mints a new digest — which is the right law, since the digest is what a played row records |
| **`ratings.matches_played` is the rating-event sequence, not a counter.** `rating_events_pkey` is `(model_id, ladder, seq)`, and `seq` is that column | Resetting it to put a played version back into placement makes count fail its very next fold — `duplicate key value violates unique constraint "rating_events_pkey"` — and the clock stays broken, retrying and failing every ten seconds, until the counter is at or above `max(seq)` again. **A version with history cannot be returned to placement by resetting the counter**: placement is a property of what a version has played, and the audit trail enforces it. Anything that restores a `ratings` row from a backup must restore `matches_played` to at least `max(seq)`, not to whatever the backup said |
| **Recreating a Kalam replica orphans its `axon` sidecar.** `network_mode: "service:kalam-N"` puts the sidecar in the replica's network namespace, and `--force-recreate kalam-N` gives the replica a *new* namespace while the sidecar stays attached to the destroyed one | The replica comes back **healthy**, claims rows, and then every wave fails at the residency barrier: `Task resident failed: Io("HTTP request to http://127.0.0.1:9090/resident failed")`. Rows go `claimed` and lapse. Nothing in `/health` says why, because the replica's own health *is* fine — the thing it talks to is gone. **Recreate the sidecar with the replica, always**, and read "the wave fails at `resident` right after a replica restart" as this until proven otherwise |
| **`/health`'s plugin digest is not the replica's claim digest.** What gates claiming is `[vars] engine_digest`, and no admin endpoint exposes it — not `/health`, not `channels` (whose `config` carries only timeout and tracing), and `/api/v1/admin/{config,vars,settings,instance}` are all 404 | They agree in a real deployment, because the entrypoint derives the var from the vendored component, so a preflight that reads the plugin digest is exact there. They **diverge under `KALAM_N_ENGINE_DIGEST`**, which is exactly what a rehearsal pins. So `declare-engine.sh`'s per-replica attribution — "will claim" vs "will drain" — is right in deployment and wrong in rehearsal, while its *conclusion* (at least one replica can claim) holds in both. Driving it proved this: the preflight reported "2 will claim, 0 will drain", and the pinned replica then drained |
| **A load-time signature refusal is fully legible in `/health`** — `status` goes `degraded`, `plugins.failed_to_load[]` carries `{plugin, version, digest, stage: "signature", reason}`, and `channels.quarantined[]` carries the whole causal chain: *"no handler is registered for `tb.rating.trueskill` … tb.rating v1 signature: the signature does not verify over sha256:… with any of the 1 configured key(s)"* | Verified by pointing a node's `[plugins.trust] public_keys` at a key that did not sign its stored plugins. This is what makes trust safe to turn on: the failure is **not** the silent one. It also means the invisible-capacity check a deploy already runs — `/health`'s plugin digest plus `channels.quarantined`, which `declare-engine.sh` reads — catches a trust misconfiguration for free, without a check of its own |
| **Turning trust on refuses the plugins already in the state database.** They were uploaded before there were keys, so they carry no signature, and the node that now has keys will not load them | The fix is a re-upload — `docker compose run --rm loader load` — not a restart. Worth knowing because Soma's state is Postgres and *survives* the restart, so the package looks present and simply does not run. A replica hides this by being disposable: its SQLite state is empty on boot and the loader re-uploads anyway |
| **`admin_auth` silently shrinks `/health`.** The detail — `workflows_loaded`, `plugins.loaded`, `plugins.failed_to_load`, `channels.quarantined` — is gated on `show_detail = !admin_auth.enabled \|\| a valid admin key` (`server/routes/mod.rs`). Unauthenticated, the endpoint still answers **200** with the coarse component states and simply omits those keys | This broke two checks the moment trust was turned on, both in the same direction: the loader's per-replica assertion reported **"tb.rating IS NOT LOADED — this node is invisible capacity"** about a node whose log said `Plugin loaded` a second earlier, and `declare-engine.sh`'s preflight would have refused a cutover on a fleet that was fine. **The check written to catch invisible capacity became a source of it.** Every reader of that detail now sends the credential, and the preflight distinguishes *hidden* from *absent* — `has("plugins")` false means "authenticate", not "no plugins" |
| **`EXPLAIN` permission-checks without executing**, so it is the cheap way to prove a role's grants cover a statement | `jodi/scripts/check-sql.sh` now runs all 21 shipped statements through `EXPLAIN` as the `jodi` role against a scratch database: nothing runs, and a statement needing a grant the role lacks fails with `permission denied for table X` naming the table. PREPARE cannot do this — it parses and plans but never checks privileges, which is exactly the gap that lets a statement pass CI and fail on a cron tick |
