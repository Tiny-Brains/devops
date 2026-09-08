# Architecture

The whole-system map. Every repository's `README.md` links this page and none repeats it; if a
statement about who talks to whom appears in two places, this is the one that is right.

The reader-facing half — what a competitor sees — is [the book](https://github.com/Tiny-Brains/docs).
This page is for someone who will change the code, run it, or deploy it.

---

## 1. The parts

| Part | Role in one sentence | Host | Cardinality | State it owns |
|---|---|---|---|---|
| **[Soma](https://github.com/Tiny-Brains/soma)** | The public API for the web shell and the SDK: sign-in, submissions, models, matches, leaderboard. | Soma's Orion | N, cluster mode | none — reads and writes the database |
| **[Jodi](https://github.com/Tiny-Brains/jodi)** — the match maker | Four clocks: **admit** verifies a submission; **withdraw** cancels the queued matches of versions that stopped contesting and of engines that retired; **pair** inserts up to the smaller of the ladder's demand and the room under a depth target, and gives a verified version its trial; **count** folds finished matches into ratings, decides trial rows, and promotes. | a package of its own; loaded into Soma's Orion today | each clock a **cluster-wide singleton** on its own key, and correct with several running: every write is fenced | none |
| **[Kalam](https://github.com/Tiny-Brains/kalam)** — the game manager | Claims up to K `pending` rows in one statement and plays them as a wave, turn by turn against the models, finishing each row with its result and replay key as its match ends. **Knows nothing about ratings or the roster.** | Kalam's Orion | N replicas, scaled by the ladder's demand; drains on SIGTERM | none — a crash loses one wave |
| **[Ants](https://github.com/Tiny-Brains/ants)** — the game engine | The rules of one game: world generation, observation, step, scoring, replay decoding. Pure, deterministic, and wave-shaped: one call advances every live match in the wave. | **a plugin inside Kalam** | one per game | none |
| **Adapter** | A competitor's declarative transform: the game's observation JSON → their model's tensors, and the model's output → the game's action JSON. | **data**, submitted with the model; evaluated by Axon's evaluator under an operation budget the game's manifest publishes | one per model version | none |
| **[Axon](https://github.com/Tiny-Brains/axon)** — the model loader | Holds models resident, applies each seat's adapter under its budget, runs the graph, holds every seat to the turn clock, and answers one play call per turn for a whole wave. One instance beside Soma serves admission: fetch, verify, inspect, validate, mirror. | its own process, beside each Kalam replica, and one beside Soma | one per replica, plus one for admission | weights in memory; residency holds |
| **Postgres** | The system of record: the match table is **both the queue and the history**, plus ratings, models, seasons, and the `clocks` table that carries the fences. | managed | 1 | everything durable |
| **Object store** | Replay blobs by key, and the mirror of admitted weights and adapters by hash. | R2 | 1 | blobs |

Soma is the REST package and keeps its endpoints. Jodi is four cron channels, their workflows and
its plugins — **a package of its own**, loaded today into that same orion-server. Kalam is a
**second package on a second Orion**, with its own connectors, its own instance config, its own
plugins and no shared Orion state with the first. Axon is one binary, deployed beside every Kalam
replica and once beside Soma.

**Packaging is not deployment.** `soma/`, `jodi/` and `kalam/` are three repositories, each
shipping a self-contained Orion package that knows nothing of the topology, and `devops/` decides
how many servers there are and which package goes in which. A modular monolith — modular in the
repos, and as monolithic in deployment as is useful. Today one orion-server holds Soma and Jodi
both; the day Soma's REST surface must scale independently of the match maker, Jodi gets its own
service and neither repository changes.

**The names.** *Jodi* is "a pair" in Hindi and in every southern language, and it pairs. *Kalam*
(களம்) is "the arena", the field a contest is fought on, in Tamil and Malayalam, and *kaḷa* in
Kannada. *Soma* is the body the whole thing hangs off; *axon* carries the signal; *ants* is the
first game.

A game defines only the **JSON shapes** its engine speaks — the observation a seat receives and the
action it answers. What a model consumes is the competitor's business, and the adapter is where
they spend that freedom.

---

## 2. Shape

```
      browser / SDK
            │
            ▼
 ┌────────────────────────────────────┐          ┌──────────────────────────────────────┐
 │  SOMA's ORION  (cluster, × N)      │          │  KALAM's ORION  (× N replicas)       │
 │                                    │          │                                      │
 │  REST channels   the public API    │          │  cron channel   claim a wave of up   │
 │  cron  JODI   four clocks, each a  │          │                 to K rows            │
 │  singleton, every write fenced:    │          │  workflow       the wave loop; each  │
 │  admit · withdraw · pair · count   │          │                 row finished as it   │
 │  plugins  rating math ·            │          │                 ends                 │
 │           pairing math             │          │  plugin  GAME ENGINE  (per game,     │
 │                                    │          │          wave-shaped)                │
 └──────┬─────────────────┬───────────┘          └────────┬──────────────────┬──────────┘
        │ inspect ·       │ inserts rows;                 │ claims, renews,  │ one play
        │ validate ·      │ folds, decides,               │ finishes rows;   │ call per
        │ mirror          │ promotes,                     │                  │ turn
        ▼                 │ withdraws                     │                  ▼
 ┌────────────────┐       ▼                               │         ┌──────────────────────┐
 │  AXON          │ ┌───────────────────────────────────┐ │         │  AXON                │
 │  (admission)   │ │  POSTGRES                         │◀┤         │  (per replica)       │
 └───────┬────────┘ │  matches (queue + history) ·      │ │         │  residency · adapter │
         │          │  ratings · models · seasons ·     │ │         │  evaluator · clock   │
         │          │  clocks                           │ │         └──────────┬───────────┘
         │          └───────────────────────────────────┘ │                    │
         │ weights PUT                                    │ replay PUT         │ weights,
         │                                                ▼                    │ by hash
         │                              ┌───────────────────────────────────┐  │
         └─────────────────────────────▶│  OBJECT STORE                     │◀─┘
                                        │  replays · weights mirror         │◀── signed GET, via Soma
                                        └───────────────────────────────────┘
```

Solid lines are SQL. Each Orion reaches its own Axon over loopback HTTP and never the other's. The
loaders reach the object store over presigned URLs: the admission instance mirrors what it
verified, and a replica's instance fetches weights by hash. **The two Orion instances never speak.**

---

## 3. The contract: one table, one row per match

Everything between the two Orion instances is one table. A row is born `pending` when Jodi decides a
match should happen, is played and finished in place by Kalam, and is counted in place by Jodi — or
withdrawn in place if a seat leaves the roster or its engine retires first, or failed in place when
it cannot be played. Its columns are
[`soma/docs/schema.md`](https://github.com/Tiny-Brains/soma/blob/main/docs/schema.md); what the row
*says*, and who may write each part, is fixed here.

| The row says | Written by | When | Read by |
|---|---|---|---|
| **what to play** — game, seats (which model version in which seat, with its hashes and its adapter reference), map or preset, seed, which ladders it counts for — none for a trial — and the engine digest it requires | Jodi | at insert | Kalam; Soma, to show "playing now" if it wants to |
| **why it exists** — a pairing id and the rating snapshot it was paired on | Jodi | at insert | audit |
| **who is playing it** — status, a claim token, a lease expiry, an attempt count, a refusal count | Kalam | at claim, which also reaps lapsed leases; on renew | Kalam |
| **what happened** — ranks, scores, reason, per-seat strikes, duration, the engine and evaluator digests; on failure, a reason and the seat it is attributed to | Kalam | at finish, or at failure | Soma, Jodi |
| **where the replay is** — the object key, named per attempt, of a JSON blob only the game's visualiser understands | Kalam | at finish | Soma, which signs a `GET` |
| **what it did to the ladder** — the mark that it has been counted, and per seat and per ladder the rating before and after; the mark alone for a trial | Jodi's count clock, under its fence | at rating | Soma (the Version screen), audit |
| **why it will not be played** — withdrawn, and the version that replaced the seat or the engine that retired | Jodi's count clock at promotion, or Jodi's withdraw clock | in the statement after the flip; on withdraw's schedule | Soma, to tell the competitor; audit |

The status walk, and who may make each move:

```
pending ──claim (K rows)──▶ claimed ──start──▶ running ──finish──▶ finished ──count──▶ rated
  ▲ ▲ │                        │                  │                   Kalam               Jodi
  │ │ └─ a seat leaves the roster, or its engine retires ─▶ cancelled
  │ │                                     (count at promotion, or the withdraw clock)
  │ └─── lease lapses; the next claim reaps ◀──┴──────────┘
  └───── the loader refuses residency; no attempt spent     a third lapse, or a fault
                                                            Kalam can name ─────▶ failed
```

- `pending → claimed` is one `UPDATE … WHERE status = 'pending' … SKIP LOCKED` carrying a token and
  taking up to K rows. **That statement is the whole of coordination between N Kalam replicas.** It
  reads the status, the engine digest the row requires and the lease expiry — reaping lapsed leases
  on the way — and orders trial rows first, then rows whose models this replica's loader already
  holds. It reads nothing else: Kalam never joins the roster.
- **A `pending` row is played only while its seats are contesting and its engine is current.** Every
  roster write goes through the **roster fence**, a counter in the `clocks` table. Promotion is two
  statements: the first bumps the fence and flips the versions, the second withdraws every `pending`
  row the predecessor was to play, naming the successor. Pair reads the fence at the start of a run
  and every insert checks it, read `FOR SHARE`, so a pair insert either committed before the flip and
  is seen by the withdraw, or fails after it and the run halts. The window between the two statements
  is the claim instant; a row claimed in it is played and counted, like any claimed row. Jodi's
  withdraw clock sweeps every minute or so for what remains. `cancelled` is terminal and not a fault:
  no attempt spent, no strike, and the competitor sees it as withdrawn. A withdrawn row is never
  re-pointed at the successor; the successor is paired afresh. "Contesting" means `active`, or
  `verified` for the candidate seat of a trial row, stated by inclusion so a status added later fails
  closed.
- A lease that lapses is reaped by the next claim, which returns the row to `pending` with its
  attempt count raised; the third lapse makes it `failed`. A replica that dies loses its wave and
  nothing else; the rows are played again from turn 0 by whoever claims them next. A fault Kalam can
  name — a hash that does not match, a graph or an adapter the loader cannot build — fails the row at
  once, with the seat it is attributed to, and no one is charged an attempt for it. A loader that
  cannot hold a row's models for want of memory releases the row without an attempt, under a refusal
  count of its own.
- **Finish is one statement per row**, conditioned on the claim token: write the result and the
  replay key onto the row and set `finished`. A stale attempt — one whose lease lapsed and whose row
  was claimed again — holds a token the row no longer carries, so its finish updates nothing, and its
  replay blob, keyed by attempt, is an orphan rather than a replacement. A match that dies mid-run has
  written nothing. Kalam touches no other table, **and its database role can touch no other.**
- **Counting is one statement per match**, made by Jodi's count clock in finish order: mark the row
  `rated`, and in the same statement apply the posteriors to the rating rows, gated on the mark having
  landed and on the **count fence**. The mark makes a match count **at most once under any
  concurrency**; the fence makes a stale run write nothing at all. A run claims its fence — the
  occurrence's instant and attempt, monotonic per channel — at its first task; every write checks that
  the fence row still carries it, read `FOR SHARE` so the row lock rather than the snapshot orders the
  check; a run that finds its fence gone halts. A trial takes the same step with no posteriors, and is
  decided in the same run.
- The singleton lock on each clock therefore buys **efficiency and order, not correctness**. Order
  within a run is finish order; a second run cannot interleave, only lose.
- `finished` and `rated` rows are permanent and are what Soma lists. `failed` and `cancelled` rows
  are kept too, so a competitor can be told why a match never happened. Nothing is deleted;
  retention is a season question — see [`deployment.md`](deployment.md).

---

## 4. One match, end to end

1. A competitor submits a release: weights, and an **adapter** in the platform's declarative
   dialect. Jodi's admit clock drives Axon beside Soma, which fetches the release once, verifies the
   hashes, inspects the graph for size, class, opset and ops, validates the adapter against the
   model's declared inputs and outputs with a sample observation under the operation budget, and
   mirrors both to the object store. Soma records the verdict: the version is verified and waits for
   its trial, or is rejected with the reason.
2. Jodi's clocks run, each a cluster-wide singleton on its own key, each fenced, none waiting for
   another. **Count** runs as often as results arrive: every `finished` row not yet marked is folded
   into ratings in finish order and marked, and a finished trial row is decided as it is reached. A
   candidate that played without forfeiting is promoted in two statements — the first bumps the
   roster fence, supersedes the predecessor, activates the candidate and seeds its ratings from the
   predecessor's; the second withdraws the predecessor's queue. A candidate that forfeited, or whose
   row failed with a fault attributed to its seat, is rejected with the reason. **Pair** runs at the
   rate the queue drains: it reads the **demand view** — how many matches the ladder wants now — and
   inserts up to the smaller of that and the room under the depth target, choosing for each the
   opponents and the maps that would teach the ladder the most, and stamping each row with the engine
   digest the deploy has declared current. A verified version with no live trial row gets one,
   against a baseline, counting for no ladder. **Withdraw** runs every minute or so as the backstop.
3. A Kalam replica claims a wave: up to K rows in one statement, trial rows first, then rows whose
   models its loader already holds, reaping any lapsed lease it passes. It asks Axon to make the
   wave's models resident, releases any row whose models the loader cannot hold, asks the game engine
   plugin for the wave's worlds from the rows' seeds, and enters the loop.
4. Each turn, three calls: the engine observes every seat of every live match; one call to Axon
   carries every observation and returns every action, the loader having applied each seat's adapter,
   run the graph, applied the adapter in reverse, and held every seat to the turn clock; the engine
   steps. A seat that missed the clock gets the no-op and a strike. Every N turns the replica renews
   its leases in one statement, and halts if the renew touches nothing.
5. As each match in the wave ends: the engine scores; a seat that forfeited ranks last; the replica
   writes the replay blob under a key that names the attempt, then finishes that row with the result
   and the key in one statement. When the wave ends it releases the models. **It has read no rating
   and written none.**
6. On count's next run the match is counted, and the row carries the rating change.
7. The leaderboard is a read over ratings. A competitor's Version screen lists a match, trial or not,
   the moment its row is `finished`, and shows the rating change once it is `rated` — at most one
   count period later.
8. The competitor's next version plays its trial, and on count's next run passes it and is promoted
   as step 2 describes. The predecessor's claimed and running matches finish and count against it. On
   pair's next run the successor is paired for the first time, and the opponents from the withdrawn
   rows are paired again.

**Step 2 is the only place the ladder is written, and the only place a version is promoted.** Steps
3 to 5 know nothing about ladders.

---

## 5. What must stay true

These are the system-wide invariants. Each repository's README §9 carries its own slice, rewritten
so it can be checked against a diff.

1. **The database is the only coupling.** No broker, no queue service, no HTTP between Orion
   instances. If two parts need to talk, one writes a row and the other reads it. Each Orion
   reaches its own Axon over loopback, never the other's.
2. **Every part but the database is disposable.** A Kalam replica has no shared Orion state: its
   definitions and plugins are baked into its image, its own Orion state can be a local SQLite
   file, it drains on SIGTERM, and a crash loses only the wave it was playing.
3. **Each of Jodi's clocks is a singleton by lock on its own key, and correct without one.** Every
   ladder and roster write carries a fence: the run's fence for count, the roster fence for pair
   and promotion, the mark on the row for the match. A stale run writes nothing and halts; a
   second pair is fenced out; a withdraw is idempotent. **The locks buy efficiency and ordering;
   the fences buy correctness.** Soma scales by load, so this is not hypothetical.
4. **A match is finished once, at the end, idempotently.** The claim token makes a stale attempt a
   no-op and the replay key names the attempt, so re-playing a match is always safe.
5. **Ratings have one writer, Jodi's count clock, applying matches in finish order** — and seeding
   a promoted version, since count is what promotes. Kalam never reads or writes a rating row, and
   its database role cannot. Because of that, how many matches a model version plays at once has
   no bearing on whether ratings are right — only on how they are paired.
6. **The adapter is data, and it runs in a sandbox.** It is a competitor's code in all but name:
   evaluated by Axon's evaluator under an operation count the game's manifest publishes and a
   deadline the evaluator enforces itself, **never as definition content**. The host's fuel and
   wall clock are backstops, not the budget.
7. **Nothing outside the game engine parses game state.** Kalam carries it as an opaque value
   between calls; the loader and the adapter see only the per-seat observation the engine hands out.
8. **Scaling signals are queries.** The demand view drives the Kalam replica count up, and the age
   of the oldest `pending` row guards latency. Drain by SIGTERM means scaling down loses nothing.
   Nothing needs a metric pipeline to scale.
9. **A trial is an ordinary match** that counts for no ladder. It is claimed first, played, listed
   and replayable like any other; count marks it without touching a rating, and decides it.
10. **The two Orion packages share no workflow.** They share one schema and one Axon binary,
    promoted together. A row records the engine and evaluator digests that played it, and is
    claimed only by the engine it requires.
11. **A queued match is a promise only while its seats are contesting and its engine is current.**
    What is already claimed finishes and counts against the version that was paired: **the ladder
    records what was played, not what is current.**

---

## 6. Why each part is on Orion, and what that costs

Soma, Jodi and Kalam are definitions — channels, workflows, connectors — rather than application
code, because the platform's work is overwhelmingly *shaped like* what Orion already does: receive a
request, run a sequence of steps against a database and an HTTP service, and do it again on a
schedule under a singleton lock. What would otherwise be three services with their own HTTP
plumbing, their own schedulers, their own retry and their own observability is instead three
packages of JSON, and the operations console reads all of them.

The costs are real and are paid deliberately:

- **No arbitrary computation in a definition.** Anything that is genuinely an algorithm — rating
  math, pairing math, the game itself, the adapter evaluator — is a WebAssembly plugin or a service
  beside it. This is the constraint that shaped the seam, and it is why Axon is a binary.
- **Debugging is reading traces, not stack frames.** The console is the debugger.
- **The version of orion-server is a deployment fact**, and a package that lints against one may not
  against another. `devops/` pins it; the packages do not.

What the platform gets back is that every schedule, every retry, every quarantine and every trace
is the same mechanism in all three packages, and that a new game is a plugin rather than a service.

---

## More

- [`decisions.md`](decisions.md) — the decision log, and the reasoning behind each
- [`deployment.md`](deployment.md) — topology, drain, cluster mode, the digest declaration
- [`orion-notes.md`](orion-notes.md) — the Orion facts the build had to discover
- [The competitor guide](https://github.com/Tiny-Brains/docs) — the reader-facing half
