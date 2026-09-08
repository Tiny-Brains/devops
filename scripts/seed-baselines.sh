#!/usr/bin/env bash
# Give the three seeded baselines real weights and real adapters, and put the bytes in the store.
#
#   devops/scripts/seed-baselines.sh
#
# WHY THIS EXISTS, AND WHAT REPLACES IT. `db-init/30-seed.sql` creates three baseline users with an
# `active` model each, and those models name PLACEHOLDER hashes -- `sha256:placeholder-baseline-greedy`
# and the like. Axon refuses a hash that is not 64 hex characters, by construction, because that
# refusal is what stops a hash from being a path. So the first real wave against seeded data does
# not play: the residency barrier answers a NAMED refusal and every row goes to `failed`, correctly
# and uselessly.
#
# The real answer is P5: a baseline is an ordinary submission, admission fetches it from a release,
# verifies it, and mirrors it to the store by hash. Until admission exists, this does the same job
# by hand with the two model-and-adapter pairs axon's own test suite uses -- which are real ONNX
# graphs and real programs in the layer 04 dialect, not stubs. They are randomly initialised, so
# they play badly; playing WELL is not what a baseline is for at this stage, and a ladder needs an
# opponent before it needs a good one.
#
# Delete this script the day admission can do it.
set -euo pipefail
cd "$(dirname "$0")/.."

AXON_CONTAINER="${AXON_CONTAINER:-tinybrains-axon-1}"
DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"
DB_NAME="${DB_NAME:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_DB)}"
AXON_SRC="${AXON_SRC:-../axon}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> dumping the reference fixtures"
( cd "$AXON_SRC" && cargo run --quiet --release --example dump-fixtures -- "$TMP" ) > "$TMP/out.json"
cat "$TMP/out.json"

echo "==> copying them into $AXON_CONTAINER's store"
# The store is `<kind>/sha256/<hex>` under AXON_STORE_DIR, and dump-fixtures wrote exactly that
# layout, so this is a directory copy rather than an API call. There is no upload endpoint on a
# replica on purpose: a replica fetches by hash and cannot be told where to fetch from.
for d in "$TMP"/*/; do
  [ -d "$d" ] || continue
  docker cp "$d" "$AXON_CONTAINER:/var/lib/axon/" 2>/dev/null || true
done
docker exec "$AXON_CONTAINER" sh -c 'find /var/lib/axon -type f | head -20'

RAGGED_W=$(python3 -c "import json;print(json.load(open('$TMP/out.json'))['ragged']['weights'])")
RAGGED_A=$(python3 -c "import json;print(json.load(open('$TMP/out.json'))['ragged']['adapter'])")
DENSE_W=$(python3 -c "import json;print(json.load(open('$TMP/out.json'))['dense']['weights'])")
DENSE_A=$(python3 -c "import json;print(json.load(open('$TMP/out.json'))['dense']['adapter'])")

echo "==> pointing the baselines at them"
# Two distinct pairs across three baselines, deliberately: a wave whose seats all name ONE model
# would never exercise the claim's affinity fill or the loader holding more than one graph.
docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
  -v rw="$RAGGED_W" -v ra="$RAGGED_A" -v dw="$DENSE_W" -v da="$DENSE_A" <<'SQL'
BEGIN;
UPDATE models m SET weights_hash = :'rw', adapter_hash = :'ra'
  FROM users u WHERE u.id = m.owner_id AND u.role = 'baseline'
   AND u.handle IN ('baseline-random', 'baseline-greedy');
UPDATE models m SET weights_hash = :'dw', adapter_hash = :'da'
  FROM users u WHERE u.id = m.owner_id AND u.role = 'baseline'
   AND u.handle = 'baseline-strong';
-- Any OTHER model still carrying a hash axon cannot key -- the hand-made candidates that were
-- inserted to drive Jodi before anything could play. Same reason, same fix, and the same script
-- deletes itself when admission exists.
UPDATE models SET weights_hash = :'rw', adapter_hash = :'ra'
 WHERE status IN ('testing', 'verified', 'active', 'superseded')
   AND weights_hash !~ '^sha256:[0-9a-f]{64}$';

-- Queued rows carry the seats' hashes as they were when pair inserted them, so a row paired
-- against a placeholder still names one. Re-point the pending ones; anything already played keeps
-- what it played, which is the record.
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
