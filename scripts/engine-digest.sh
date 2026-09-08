#!/usr/bin/env bash
# Declare the current engine: write games.active_engine_digest, and re-stamp the queue.
#
#   devops/scripts/engine-digest.sh                     # from KALAM_ENGINE_DIGEST in .env
#   devops/scripts/engine-digest.sh sha256:abc...       # explicit
#
# THIS IS THE DEPLOY STEP, in the shape layer 07 will formalise (tracker §9.2). Pair stamps
# `games.active_engine_digest` onto every row it inserts, and a Kalam replica claims only rows
# naming the digest of the engine it actually has. So until this runs, the two never meet: the
# replica claims nothing, the queue grows, and nothing anywhere reports an error. That silence is
# by design -- it is what lets old replicas drain their own rows across a rolling deploy (finding
# 5 option A) -- and it is exactly why declaring the digest has to be a deliberate act.
#
# The order matters in a real deployment: the new replicas must EXIST before this runs, or pair
# stamps rows nothing can play. Locally there is one replica and it is already up.
#
# Re-stamping the queue is the local-development half. `pending` rows carrying a superseded digest
# would sit unclaimable for ever; in production withdraw and the drain deal with them, and here we
# simply move them onto the engine that exists.
set -euo pipefail
cd "$(dirname "$0")/.."

DIGEST="${1:-${KALAM_ENGINE_DIGEST:-}}"
if [ -z "$DIGEST" ] && [ -r .env ]; then
  DIGEST=$(grep -E '^KALAM_ENGINE_DIGEST=' .env | tail -1 | cut -d= -f2-)
fi
[ -n "$DIGEST" ] || { echo "no digest: pass one, or set KALAM_ENGINE_DIGEST in devops/.env" >&2; exit 1; }
case "$DIGEST" in
  sha256:[0-9a-f]*) ;;
  *) echo "digest must look like sha256:<hex>, got '$DIGEST'" >&2; exit 1 ;;
esac

DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"
DB_NAME="${DB_NAME:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_DB)}"

docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -v d="$DIGEST" <<'SQL'
\set QUIET on
BEGIN;

UPDATE games SET active_engine_digest = :'d' WHERE active_engine_digest IS DISTINCT FROM :'d';
\echo '  games.active_engine_digest set'

-- Only `pending` rows. A claimed, running or finished row records the engine it was actually
-- played on and must never be rewritten -- that record is what makes an engine skew visible.
UPDATE matches SET engine_digest = :'d'
 WHERE status = 'pending' AND engine_digest IS DISTINCT FROM :'d';
\echo '  pending rows re-stamped'

COMMIT;
\set QUIET off
SELECT g.slug, g.active_engine_digest,
       (SELECT count(*) FROM matches m WHERE m.status = 'pending'
          AND m.engine_digest = g.active_engine_digest) AS claimable_now
  FROM games g;
SQL
