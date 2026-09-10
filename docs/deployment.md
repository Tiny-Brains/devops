# Deployment and scaling

How TinyBrains is deployed: the fleet, the two Orion configs, cluster mode, the autoscaler, drain,
the loader on both sides, the database roles, the deploy order and retention.

The system map is [`architecture.md`](architecture.md); the reasoning behind the numbers is
[`decisions.md`](decisions.md), which carries decisions 5, 25 and 41 to 45 from this page.

## 1. What this page fixes

| Settled | Left to |
|---|---|
| the fleet: three deployment units and what each one is (§2) | the orchestrator — Kubernetes or Cloudflare Containers — which this page deliberately does not choose (§13.1) |
| the config split: one template becomes two, and the rule for which `[vars]` section goes where (§3) | a `policies` table — versioned, immutable, read in the run that acts on it — the day a number must change without a redeploy |
| **Soma and Jodi in cluster mode**, and why that is a requirement rather than a scaling choice (§4.1) | the replica count for Soma, which is an availability number and not a load one |
| **Kalam not in cluster mode**, and why that is a correctness requirement rather than a saving (§4.2) | — |
| the drain: which of the four numbers actually bounds a wave, corrected from source (§6) | the measurement that confirms it on a real replica (§14) |
| the autoscaler's query, and why it reads demand and never queue depth (§5) | the orchestrator's scaler API, and the reconciliation period |
| **decision 5** — K as a residency budget rather than a measurement (§7.1) | the class mix a real fleet serves |
| **decision 25** — the poll interval's shape, with its constant still owed to the spike (§7.2) | the claim-under-load spike, tracker §3.1 |
| the loader beside every replica and once beside Soma; S3/R2 as the third store (§8) | asynchronous load, which stays out until a cold large model measurably hurts |
| the deploy step: the order, and the engine digest as the cutover switch (§9) | — |
| the Kalam role's password in a deployed database (§10) | a `jodi` role of its own, which is owed and is not this page's |
| TLS, `admin_auth`, the trust keys, and what each one gates (§11) | minting the keys, which is an operational act |
| retention made real: the bucket lifecycle rule and Orion's trace retention (§12) | — |

---

## 2. The fleet

Three deployment units, and the parts that are not Orion.

```
                    ┌──────────────────────────────────────────┐
   browser ───TLS──▶│  soma+jodi  — Orion, CLUSTER MODE, N≥2   │
                    │  REST + four cron clocks                 │
                    └───┬──────────────────────┬───────────────┘
                        │                      │
                 ┌──────▼──────┐        ┌──────▼───────┐
                 │ axon        │        │  Redis       │  cluster: dedup,
                 │ (admission) │        │              │  caches, rate limits
                 └──────┬──────┘        └──────────────┘
                        │
   ┌────────────────────▼───────────────────────────────────────┐
   │  Postgres (managed) — TWO databases                        │
   │    soma         the match schema, one migration set        │
   │    orion_state  Soma+Jodi's Orion state, cluster-shared    │
   └────────────────────▲───────────────────────────────────────┘
                        │
   ┌────────────────────┴───────────────────────────────────────┐
   │  kalam × N — one Orion EACH, single instance, local SQLite │
   │  ┌─────────────┐  ┌─────────────┐        ┌─────────────┐   │
   │  │ orion+tb.ants│ │ orion+tb.ants│  ...  │ orion+...   │   │
   │  │   + axon    │  │   + axon    │        │   + axon    │   │
   │  └─────────────┘  └─────────────┘        └─────────────┘   │
   └────────────────────────────────────────────────────────────┘
                        │
                 ┌──────▼──────┐
                 │  R2         │  the model store (by hash) AND the replay bucket
                 └─────────────┘
```

| Unit | What it is | Scales on |
|---|---|---|
| **soma+jodi** | one Orion in cluster mode, N ≥ 2 behind a load balancer, over the shared `orion_state` database and a Redis. Serves the fourteen REST routes and runs the four cron clocks | availability, then request rate. Never on match volume — the clocks are singletons whatever N is |
| **kalam** | N Orions, each a single instance with its own local SQLite state, each with an `axon` beside it. No load balancer, no route, no shared state | **the demand view** (§5) |
| **axon** | one binary, two roles by configuration: beside every Kalam replica, and once beside Soma as `axon-admission` | with its host |

**The parts that are not Orion**: managed Postgres, a Redis, and R2 — which is now two things it was
not locally, the model store *and* the replay bucket, over one credential.

**What each unit must not become.** Kalam replicas must never share Orion state (§4.2). Soma+Jodi
must never run outside cluster mode at N > 1, because the four clocks would each run N times. Those
are the two ways this topology is wrong rather than merely mis-sized.

---

## 3. One template becomes two

Until this page, `devops/orion/orion.toml.tmpl` was one file with one `[vars]` block sectioned by owner, and
its header already says why: *"the day devops gives a package a server of its own, its section
moves with it and nothing in the package repos changes."* This page is that day.

