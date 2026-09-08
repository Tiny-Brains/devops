#!/usr/bin/env sh
# Set the stack up, then load every package. Idempotent, and run on every `docker compose up`.
#
#   loader            # all: setup, then load
#   loader setup      # the database facts and the bucket only
#   loader load       # the three packages only
#
# SETUP is what a fresh volume used to need three hand-run scripts for, in the right order, before
# a single match would play. Each step is a statement that is safe to repeat, so they run every
# time and there is no order to remember:
#
#   * the `kalam` role's password    -- the migration creates it with LOGIN and no password, so the
#                                       committed schema ships no secret; the credential is ours
#   * the engine digest              -- games.active_engine_digest is what the deploy declares, and the
#                                       LIVE SEASON pins a copy that pair stamps on every row, the ONLY
#                                       rows the wave claims (layer 06 §4.4). Derived from the vendored
#                                       component, never typed, so it equals the plugin's digest by
#                                       construction. A mismatch is not an error anywhere: the wave
#                                       claims nothing, for ever. By default the write is a PATCH --
#                                       behaviour-preserving, the live season takes it too; with
#                                       ENGINE_RELEASE=1 it is a RELEASE -- a rules change -- which is
#                                       REFUSED while a season is live and fails this script loudly
#   * games.manifest and
#     games.reference_observations   -- what admission validates a submission against; without them
#                                       tb-admit releases every claim MANIFEST_INCOMPLETE
#   * the replay bucket              -- a `finished` row REQUIRES replay_key, so a wave that cannot
#                                       write a blob cannot finish a match
#
# LOAD runs soma, jodi and kalam's own load-package.sh, in that order, against ORION_ADMIN. Each
# one sweeps its own tag (pkg:soma, pkg:jodi, pkg:kalam) and re-creates only its own objects, which
# is what lets three packages share one server without disturbing each other. What each script
# needs from the environment is documented at the top of that script; the compose file sets it.
set -eu

ADMIN="${ORION_ADMIN:?ORION_ADMIN is required -- the admin API of the orion service}"
PKG="${PKG_ROOT:-/pkg}"
DB="${LOADER_DB_URL:?LOADER_DB_URL is required -- the match database, as its owner}"

psql_db() { psql "$DB" -q -v ON_ERROR_STOP=1 "$@"; }

# ---------------------------------------------------------------------------- wait
wait_ready() {
  echo "==> waiting for orion at $ADMIN"
  i=0
  until curl -fsS "${ADMIN%/api/v1/admin}/readyz" > /dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || { echo "orion did not become ready" >&2; exit 1; }
    sleep 2
  done
}

# ---------------------------------------------------------------------------- setup
engine_digest() {
  wasm="${KALAM_ENGINE_WASM:-$PKG/kalam/plugins/tb-ants/tb-ants.wasm}"
  [ -r "$wasm" ] || { echo "engine component not readable at $wasm" >&2; exit 1; }
  d="sha256:$(sha256sum "$wasm" | cut -d' ' -f1)"
  # A pinned value that disagrees with the file is the exact silent failure this exists to prevent
  # -- the server would advertise one engine and the queue would carry another.
  if [ -n "${KALAM_ENGINE_DIGEST:-}" ] && [ "$KALAM_ENGINE_DIGEST" != "$d" ]; then
    echo "KALAM_ENGINE_DIGEST is $KALAM_ENGINE_DIGEST but $wasm hashes to $d -- unset it, or re-vendor" >&2
    exit 1
  fi
  echo "$d"
}

