#!/usr/bin/env sh
# STEP 6 OF THE DEPLOY -- the engine cutover. docs/deployment.md §9, decision 44.
#
#   devops/scripts/declare-engine.sh [--release] [sha256:DIGEST]
#
# Runs in the loader image, which is where the deploy's other database steps run:
#
#   docker compose run --rm --no-deps --entrypoint /pkg/devops/scripts/declare-engine.sh loader
#
# The deploy's other six steps are safe against the fleet as it stands when they run. This one is
# THE SWITCH: before it the new replicas are idle and the old fleet is playing; after it pair
# stamps the new digest, the new replicas claim, and the old ones can claim nothing and drain what
# they hold. It is one statement, and it runs LAST -- once the new replicas exist and are loaded.
#
# WHY THIS IS NOT `loader setup`. The local loader declares the engine on every `docker compose up`
# and derives it from the vendored component, which is right for one server and wrong for a rolling
# deploy in two ways:
#
#   * it re-stamps the live season's `pending` rows onto the new digest. That is a kindness to a
#     dev stack and WRONG in a deployment: the pairing was chosen for the old engine and the
#     ratings have moved since. Let withdraw cancel those rows as ENGINE_RETIRED and pair re-insert
#     on the new digest -- a fresh insert is a fresh pairing, and it costs one withdraw period.
#   * it asserts nothing about the fleet. Declaring a digest no replica carries gives the ladder a
#     queue nobody can claim, and NOTHING ERRORS: pair keeps inserting, the rows sit `pending`, and
#     every replica stays healthy and idle. That is the failure this script's preflight exists to
#     prevent, and it is the same shape as docs/deployment.md §8.2's invisible capacity.
#
# THE PREFLIGHT. Orion 1.7.0's /health reports each loaded plugin's DIGEST, not merely its name:
#
#   .plugins.loaded[] | {plugin, version, digest}
#
# so "the new replicas exist and are loaded" is checkable rather than assumed. At least one replica
# must carry the digest being declared -- otherwise the declaration is the silent stall above. The
# others may carry the old one; that is what a roll looks like mid-flight, and this script names
# them as the fleet that will drain.
#
# WHAT IT NEEDS
#   LOADER_DB_URL        the match database, as its owner
#   KALAM_ORION_ADMINS   comma-separated, one admin URL per replica -- each has its own state
#                        database and there is no epoch bus between them (decision 41)
#   GAME                 defaults to ants
#
# DIGEST defaults to the hash of the vendored component, derived and never typed, for the same
# reason the loader derives it: a literal that disagrees with the file is the one failure that is
# silent everywhere.
#
# --release marks a RULES CHANGE rather than a patch. 06 §5.3 refuses one while a season is live --
# its rows all name the old digest and the season would stall in silence -- so this exits non-zero
# and tells the operator to close the season or roll back.
#
# Exit 0 means the column, the live season and the roster epoch agree with the digest, and at least
# one replica can claim what pair stamps next.
set -eu

RELEASE=0
DIGEST=""
for a in "$@"; do
  case "$a" in
    --release) RELEASE=1 ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    sha256:*)  DIGEST="$a" ;;
    *) echo "unknown argument: $a (want --release, or a sha256:... digest)" >&2; exit 2 ;;
  esac
done

DB="${LOADER_DB_URL:?LOADER_DB_URL is required -- the match database, as its owner}"
# The preflight reads /health's plugin digests, and that detail is admin-only when admin_auth is
# enabled: `show_detail = !admin_auth.enabled || a valid key`. Without the credential /health still
# answers 200, omits `plugins`, and the preflight below concludes the fleet carries no engine --
# refusing a cutover that was fine. Unset is still allowed, for a server with admin_auth off.
ADMIN_AUTH=""
[ -n "${ORION_ADMIN_API_KEY:-}" ] && ADMIN_AUTH="Authorization: Bearer ${ORION_ADMIN_API_KEY}"
hcurl() { if [ -n "$ADMIN_AUTH" ]; then curl -H "$ADMIN_AUTH" "$@"; else curl "$@"; fi; }
ADMINS="${KALAM_ORION_ADMINS:-${ORION_ADMIN:-}}"
if [ -z "$ADMINS" ]; then
  echo "KALAM_ORION_ADMINS (or ORION_ADMIN) is required" >&2; exit 1
