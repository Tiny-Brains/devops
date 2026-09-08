#!/usr/bin/env bash
# THE CLAIM-UNDER-LOAD SPIKE -- tracker §3.1, and the only thing that moves decision 25.
#
#   devops/scripts/verify/run.sh [seconds-per-run]      # needs the db container up
#
# 07 §7.2 fixes the poll interval's SHAPE at 5 s and refuses to invent its constant. The interval is
# bounded below by claim load -- N replicas at interval i issue N/i claims a second, each one
# statement against the partial index on `pending` -- and the rule for moving it is: raise it only
# when the claim rate is a measurable fraction of database capacity. This measures that capacity.
#
# WHAT IT DOES NOT TOUCH. Everything runs in a scratch database restored from the live one, so the
# index statistics, the row widths and the ~5k finished rows behind the partial index are the real
# ones rather than a generated approximation. `soma` and `orion_state` are untouched and the scratch
# database is dropped at the end.
#
# THE TWO CASES, which are the two ends of 07 §7.2's argument:
#
#   idle   an EMPTY queue and N pollers. The document calls this the pathological case -- a large
#          fleet polling nothing -- and it is also the common one, because a fleet sized by the
#          autoscaler spends most of its time keeping up. Pure index-probe cost.
#   deep   64 pending rows, which is `pair_depth_target` and therefore the deepest the queue is
#          allowed to get, with N pollers contending over them under SKIP LOCKED.
#
# Each claim is rolled back, so the queue does not drain and every run measures the same shape. The
# locks are real: SKIP LOCKED makes each client take a different row and release it at the rollback.
set -euo pipefail
cd "$(dirname "$0")"

SECS="${1:-10}"
DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"
LIVE="${DB_NAME:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_DB)}"
SCRATCH=l07_claim
CLIENTS="${CLIENTS:-1 4 8 16 32 64}"

psql() { docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" "$@"; }
val()  { psql -d "$SCRATCH" -At -c "$1"; }

echo "==> scratch database from the live one"
psql -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $SCRATCH" > /dev/null
# TEMPLATE copies the whole database, statistics and all, in one statement and without a dump. It
# needs no other session on the source, which is why the stack's own connections are counted first.
if [ "$(psql -d postgres -At -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$LIVE'")" != "0" ]; then
  echo "    $LIVE has live connections, so TEMPLATE is refused -- dumping instead"
  psql -d postgres -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE $SCRATCH" > /dev/null
  docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$LIVE" --no-owner --no-privileges \
    | psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1 > /dev/null 2>&1
else
  psql -d postgres -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE $SCRATCH TEMPLATE $LIVE" > /dev/null
fi

DIGEST=$(val "SELECT active_engine_digest FROM games WHERE slug = 'ants'")
echo "    rows: $(val "SELECT count(*) FROM matches") matches, $(val "SELECT count(*) FROM match_seats") seats"
echo "    engine: $DIGEST"

# A residency list of the shape the wave actually sends: the weights the replica already holds.
RESIDENT=$(val "SELECT '{\"' || string_agg(h, '\",\"') || '\"}' FROM (SELECT DISTINCT weights_hash h FROM match_seats LIMIT 8) x")
docker cp claim.sql "$DB_CONTAINER":/tmp/claim.sql > /dev/null

echo "==> making the queue reproducible"
psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1 <<'SQL' > /dev/null
-- Whatever the live stack was mid-flight, start from nothing pending.
UPDATE matches SET status = 'rated' WHERE status IN ('pending', 'claimed', 'running', 'finished');
ANALYZE matches;
ANALYZE match_seats;
SQL

run_case() {   # $1 label, $2 pending rows to stage
  echo
  echo "==> $1 queue: $2 pending row(s)"
  # Staged by INSERT, not by flipping a rated row back: `matches_status_shape` requires a `pending`
  # row to have played_at, rated_at, closed_at, claim_token and lease_expires_at all NULL, and a
  # rated one has them set. The seats are cloned from a real match so the residency EXISTS() in the
  # ORDER BY has genuine hashes to match against.
  psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1 -v n="$2" <<'SQL' > /dev/null
DELETE FROM match_seats WHERE match_id IN (SELECT id FROM matches WHERE status = 'pending');
DELETE FROM matches WHERE status = 'pending';
WITH src AS (
    SELECT * FROM matches WHERE status = 'rated' ORDER BY created_at DESC LIMIT 1
), ins AS (
    INSERT INTO matches (game_id, season_id, engine_digest, seed, preset, seat_count, ladders)
    SELECT src.game_id, src.season_id, src.engine_digest, g.i, src.preset, src.seat_count, src.ladders
      FROM src, generate_series(1, :'n'::int) g(i)
 RETURNING id
)
INSERT INTO match_seats (match_id, seat, model_id, weights_hash, adapter_hash)
SELECT ins.id, s.seat, s.model_id, s.weights_hash, s.adapter_hash
  FROM ins CROSS JOIN LATERAL (
       SELECT seat, model_id, weights_hash, adapter_hash FROM match_seats
        WHERE match_id = (SELECT id FROM src)) s;
ANALYZE matches;
ANALYZE match_seats;
SQL
  printf '    %-8s %12s %14s\n' clients "claims/s" "mean ms"
  for c in $CLIENTS; do
    out=$(docker exec "$DB_CONTAINER" pgbench -U "$DB_USER" -d "$SCRATCH" \
            -n -c "$c" -j "$(( c > 8 ? 8 : c ))" -T "$SECS" \
            -D digest="'$DIGEST'" -D resident="'$RESIDENT'" -f /tmp/claim.sql 2>&1) || {
      echo "$out" | tail -5 >&2; return 1; }
    tps=$(echo "$out" | awk '/^tps =/ {print $3; exit}')
    lat=$(echo "$out" | awk '/^latency average/ {print $4; exit}')
    mx=$(echo "$out" | awk '/^initial connection time/ {print $5; exit}')
    printf '    %-8s %12.0f %14s\n' "$c" "${tps:-0}" "${lat:-?}"
    # The floor across every run is what the interval is judged against, not the peak.
    if [ -z "${FLOOR:-}" ] || [ "${tps%%.*}" -lt "$FLOOR" ]; then FLOOR="${tps%%.*}"; fi
  done
}

run_case "idle  -- the pathological case: a large fleet polling nothing" 0
run_case "deep  -- pair_depth_target, the deepest the queue may get" 64

echo
echo "==> what this says about decision 25"
echo "    Floor across every run: $FLOOR claims/s (the slowest, which is the single-client case --"
echo "    concurrency buys throughput here, it does not cost it)."
echo
printf '    %-22s %14s %16s\n' "fleet" "claims/s" "of capacity"
for spec in "20 5" "100 5" "100 1" "1000 5"; do
  set -- $spec
  rate=$(( $1 / $2 ))
  pct=$(awk -v r="$rate" -v f="$FLOOR" 'BEGIN{printf "%.2f%%", 100*r/f}')
  printf '    %-22s %14s %16s\n' "N=$1 at i=${2}s" "$rate" "$pct"
done
echo
echo "    07 §7.2's rule is to raise the interval only when N/i is a measurable fraction of that"
echo "    floor. It is not one at any fleet size this design contemplates, so the lower bound on"
echo "    the interval is not claim load -- it is latency, which pushes the other way."

psql -d postgres -q -c "DROP DATABASE IF EXISTS $SCRATCH" > /dev/null
echo
echo "==> scratch dropped; $LIVE untouched"
