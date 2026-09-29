#!/usr/bin/env bash
# QA, REBUILT FROM THE LIVE LADDER. The QA stack's data is thrown away, production's is copied in as
# it stands, the candidate's migrations are run over that copy, and the stack comes up on it.
#
#   scripts/setup/qa-refresh.sh              # what it would do, and every refusal, without acting
#   scripts/setup/qa-refresh.sh --yes        # do it, leaving the stack down
#   scripts/setup/qa-refresh.sh --yes --up   # ...and bring QA up on the result
#
# THE POINT. A QA stack on an empty database tests the code and none of the data: the rows that
# break a release are the ones a season has already accumulated -- a settled version, a match half
# claimed, a competitor whose manifest predates a rule. So QA starts from production's rows every
# time, and the release's own migrations are what turns them into the candidate's schema. That
# migration running here, against real data, is the rehearsal for running it on production.
#
# THE ORDER, AND WHY IT IS THIS ORDER:
#
#   1  stop QA            a database with sessions open cannot be dropped, and a node holding the
#                         old schema must not see the new one appear under it
#   2  drop and remake     soma_qa and orion_state_qa, empty (scripts/setup/qa-db.sh, whose refusals
#                         stand in front of this one: separate databases, one shared gate password)
#   3  copy production     pg_dump of the LIVE soma database, restored into soma_qa. One snapshot,
#                         taken while production serves -- pg_dump is consistent and takes no locks
#                         a competitor would feel. `orion_state` is NOT copied: Orion's state is a
#                         node's own, and QA's node rebuilds it from the package at its boot apply.
#   4  migrate             soma's scripts/cutover, with the CANDIDATE IMAGE'S migrations -- the very
#                         bytes its bootstrap will hash, so bootstrap then finds the schema current.
#                         Skipped when the two digests already agree, which is the ordinary case for
#                         a release that did not touch the schema.
#   5  the models bucket   production's models copied into QA's, so a copied submission is a model
#                         that actually loads. Replays are NOT copied: they are the bulk of the
#                         bytes and a QA match writes its own. Old replays 404 in QA's viewer.
#   6  --up                the stack, on the refreshed database.
#
# WHAT IT WILL NOT DO, each refusal a production outage standing behind it:
#
#   - run when QA and production name one database, or one bucket (qa-db.sh checks the first; the
#     buckets are checked here, because a QA runner writing replays into production's bucket
#     overwrites a competitor's)
#   - run when the gate password has drifted (qa-db.sh again: the role is cluster-wide)
#   - run when QA and production share a session or runner-token secret: a QA-minted credential
#     would then verify on production
#   - WRITE ANYTHING TO PRODUCTION. Every production URL here is read, and the only production
#     connection it opens is a pg_dump.
#
# It is not a deploy of the candidate's IMAGES: qa/web/.env names those, and a new image needs its
# plugins signed (TB_ENV=qa scripts/setup/sign-plugins.sh prod/web/keys/tinybrains-dev.pem) before --up.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROD_ENV="${PROD_ENV:-prod/web/.env}"
QA_ENV="${QA_ENV:-qa/web/.env}"
# soma's cutover lives in soma, not here -- it is that repo's knowledge of its own bytes. A checkout
# at the candidate's tag is what this needs; the image does not carry it.
CUTOVER_DIR="${SOMA_CUTOVER_DIR:-../soma/scripts/cutover}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"
# Where the client containers run. `host` is the production machine's answer -- a Cloud SQL private
# IP is reachable there exactly as the stack's containers reach it. `container:<name>` points a
# rehearsal at a local stack's Postgres, which publishes no port; cutover.sh takes the same name.
DOCKER_NETWORK="${DOCKER_NETWORK:-host}"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:1}"

GO=0; UP=0; SKIP_MODELS=0; FROM_DIGEST="${FROM_DIGEST:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)      GO=1 ;;
    --up)          UP=1 ;;
    --skip-models) SKIP_MODELS=1 ;;
    --from-digest) FROM_DIGEST="${2:?--from-digest takes a sha256 hex}"; shift ;;
    *) echo "usage: scripts/setup/qa-refresh.sh [--yes] [--up] [--skip-models] [--from-digest <hex>]" >&2; exit 2 ;;
  esac
  shift
done

