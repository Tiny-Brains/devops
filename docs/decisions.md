# Decisions

Why the system is shaped the way it is. One line per decision, with the reasoning kept and the
cost of flipping it named where that was worked out.

> **Two numbering series, and they collide.** The **A-series** (§1) is the twenty-one architectural
> decisions taken when the design was reviewed, before anything was built. The **plain series**
> (§3) is the forty-five build decisions the layers took as they were built, and it numbers from 1
> again. `A5` ("who rates and who lists") and `5` ("K, rows per wave per replica") are different
> decisions. Code comments that cite a bare number mean the plain series.

The system map those decisions produced is [`architecture.md`](architecture.md).

---

## 1. Architectural decisions

| # | Question | Decision | What it fixed |
|---|---|---|---|
| A1 | Where does the game engine run? | A plugin inside Kalam | one process per replica |
| A2 | Who owns the game-to-tensor transformation? | **The competitor**, declaratively, submitted with the model. The game defines only its JSON shapes | the evaluator in Axon; admission validates adapters through it |
| A3 | What is one row? | **One match**, carrying the players and their model details; a replica claims and plays a wave of such rows | the engine stays wave-shaped; one inference per distinct model per turn, per replica |
| A4 | Where does a finished match go? | **The same row**, finished in place; a status column separates queue from history. Not a second table | one table; finish is an update conditioned on the claim token |
| A5 | Who rates and who lists? | **Jodi's count clock**, under a fence, in finish order; Kalam publishes results only and Soma lists | rating math in Jodi's package; the mark on the row |
| A6 | The match maker in several instances? | Soma scales by load; Jodi is a **cluster-wide singleton** | cluster mode is a requirement, not a refinement |
| A7 | Trials? | Visible to the competitor, identical to any match, only unrated; count decides them | a trial is an ordinary match |
| A8 | Replays? | A JSON blob only the visualiser understands, **in the object store**, keyed per attempt; the key on the row | — |
| A9 | The match maker's name | **Jodi** | — |
| A10 | The game manager's name | **Kalam** | — |
| A11 | The Rater | **Not a part.** Counting is Jodi's | — |
| A12 | A superseded version's queued matches? | **Withdrawn in the statement after the flip**, ordered by the roster fence, to a terminal `cancelled` naming the successor; claimed and running ones finish and count; never re-pointed at the successor | Kalam stays roster-blind |
| A13 | What does Jodi do? | Withdraw, pair, count — and, since admission, admit. Pairing takes the versions whose rating has not settled and spreads their matches across the game's maps; a settled version plays as an opponent | — |
| A14 | In what order? | **No order.** Cron channels, each its own schedule and singleton key; they meet only in rows, and every write is fenced | — |
| A15 | Correct without the lock? | **A fence per clock** in a `clocks` table; a stale run writes nothing and halts. The rating math stays in the plugin, not in Postgres | the locks buy efficiency, the fences correctness |
| A16 | Who promotes? | **Count**, in the run that decides the trial row, in two statements under the roster fence. Not admission | the seed includes every match counted before it |
| A17 | Where does the adapter run? | **In Axon**, under an operation count the evaluator keeps and a deadline it enforces; the host's fuel and wall clock are backstops. Not an Orion plugin | — |
| A18 | One match per workflow run, or a wave? | **A wave per replica**: up to K rows claimed in one statement, one play call per turn, each row finished as its match ends | — |
| A19 | Which engine plays a row? | **The row says**: pair stamps the digest the deploy declares current, the claim filters on its own, withdraw cancels a retired one | the digests that played a match are recorded at finish |
| A20 | How does Kalam scale? | **Up on the demand view, down by drain** on SIGTERM | — |
| A21 | Who has a data path for admission? | **An Axon beside Soma**: fetch once, verify, inspect, validate, mirror to the object store; Kalam's loaders fetch by hash | — |

---

## 2. The twelve findings that forced them