| New file | Holds | `[vars]` sections |
|---|---|---|
| `devops/compose/orion/soma.toml.tmpl` | `data_mounts`, `[cluster]`, `[storage]` on Postgres, `[plugins]` for Jodi's two, `[cron]` | **SOMA** and **JODI**, verbatim |
| `devops/compose/orion/kalam.toml.tmpl` | no `data_mounts`, no `[cluster]`, `[storage]` on local SQLite, `[plugins]` for `tb.ants`, `[cron]`, `[engine]` | **KALAM**, verbatim |

The sections move unchanged. What the split creates that one file could not have is **a value in two
places that must agree**, and there are exactly three:

| Value | In both because | What a disagreement does |
|---|---|---|
| `forfeit_strikes` (Jodi) = `strike_ceiling` (Kalam) | Kalam applies it, count reads its consequences off the row | count judges a trial by a rule the wave did not play by. Already flagged in the one-file config; the split makes it a real hazard |
| `prior_mu`, `prior_sigma` | Soma's season create seeds carried baselines; Jodi's count seeds at promotion | two priors on one ladder. Both are in the *same* file after the split, so this one is safe — noted because it stops being safe the day Soma leaves Jodi |
| `engine_digest` (Kalam) = `games.active_engine_digest` (the deploy) | the claim filters on it | the wave claims nothing, for ever. §9 |

**The check is a script, not a convention.** `devops/scripts/check/configs.sh` parses both templates
with the defaults applied and asserts the three equalities, and it runs in the deploy before either
config is shipped. A rule that lives only in a comment is one rebase from being wrong, and the
failure mode of each of the three is silence.

Each package's `scripts/load-package.sh` already lists what the deploying config owes it, so the
script has something to check against on each side.

---

## 4. Cluster mode

### 4.1 Soma and Jodi: a requirement, not a scaling choice

Orion's cluster mode needs two shared backends and refuses to start without them: **Postgres or
MySQL** — `sqlite:` is refused, a file being single-host by construction — and **a shared Redis**.

```toml
[cluster]
enabled = true
redis_url = "env://REDIS_URL"
epoch_poll_interval_ms = 2000
instance_id = "${INSTANCE_ID:-}"      # stable per replica; also the Kafka group.instance.id

[storage]
url = "env://ORION_STATE_DB_URL"      # the orion_state database, NOT soma
auto_migrate = false                  # §9; a cluster with it true is REFUSED at startup
```

The reason it is not optional is Jodi. **A `forbid` singleton is a row exactly one occurrence holds
at a time, acquired in the same transaction that marks it running** — Orion coordinates cron
entirely through its state tables and needs no leader. Cluster-wide is therefore the same thing as
*state-database-wide*: two Orions over one `orion_state` are one scheduler, and two Orions over two
are two schedulers. Run Soma at N = 2 without cluster mode and you get two `tb-count` clocks folding
the same finished matches, which the fence in `clocks` would make *safe* but not *once*.

Three things change for Soma on the way in, all of them improvements:

- **The six `principal_rate_limit` channels become fleet-wide.** Per-channel rate limits live on the
  shared Redis in cluster mode, so `10 rps` on `/v1/me` is 10 rps across the fleet rather than 10N.
  That is what the number always meant. No channel changes.
- **A config change through any node reaches all of them**, which is what makes
  `load-package.sh` against one replica a fleet-wide install (§9).
- **`/health` gains `config_propagation`.** `degraded` means a bump failed and peers may be stale.
  Alert on it and on `orion_errors_total{reason="config_epoch_bump"}`.

Two costs to size for. `max_concurrent_per_node` is per node, so N replicas admit N× that many in
flight; and platform `[rate_limit]` IP limits stay per node, N× the configured value fleet-wide —
which is the opposite of the channel limits above and is easy to get backwards.

**One trap that does not apply, checked rather than assumed.** A channel whose *deduplication* or
*cache* connector is missing, broken, or explicitly in-memory refuses to load in cluster mode and is
quarantined — served as `503`, absent from the route table, listed under `/health`. None of Soma's
thirteen channels declare either; the six that declare anything declare `principal_rate_limit`,
which is not in that set. Soma goes cluster with no channel edits. This is worth having checked,
because the failure is a live endpoint becoming a `503` on a config change nobody associates with it.

### 4.2 Kalam: single instance, and that is the correctness half

**A Kalam replica must have its own Orion state, and the reason is the same sentence that makes
cluster mode right for Jodi.** `forbid` on a cron channel is a row in the state database. Kalam's
`tb-wave` channel is `{"policy": "forbid", "key": "wave"}` — one wave in flight per replica, which
is what K bounds and what the loader's residency budget is sized for. Put N replicas over one shared
state and that row becomes fleet-wide: **exactly one replica would ever run a wave**, and the other
N−1 would poll every five seconds and find the singleton held. The fleet would scale to zero
throughput and every replica would look healthy.

So local SQLite per replica is not a saving over a managed Postgres. It is what makes each replica
its own scheduler.

