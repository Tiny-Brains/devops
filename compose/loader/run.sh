#!/usr/bin/env sh
# Set the stack up, then load every package. Idempotent, and run on every `docker compose up`.
#
#   loader            # all: setup, then load
#   loader setup      # the database facts and the buckets only
#   loader load       # the three packages only
#
# SETUP is four statements that are safe to repeat, so there is no order to remember:
#
#   * the kalam and jodi role passwords -- the migration creates both with LOGIN and no password,
#     so the committed schema ships no secret and the credential is ours
#   * the engine digest -- derived from the vendored component, never typed, so it equals the
#     plugin's digest by construction. A mismatch is not an error anywhere: the wave claims nothing,
#     for ever. By default a PATCH, which the live season takes too; ENGINE_RELEASE=1 makes it a
#     RELEASE -- a rules change -- which is refused while a season is live
#   * games.manifest and games.reference_observations -- what admission validates against; without
#     them tb-admit releases every claim MANIFEST_INCOMPLETE
#   * the buckets -- a `finished` row REQUIRES replay_key, so a wave that cannot write a blob
#     cannot finish a match
#
# LOAD installs each package into the server that runs it. Two kinds of target:
#
#   SOMA_ORION_ADMIN     one cluster-mode Orion running soma and jodi. Loading against ANY node
#                        reaches all of them -- an admin mutation advances a shared config epoch.
#   KALAM_ORION_ADMINS   a COMMA-SEPARATED LIST, one per replica, because each replica has its own
#                        state database and there is no epoch bus between them (decision 41).
set -eu

# ORION_ADMIN is the single-server spelling: it sets both targets at once.
SOMA_ADMIN="${SOMA_ORION_ADMIN:-${ORION_ADMIN:-}}"
KALAM_ADMINS="${KALAM_ORION_ADMINS:-${ORION_ADMIN:-}}"
[ -n "$SOMA_ADMIN" ] || { echo "SOMA_ORION_ADMIN (or ORION_ADMIN) is required" >&2; exit 1; }
[ -n "$KALAM_ADMINS" ] || { echo "KALAM_ORION_ADMINS (or ORION_ADMIN) is required" >&2; exit 1; }
PKG="${PKG_ROOT:-/pkg}"
DB="${LOADER_DB_URL:?LOADER_DB_URL is required -- the match database, as its owner}"

# The comma-separated list as words, for `for` loops.
kalam_admins() { echo "$KALAM_ADMINS" | tr ',' ' '; }

psql_db() { psql "$DB" -q -v ON_ERROR_STOP=1 "$@"; }

# Unset is still allowed: a server with admin_auth disabled accepts either, so this stays usable
# against a bare `orion-server`.
ADMIN_AUTH=""
[ -n "${ORION_ADMIN_API_KEY:-}" ] && ADMIN_AUTH="Authorization: Bearer ${ORION_ADMIN_API_KEY}"
acurl() {
  if [ -n "$ADMIN_AUTH" ]; then curl -H "$ADMIN_AUTH" "$@"; else curl "$@"; fi
}

# ---------------------------------------------------------------------------- wait
wait_one() {
  echo "==> waiting for orion at $1"
  i=0
  until curl -fsS "${1%/api/v1/admin}/readyz" > /dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || { echo "orion at $1 did not become ready" >&2; exit 1; }
    sleep 2
  done
}

wait_ready() {
  wait_one "$SOMA_ADMIN"
  for a in $(kalam_admins); do
    [ "$a" = "$SOMA_ADMIN" ] || wait_one "$a"
  done
}