The review that produced §1 found that four of the eleven system invariants did not hold as
written, two mechanisms had no owner, and the design had changed the platform's cost model without
pricing it. The verdict it sat under: **the split by scaling axis and the one-table contract are
the right seam, and the status walk is the best part of the design.**

| # | Finding | Decision |
|---|---|---|
| 1 | **Count is not correct without its lock.** | **A fence per clock** — the claim-token pattern Kalam already uses on the match row, applied to Jodi, so the design carries one idea rather than two. A `clocks` table holds one row per clock. The first task of a run claims the fence — the occurrence's `scheduled_for` and `attempt`, both monotonic per channel — by updating the row only if the stored fence is lower. Every ladder write carries a predicate that the fence row still equals this run's fence, read `FOR SHARE`, so the row lock rather than the snapshot orders the check. |
| 2 | **Promotion cannot withdraw "in the statement that supersedes it".** | **The roster fence** — the same table and predicate as finding 1, so the design carries one mechanism for "a stale run writes nothing" and "a stale roster pairs nothing". The roster key is a counter bumped by any roster writer, not a run fence, so `clocks` carries two flavours. Promotion is two statements: bump-and-flip, then withdraw. A crash between them is the withdraw clock's case. |
| 3 | **Ratings have two writers.** | **Count promotes**, putting every ladder write — the mark, the posterior, the seed, the flip and the roster bump — under one fenced run. |
| 4 | **The adapter budget is not answered by the host.** | The **evaluator counts operations** (logic nodes plus tensor elements) and carries its own deadline; the loader owns `turn_ms` across adapter, inference and adapter. Fuel and wall clock are backstops only. **The number came out at 1,000,000 — five times what was argued** — because a real adapter measured against a real observation said so. |
| 5 | **Two engine digests can rate into one ladder.** | The row carries **the digest it requires**, and the digests that played it are recorded at finish. Count does *not* refuse foreign digests (decision 13); what keeps a behaviour-changing engine out of a ladder is that a release is refused while a season is live. |
| 6 | **The trial path has no owner.** | Pair inserts, Kalam attributes, count decides; trials claim first. |
| 7 | **The lease and the attempt have no owner.** | The claim reaps lapsed leases; a partial renew halts; refusals are counted apart from attempts; the replay key names the attempt. The attempt ceiling counts lapses only, and with drain, lapses come only from crashes — so **three**. |
| 8 | **The scaling signal is capped by the thing it measures.** | A **demand view**, not queue depth: pair tops the queue to a target, so depth could never distinguish two missing replicas from twenty. Drain by SIGTERM on the way down. |
| 9–11 | **The batching economics are gone; per-turn work multiplies; the reason Kalam is on Orion is also its largest cost.** | **The evaluator in the loader, waves per replica.** It restores the economics the design was built on, cuts the per-turn task count by the wave size, and answers "why is Kalam on Orion" with the loop as a workflow, the engine as a plugin, and the claim, lease and finish as SQL. **Measured afterwards: batching is worth 1.11× at Ants' full board, not an order of magnitude**, because every seat costs its own forward pass either way. The decision survives the correction; the argument for it was overstated. |
| 12.1 | Lease renews are updates on the permanent history table every few turns | **Keep the columns on `matches`, index none of them, set a fill factor** so renews are heap-only updates. A narrow claims table only if vacuum shows it. |
| 12.2 | Kalam's credential can touch any table | **A dedicated role** with column-level grants. One statement, and it makes the rule a fact rather than discipline. |
| 12.3 | Every replica fetches every model from GitHub | **An admission-side loader fetches once, verifies, inspects, validates and mirrors to R2**; Kalam's loaders fetch by hash. GitHub is touched once per submission, and a competitor deleting their release cannot break their own replays. |
| 12.4 | The endpoints keep their paths but not their shapes | **Additive fields**, so a competitor is still told why a match never happened. |
| 12.5 | Forfeit ranks have no owner | **Kalam overrides ranks at finish**, forfeited seats last, the engine's ranks kept in the replay envelope. Telling the engine is refused; letting the engine's result stand would let a timed-out model win on points. |
| 12.6 | **Admission has no data path** | Answered by 12.3: the loader is a part on both sides. The two Orion packages still share no workflow. |