Nothing is lost by it, because **Kalam's fence is not Orion's**. Its mutual exclusion is the
database claim on `matches` — `FOR UPDATE SKIP LOCKED` over the partial index, leased, with the
lapse and reap of the match table's claim and lease ([`soma/docs/schema.md`](https://github.com/Tiny-Brains/soma/blob/main/docs/schema.md) §4) — and that is shared state of the only kind Kalam needs. Orion's
occurrence lease would recover a dead node's *occurrence*; the match lease recovers its *rows*, which
is the thing that matters, and it already works.

```toml
# kalam.toml.tmpl — no [cluster] block at all
[storage]
url = "sqlite:/var/lib/orion/state.db"
```

**The consequence that must be built for**: every replica needs the `kalam` package loaded into its
own state before it can play, so §8.2's loader is an init step on every replica and not a one-shot
for the fleet.

**The open ask this resolves.** Tracker §3.1's third bullet asks Orion for a per-channel, per-node
cron concurrency cap. It is no longer needed for correctness — per-node is what a replica with its
own state already has. It would only be needed if a replica ever wanted *more than one* wave in
flight, which K exists to avoid. Downgrade the ask; do not withdraw it.

---

## 5. The autoscaler

**It reads demand, and it must never read queue depth.** The reason is arithmetic and it is a trap
worth stating before the query: pair inserts `least(sum(want), pair_depth_target − depth)`, so the
pending queue **cannot exceed `pair_depth_target`**, which is 64. At K = 16 a scaler that read depth
would ask for at most four replicas no matter how much the ladder wanted, and would look correct
while capping the fleet. The depth target is a staleness cap on pairings, never a signal.

Demand also **leads the queue**, which is the answer to the risk register's "autoscaling lag against
match duration": the demand view says what the ladder wants before pair has inserted it, so a
replica is asked for before the rows it will claim exist.

`$1` game · `$2` burst · `$3` steady cap · `$4` settled sigma — the demand view's own parameters,
02 §4 — and `$5` K · `$6` floor · `$7` ceiling · `$8` the latency guard in seconds:

```sql
WITH demand AS (
    -- Jodi's demand view, verbatim, scoped to the live season by the season scope
    ...
), q AS (
    SELECT count(*) FILTER (WHERE m.status = 'pending')                          AS depth,
           count(*) FILTER (WHERE m.status IN ('pending','claimed','running'))   AS outstanding,
           coalesce(extract(epoch FROM now() -
                min(m.created_at) FILTER (WHERE m.status = 'pending')), 0)       AS oldest_pending_s
      FROM matches m
      JOIN seasons s ON s.id = m.season_id AND s.closed_at IS NULL
      JOIN games   g ON g.id = m.game_id  AND g.slug = ($1)::text
     WHERE m.engine_digest = s.engine_digest      -- rows of the CURRENT engine only; §9
), want AS (
    SELECT coalesce(sum(want), 0) AS want FROM demand
)
SELECT want.want, q.depth, q.outstanding, q.oldest_pending_s,
       least(($7)::int, greatest(($6)::int,
           ceil((want.want + q.outstanding)::numeric / ($5)::int)::int
         + CASE WHEN q.oldest_pending_s > ($8)::int THEN 1 ELSE 0 END
       )) AS replicas
  FROM want, q
```

**Why the numerator is `want + outstanding`.** `outstanding` is every match row the current engine
still owes work on; `want` is what the ladder wants *beyond* what is already in flight, since the
view's `want` is `greatest(cap − in_flight, 0)`. Their sum is the work the fleet must hold, and a
replica holds K of it, so `ceil(…/K)` is the fleet that drains it in one wave.

**The latency guard is a nudge, not a jump.** One replica above the computed target while the oldest
pending row is older than `$8` — it catches the case the arithmetic cannot see, a row nothing is
claiming because the fleet is busy elsewhere, without turning a single stuck row into a fleet.

**The `engine_digest = s.engine_digest` predicate is what makes a rolling deploy not oscillate.**
Mid-deploy the old engine's rows are being drained by replicas that are going away; counting them
would ask for new-engine replicas to cover work they cannot claim. §9.

**Driven, 8 September 2026.** `scripts/check/autoscale.sh` substitutes jodi's demand view --
verbatim out of `tb-pair-run.json` -- into the skeleton above and runs it over six staged ladders in
a scratch copy of the real database. All four claims hold: want is 6 with the queue still **empty**,
so demand leads it; a queue pinned at `pair_depth_target` = 64 asks for **5** replicas rather than
the 4 a depth-reading scaler would cap at; the latency guard takes 5 to **6**, exactly one, when the
oldest pending row is 600 s; and 40 rows on a retired engine are counted as **zero**. What is not
driven is the loop itself, which needs an orchestrator to close.

**Sizing the loop.** The reconciliation period must be above the scale-up latency — a replica's boot
plus its package load plus its first model fetch — or the scaler acts on a fleet it has already
asked for. Below the wave duration, or it never sees the effect of the last decision. Both bounds
are deployment facts; the period is not a number this document can pick.

---