for f in "$QA_ENV" "$PROD_ENV"; do
  [ -f "$f" ] || { echo "no $f -- this runs on the machine that RUNS production, where both are real" >&2; exit 1; }
done

# A VALUE, not the name: the templates declare every name with an empty value, so `^NAME=` matches a
# blank the same as a filled one.
value_of() { { grep -E "^$1=.+" "$2" 2>/dev/null || true; } | tail -1 | cut -d= -f2-; }
db_name() { local u="${1%%\?*}"; printf '%s' "${u##*/}"; }

QA_SOMA_URL=$(value_of SOMA_DB_URL "$QA_ENV")
PROD_SOMA_URL=$(value_of SOMA_DB_URL "$PROD_ENV")
[ -n "$QA_SOMA_URL" ] && [ -n "$PROD_SOMA_URL" ] || {
  echo "both $QA_ENV and $PROD_ENV need SOMA_DB_URL" >&2; exit 1; }
QA_SOMA=$(db_name "$QA_SOMA_URL"); PROD_SOMA=$(db_name "$PROD_SOMA_URL")

# ---- the refusals ----------------------------------------------------------------------------------
# qa-db.sh owns the database and gate-password checks and runs them again in step 2; these are the
# ones only a data copy needs.
[ "$QA_SOMA" != "$PROD_SOMA" ] || {
  echo "REFUSED: $QA_ENV and $PROD_ENV name the same database ($QA_SOMA)." >&2; exit 1; }

for pair in MODELS_BUCKET R2_BUCKET; do
  q=$(value_of "$pair" "$QA_ENV"); p=$(value_of "$pair" "$PROD_ENV")
  if [ -n "$q" ] && [ "$q" = "$p" ]; then
    echo "REFUSED: $pair is \`$q\` in BOTH $QA_ENV and $PROD_ENV." >&2
    echo "QA writes replays and reads models by digest; on production's bucket the object it" >&2
    echo "overwrites is a competitor's. QA's buckets are tinybrains-{models,replays}-qa." >&2
    exit 1
  fi
done

for s in SOMA_SESSION_SECRET RUNNER_TOKEN_SECRET ORION_ADMIN_KEY; do
  q=$(value_of "$s" "$QA_ENV"); p=$(value_of "$s" "$PROD_ENV")
  [ -n "$q" ] || { echo "REFUSED: $QA_ENV carries no $s -- run scripts/setup/qa-secrets.sh first." >&2; exit 1; }
  if [ "$q" = "$p" ]; then
    echo "REFUSED: $s is the same value in $QA_ENV and $PROD_ENV." >&2
    echo "A credential QA mints would then verify on production. qa-secrets.sh mints QA its own." >&2
    exit 1
  fi
done

command -v docker > /dev/null || { echo "docker is required" >&2; exit 1; }
[ -x "$CUTOVER_DIR/cutover.sh" ] || {
  echo "no $CUTOVER_DIR/cutover.sh -- the migration lives in soma, not here." >&2
  echo "Check soma out at the candidate's tag beside this directory:" >&2
  echo "  git clone -b \"v\${SOMA_VERSION}\" https://github.com/Tiny-Brains/soma ../soma" >&2
  echo "or point SOMA_CUTOVER_DIR at one." >&2
  exit 1
}

SOMA_IMAGE=$(value_of SOMA_IMAGE "$QA_ENV")
[ -n "$SOMA_IMAGE" ] || { echo "$QA_ENV names no SOMA_IMAGE -- that is the candidate being tested." >&2; exit 1; }

# `psql` when the machine has one, otherwise the image -- how SQL reaches Cloud SQL from the VM.
# --network host so a private-IP instance is reachable exactly as the containers reach it.
WORK=$(mktemp -d); chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# THE CLIENTS ARE CHOSEN SEPARATELY, because they tolerate a version gap differently. `psql` talks
# to a newer server happily; `pg_dump` REFUSES one ("aborting because of server version mismatch"),
# and a production VM whose distribution ships PostgreSQL 15 against a managed PostgreSQL 16 is the
# ordinary case, not a broken machine. So the native pg_dump is used only when it is at least the
# server's major, and $PSQL_IMAGE -- pinned to the major the platform runs -- otherwise.
#
# The dump file therefore has two names: the one the dumper writes and the one the restorer reads.
# They differ whenever one of the two is a container and the other is not.
DUMP_HOST="$WORK/prod.dump"
if command -v psql > /dev/null; then
  run_psql() { psql "$@"; }
  DUMP_READ="$DUMP_HOST"