### Orion changes worth asking for

Not required by any decision above, and listed so they are not confused with the fixes.

| Change | Earns its place because | Needed by |
|---|---|---|
| Per-channel, per-node concurrency cap on cron | Kalam wants K matches in flight per replica per channel; the only knob is `cron.workers`, node-wide across every channel | Kalam — **downgraded, not withdrawn**: a `forbid` singleton is already per-replica state, so this is wanted only if a replica ever wants more than one wave in flight |
| A monotonic fence integer in `metadata.trigger` | Ergonomics only; `scheduled_for` plus `attempt` already serves | nobody |

---

## 3. Build decisions

Numbered as the build numbered them. Each names the repository it now lives in.

### The match table — [`soma`](https://github.com/Tiny-Brains/soma)

| # | Decision | Taken as | Why |
|---|---|---|---|
| 2 | Seat shape | **a `match_seats` table**; jsonb only for the two ladder-keyed rating facts | every read is a plain join, Postgres refuses a dangling seat, Kalam's grant is column-level on both tables. A single document was set aside because three writers fill a seat at three moments and a column grant cannot bound Kalam inside one |
| 3 | Seed columns | **kept**: a promoted version inherits its predecessor's `mu` per ladder with `sigma` inflated and capped at the prior | continuity for a competitor who iterates, and informed first pairings; a column read beats a jsonb query for the one question an auditor asks |
| 7 | Lapse ceiling | 3, in a `CHECK` and the reap | with drain, lapses come only from crashes |
| 7c | Refusal ceiling | a parameter, Kalam's number | — |
| 7d | Replay key per attempt | by claim token, not attempt number | the token is minted per claim and already on the row; no counter to keep in step |
| 18 | One preset per wave | **yes**, in the claim's fill clause | `worldgen(seed[], preset, players)` takes one preset; the cost is throughput under many presets |
| 21 | Verified state | **a `verified` status value**: `testing → verified → active \| rejected` | one predicate everywhere, and `SELECT status` tells an operator the whole story |
| 22 | Rating history | **a `rating_events` table**: one row per seat per ladder per counted match, plus a `seq = 0` row for the seed | every read is a join an operator can write; the primary key is finding 1's chain constraint for free; the history survives whatever retention does to match rows |
| — | Promotion as one statement | kept; the one-active rule is a deferrable exclusion constraint | correctness rests on constraint semantics the manual specifies, not on the order Postgres runs CTEs |
| — | The rating mark | `status = 'rated'` with `rated_at` and `rated_seq`; a trial is `rated` with no `rating_change` | one status walk, one mark |
| — | The reap | its own statement before the claim | a CTE's writes are invisible to the claim in one snapshot |
| — | `models.adapter` | **the release asset's exact text**, with a check that it hashes to `adapter_hash` | as text it is self-verifying where jsonb would not hash |
| — | The schema is initial | `CREATE TABLE`s, not a migration chain | nothing is released; a migration chain would version a schema nobody runs. **Versioning starts at the first release.** |

### The clocks — [`jodi`](https://github.com/Tiny-Brains/jodi)