## 6. Drain, and which number actually bounds a wave

### 6.1 The correction

[`orion-notes.md`](orion-notes.md) §4 records, from the build: *"Drain is three numbers and
the smallest wins"*, and Kalam's drain ([`kalam/docs/design.md`](https://github.com/Tiny-Brains/kalam/blob/main/docs/design.md) §5)'s banner says all three must exceed the longest match. **The
measurement was right and the rule drawn from it is wrong**, which matters because the rule tells an
operator to raise a number that costs them and leaves the one that would have helped at its default.

Read out of `orion-server` 1.7.0's `main.rs`, the shutdown is:

1. `/readyz` flips to `503`.
2. The HTTP server **sleeps for `server.shutdown_drain_secs`** — `tokio::time::sleep(drain).await`,
   an unconditional fixed period, not a maximum.
3. Accepting stops; in-flight *requests* get up to `server.shutdown_force_timeout_secs`.
4. Then, and only then, the supervised background tasks are stopped —
   `tasks.shutdown(Duration::from_secs(config.server.shutdown_force_timeout_secs))`.
   **The cron worker is one of those tasks.**
5. Inside that, the cron worker's own drain waits for in-flight occurrences under
   `cron.shutdown_timeout_secs`.

So the bound on a draining wave is `min(cron.shutdown_timeout_secs,
server.shutdown_force_timeout_secs)` — an **inner** deadline under an **outer** one, and
`cron.shutdown_timeout_secs` can only ever make it shorter. Layer 03's config sets cron to 2 700 and
the build left the server keys at their 30 s defaults, and measured a 30 s drain. That is not three
numbers racing; it is the outer deadline doing exactly what it says.

### 6.2 What that buys Kalam

**`shutdown_drain_secs` buys a Kalam replica nothing and costs it everything.** It exists so a load
balancer's in-flight requests survive its own poll interval. Kalam binds no route and sits behind no
balancer. It is also the one number that is paid unconditionally — an idle replica pays it in full —
so setting it to the longest match, as the folk rule implies, makes **every** scale-down cost a
match duration whether or not a wave is in hand.

| Number | Kalam | Soma+Jodi | Why |
|---|---|---|---|
| `server.shutdown_drain_secs` | **5** | **30** | fixed and paid always. Kalam has no rotation to leave; Soma does |
| `server.shutdown_force_timeout_secs` | **2 700** | **30** | **the real bound on the wave.** Above `channel_timeout_ms` (2 400 s) |
| `cron.shutdown_timeout_secs` | **2 700** | **60** | the inner deadline; equal to the outer on Kalam so neither surprises |
| orchestrator grace | **2 760** | **90** | above `drain + force`, as Orion's own checklist requires |

**A scale-down costs one wave, not one timeout.** The drain ends when the wave ends; the timeout is
only the cap. Measured waves are 3.8–9.1 s for ~150 turns, so the expected cost of shedding a
replica is seconds, and 2 700 is the pathological match nobody has seen. The risk register's "a
scale-down takes a match duration per replica" is the worst case, not the case.

**And a wave that does outlive the cap is not lost.** Orion cancels the attempt and *deliberately
leaves the claim and singleton rows to expire* rather than releasing them eagerly — the same safety
window Kalam's own lease uses. The rows lapse, the next claim reaps them, and they are replayed from
turn zero at the cost of one attempt. That is the design working, not a failure.

### 6.3 The entrypoint

Layer 03's banner records the trap and its fix, and it must survive into every replica image:
`trap 'kill -TERM $PID'; wait $PID` returns *when the trap fires*, so the script falls off its end
and the container exits while Orion is still draining — measured at `docker stop -t 300` returning in
zero seconds with two rows still `running`. **Wait again, in a loop, until the process is gone.**
`devops/compose/orion/entrypoint.sh` has this; the Kalam image inherits the same file.

---

## 7. The two deployment numbers

### 7.1 Decision 5 — K, and what actually bounds it

Every candidate bound has now been measured and none of them binds at 16: not `wave_state` against
the plugin request ceiling (14% at K=16, and it does not bind until ~64), not Orion's per-turn cost
(~3–4.6 ms per match-turn, linear in K), and not inference — `axon` costs ~1.0 ms a seat, so K = 32
is 162 ms of a 1 000 ms turn. Layer 04 §13.1 names the caveat the table cannot show: **that was a
Micro model, and the classes go to 64 MiB.**

**So K is bounded by the loader's residency budget, and this page takes it as one:**

```
K × seats_per_match × max_class_bytes  ≤  the replica's memory for weights
```

At K = 16, two seats and a `large` class of 64 MiB, that is **2 GiB of resident weights** in the
worst case where every seat of every match is a distinct large model — which is the case affinity
tries to avoid and cannot be relied on to. A replica sized for 4 GiB of weights holds it with room;
one sized for 1 GiB does not, and the symptom is not a crash but the residency barrier refusing
holds, `refusal_ceiling` counting up, and rows going unplayable five refusals later.

