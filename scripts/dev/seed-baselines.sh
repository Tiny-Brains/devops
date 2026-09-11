#!/usr/bin/env bash
# Point the seeded baselines at the trained artifacts, and put the bytes in the store.
#
#   scripts/dev/seed-baselines.sh [path-to-ants-baselines]     # default ../ants-baselines
#
# compose/db-init/30-seed.sql creates one baseline per artifact naming PLACEHOLDER hashes, because a
# volume initialises long before any model exists. Axon refuses a hash that is not 64 hex characters
# -- that refusal is what stops a hash from being a path -- so until this runs, every wave seating a
# baseline fails at the residency barrier, correctly and uselessly.
#
# WHAT CHANGED, 10 SEPTEMBER 2026. This used to dump axon's own test fixtures: real ONNX graphs with
# random weights, which hold every ant on every turn, so every trial ended `idle_food` and beating
# one proved that an entry emitted valid actions and nothing else. It now reads TRAINED artifacts
# from ants-baselines, each of which carries the `metrics.json` that admission would otherwise have
# produced -- so a seeded baseline is indistinguishable from an admitted version, which is the point.
#
# Delete this script the day admission can do it: these are ordinary submissions from an ordinary
# repository, and the only reason they are seeded rather than submitted is that a baseline has no
# trial opponent until a baseline exists.
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC="${1:-../ants-baselines}"
[ -d "$SRC/models" ] || {
  echo "no $SRC/models -- clone Tiny-Brains/ants-baselines beside this repository, or pass its path" >&2
  echo "  its README has the two commands that build the artifacts" >&2
  exit 1
}

# The rating prior, read from the template `check/configs.sh` treats as the source of truth rather
# than typed here. Two priors on one ladder is a real failure -- a baseline's first fold reads
# [vars] while its seed row read something else -- and a third copy is a third thing to keep in step.
SOMA_TMPL=compose/orion/soma.toml.tmpl
PRIOR_MU=$(awk -F= '/^prior_mu[[:space:]]*=/{gsub(/ /,"",$2);print $2}' "$SOMA_TMPL")
PRIOR_SIGMA=$(awk -F= '/^prior_sigma[[:space:]]*=/{gsub(/ /,"",$2);print $2}' "$SOMA_TMPL")
[ -n "$PRIOR_MU" ] && [ -n "$PRIOR_SIGMA" ] || { echo "no prior_mu/prior_sigma in $SOMA_TMPL" >&2; exit 1; }

DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"
DB_NAME="${DB_NAME:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_DB)}"

# A signed PUT to the one bucket the admission instance and every replica share. Signed by curl
# rather than by axon: a seeder that depends on the code under test cannot tell you the store is
# wrong.
S3_ENDPOINT="${R2_ENDPOINT:-http://127.0.0.1:9000}"
S3_BUCKET="${AXON_STORE_BUCKET:-tinybrains-models}"
S3_REGION="${R2_REGION:-us-east-1}"
S3_KEY="${R2_ACCESS_KEY:-tinybrains}"
S3_SECRET="${R2_SECRET_KEY:-tinybrains-dev-secret}"

put() {   # put <file> <kind>   -- keyed by the digest metrics.json already recorded
  local file="$1" hash="$2" key
  key="$(printf '%s' "$hash" | sed 's|^sha256:|/sha256/|')"
  key="${3}${key}"
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --aws-sigv4 "aws:amz:$S3_REGION:s3" \
      --user "$S3_KEY:$S3_SECRET" -X PUT --data-binary "@$file" "$S3_ENDPOINT/$S3_BUCKET/$key")
  case "$code" in
    200) echo "    $key" ;;
    *) echo "PUT $key answered HTTP $code -- is the bucket there? \`docker compose run --rm loader setup\`" >&2; exit 1 ;;
  esac
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/rows.json"