| # | Decision | Taken as |
|---|---|---|
| 1 | Matches in flight per version | **a policy by state**, not a fixed cap — baselines high, a placement burst for a new version, a small number in steady state, one for a trial. It is what the demand view counts |
| 7 | Count's schedule and batch; pair's schedule and depth target | 10 s and 50; 15 s and 64 |
| 8 | The settled threshold and the re-pair cap | sigma 3.0; 3 trials |
| 9 | The cross-class fraction | 0.20 |
| 10 | The cold fraction | **dropped**: residency is Kalam's, staleness is `tau`'s |
| 11 | Sigma inflation at seed | **the rule is final** — inherit `mu`, multiply `sigma`, cap at the prior, store both; the number stays 2.0 |
| 12 | Rank ties | **final: equal ranks draw**; numbering style never reaches the update |
| 13 | Count refusing foreign digests | **no** |
| 23 | Season scope | **per game** — everything a season holds is per game, and closing when settled cannot be shared |
| 24 | Retention | **a policy table**: standings forever, match rows indefinitely, replays by a bucket lifecycle rule, traces by Orion's config |
| — | The dynamics factor | **`tau` per update; no clock inflates a sigma** — frozen weights do not drift, and a clock that re-opened sigma would hold a season open forever |
| — | What a season is | **an admin-created window**: opening date, last submission date, closes itself when settled |
| — | A version's season | **one, stamped at submission** — a version never crosses a boundary, so nothing is re-keyed |
| — | Non-overlap | **a partial unique index on the live season**, and the gap checked at create against the previous close |
| — | Who closes a season | **withdraw's second task**, by the settle predicate or an admin's intent — no fifth clock |
| — | Where the engine digest lives | **the deploy declares it on `games`, the season pins a copy** — the two mean different things and a difference is a fact |
| — | Baselines | **carried into each new season by the create**, as new `model_versions` rows against the entries they already have, at the prior |
| **51** | **An entry and a version are two tables** | `models` is the entry — a competitor's named lineage, keyed by the GitHub repository it publishes from — and `model_versions` is one submission of it. Everything a rating, a seat or a match points at is a VERSION; a rename, a retirement and a quota are about the ENTRY. Before the split "the entry" was spelled `(owner_id, game_id)` inside seven statements, which is why a competitor could hold exactly one. Uniqueness is `(owner_id, game_id, lower(repo))` and deliberately NOT global: the cross-competitor half follows from `repo_owned()`, because a repository's first path segment must be the competitor's own GitHub login. A global index would be a permanent claim on a namespace that is not ours — logins are recyclable, repositories transferable — and it is also what lets the three baselines share one repository |
| **52** | **The season's rules are the whole description of a contest** | `seasons.rules`, ten blocks, validated by `season_rules_ok()` against a `season_rule_spec()` VALUES table so the spec IS the documentation. Every rule is read `coalesce(rule, <the [vars] value>)`, so a season that declares nothing behaves exactly as the deploy does. **This closes decision 29**: quotas are season rules and not a global table, because a quota is a property of the contest it belongs to and travels with it. The CHECK it replaces enumerated two block names and looked no further, so `{"participants": {"enabld": true}}` stored cleanly and then admitted the world |
| **53** | **A participant list is matched at submission, not resolved at creation** | A cohort is a list of GitHub logins written before the term starts, and most of its members have never signed in. Resolving once and keeping only the ids would silently refuse exactly those people for the whole season. The handles are stored as given and matched against `users.handle` — which IS the GitHub login, rewritten by the auth upsert on every sign-in — with the ids that do resolve kept beside them as the fast path |
| **54** | **The strike ceiling is pinned on the match row** | `matches.strike_ceiling`, stamped by pair, read by Kalam off the row it claimed and by count off the trial it judges. Kalam's own `[vars] strike_ceiling` is deleted and `configs.sh`'s equality assertion with it: the documented cross-repo footgun disappears because Kalam stops keeping a second copy, not because Jodi stops keeping the first. NOT NULL is the point — with both the season and the deploy silent, pair halts at its insert, where a halt is correct, instead of Kalam comparing a strike count against null (which is TRUE) and forfeiting every seat on turn 0 |
| **56** | **A quantised-only season reads the WEIGHTS' dtypes, not the ports'** | `/inspect` gained `weight_dtypes`: every distinct element type the initializers declare, read off `TensorProto.data_type` rather than inferred from which payload field carried the bytes. The graph's input and output dtypes were already reported and say nothing about this — a network with float32 ports may hold int8 weights, which is what quantisation IS. An unrecognised type number becomes `type-<n>` rather than being dropped, so a future ONNX dtype cannot pass a quantised-only season by being unnameable |
| **55** | **Self-pairing is refused by the INSERT, not only by the plugin** | Two versions of one owner in one match is a free rating transfer between a competitor's own models: the ladder is *wrong*, not merely worse, so it is correctness and belongs in the statement. The plugin declines to propose one; the insert refuses one anyway. `P_TRIALS` was made owner-distinct first, because a trial is plan item 0 and a trial the insert refuses would halt pair every run, for ever |
| — | The season's rules | **a document on the season row**, each rule under its key with an `enabled` flag, checked as predicates in the submission insert |
| — | Verdicts in the same run as the fold | yes: one loop over one document, folds first |
| — | Pair claims no run fence | the roster fence is the guarantee; a retry overfills by at most one run |
| — | The trial insert is SQL, not the plugin | the choice is mechanical and must not depend on the plugin's state |