else
  run_psql() { docker run --rm -i --network "$DOCKER_NETWORK" -v "$WORK:/w" "$PSQL_IMAGE" psql "$@"; }
  DUMP_READ=/w/prod.dump
fi

use_image_dump=1
if command -v pg_dump > /dev/null; then
  client_major=$(pg_dump --version | sed -E 's/[^0-9]*([0-9]+).*/\1/')
  server_major=$(run_psql -X -At "$PROD_SOMA_URL" -c 'SHOW server_version_num' 2>/dev/null | cut -c1-2 | sed 's/^0//')
  if [ -n "$client_major" ] && [ -n "$server_major" ] && [ "$client_major" -ge "$server_major" ] 2>/dev/null; then
    use_image_dump=0
  else
    echo "    pg_dump here is ${client_major:-?} and the server is ${server_major:-?}: using $PSQL_IMAGE to dump"
  fi
fi
if [ "$use_image_dump" = 0 ]; then
  run_pg_dump() { pg_dump "$@"; }
  DUMP_WRITE="$DUMP_HOST"
else
  run_pg_dump() { docker run --rm -i --network "$DOCKER_NETWORK" -v "$WORK:/w" "$PSQL_IMAGE" pg_dump "$@"; }
  DUMP_WRITE=/w/prod.dump
fi

digest_of() { run_psql -X "$1" -At -c "SELECT coalesce((SELECT digest FROM public.soma_schema), '')" 2>/dev/null || true; }

echo "==> production  $PROD_SOMA   ->   QA  $QA_SOMA"
LIVE_DIGEST=$(digest_of "$PROD_SOMA_URL")
[ -n "$LIVE_DIGEST" ] || {
  echo "cannot read production's schema digest from $PROD_SOMA -- is this the production machine," >&2
  echo "and is $PROD_ENV the live deployment's file? (\`prod/\` on a laptop is a stale copy.)" >&2
  exit 1; }
echo "    live schema      sha256:${LIVE_DIGEST:0:12}..."