setup() {
  echo "==> the kalam role can log in"
  # Through stdin rather than -c: psql expands :'var' in a script, not in a -c string, and a -c
  # that looks right and is not expanded fails with a syntax error at the colon.
  psql_db -v pw="${KALAM_DB_PASSWORD:?KALAM_DB_PASSWORD is required}" <<'SQL'
ALTER ROLE kalam WITH LOGIN PASSWORD :'pw';
SQL

  DIGEST=$(engine_digest)
  if [ "${ENGINE_RELEASE:-0}" = "1" ]; then
    echo "==> releasing the engine $DIGEST (a rules change: only between seasons)"
    # 06 §5.3: a release may not enter a live season -- its rows all name the old digest, so the new
    # replicas would claim nothing and the season would stall in silence. Zero rows means refuse.
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
    # A patch is behaviour-preserving, so the live season keeps its ratings and takes the new digest
    # (06 §5.3); the roster epoch bumps so a pair run mid-plan halts and re-reads. Only `pending`
    # rows of the live season are re-stamped -- kinder to a dev stack than letting withdraw retire
    # them and pair re-insert, and the same result. A claimed, running or finished row records the
    # engine it was actually played on and must never be rewritten -- that record is what makes a
    # skew visible.
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
  # The manifest is the copy vendored beside the component, so the budgets admission judges by are
  # the ones the loaded engine was built with. The reference set is what an adapter is validated
  # AGAINST, and the worst case must be in it or the gate is theatre (layer 04 §3.6): until ants/
  # publishes reference/observations.json, the one worst-case fixture axon's tests use stands in.
  manifest="${CARTRIDGE_MANIFEST:-$PKG/kalam/plugins/tb-ants/cartridge.json}"
  [ -r "$manifest" ] || { echo "no cartridge manifest at $manifest -- run kalam/scripts/vendor-engine.sh" >&2; exit 1; }
  jq -e '.budgets.adapter_ops_max and (.budgets.flop_caps | length > 0)' "$manifest" > /dev/null \
    || { echo "$manifest declares no budgets.adapter_ops_max / budgets.flop_caps" >&2; exit 1; }
  if [ -r "$PKG/ants/reference/observations.json" ]; then
    obs=$(jq -c . "$PKG/ants/reference/observations.json")
    echo "    reference set: ants/reference/observations.json"
  else
    obs=$(jq -c '[.]' "${REFERENCE_OBSERVATION:-$PKG/reference/ants-observation.json}")
    echo "    reference set: ONE observation from axon's fixture -- ants/reference/observations.json is owed"
  fi
  # psql -v carries the documents intact and :'m' quotes them; no dollar-quoting to keep unbroken.
  psql_db -v m="$(jq -c . "$manifest")" -v o="$obs" -v g="${GAME:-ants}" <<'SQL'
UPDATE games SET manifest = :'m'::jsonb, reference_observations = :'o'::jsonb WHERE slug = :'g';
SQL
  psql -X "$DB" -At -c "SELECT '    ' || slug || ': engine ' || left(active_engine_digest, 19) || '..., adapter_ops_max=' || (manifest -> 'budgets' ->> 'adapter_ops_max') || ', ' || jsonb_array_length(reference_observations) || ' observation(s)' FROM games"
  psql -X "$DB" -At -c "SELECT '    ' || g.slug || ': season ' || s.number || ' ' || CASE WHEN s.closed_at IS NOT NULL THEN 'closed' WHEN now() < s.submissions_open_at THEN 'scheduled' WHEN now() < s.submissions_close_at THEN 'open' ELSE 'settling' END || ', engine ' || left(s.engine_digest, 19) || '..., submissions ' || to_char(s.submissions_open_at, 'YYYY-MM-DD') || ' to ' || to_char(s.submissions_close_at, 'YYYY-MM-DD') FROM seasons s JOIN games g ON g.id = s.game_id ORDER BY (s.closed_at IS NULL) DESC, s.number DESC LIMIT 1"

  echo "==> the replay bucket"
  # S3 PUT Bucket, signed with sigv4 by curl itself. 200 is created, 409 is BucketAlreadyOwnedByYou.
  code=$(curl -sS -o /dev/null -w '%{http_code}' --aws-sigv4 "aws:amz:us-east-1:s3" \
      --user "${R2_ACCESS_KEY:?}:${R2_SECRET_KEY:?}" -X PUT "${R2_ENDPOINT:?}/${R2_BUCKET:?}")
  case "$code" in
    200|409) echo "    $R2_BUCKET at $R2_ENDPOINT" ;;
    *) echo "creating bucket $R2_BUCKET at $R2_ENDPOINT answered HTTP $code" >&2; exit 1 ;;
  esac
}

# ---------------------------------------------------------------------------- load
load() {
  for p in soma jodi kalam; do
    echo "==> loading $p"
    [ -x "$PKG/$p/scripts/load-package.sh" ] || [ -r "$PKG/$p/scripts/load-package.sh" ] \
      || { echo "$PKG/$p/scripts/load-package.sh is missing -- mount ../$p at $PKG/$p" >&2; exit 1; }
    # Not piped through an indenter: a pipe would hide the script's exit status from set -e.
    sh "$PKG/$p/scripts/load-package.sh"
  done

  echo "==> health"
  curl -fsS "${ADMIN%/api/v1/admin}/health" | jq -r '
    "    status: \(.status)",
    "    plugins: \([.plugins.loaded[]? | "\(.plugin)@\(.version)"] | join(", "))",
    (if (.plugins.failed_to_load // []) | length > 0 then "    FAILED TO LOAD: \(.plugins.failed_to_load)" else empty end),
    (if (.channels.quarantined // []) | length > 0 then "    QUARANTINED: \(.channels.quarantined)" else empty end)'
  curl -fsS "$ADMIN/channels?limit=500" | jq -r '.data | group_by(.tags[0]) | map("    \(.[0].tags[0]): \(length) channels") | .[]'
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