### Admission — [`jodi`](https://github.com/Tiny-Brains/jodi)

| # | Decision | Taken as |
|---|---|---|
| 20 | The admission timeout | **180 s per attempt, 3 attempts, then `TIMED_OUT`.** It covers verification only; a trial never times out the candidate. The number is set by `zstd -19` over a `Large` model |
| 35 | Does the competitor declare the hashes? | **Yes, both, at submit** — it lets a competitor verify what was admitted, and pins the bytes across a retry. `POST /v1/submissions` refuses `400` when either is missing or malformed |
| 36 | Where admission runs | **A fourth clock inside `jodi`.** Jodi is the version's life cycle, not just the match maker |
| 37 | Does admission need a run fence? | **No.** The per-row claim is the mutual exclusion, and is strictly better here: a dead run releases what it had not reached at once |
| 38 | Where the game's budgets and reference observations live | **`games.manifest` and `games.reference_observations`** — not `[vars]`, so a second cartridge is content |
| 39 | What a dialect change does to admitted versions | **Re-validate as the tail of the admission run**; reject on failure and let withdraw sweep the queue |
| 40 | The stale-admission lockout | **Replaced by the trial wait, made visible.** Nothing sweeps a `verified` version |

### The wave — [`kalam`](https://github.com/Tiny-Brains/kalam)

| # | Decision | Taken as |
|---|---|---|
| 19 | N, the renew interval, and the lease | 30 turns and 300 s |
| 33 | The finish drain | one per sweep from a queue, tail drain after the last match ends, terminal on "nothing live and nothing pending" |
| — | A partial renew halts | all of a wave's rows share one lease, so a shortfall means this replica's grip is not what it believes |
| — | Strikes are counted cumulatively | five missed clocks in a match, not five in a row — the stricter reading |
| — | Per-seat state rides in the ref | the only mechanism a fixed task list has, since element scope does not nest inside root scope |
| — | The refs are flat, matched on `(m, seat)` | a nested array shifts the moment a match ends, silently |
| — | The forfeited seat is not sent to the loader | it plays the no-op by construction; the loader is not asked to run a model whose action is discarded |

### The loader — [`axon`](https://github.com/Tiny-Brains/axon)