# ---------------------------------------------------------------------------- setup
engine_digest() {
  wasm="${KALAM_ENGINE_WASM:-$PKG/kalam/plugins/tb-ants/tb-ants.wasm}"
  [ -r "$wasm" ] || { echo "engine component not readable at $wasm" >&2; exit 1; }
  d="sha256:$(sha256sum "$wasm" | cut -d' ' -f1)"
  # A pin that disagrees with the file is the silent failure this exists to prevent: the server
  # would advertise one engine and the queue would carry another.
  if [ -n "${KALAM_ENGINE_DIGEST:-}" ] && [ "$KALAM_ENGINE_DIGEST" != "$d" ]; then
    echo "KALAM_ENGINE_DIGEST is $KALAM_ENGINE_DIGEST but $wasm hashes to $d -- unset it, or re-vendor" >&2
    exit 1
  fi
  echo "$d"
}

setup() {
  echo "==> the kalam and jodi roles can log in"
  # Through stdin rather than -c: psql expands :'var' in a script, not in a -c string, and a -c
  # that looks right and is not expanded fails with a syntax error at the colon.
  psql_db -v pw="${KALAM_DB_PASSWORD:?KALAM_DB_PASSWORD is required}" <<'SQL'
ALTER ROLE kalam WITH LOGIN PASSWORD :'pw';
SQL
  psql_db -v pw="${JODI_DB_PASSWORD:?JODI_DB_PASSWORD is required}" <<'SQL'
ALTER ROLE jodi WITH LOGIN PASSWORD :'pw';
SQL

  DIGEST=$(engine_digest)
  if [ "${ENGINE_RELEASE:-0}" = "1" ]; then
    echo "==> releasing the engine $DIGEST (a rules change: only between seasons)"
    # A release may not enter a live season: its rows all name the old digest, so the new replicas
    # would claim nothing and the season would stall in silence. Zero rows means refuse.
    n=$(psql -X "$DB" -At -v d="$DIGEST" <<'SQL'
WITH g AS (
    UPDATE games g SET active_engine_digest = :'d'
     WHERE NOT EXISTS (SELECT 1 FROM seasons s WHERE s.game_id = g.id AND s.closed_at IS NULL)
 RETURNING id)
SELECT count(*) FROM g;
SQL
)
    if [ "${n:-0}" -eq 0 ]; then
      echo "REFUSED: a season is live. Ask the admin to close it (POST /v1/games/{game}/seasons/current/close), or roll the engine back." >&2
      exit 1
    fi
  else
    echo "==> declaring the engine $DIGEST (a patch: the live season takes it too)"
    # A patch is behaviour-preserving, so the live season keeps its ratings and takes the new
    # digest; the roster epoch bumps so a pair run mid-plan halts and re-reads. Only `pending` rows
    # are re-stamped: a claimed, running or finished row records the engine it was ACTUALLY played
    # on, and that record is what makes a skew visible.
    psql_db -v d="$DIGEST" <<'SQL'
UPDATE games SET active_engine_digest = :'d' WHERE active_engine_digest IS DISTINCT FROM :'d';
WITH s AS (
    UPDATE seasons s SET engine_digest = :'d'
     WHERE s.closed_at IS NULL AND s.engine_digest <> :'d'
 RETURNING s.id)
UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now() FROM s WHERE c.key = 'roster';
UPDATE matches m SET engine_digest = :'d'
  FROM seasons s
 WHERE s.id = m.season_id AND s.closed_at IS NULL
   AND m.status = 'pending' AND m.engine_digest IS DISTINCT FROM :'d';
SQL
  fi

  echo "==> registering the cartridge"
  # The manifest is the copy vendored beside the component, so the budget admission judges by is
  # the one the loaded engine was built with. The worst case must be in the reference set or the
  # gate is theatre; until ants publishes one, axon's worst-case fixture stands in.
  manifest="${CARTRIDGE_MANIFEST:-$PKG/kalam/plugins/tb-ants/cartridge.json}"
  [ -r "$manifest" ] || { echo "no cartridge manifest at $manifest -- run kalam/scripts/vendor-engine.sh" >&2; exit 1; }
  # adapter_ops_max only: there is no compute budget since decision 46. A manifest still declaring
  # flop_caps is stale rather than wrong, and is ignored.
  jq -e '.budgets.adapter_ops_max' "$manifest" > /dev/null \
    || { echo "$manifest declares no budgets.adapter_ops_max" >&2; exit 1; }
  if [ -r "$PKG/ants/reference/observations.json" ]; then
    # The file is an OBJECT and the column is an ARRAY, so take the array out rather than storing
    # the envelope.
    obs=$(jq -ce '.observations | select(type == "array")' "$PKG/ants/reference/observations.json") \
      || { echo "$PKG/ants/reference/observations.json has no 'observations' array" >&2; exit 1; }
    echo "    reference set: ants/reference/observations.json"
  else
    obs=$(jq -c '[.]' "${REFERENCE_OBSERVATION:-$PKG/reference/ants-observation.json}")
    echo "    reference set: ONE observation from axon's fixture -- ants/reference/observations.json is owed"
  fi
  # psql -v carries the documents intact and :'m' quotes them.
  psql_db -v m="$(jq -c . "$manifest")" -v o="$obs" -v g="${GAME:-ants}" <<'SQL'
UPDATE games SET manifest = :'m'::jsonb, reference_observations = :'o'::jsonb WHERE slug = :'g';
SQL
  psql -X "$DB" -At -c "SELECT '    ' || slug || ': engine ' || left(active_engine_digest, 19) || '..., adapter_ops_max=' || (manifest -> 'budgets' ->> 'adapter_ops_max') || ', ' || jsonb_array_length(reference_observations) || ' observation(s)' FROM games"
  psql -X "$DB" -At -c "SELECT '    ' || g.slug || ': season ' || s.number || ' ' || CASE WHEN s.closed_at IS NOT NULL THEN 'closed' WHEN now() < s.submissions_open_at THEN 'scheduled' WHEN now() < s.submissions_close_at THEN 'open' ELSE 'settling' END || ', engine ' || left(s.engine_digest, 19) || '..., submissions ' || to_char(s.submissions_open_at, 'YYYY-MM-DD') || ' to ' || to_char(s.submissions_close_at, 'YYYY-MM-DD') FROM seasons s JOIN games g ON g.id = s.game_id ORDER BY (s.closed_at IS NULL) DESC, s.number DESC LIMIT 1"

  echo "==> the buckets"
  # Two buckets, one credential: replays, and the model store that admission writes and every
  # replica reads. They MUST be the same store, or admission succeeds and every match the version
  # is paired for fails at the residency barrier, quietly.
  #
  # S3 PUT Bucket, sigv4-signed by curl. 200 is created, 409 is BucketAlreadyOwnedByYou.
  for b in "${R2_BUCKET:?}" "${AXON_STORE_BUCKET:-tinybrains-models}"; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --aws-sigv4 "aws:amz:${R2_REGION:-us-east-1}:s3" \
        --user "${R2_ACCESS_KEY:?}:${R2_SECRET_KEY:?}" -X PUT "${R2_ENDPOINT:?}/$b")
    case "$code" in
      200|409) echo "    $b at $R2_ENDPOINT" ;;
      *) echo "creating bucket $b at $R2_ENDPOINT answered HTTP $code" >&2; exit 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------- load
