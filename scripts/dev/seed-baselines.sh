#!/usr/bin/env bash
# Give the three seeded baselines real weights and adapters, and put the bytes in the store.
#
#   scripts/dev/seed-baselines.sh
#
# compose/db-init/30-seed.sql creates three baselines naming PLACEHOLDER hashes, and axon refuses a
# hash that is not 64 hex characters -- that refusal is what stops a hash from being a path. So the
# first wave against seeded data fails every row at the residency barrier, correctly and uselessly.
#
# This stands in for admission with the two model-and-adapter pairs axon's own tests use: real ONNX
# graphs and real dialect programs, randomly initialised, so they play badly. A ladder needs an
# opponent before it needs a good one.
#
# Delete this script the day admission can do it.
set -euo pipefail
cd "$(dirname "$0")/../.."

DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"
DB_NAME="${DB_NAME:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_DB)}"
AXON_SRC="${AXON_SRC:-../axon}"

# A signed PUT to the one bucket the admission instance and every replica share. Signed by curl
# rather than by axon: a seeder that depends on the code under test cannot tell you the store is
# wrong.
S3_ENDPOINT="${R2_ENDPOINT:-http://127.0.0.1:9000}"
S3_BUCKET="${AXON_STORE_BUCKET:-tinybrains-models}"
S3_REGION="${R2_REGION:-us-east-1}"
S3_KEY="${R2_ACCESS_KEY:-tinybrains}"
S3_SECRET="${R2_SECRET_KEY:-tinybrains-dev-secret}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> dumping the reference fixtures"
( cd "$AXON_SRC" && cargo run --quiet --release --example dump-fixtures -- "$TMP" ) > "$TMP/out.json"
cat "$TMP/out.json"

echo "==> putting them in $S3_BUCKET at $S3_ENDPOINT"
# dump-fixtures writes the store's own `<kind>/sha256/<hex>` layout, so each path under $TMP IS its
# key. A replica has no upload endpoint on purpose: bytes reach it only by already being in the
# store.
( cd "$TMP" && find . -type f -path './*/sha256/*' | sed 's|^\./||' ) | while read -r k; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --aws-sigv4 "aws:amz:$S3_REGION:s3" \
      --user "$S3_KEY:$S3_SECRET" -X PUT --data-binary "@$TMP/$k" "$S3_ENDPOINT/$S3_BUCKET/$k")
  case "$code" in
    200) echo "    $k" ;;
    *) echo "PUT $k answered HTTP $code -- is the bucket there? \`docker compose run --rm loader setup\`" >&2; exit 1 ;;
  esac
done

RAGGED_W=$(python3 -c "import json;print(json.load(open('$TMP/out.json'))['ragged']['weights'])")
RAGGED_A=$(python3 -c "import json;print(json.load(open('$TMP/out.json'))['ragged']['adapter'])")
DENSE_W=$(python3 -c "import json;print(json.load(open('$TMP/out.json'))['dense']['weights'])")
DENSE_A=$(python3 -c "import json;print(json.load(open('$TMP/out.json'))['dense']['adapter'])")

echo "==> pointing the baselines at them"
# Two distinct pairs across three baselines: a wave whose seats all name ONE model would never
# exercise the claim's affinity fill or the loader holding more than one graph.
docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
  -v rw="$RAGGED_W" -v ra="$RAGGED_A" -v dw="$DENSE_W" -v da="$DENSE_A" <<'SQL'
BEGIN;
UPDATE models m SET weights_hash = :'rw', adapter_hash = :'ra'
  FROM users u WHERE u.id = m.owner_id AND u.role = 'baseline'
   AND u.handle IN ('baseline-random', 'baseline-greedy');
UPDATE models m SET weights_hash = :'dw', adapter_hash = :'da'
  FROM users u WHERE u.id = m.owner_id AND u.role = 'baseline'
   AND u.handle = 'baseline-strong';
-- Any other model still carrying a hash axon cannot key: the hand-made candidates inserted to
-- drive Jodi before anything could play.
UPDATE models SET weights_hash = :'rw', adapter_hash = :'ra'
 WHERE status IN ('testing', 'verified', 'active', 'superseded')
   AND weights_hash !~ '^sha256:[0-9a-f]{64}$';

-- Re-point pending rows only: anything already played keeps what it played, which is the record.
UPDATE match_seats s SET weights_hash = md.weights_hash, adapter_hash = md.adapter_hash
  FROM models md, matches mt
 WHERE s.model_id = md.id AND mt.id = s.match_id AND mt.status = 'pending'
   AND (s.weights_hash IS DISTINCT FROM md.weights_hash
     OR s.adapter_hash IS DISTINCT FROM md.adapter_hash);
COMMIT;
SELECT u.handle, m.weights_hash, m.adapter_hash
  FROM models m JOIN users u ON u.id = m.owner_id
 WHERE u.role = 'baseline' ORDER BY u.handle;
SQL