fi
GAME="${GAME:-ants}"

psql_db() { psql "$DB" -q -v ON_ERROR_STOP=1 "$@"; }
val()     { psql -X "$DB" -At -c "$1"; }
short()   { printf '%.19s...' "$1"; }

# ---------------------------------------------------------------- the digest, derived not typed
if [ -z "$DIGEST" ]; then
  WASM="${KALAM_ENGINE_WASM:-/pkg/kalam/plugins/tb-ants/tb-ants.wasm}"
  if [ ! -r "$WASM" ]; then
    echo "no component at $WASM -- pass a sha256:... digest, or set KALAM_ENGINE_WASM" >&2; exit 1
  fi
  DIGEST="sha256:$(sha256sum "$WASM" | cut -d' ' -f1)"
  echo "==> digest derived from $WASM"
fi
echo "    declaring $DIGEST"

CURRENT=$(val "SELECT active_engine_digest FROM games WHERE slug = '$GAME'")
if [ -z "$CURRENT" ]; then echo "no game '$GAME'" >&2; exit 1; fi
echo "    replacing $CURRENT"
if [ "$CURRENT" = "$DIGEST" ]; then
  echo "    (already declared -- this run repairs the season and the epoch if they lag, nothing else)"
fi

# ---------------------------------------------------------------- preflight: can anyone claim it?
echo "==> the fleet"
carriers=0
drainers=0
for admin in $(echo "$ADMINS" | tr ',' ' '); do
  base=$(echo "$admin" | sed 's|/api/v1/admin$||')
  if ! h=$(hcurl -fsS "$base/health" 2>/dev/null); then
    echo "  FAIL  $base is not answering /health" >&2; exit 1
  fi
  d=$(echo "$h" | jq -r '[.plugins.loaded[]? | select(.plugin == "tb.ants") | .digest] | first // ""')
  q=$(echo "$h" | jq -r '(.channels.quarantined // []) | length')
  if [ "$(echo "$h" | jq -r 'has("plugins")')" != "true" ]; then
    echo "  FAIL  $base answered /health without its plugin detail." >&2
    echo "        That is admin_auth hiding it, not a node with no plugins: set" >&2
    echo "        ORION_ADMIN_API_KEY so this can read what it is asserting on." >&2
    exit 1
  elif [ -z "$d" ]; then
    echo "  FAIL  $base has no tb.ants loaded -- invisible capacity, not a replica" >&2
    exit 1
  elif [ "$q" != "0" ]; then
    echo "  FAIL  $base has a quarantined channel" >&2
    exit 1
  elif [ "$d" = "$DIGEST" ]; then
    echo "  ok    $base carries the new engine -- it will claim"
    carriers=$((carriers + 1))
  else
    echo "  note  $base carries $(short "$d") -- it will drain its own rows and claim none of the new"
    drainers=$((drainers + 1))
  fi
done

if [ "$carriers" -eq 0 ]; then
  echo >&2
  echo "REFUSED: no replica carries $DIGEST." >&2
  echo "Declaring it now would stamp every new row with an engine nobody can claim: pair keeps" >&2
  echo "inserting, the queue grows, every replica stays healthy and idle, and nothing errors." >&2
  echo "Load the new package into at least one replica first -- that is step 5, and it comes" >&2
  echo "before this one for exactly this reason (docs/deployment.md §9, decision 44)." >&2
  exit 1
fi
echo "    $carriers replica(s) will claim, $drainers will drain"