# The candidate's digest, exactly as soma's entrypoint computes it: the migration files' content,
# concatenated in filename order. Read out of the image, so it is the bytes bootstrap will hash.
docker image inspect "$SOMA_IMAGE" > /dev/null 2>&1 || docker pull -q "$SOMA_IMAGE" > /dev/null
cid=$(docker create "$SOMA_IMAGE"); mkdir -p "$WORK/migrations"
docker cp "$cid:/pkg/soma/migrations/." "$WORK/migrations/" > /dev/null
docker rm "$cid" > /dev/null
if command -v sha256sum > /dev/null; then sum() { sha256sum | cut -d' ' -f1; }; else sum() { shasum -a 256 | cut -d' ' -f1; }; fi
# shellcheck disable=SC2086
CAND_DIGEST=$(cat $(ls -1 "$WORK"/migrations/*.sql) | sum)
echo "    candidate        sha256:${CAND_DIGEST:0:12}...  ($SOMA_IMAGE)"

if [ "$LIVE_DIGEST" = "$CAND_DIGEST" ]; then
  echo "    the schemas agree -- step 4 is a no-op, the copy is already on the candidate's schema"
  NEEDS_CUTOVER=0
else
  echo "    they differ -- step 4 runs soma's cutover over the copy"
  NEEDS_CUTOVER=1
fi

if [ "$GO" = 0 ]; then
  echo
  echo "This is the dry run: nothing has been changed. It would"
  echo "  1  stop the QA stack (tinybrains-qa)"
  echo "  2  DROP and remake $QA_SOMA and $(db_name "$(value_of ORION_STATE_DB_URL "$QA_ENV")")"
  echo "  3  copy production's $PROD_SOMA into $QA_SOMA"
  if [ "$NEEDS_CUTOVER" = 1 ]; then echo "  4  migrate it to sha256:${CAND_DIGEST:0:12}... with $CUTOVER_DIR/cutover.sh"; fi
  if [ "$SKIP_MODELS" = 0 ]; then echo "  5  copy $(value_of MODELS_BUCKET "$PROD_ENV") into $(value_of MODELS_BUCKET "$QA_ENV")"; fi
  if [ "$UP" = 1 ]; then echo "  6  bring QA up"; fi
  echo
  echo "Run it with --yes. Production is only ever READ."
  exit 0
fi

# ---- 1  stop QA -------------------------------------------------------------------------------------
echo "==> 1  stopping the QA stack"
./tb qa web down --remove-orphans || true

# ---- 2  empty databases -----------------------------------------------------------------------------
echo "==> 2  dropping and remaking QA's databases"
PROD_ENV="$PROD_ENV" QA_ENV="$QA_ENV" scripts/setup/qa-db.sh --drop
PROD_ENV="$PROD_ENV" QA_ENV="$QA_ENV" scripts/setup/qa-db.sh

# ---- 3  copy production -----------------------------------------------------------------------------
# --no-owner: the objects land owned by the role QA's URL connects as, whatever production's is.
# The ACLs are KEPT, because `runner_gate`'s grants ride the dump and the gate connects by them.
#
# A PLAIN DUMP, AND ONE LINE OF IT REWRITTEN, rather than the archive format. pg_dump opens every
# dump with
#     SELECT pg_catalog.set_config('search_path', '', false);
# and the schema has SQL functions whose BODIES name other functions unqualified -- a function body
# is text, resolved when it runs, not when it is created. So `notification_category_ok`, reached
# from a CHECK constraint while `notifications` is being COPYed in, cannot see
# `notification_category_spec` and the load fails partway with the table half filled. Restoring
# under `public, pg_catalog` is what production itself runs under, and it leaves the copy byte for
# byte production's -- the alternative, altering the functions after the fact, would make QA's
# schema one production does not have.
#
# --single-transaction: a failure leaves QA's database empty rather than half production's.
echo "==> 3  copying $PROD_SOMA (a consistent snapshot; production keeps serving)"
run_pg_dump --no-owner -f "$DUMP_WRITE" "$PROD_SOMA_URL" 2>&1 | sed 's/^/    /' || {
  echo "the dump of production failed -- nothing in QA has been filled" >&2; exit 1; }
echo "    dump  $(du -h "$DUMP_HOST" | cut -f1)"
sed -i.bak "s/set_config('search_path', '', false)/set_config('search_path', 'public, pg_catalog', false)/g" \
  "$DUMP_HOST" && rm -f "$DUMP_HOST.bak"
# -o /dev/null: a dump's own `set_config` and `setval` calls print result rows, and a page of them
# between the dump's size and the row counts is a page nobody reads. Errors are on stderr.
run_psql -X -q -o /dev/null -v ON_ERROR_STOP=1 --single-transaction -f "$DUMP_READ" "$QA_SOMA_URL" 2>&1 | sed 's/^/    /'

COPIED=$(digest_of "$QA_SOMA_URL")
[ "$COPIED" = "$LIVE_DIGEST" ] || {
  echo "REFUSED: the copy's schema digest (${COPIED:-none}) is not production's -- the restore is incomplete." >&2
  exit 1; }
# COUNTED ON BOTH SIDES, not just the copy. `--single-transaction` makes a partial load impossible,
# but a dump that silently skipped a table is not a partial load -- it is a smaller database that
# restores cleanly, and the two numbers side by side are the only thing that shows it.
echo "    table            live      copy"
for t in users model_versions matches seasons notifications; do
  a=$(run_psql -X "$PROD_SOMA_URL" -At -c "SELECT count(*) FROM $t" 2>/dev/null || echo '-')
  b=$(run_psql -X "$QA_SOMA_URL"   -At -c "SELECT count(*) FROM $t" 2>/dev/null || echo '-')
  printf '    %-16s %-9s %s%s\n' "$t" "$a" "$b" "$([ "$a" = "$b" ] || echo '   <- DIFFERS')"
  [ "$a" = "$b" ] || { echo "REFUSED: $t did not copy completely." >&2; exit 1; }
done

# ---- 4  the migration -------------------------------------------------------------------------------
if [ "$NEEDS_CUTOVER" = 1 ]; then
  echo "==> 4  migrating the copy onto the candidate's schema"
  SOMA_IMAGE="$SOMA_IMAGE" FROM_DIGEST="${FROM_DIGEST:-$LIVE_DIGEST}" DOCKER_NETWORK="$DOCKER_NETWORK" \
    "$CUTOVER_DIR/cutover.sh" "$QA_SOMA_URL" --commit
  NOW=$(digest_of "$QA_SOMA_URL")
  [ "$NOW" = "$CAND_DIGEST" ] || {
    echo "REFUSED: after the cutover the copy is on sha256:${NOW:0:12}..., not the candidate's." >&2
    echo "QA's bootstrap would refuse it by name. The cutover rolled back; the copy is production's." >&2
    exit 1; }
  echo "    now on sha256:${NOW:0:12}... -- the candidate's bootstrap will find it current"
else
  echo "==> 4  no migration needed"
fi

# ---- 5  the models bucket ---------------------------------------------------------------------------
# Two DIFFERENT credentials, source and destination -- production's token must not reach QA's bucket
# and QA's must not reach production's -- which is why this is rclone with two remotes and not
# `aws s3 sync`, which carries one. The env file is written 600 rather than passed on the command
# line, where `ps` would show both secrets.
if [ "$SKIP_MODELS" = 0 ]; then
  SRC_BUCKET=$(value_of MODELS_BUCKET "$PROD_ENV"); DST_BUCKET=$(value_of MODELS_BUCKET "$QA_ENV")
  echo "==> 5  copying models: $SRC_BUCKET -> $DST_BUCKET"
  umask 077
  {
    echo "RCLONE_CONFIG_SRC_TYPE=s3";  echo "RCLONE_CONFIG_SRC_PROVIDER=Cloudflare"; echo "RCLONE_CONFIG_SRC_REGION=auto"
    echo "RCLONE_CONFIG_SRC_ENDPOINT=$(value_of R2_S3_ENDPOINT "$PROD_ENV")"
    echo "RCLONE_CONFIG_SRC_ACCESS_KEY_ID=$(value_of R2_ACCESS_KEY "$PROD_ENV")"
    echo "RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY=$(value_of R2_SECRET_KEY "$PROD_ENV")"
    echo "RCLONE_CONFIG_DST_TYPE=s3";  echo "RCLONE_CONFIG_DST_PROVIDER=Cloudflare"; echo "RCLONE_CONFIG_DST_REGION=auto"
    echo "RCLONE_CONFIG_DST_ENDPOINT=$(value_of R2_S3_ENDPOINT "$QA_ENV")"
    echo "RCLONE_CONFIG_DST_ACCESS_KEY_ID=$(value_of R2_ACCESS_KEY "$QA_ENV")"
    echo "RCLONE_CONFIG_DST_SECRET_ACCESS_KEY=$(value_of R2_SECRET_KEY "$QA_ENV")"
    # The QA token is scoped to the two -qa buckets and cannot list the account's buckets.
    echo "RCLONE_CONFIG_DST_NO_CHECK_BUCKET=true"
  } > "$WORK/rclone.env"
  # --size-only: R2 sets an etag that is not an md5 for multipart objects, and a model is immutable
  # under its digest anyway -- the name IS the checksum.
  docker run --rm --env-file "$WORK/rclone.env" "$RCLONE_IMAGE" \
    copy "src:$SRC_BUCKET" "dst:$DST_BUCKET" --size-only --transfers 4 --stats-one-line --stats 30s \
    2>&1 | sed 's/^/    /'
else
  echo "==> 5  models skipped (--skip-models): a copied submission will not load in QA"
fi

# ---- 6  up ------------------------------------------------------------------------------------------
echo
if [ "$UP" = 1 ]; then
  SIGS="${SIG_DIR:-qa/web/keys/signatures}"
  if [ -z "$(ls -A "$SIGS" 2>/dev/null)" ]; then
    echo "REFUSED: $SIGS is empty -- the node stops at its boot apply rather than serving unsigned." >&2
    echo "  TB_ENV=qa scripts/setup/sign-plugins.sh prod/web/keys/tinybrains-dev.pem" >&2
    exit 1
  fi
  echo "==> 6  bringing QA up on the refreshed database"
  ./tb qa web up -d
  echo
  echo "    ./tb qa web logs -f soma        the bootstrap, then the boot apply"
  echo "    https://$(value_of QA_HOST "$QA_ENV")/"
else
  echo "QA's data is production's, on the candidate's schema. To start it:"
  echo "  TB_ENV=qa scripts/setup/sign-plugins.sh prod/web/keys/tinybrains-dev.pem   # after a new image"
  echo "  ./tb qa web up -d"
fi