**K = 16 stands**, now as an answer rather than a placeholder: it is the largest K that fits a 2 GiB
weight budget at the largest class the fleet serves. Moving it is arithmetic on that line, not
another measurement — and it moves *down* for a fleet serving large models on small replicas, which
is the direction the old framing never suggested.

**Blast radius is the second bound and it does not bind at 16**: a replica death replays K matches
from turn zero, and at K = 16 that is 16 attempts burned against a `refusal_ceiling` of 5 and three
lapses to failure. It would bind well above the residency number.

### 7.2 Decision 25 — the poll interval

**Taken in shape, and its constant is still owed.** The interval is bounded on two sides:

- **Below, by claim load.** N replicas at interval *i* issue N/*i* claims per second, each one
  statement against the partial index on `pending`. At N = 20 and i = 5 s that is 4 per second,
  which is not a load question. It becomes one somewhere, and **where is exactly what the
  claim-under-load spike measures** (tracker §3.1) — several pollers against the partial index with
  a table of finished rows behind it, at N per second, against the seats-table joins of 01 §4.2.
- **Above, by latency.** A newly paired row waits up to *i* before any replica sees it, and that
  wait is on the front of every trial — the thing a competitor is watching on the Version screen.

**5 s stands**, and the rule for moving it was: raise it only when the spike says the claim rate is a
measurable fraction of database capacity, and then raise it rather than adding replicas to absorb
it.

**The spike has now run** — `scripts/check/claim-load.sh`, against a scratch copy of the real database
so the index statistics and row widths are the real ones. One claim costs **0.68 ms** at a single
client and the table sustains **~1,470 claims/s** at that client, rising to ~11,000 at 64. **Queue
depth does not move it**: an empty queue and a queue at `pair_depth_target` measure the same at every
client count, which is the partial index on `pending` doing exactly what it was shaped for — the
finished rows behind it are not scanned. The seats-table joins of 01 §4.2 do not bite at this scale
either.

So the fractions are: 20 replicas at 5 s is 0.27% of the floor, 100 replicas at 5 s is 1.4%, and
even 100 replicas at a 1 s interval is 6.8%. **Claim load does not bound the interval at any fleet
size this design contemplates.** What bounds it is the other side — a newly paired row waits up to
*i* before any replica sees it, and that wait is on the front of every trial. The decision is
closed at 5 s, and the honest statement of the bound is that it is a latency choice and was never
going to be a load one. Re-run the spike if the table grows by orders of magnitude.

**One thing worth noting**: the interval is per replica, so the claim rate rises with the fleet
exactly when the queue is deepest and each claim is most likely to return rows. The pathological
case is the opposite one — a large idle fleet polling an empty queue — and the autoscaler's floor
`$6` is what keeps that fleet small.

---

## 8. The loader, on both sides

### 8.1 One binary, two roles, and one store

`axon` refuses to be both, which is the design: a replica's fetch allowlist is empty whatever the
environment says, and the admission instance answers `/play` with a `404`. Two processes, so a
confusion of roles is loud rather than subtle.

**They must share one store, and in a fleet that means R2.** The admission instance mirrors what it
verified under the bytes' hash; every replica fetches by that hash. Two stores would mean admission
succeeds and every match the version is then paired for fails at the residency barrier — quietly,
and a long way from the cause. Locally this is one shared volume; there is no shared volume across
hosts, so **S3/R2 with SigV4 is not an optimisation for this page, it is what makes the fleet
possible at all.**

That is tracker §3.3's owed item, and **it is built** — `axon/src/store.rs`, `S3Store`:

- a third implementation of `axon`'s `Store` trait beside `DirStore` and `HttpStore`, signing SigV4
  against the same account that holds the replay bucket. Path style, one credential, two grants:
  the admission instance writes, every replica reads;
- selected by `AXON_STORE_S3_BUCKET` **first**, before the directory and HTTP specs. A deployment
  that names a bucket means it, and falling back to a directory because one variable was missing
  would give every replica its own empty store — the exact split-store failure above, and silent;
- signing is checked two ways, because a consistently wrong implementation round-trips perfectly:
  unit tests pin GET and PUT signatures produced by an **independent** implementation over the same
  canonical request, and `tests/s3_live.rs` drives a **real S3 server** — the stack's MinIO — for
  the round trip, a missing object as `NotFound`, and a bad secret as `Unavailable` rather than
  `NotFound`. That last distinction is load-bearing: admission rejects on one and retries on the
  other, so confusing them rejects a good submission for a credential problem;
- **asynchronous load stays out.** It is the answer to a cold large model stalling a wave behind the
  residency barrier, and the barrier's two-class refusal split already releases what it cannot hold.
  Build it when a measurement says a cold hold costs a wave, not before.

### 8.2 Beside every replica, and once beside Soma

The admission instance is one process beside the Soma+Jodi fleet — `tb-admit` reaches it through the
`jodi-loader` connector, and it is the only `axon` with a non-empty `AXON_FETCH_ALLOW_HOSTS`.

Every Kalam replica carries its own, and **the package load is an init step on each one** (§4.2):
each replica has its own SQLite state, so `kalam/scripts/load-package.sh` runs against
`localhost:8080` before the replica is useful.

**The failure mode this creates, and the health check that closes it.** Orion's `/readyz` goes green
as soon as the first generation publishes — a replica whose package load failed is *ready*, has no
`tb-wave` channel, claims nothing, and is **invisible capacity**: the autoscaler counts it, the
ladder does not. Nothing errors. So a replica's readiness gate is not `/readyz`, it is
`/health` asserting `tb.ants` is loaded and the `tb-wave` channel is present and not quarantined.
Without that check the fleet can scale up into an empty ladder and every dashboard stays green.

---

## 9. The deploy step

**One migration set, one loader artifact, both packages, promoted together** — the review decision
B′, and the reason the digests on the row exist is to make a skew visible when it is not.

The order is not arbitrary. Each step is safe against the fleet as it stands when it runs:

| # | Step | Safe because |
|---|---|---|
| 1 | `orion-server migrate` on `orion_state` | `auto_migrate = false` is required in cluster mode — a cluster left on `true` is refused at startup, and a replica booting against a pending migration fails fast |
| 2 | the `soma` schema's migrations | additive only. **The schema is pre-release today and `0001_init.sql` is rewritten in place; the day it releases, this becomes expand/contract** — ship the add, run both shapes, remove the old shape a release later. Old and new binaries share one database during any roll |
| 3 | the new `axon` to both roles | the evaluator's digest is what `models.evaluator_digest` was stamped with; promoting the two roles together is what keeps them equal outside the rollout window |
| 4 | `load-package.sh` for soma and jodi, against **one** cluster node | a config change through any node reaches all of them (§4.1) |
| 5 | the new Kalam replicas, each loading its own package | they claim **nothing** yet — every row of the season names the old digest |
| 6 | **declare the engine digest** | the cutover |
| 7 | the old replicas drain | they claim nothing new; withdraw retires what is left |

**Step 6 is the switch, and it is one statement.** Layer 06 §5.3's patch, run only once the new
replicas exist — finding 5 option A, and the reason the deploy declares rather than the server
advertising:

```sql
WITH g AS (
    UPDATE games SET active_engine_digest = ($2)::text
     WHERE id = ($1)::uuid AND active_engine_digest IS DISTINCT FROM ($2)::text
 RETURNING id
), s AS (
    UPDATE seasons s SET engine_digest = ($2)::text
     WHERE s.game_id = ($1)::uuid AND s.closed_at IS NULL AND s.engine_digest <> ($2)::text
 RETURNING s.id
)
UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now() FROM s WHERE c.key = 'roster'
```

Before it, the new replicas are idle and the old fleet is playing. After it, pair stamps the new
digest, the new replicas claim, and the old ones can claim nothing — they drain what they hold.
Withdraw cancels every `pending` row still naming the old digest as `ENGINE_RETIRED` within the
minute, and pair re-inserts on the new one. **No engine mixes into a ladder at any instant**, which
is the rolling-deploy requirement, and it holds without a deploy pause or a deactivation step.

**One change from what the local loader does.** It re-stamps `pending` rows onto the new digest as a
kindness to a dev stack. A deployment should not: let withdraw cancel and pair re-insert. The
pairing was chosen for the old engine and the ratings have moved since; a fresh insert is a fresh
pairing, and it costs one withdraw period.

**A release, not a patch, is refused while a season is live** — 06 §5.3, zero rows, and the loader
fails loudly. The operator rolls back or asks the admin to close the season. This is already built.

---

## 10. The Kalam role

Layer 01's migration creates the role with `LOGIN` and no password and grants it `SELECT` on
`matches` and `match_seats` and `UPDATE` on exactly its own columns, so the committed schema ships
no secret and the grants come free with step 2 above. What does not come free is the password:

```sql
ALTER ROLE kalam WITH LOGIN PASSWORD :'pw';
```

from the orchestrator's secret store, not from a compose default. `kalam/scripts/check-sql.sh`
already asserts the grants cover what the wave writes and no more, and `soma/scripts/check/claim-load.sh` proves
Postgres refuses it everything else; both should run against the deployed database once, as a
deploy-time assertion rather than a local one.

**Owed and not this page's**: Soma and Jodi still share the owner role. A `jodi` role with exactly
its grants is worth doing the way `kalam` was, and the split makes it easier to reason about, not
harder.

---

## 11. Security, and what each item gates

Carried from the old tracker §6.4. Each of these is a precondition for something, and naming which
is what stops them being a list nobody finishes.

| Item | Gates |
|---|---|
| **TLS**, and `cookie_secure = true` with it | any origin that is not loopback. Browsers will not store a `Secure` cookie from `http://`, and Orion refuses a non-https `oauth_redirect_uri` off a loopback host at load — so this is not optional, it is the first thing that must be true |
| **`admin_auth` on the Orion admin API** | the admin plane becoming reachable off loopback at all. Locally the port is bound to `127.0.0.1`; in a fleet the loader must reach it across the network, which is precisely when it stops being safe unauthenticated |
| **Ed25519 trust keys**, `[plugins.trust] public_keys` non-empty | `tb-ants` signed, verified at every load. It is the one place a third party's code enters the platform — so it must be non-empty **before** a second cartridge by an outsider ships |
| **R2 credentials**, two grants over one account | §8.1. The admission role writes the model store; replicas read it; Soma presigns replay `GET`s and Kalam presigns `PUT`s |

**The property to keep, not a task**: the evaluator is the only place competitor logic runs, and
never as definition content. Nothing in this page moves it.

---

## 12. Retention made real

Layer 06 §7's policy table says what is kept; this page is where two of its rows stop being policy.

| Row | Kept | Mechanism |
|---|---|---|
| standings | for ever | the `seasons` and `ratings` rows. Nothing to build |
| match rows | indefinitely | nothing to build; revisit when vacuum shows it (tracker's deferred list) |
| **replays** | by a bucket lifecycle rule | an R2 lifecycle rule on the `replays/` prefix. Layer 06 §7's evictable-hash query is what says which are safe to sweep |
| **traces** | Orion's own retention | `[trace_storage]`. `sync` mode is right at Soma's volume; the five cron channels already carry `errors_only`, so a clean wave writes nothing |
| model store | by the same query | the evictable-hash query names weights held only by closed seasons' rejected rows |

---

## 13. What this page deliberately does not decide

### 13.1 The orchestrator

Kubernetes and Cloudflare Containers behind a Worker are both viable and the design does not depend
on which. Everything above is expressed as *the orchestrator's grace period*, *the scaler's target*,
*an init step* and *a secret store*, because those are the four things any orchestrator has. Orion
ships a Helm chart that deploys the cluster shape — 2 replicas, a pre-upgrade migration Job, surge
rolling deploys, a PodDisruptionBudget — and that is the shortest path for the soma+jodi unit if
Kubernetes is chosen. **Choosing is an owner decision and a cost question, not a design one.**

### 13.2 Soma's replica count

An availability number. Two survives a rolling deploy and a node failure, which is the requirement;
load is nowhere near a single instance's measured ceiling and the clocks do not care.

---

## 14. What is verified, and what is not

**Verified — read out of Orion 1.7.0's source and documentation, not assumed:**

- cluster mode refuses `sqlite:` and requires a Redis; `auto_migrate = true` is refused at startup in
  a cluster (`docs/src/operate/cluster.md`);
- a `forbid` singleton is a row in the state database, held by one occurrence at a time, so
  cluster-wide means state-database-wide — §4.1 and §4.2 both turn on this;
- the supervised-task drain, which contains the cron worker, is bounded by
  `server.shutdown_force_timeout_secs` and not by `cron.shutdown_timeout_secs`
  (`crates/orion-server/src/main.rs`, `runtime/tasks.rs`, `cron/worker.rs`) — §6.1;
- `shutdown_drain_secs` is an unconditional `sleep` (`server/serve.rs`), a fixed period;
- a cancelled cron attempt's claims and singleton rows are left to expire deliberately, never
  released eagerly (`cron/worker.rs`) — §6.2;
- strict-mode quarantine is reached only through a **cache connector** — the dedup store and the
  response cache — and is refused for `backend == "memory"` or a missing connector
  (`channel/registry.rs`). Soma declares neither, so none of its thirteen channels can be caught
  by it;
- `build_limiter` picks `RedisRateLimitBackend` whenever `cluster_redis` is present and
  `LocalRateLimitBackend` otherwise, and **`principal_rate_limit` goes through the same builder as
  `rate_limit`** (`channel/registry.rs`) — so Soma's six quota channels become fleet-wide on the
  strength of `[cluster] redis_url` alone, with no channel edit — §4.1.

**Driven on the local stack, 8 September 2026** — the split is built, and these ran:

1. **The config split (§3).** `orion.toml.tmpl` is now `soma.toml.tmpl` and `kalam.toml.tmpl`, each
   parsing through `orion-server validate-config`. `devops/scripts/check/configs.sh` asserts the
   three cross-file values and the four structural rules, and passes.
2. **Cluster mode (§4.1).** Soma runs with `[cluster] enabled`, Postgres state and Redis, and
   `auto_migrate = false` with `migrate` as the entrypoint's step. All four clocks run as
   singletons under one `instance_id` with `fencing_token=1`, and `/health` reports
   `config_propagation: ok`. **No channel needed editing** — the quarantine trap is for dedup and
   cache connectors, and Soma declares neither.
3. **A replica is its own scheduler (§4.2, decision 41).** Two replicas, each with its own SQLite
   state and its own `axon` sidecar, claimed and played **two concurrent waves** — 48 rows drained
   in about 50 s. Under one shared state that number would have been one wave, for ever.
4. **The loop closes across the split.** 168 matches paired, claimed through the sidecar at
   `127.0.0.1:9090`, played, finished and folded into ratings by count on the other unit.
5. **§6.1's correction, measured and confirmed.** This is the one that mattered, because the layer
   asserts it against what the build had written down:

   | `drain` | `force` | `cron` | `docker stop` returned | rows left `running` |
   |---:|---:|---:|---:|---:|
   | 5 | 2 700 | 2 700 | **16 s** | **0** |
   | 0 | **1** | 2 700 | **2 s** | **16** |

   `cron.shutdown_timeout_secs = 2700` did **not** protect the wave. The bound was
   `server.shutdown_force_timeout_secs`, exactly as `main.rs` says. And the drain ends when the wave
   ends, not at the cap: 16 s, not 2 700.
6. **The recovery path (Kalam's drain ([`kalam/docs/design.md`](https://github.com/Tiny-Brains/kalam/blob/main/docs/design.md) §5)).** The 16 abandoned rows lapsed after their 300 s lease, the
   next claim reaped them, they were replayed from turn zero, and every one reached `rated` —
   `lapses = 1`. This is what makes decision 42's small drain safe rather than merely cheap.
7. **§8.2's invisible capacity, met in the wild.** Recreating a replica gives it empty state, so it
   comes back with no `tb-wave` channel: `/readyz` green, claims nothing, nothing logged. It cost a
   confusing minute before the loader's new per-replica `tb.ants` assertion caught it, which is the
   check this page added for exactly that reason.

8. **§8.1's store, built and driven.** The three axons run on MinIO over SigV4 with the
   `axon-store` volume removed; the four existing objects were migrated into the bucket, and 24
   matches then played across two replicas with **0 failed**, every weight and adapter fetched from
   S3. `devops/scripts/dev/seed-baselines.sh` writes through a signed PUT now rather than `docker cp`.

**Still not verified**: the autoscaler's query against a live demand view (§5); a rolling engine
deploy with two replicas on different digests, which is also tracker §3.4's second walk — the rig
is in place now that replicas take `KALAM_N_ENGINE_DIGEST`; the SigV4 store against **real R2** as opposed to MinIO,
which is the same S3 surface but not the same service; the deploy order of §9 end to end; and the numbers in §7 other than the poll interval, which the
claim-under-load spike has now measured (§7.2).

**One honest caveat about the drain table.** The measured waves are baseline-vs-baseline matches of
a few seconds, so the second row's window had to be squeezed to 1 s to make the difference visible
at all. The mechanism is what was under test and the mechanism is confirmed; the *numbers* for a
real class mix are still this page's to set.

**What is left, cheapest evidence first**: §9's order, then §11's security, then the orchestrator.

---

## 15. Decisions taken here

Decisions **5** (K, rows per wave per replica), **25** (the poll interval), and **41** to **45**
were taken on this page. They are recorded with their reasoning and the cost of flipping them in
[`decisions.md`](decisions.md) §3, under *Deployment*.

## 16. Open questions

1. **The reconciliation period** (§5) wanted one measurement — a replica's boot-to-first-claim —
   and it has been taken on the local stack, in the three parts it is actually made of:

   | | |
   |---|---:|
   | container start → orion-server's first log line | **0.1 s** |
   | package load into the new replica | **1.4 s** |
   | worst-case wait for the next poll (§7.2) | **5.0 s** |
   | **boot-to-first-claim** | **~6.5 s** |

   The entrypoint is cheap by construction — derive the digest, migrate a SQLite file, `exec` — and
   the load is one package into an empty state. **What this does not measure is the image pull**,
   which dominates a real scale-up and belongs to the orchestrator rather than to this design; it is
   the one term a deployment has to add.

   So the lower bound is ~7 s plus a pull, and the practical floor is the pull. Against measured
   waves of 3.8–9.1 s, a reconciliation period an order of magnitude above boot-to-first-claim is
   what stops the scaler counting a replica that has not started working yet and adding another:
   **60 s is the figure the measurement supports**, and the argument for it is the ratio, not the
   number.
2. **A replica pool per weight class** is refused above (decision 45) for a real reason: the claim
   has no class predicate. If the class mix ever makes K's residency budget bind badly — a fleet
   sized for `large` wasting memory on `nano` waves — the answer is a claim predicate, and that is a
   a schema change rather than a deployment one.
3. **The `jodi` database role** (§10) is owed and keeps being deferred. It is small, and the longer
   Jodi shares the owner role the more the schema forgets which grants it actually needs.
4. **Soma without Jodi.** §3's table notes that `prior_mu` and `prior_sigma` are safe only while the
   two share a config. The day Soma's REST surface gets a server of its own — the split this whole
   topology is designed to make cheap — that safety goes away and the check script has a fourth
   equality to assert. Worth building the check with the fourth case already in it.
5. **Whether `shutdown_drain_secs` at 5 s is right for Kalam** is an argument here and not a
   measurement. It rests on Kalam binding no route, which is true today. A development-only REST
   path was mounted on Kalam's config to make a cron occurrence's data readable at all
   (`build-findings.md` §4) — if that ever becomes permanent, the number changes with it.