# ---------------------------------------------------------------- a release is not a patch
if [ "$RELEASE" = 1 ]; then
  live=$(val "SELECT count(*) FROM seasons s JOIN games g ON g.id = s.game_id AND g.slug = '$GAME' WHERE s.closed_at IS NULL")
  if [ "${live:-0}" -ne 0 ]; then
    echo >&2
    echo "REFUSED: --release is a rules change and a season is live (06 §5.3)." >&2
    echo "Its rows all name the old digest, so the new replicas would claim nothing and the season" >&2
    echo "would stall in silence. Close the season first --" >&2
    echo "POST /v1/games/$GAME/seasons/current/close -- or roll the engine back." >&2
    exit 1
  fi
  echo "==> no live season: the release may land"
fi

# ---------------------------------------------------------------- what the switch will cost
echo "==> the queue, before"
psql -X "$DB" -At -c "
SELECT '    ' || count(*) || ' pending on ' || left(engine_digest, 19) || '...'
  FROM matches WHERE status = 'pending' GROUP BY engine_digest"
psql -X "$DB" -At -c "
SELECT '    ' || count(*) || ' in flight on ' || left(engine_digest, 19) || '...'
  FROM matches WHERE status IN ('claimed', 'running') GROUP BY engine_digest"

# ---------------------------------------------------------------- THE SWITCH -- docs/deployment.md §9
#
# Three writes, one transaction, and deliberately NOT chained through one another so a re-run
# repairs whichever half lagged:
#
#   games.active_engine_digest   what the deploy declares; pair reads it to stamp new rows
#   seasons.engine_digest        the live season's pinned copy, which is what a row actually
#                                carries (06 §4.4). A PATCH is behaviour-preserving, so the live
#                                season takes it and keeps its ratings
#   clocks.roster                bumped, so a pair run already mid-plan halts at its fence and
#                                re-reads rather than inserting against the engine it started under
#
# `pending` rows are NOT re-stamped. That is the one thing this does differently from the local
# loader, and it is the whole difference between a dev convenience and a deploy.
echo "==> declaring"
psql_db -v d="$DIGEST" -v g="$GAME" <<'SQL'
BEGIN;

UPDATE games SET active_engine_digest = :'d'
 WHERE slug = :'g' AND active_engine_digest IS DISTINCT FROM :'d';

WITH s AS (
  UPDATE seasons s SET engine_digest = :'d'
    FROM games g
   WHERE g.slug = :'g' AND s.game_id = g.id AND s.closed_at IS NULL AND s.engine_digest <> :'d'
  RETURNING s.id)
UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now()
  FROM s WHERE c.key = 'roster';

COMMIT;
SQL

# ---------------------------------------------------------------- what happens next, said plainly
echo "==> declared"
psql -X "$DB" -At -c "
SELECT '    game:   ' || left(active_engine_digest, 19) || '...' FROM games WHERE slug = '$GAME'"
psql -X "$DB" -At -c "
SELECT '    season ' || s.number || ': ' || left(s.engine_digest, 19) || '...'
  FROM seasons s JOIN games g ON g.id = s.game_id AND g.slug = '$GAME'
 WHERE s.closed_at IS NULL"
psql -X "$DB" -At -c "SELECT '    roster epoch: ' || epoch FROM clocks WHERE key = 'roster'"

stale=$(val "SELECT count(*) FROM matches WHERE status = 'pending' AND engine_digest <> '$DIGEST'")
inflight=$(val "SELECT count(*) FROM matches WHERE status IN ('claimed','running') AND engine_digest <> '$DIGEST'")
echo
echo "    $stale pending row(s) still name the old engine. They are NOT re-stamped: withdraw"
echo "    cancels them as ENGINE_RETIRED within its period, and pair re-inserts on the new digest."
echo "    $inflight row(s) are in flight on the old engine. They finish where they are -- a claimed,"
echo "    running or finished row records the engine it was ACTUALLY played on, and that record is"
echo "    what makes a skew visible."