| # | Decision | Taken as |
|---|---|---|
| 6 | The op budget number | **1,000,000**, measured rather than argued: a reference six-plane Ants adapter costs 197,272 against a real worst-case observation |
| 34 | The resident call | `GET /resident`, advisory, weights hashes, `loading` excluded |
| — | A tensor is opaque to a program | the encoding question disappears with the encoding |
| — | The operator set is the platform's, and has no arithmetic | marshalling is priced by the op count, knowledge by `S`. The third axis — computation — was the FLOP cap, retired by 46; the no-arithmetic rule survives on the op count's own cost rule, which prices data and not multiplies |
| — | The count is a run-time count | the static bound stays rejected, and the consequence — an adapter can fail at play having passed admission — is accepted and made visible as a strike |
| — | `dialect_version` and `evaluator_digest` are different things | the digest hashes the dialect, not the binary, so the re-validation sweep fires on meaning and not on releases |
| — | `/load` takes hashes; only admission takes URLs | the store key *is* the hash, so resolving it is content addressing, not platform knowledge |
| — | The mirror happens inside admission's `/load` | there is no state where a version is admitted and its bytes are not in the store |
| — | `fault: model \| loader` on every refusal | Kalam branches on a field, not a vocabulary, so a new reason word costs no workflow change |
| — | The graph is timed at the shapes the adapter actually produced | a declared input shape is a claim; what is fed is a fact |
| **46** | **There is no compute cap. `turn_ms` is the fairness control** | measured 10 September 2026 and recorded in axon/docs/design.md §10.2: `2·params·spatial` was shadowed by `S` below and by the deadline above, decided something only for a quantized Nano or Micro entry, and could not catch the few-bytes-much-compute exploit it was introduced for, because that exploit minimises `params`. Prerequisite, landed with it: the loader gives each row its own share of `deadline_ms`, so a slow graph times *itself* out instead of striking the seats behind it. `models.infer_us` replaces `flops_estimate` — reported to the competitor, gating nothing |
| **47** | **The training environment is a CLI verb, and deliberately not a referee** | `tinybrains env` hosts the cartridge as a pool of waves over JSON Lines. It lives in `devops/cli` because that is the only place that already hosts a component, links axon as a library and resolves games from the registry; a second host in a trainer's repository would be a second wave loop, which is what `conform` exists to prevent. It has no deadline, no strike ceiling, no forfeit and no adapter evaluation — which is exactly why its actions can be *positional*, the protocol's own form, correct here only because a training env never forfeits a seat. Needing Kalam's explicit `{m, seat, action}` form is the symptom of a rule it does not have. Measured on an M2 Pro: 4,900 seat-turns/s with real colonies |
| **48** | **A dense per-turn reward needs no cartridge change** | `f_finish` gates only `map` on `done` and answers `scores`, `ranks` and `turns` for a match still running, so an exact per-turn score costs one extra invocation (29% of env throughput, declinable with `--scores end`). The trainer sees it and the policy never does, which is asymmetric actor-critic rather than a hole in the fog: the value head that consumes it is discarded before export |
| **49** | **The baselines are trained artifacts in a repository of their own** | `Tiny-Brains/ants-baselines`, a competitor repository the platform owns, with no special access. One fixed teacher distilled into each weight class (the size/fidelity curve the classes exist to measure) plus a method column at micro (one class, one dataset, several learners). It submits through the ordinary gate, which also means the ordinary gate gets exercised by something other than a fixture |
| **50** | **Above `mini`, the byte cap stops being the binding constraint** | Measured, not predicted. A row owns `turn_ms / rows` of a play call — 31.2 ms at `wave_k` 16 — and a fully convolutional network over the largest board runs out of turn at about 170,000 parameters, which is inside Mini. `small` reaches its share at roughly a quarter of its 4 MiB cap; no dense architecture reaches `large`'s at all. The classes are not wrong, but the top two are byte budgets nobody can currently spend, and closing that means parameters that are *read* rather than multiplied. Tracked in design/tracker.md §10 |
| — | The adapter's raw cap | 4 MiB |

### Deployment — [`devops`](https://github.com/Tiny-Brains/devops)