# Each load-package.sh sweeps its OWN tag before re-creating it. Nothing sweeps a tag off a server
# that STOPPED running it, and the leftovers are not harmless: a channel that cannot resolve its
# connector is a permanent `degraded` status that hides the next real one. So each target is swept
# of what it must not run, every time -- zero rows on a server that was always right.
sweep_foreign() {   # $1 admin, $2... tags to remove
  admin="$1"; shift
  for tag in "$@"; do
    for kind in channels workflows connectors plugins; do
      case "$kind" in
        channels)   key=channel_id ;;
        workflows)  key=workflow_id ;;
        connectors) key=id ;;
        plugins)    key=plugin_id ;;
      esac
      for id in $(acurl -sS "$admin/$kind?tag=$tag&limit=500" | jq -r ".data[].$key" 2>/dev/null); do
        # A plugin cannot be archived while an active workflow calls it: workflows sweep first.
        [ "$kind" = plugins ] && acurl -sS -X PATCH "$admin/plugins/$id/status" \
            -H 'Content-Type: application/json' -d '{"status":"archived"}' -o /dev/null || true
        acurl -sS -X DELETE "$admin/$kind/$id" -o /dev/null || true
        echo "    swept $tag $kind/$id"
      done
    done
  done
}

load_one() {   # $1 package, $2 admin
  [ -x "$PKG/$1/scripts/load-package.sh" ] || [ -r "$PKG/$1/scripts/load-package.sh" ] \
    || { echo "$PKG/$1/scripts/load-package.sh is missing -- mount ../$1 at $PKG/$1" >&2; exit 1; }
  # Not piped through an indenter: a pipe would hide the exit status from set -e.
  ORION_ADMIN="$2" sh "$PKG/$1/scripts/load-package.sh"
}