echo "==> reading $SRC/models"
found=0
for dir in "$SRC"/models/*/; do
  name=$(basename "$dir")
  [ -f "$dir/metrics.json" ] || { echo "    $name has no metrics.json -- run its export" >&2; continue; }
  for f in model.onnx adapter.json; do
    [ -f "$dir/$f" ] || { echo "    $name has no $f" >&2; exit 1; }
  done

  wh=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['weights_hash'])" "$dir/metrics.json")
  ah=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['adapter_hash'])" "$dir/metrics.json")

  # The hashes in metrics.json came from `tinybrains check`, which hashed these exact files. Verify
  # rather than trust: a stale metrics.json beside a rebuilt model is the one way this goes wrong,
  # and it would seed a row naming bytes the store does not hold.
  for pair in "model.onnx:$wh" "adapter.json:$ah"; do
    f=${pair%%:*}; want=${pair#*:}
    got="sha256:$(shasum -a 256 "$dir/$f" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || {
      echo "    $name/$f hashes to $got but metrics.json says $want -- re-run the export" >&2
      exit 1
    }
  done

  echo "  $name"
  put "$dir/model.onnx"   "$wh" weights
  put "$dir/adapter.json" "$ah" adapters   # plural: axon's Kind::Adapter prefix

  python3 - "$dir" "$name" >> "$TMP/rows.json" <<'PY'
import json, sys, pathlib
d, name = pathlib.Path(sys.argv[1]), sys.argv[2]
m = json.load(open(d / "metrics.json"))
print(json.dumps({
    "handle": f"baseline-{name}",
    "weight_class": m["class"],
    "weights_hash": m["weights_hash"],
    "adapter_hash": m["adapter_hash"],
    "adapter": (d / "adapter.json").read_text(),
    "size_bytes": m["size_metric_bytes"],
    "param_count": m["params"],
    "infer_us": m["infer_us_max"],
    "evaluator_digest": m["evaluator_digest"],
}))
PY
  found=$((found + 1))
done
[ "$found" -gt 0 ] || { echo "no exported models in $SRC/models" >&2; exit 1; }

echo "==> pointing the baselines at them"
# One statement over a jsonb array rather than a loop of UPDATEs: every baseline moves together or
# none does, which matters because pair may be inserting trials against them while this runs.
python3 -c "import json,sys;print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()]))" \
  < "$TMP/rows.json" > "$TMP/rows-array.json"

docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
  -v rows="$(cat "$TMP/rows-array.json")" -v mu="$PRIOR_MU" -v sigma="$PRIOR_SIGMA" <<'SQL'
BEGIN;

CREATE TEMP TABLE seeding ON COMMIT DROP AS
SELECT * FROM jsonb_to_recordset((:'rows')::jsonb)
     AS r (handle text, weight_class text, weights_hash text, adapter_hash text, adapter text,
           size_bytes bigint, param_count bigint, infer_us bigint, evaluator_digest text);

-- A baseline is a competitor: a user, so it can be told apart on a leaderboard that shows an entry
-- as its owner's handle. github_id stays null; they never sign in.
INSERT INTO users (handle, role)
SELECT handle, 'baseline' FROM seeding
ON CONFLICT (handle) DO NOTHING;

-- THE CLASS IS CHECKED, NOT SET. `ratings` and `rating_events` are keyed by ladder, and a ladder
-- IS a weight class, so moving a baseline between classes here would strand every rating row it
-- already has and leave it rated on a ladder it no longer plays. 30-seed.sql fixes the class from
-- the handle; if an artifact has been retrained into a different class it needs a new handle, which
-- is the same rule a competitor lives under.
DO $$
DECLARE bad text;
BEGIN
    SELECT string_agg(format('%s is seeded as %s but its artifact measures %s',
                             s.handle, m.weight_class, s.weight_class), E'\n  ')
      INTO bad
      FROM seeding s
      JOIN users u ON u.handle = s.handle
      JOIN models e ON e.owner_id = u.id
      JOIN model_versions m ON m.model_id = e.id
     WHERE m.weight_class IS DISTINCT FROM s.weight_class::ladder;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION E'a baseline changed weight class:\n  %\n\nRatings are keyed by ladder, so this needs a new handle rather than an update.', bad;
    END IF;
END $$;

-- A baseline this database has never seen: a version, its two ratings and their origin events, in
-- exactly the shape compose/db-init/30-seed.sql writes on a fresh volume. Without this an existing
-- stack could only ever have the baselines its volume was initialised with, and adding one would
-- mean `docker compose down -v` -- which throws away every session and every match played.
WITH missing AS (
    SELECT s.*, u.id AS owner_id, g.id AS game_id, se.id AS season_id
      FROM seeding s
      JOIN users u ON u.handle = s.handle
      CROSS JOIN games g
      JOIN seasons se ON se.game_id = g.id AND se.closed_at IS NULL
     WHERE g.slug = 'ants'
       AND NOT EXISTS (SELECT 1 FROM models e WHERE e.owner_id = u.id AND e.game_id = g.id)
), entry AS (
    -- The ENTRY first: a baseline is a model with a name and a repository, exactly as a
    -- competitor's is. Three of them share one repository, which is legal because an entry is
    -- unique per (owner, repository) rather than globally.
    INSERT INTO models (owner_id, game_id, name, repo)
    SELECT owner_id, game_id, substring(handle from 'baseline-(.*)'),
           'Tiny-Brains/ants-baselines'
      FROM missing
    RETURNING id, owner_id, game_id
), made AS (
    INSERT INTO model_versions (model_id, game_id, season_id, version, release_tag, commit_sha,
                                status, weight_class, size_bytes, param_count, infer_us,
                                weights_hash, adapter_hash, adapter, evaluator_digest)
    SELECT entry.id, entry.game_id, missing.season_id, 1,
           'v0-seeded', NULL,
           'active', missing.weight_class::ladder, missing.size_bytes, missing.param_count,
           missing.infer_us, missing.weights_hash, missing.adapter_hash, missing.adapter,
           missing.evaluator_digest
      FROM entry JOIN missing ON missing.owner_id = entry.owner_id
    RETURNING id, weight_class
), rated AS (
    -- Two ladders each -- the class and open -- at the prior, so a baseline is rated by the matches
    -- other people want rather than being an unrated void the fold silently drops.
    INSERT INTO ratings (version_id, ladder, mu, sigma)
    SELECT made.id, l.ladder, (:'mu')::float8, (:'sigma')::float8
      FROM made CROSS JOIN LATERAL (VALUES (made.weight_class), ('open'::ladder)) AS l (ladder)
    ON CONFLICT (version_id, ladder) DO NOTHING
    RETURNING version_id, ladder, mu, sigma
)
-- seq 0, exactly as promotion writes one: no match and no `before`, as rating_events_seed_shape
-- requires. Without it the first fold starts a chain with no origin.
INSERT INTO rating_events (version_id, ladder, seq, mu_after, sigma_after)
SELECT version_id, ladder, 0, mu, sigma FROM rated
ON CONFLICT (version_id, ladder, seq) DO NOTHING;

-- Scoped through the ENTRY and to the versions of THIS handle's model. Scoped by owner alone --
-- as it was when a competitor could hold only one model -- this would overwrite every version of
-- every model that owner has, which for a baseline is now three rows and not one.
UPDATE model_versions m
   SET weights_hash = s.weights_hash,
       adapter_hash = s.adapter_hash,
       adapter      = s.adapter,
       size_bytes   = s.size_bytes,
       param_count  = s.param_count,
       infer_us     = s.infer_us,
       evaluator_digest = s.evaluator_digest
  FROM seeding s, users u, models e
 WHERE u.handle = s.handle AND e.owner_id = u.id AND m.model_id = e.id;

-- Any other model still carrying a hash axon cannot key: the hand-made candidates inserted to drive
-- Jodi before anything could play. They get the smallest baseline, which is the cheapest to hold.
-- Qualified on both sides: `seeding` has a `weights_hash` too, and an UPDATE ... FROM makes the
-- bare name ambiguous rather than defaulting to the target.
UPDATE model_versions m SET weights_hash = s.weights_hash, adapter_hash = s.adapter_hash,
       adapter = s.adapter
  FROM (SELECT * FROM seeding ORDER BY size_bytes LIMIT 1) s
 WHERE m.status IN ('testing', 'verified', 'active', 'superseded')
   AND m.weights_hash !~ '^sha256:[0-9a-f]{64}$';

-- Re-point pending rows only: anything already played keeps what it played, which is the record.
UPDATE match_seats s SET weights_hash = v.weights_hash, adapter_hash = v.adapter_hash
  FROM model_versions v, matches mt
 WHERE s.version_id = v.id AND mt.id = s.match_id AND mt.status = 'pending'
   AND (s.weights_hash IS DISTINCT FROM v.weights_hash
     OR s.adapter_hash IS DISTINCT FROM v.adapter_hash);

-- Last, and inside the same transaction: the roster the pair clock reads has changed, and it must
-- not see the new epoch before it can see the rows the epoch is about.
UPDATE clocks SET epoch = epoch + 1, updated_at = now() WHERE key = 'roster';

COMMIT;

SELECT u.handle, e.name AS model, v.weight_class, v.size_bytes, v.param_count, v.infer_us,
       left(v.weights_hash, 18) AS weights
  FROM model_versions v JOIN models e ON e.id = v.model_id JOIN users u ON u.id = e.owner_id
 WHERE u.role = 'baseline' ORDER BY v.size_bytes;
SQL