| # | Decision | Taken as | Why |
|---|---|---|---|
| 5 | K, rows per wave per replica | **a residency budget**: `K × seats × max_class_bytes ≤ the replica's weight memory`. K = 16 is the largest that fits 2 GiB at a 64 MiB class | every measured ceiling was checked and none binds; memory at the largest class does, and it moves K *down* on small replicas |
| 25 | The poll interval at N replicas | **5 s, closed by measurement.** One claim is 0.68 ms against the real table, unchanged by queue depth; 100 replicas at 5 s is 1.4% of the single-client floor | the lower bound was supposed to be claim load, and it is not one at any contemplated fleet size — what bounds the interval is trial latency, which argues for keeping it small |
| 41 | Kalam in cluster mode | **no** — one Orion per replica on local SQLite | a shared `forbid` row would make the wave a fleet-wide singleton: one replica plays, N−1 idle, all healthy |
| 42 | What bounds a draining wave | **`server.shutdown_force_timeout_secs`**, with `cron.shutdown_timeout_secs` as the inner deadline | the folk rule raised the number that costs and left the one that helps |
| 43 | What the autoscaler reads | **demand, never depth** | `pair_depth_target` caps the queue, so depth would cap the fleet and look correct doing it |
| 44 | When the deploy declares the digest | **last**, once the new replicas exist and are loaded | before it they claim nothing; after it the old ones cannot. The column is the cutover switch |
| 45 | Replica pools per weight class | **one pool**, K sized for the largest class the fleet serves | a wave can contain any mix and the claim does not select by class |
| — | Where the package lives on a replica | **loaded into each replica's own state at init**, not baked into the image | the load script is the same one a developer runs |

### The game and the protocol — [`ants`](https://github.com/Tiny-Brains/ants)

| # | Decision | Taken as |
|---|---|---|
| 4 | The adapter instruction budget | **1,000,000** — see decision 6 above; this is the same number reached from the protocol side |
| 14 | Players per match | **the preset decides.** The number of players is a property of the *map*, so a preset names a world and how many play it. A version's rating mixes seat counts, which is fine: map coverage spreads every version across the same preset distribution, so any king-making from a larger map inflates sigma rather than biasing mu |
| 15 | `wave_state` encoding | **an opaque base64 blob over a packed binary encoding** — smaller, and it makes "nothing outside the cartridge parses game state" a property rather than a promise |
| 16 | Forfeit and resignation | **a forfeited seat plays no-ops and is ranked last by Kalam**; no resign value in the action schema yet |
| — | Ordering of `mine` | **deterministic, not stable** — row-major by position, so a determinism audit reproduces without the ordering becoming an identity channel. Going from "meaningless" to "stable" later breaks no adapter; the reverse breaks every one |
| — | What `water` carries | **`water AND seen`**, a per-player seen-mask. The only reading that matches what the field is documented to mean — a model is a pure function of one observation and has no channel to accumulate a map itself. It costs: the masks are 60% of `wave_state`, and the observation grows monotonically over a match |

---

## 4. Still open

| # | Decision | Forced at | Note |
|---|---|---|---|
| 26 | Session mechanism | web | — |
| 27 | The front-page ladder | web | open is fullest and most legible to a newcomer; a weight class is where the thesis lives |
| 28 | Baselines on the ladder | web | — |
| 30 | λ for the TinyBrain Index | public launch | fit after season one, or publish a provisional value so competitors have something to optimise against from day one. `seasons.lambda` is gone; `standings.lambda` in the rules document is its home |
| 31 | Shared trust root for cartridge and platform plugins | public launch | one key serves both units today; `public_keys` is a per-unit list, which is what keeps this free to go either way |
| 32 | Was dropping `turn` from Ants right | public launch | cheap, and endgame behaviour might turn on it; a model can infer lateness from ant counts and map control. Worth an A/B once there is a ladder |
| — | Scheduling a season ahead | owner's call | as built, the next season is created only after the previous closes, so nobody can announce "season 4 opens on the first" while season 3 settles |
| — | The king match | pairing | one match of a placement burst against the current leader of the version's class ladder, as pairing's answer to a stale top |
| — | The orchestrator | deployment | Kubernetes and Cloudflare Containers behind a Worker are both viable; everything in the deployment layer is expressed as *the orchestrator's grace period*, *the scaler's target*, *an init step* and *a secret store* so that it stays that way |

---

## More

- [`architecture.md`](architecture.md) — the system these decisions produced
- [`deployment.md`](deployment.md) — topology, drain, cluster mode, the digest declaration
- [`orion-notes.md`](orion-notes.md) — the Orion facts the build had to discover