# /readyz goes green as soon as the first generation publishes, so a replica whose package load
# failed is READY, has no tb-wave channel, claims nothing, and is INVISIBLE CAPACITY: the autoscaler
# counts it, the ladder does not, and nothing errors. This, not /readyz, is a replica's real gate.
health() {   # $1 admin, $2 what must be there ("" to skip the assertion)
  echo "==> health at $1"
  # AUTHENTICATED, and it has to be: with admin_auth on, an unauthenticated /health answers 200 and
  # OMITS `plugins`, so the assertion below would read "no tb.ants loaded" on a node that has it --
  # the invisible-capacity false positive, produced by the check meant to catch it.
  h=$(acurl -fsS "${1%/api/v1/admin}/health")
  echo "$h" | jq -r '
    "    status: \(.status)",
    "    plugins: \([.plugins.loaded[]? | "\(.plugin)@\(.version)"] | join(", "))",
    (if .components.config_propagation then "    config_propagation: \(.components.config_propagation)" else empty end),
    (if (.plugins.failed_to_load // []) | length > 0 then "    FAILED TO LOAD: \(.plugins.failed_to_load)" else empty end),
    (if (.channels.quarantined // []) | length > 0 then "    QUARANTINED: \(.channels.quarantined)" else empty end)'
  acurl -fsS "$1/channels?limit=500" | jq -r '.data | group_by(.tags[0]) | map("    \(.[0].tags[0]): \(length) channels") | .[]'
  if [ -n "$2" ]; then
    echo "$h" | jq -e --arg p "$2" '[.plugins.loaded[]?.plugin] | index($p)' > /dev/null \
      || { echo "    $2 IS NOT LOADED at $1 -- this node is invisible capacity, not a working replica" >&2; exit 1; }
    echo "$h" | jq -e '(.channels.quarantined // []) | length == 0' > /dev/null \
      || { echo "    a channel is quarantined at $1" >&2; exit 1; }
  fi
}

load() {
  echo "==> sweeping what $SOMA_ADMIN must not run"
  sweep_foreign "$SOMA_ADMIN" pkg:kalam pkg:spike
  for p in soma jodi; do
    echo "==> loading $p into $SOMA_ADMIN"
    load_one "$p" "$SOMA_ADMIN"
  done
  # One call reaches every node of the cluster; only the Kalam replicas need visiting one by one.
  health "$SOMA_ADMIN" "tb.rating"

  for a in $(kalam_admins); do
    if [ "$a" != "$SOMA_ADMIN" ]; then
      echo "==> sweeping what $a must not run"
      sweep_foreign "$a" pkg:soma pkg:jodi pkg:spike
    fi
    echo "==> loading kalam into $a"
    load_one kalam "$a"
    health "$a" "tb.ants"
  done
}

# ---------------------------------------------------------------------------- main
wait_ready
case "${1:-all}" in
  setup) setup ;;
  load)  load ;;
  all)   setup; load ;;
  *) echo "usage: loader [all|setup|load]" >&2; exit 2 ;;
esac
echo "==> done"
