#!/usr/bin/env bash
# QA, REBUILT FROM PRODUCTION'S OWN BACKUP. QA's database instance is replaced by a backup
# production already took, the candidate's migrations are run over it, and the stack comes up.
#
#   scripts/setup/qa-refresh.sh              # what it would do, and every refusal, without acting
#   scripts/setup/qa-refresh.sh --yes        # do it, leaving the stack down
#   scripts/setup/qa-refresh.sh --yes --up   # ...and bring QA up on the result
#
# THE POINT. A QA stack on an empty database tests the code and none of the data: the rows that
# break a release are the ones a season has accumulated -- a settled version, a match half claimed,
# a competitor whose manifest predates a rule. So QA starts from production's rows every time, and
# the release's own migrations are what turns them into the candidate's schema. That migration
# running here, against real data, is the rehearsal for running it on production.
#
# QA OWNS EVERYTHING ELSE AND TOUCHES NOTHING OF PRODUCTION'S. Its VM, its Cloud SQL instance, its
# buckets, its Redis, its OAuth App, its trust key, its edge. THE ONLY THING IT TAKES FROM
# PRODUCTION IS A BACKUP -- and it does not even connect to production's database to get one:
# `gcloud sql backups restore` is an instance-side operation between two managed instances, so
# production does no extra work and QA holds no credential of production's.
#
# THE ORDER, AND WHY IT IS THIS ORDER:
#
#   1  stop QA            a restore replaces the instance under any node still talking to it
#   2  restore            production's latest SUCCESSFUL automatic backup onto QA's instance. This
#                         REPLACES THAT INSTANCE WHOLE -- every database, and every ROLE, because
#                         roles are cluster-wide and a backup carries the cluster.
#   3  QA's own passwords  which is the other half of step 2: after the restore the roles are
#                         production's, passwords included, so each one QA connects as is reset to
#                         QA's value. Production's secrets are never written into qa/web/.env; they
#                         arrive inside the backup and are overwritten before anything uses them.
#   4  migrate            soma's scripts/cutover, with the CANDIDATE IMAGE'S migrations -- the very
#                         bytes its bootstrap will hash, so bootstrap then finds the schema current.
#                         Skipped when the two digests already agree.
#   5  the models bucket   production's models copied into QA's, so a copied submission is a model
#                         that actually loads. Replays are NOT copied: a QA match writes its own.
#   6  --up                the stack, on the refreshed database.
#
# WHAT IT WILL NOT DO:
#
#   - restore onto production, or onto any instance that is not QA's (the two names must differ,
#     and the target must be the one qa/web/.env's URLs actually point at)
#   - run when QA and production share an R2 bucket, a session secret or a runner-token secret
#   - WRITE ANYTHING TO PRODUCTION. It reads production's backup LIST and nothing else.
#
# It is not a deploy of the candidate's IMAGES: qa/web/.env names those, and a new image needs its
# plugins signed (TB_ENV=qa scripts/setup/sign-plugins.sh) before --up.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROD_ENV="${PROD_ENV:-prod/web/.env}"
QA_ENV="${QA_ENV:-qa/web/.env}"
# soma's cutover lives in soma, not here -- it is that repo's knowledge of its own bytes.
CUTOVER_DIR="${SOMA_CUTOVER_DIR:-../soma/scripts/cutover}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:1}"
DOCKER_NETWORK="${DOCKER_NETWORK:-host}"

GO=0; UP=0; SKIP_MODELS=0; SKIP_RESTORE=0; FROM_DIGEST="${FROM_DIGEST:-}"; BACKUP_ID="${BACKUP_ID:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)      GO=1 ;;
    --up)          UP=1 ;;
    --skip-models) SKIP_MODELS=1 ;;
    # The backup is already on the instance; redo only what comes after it.
    --skip-restore) SKIP_RESTORE=1 ;;
    --backup)      BACKUP_ID="${2:?--backup takes a backup id}"; shift ;;
    --from-digest) FROM_DIGEST="${2:?--from-digest takes a sha256 hex}"; shift ;;
    *) echo "usage: scripts/setup/qa-refresh.sh [--yes] [--up] [--skip-models] [--skip-restore] [--backup <id>] [--from-digest <hex>]" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$QA_ENV" ] || { echo "no $QA_ENV -- run this where QA's settings are" >&2; exit 1; }
value_of() { { grep -E "^$1=.+" "$2" 2>/dev/null || true; } | tail -1 | cut -d= -f2-; }
host_of()  { local u="${1#*@}"; printf '%s' "${u%%/*}"; }
db_name()  { local u="${1%%\?*}"; printf '%s' "${u##*/}"; }

PROJECT=$(value_of GCP_PROJECT "$QA_ENV")
QA_SQL=$(value_of QA_SQL_INSTANCE "$QA_ENV")
PROD_SQL=$(value_of PROD_SQL_INSTANCE "$QA_ENV")
QA_SOMA_URL=$(value_of SOMA_DB_URL "$QA_ENV")
QA_STATE_URL=$(value_of ORION_STATE_DB_URL "$QA_ENV")
QA_ADMIN_URL=$(value_of SOMA_ADMIN_DB_URL "$QA_ENV")
for n in GCP_PROJECT:$PROJECT QA_SQL_INSTANCE:$QA_SQL PROD_SQL_INSTANCE:$PROD_SQL SOMA_DB_URL:$QA_SOMA_URL; do
  [ -n "${n#*:}" ] || { echo "$QA_ENV needs ${n%%:*}" >&2; exit 1; }
done

# ---- the refusals ----------------------------------------------------------------------------------
[ "$QA_SQL" != "$PROD_SQL" ] || {
  echo "REFUSED: QA_SQL_INSTANCE and PROD_SQL_INSTANCE are both \`$QA_SQL\`." >&2
  echo "This restores ONTO the first one, replacing it. They must never be the same instance." >&2
  exit 1; }

# The instance this replaces must be the one QA actually connects to; otherwise the restore lands
# somewhere nothing reads and the stack comes up on a database that was never refreshed.
QA_PRIVATE_IP=$(gcloud sql instances describe "$QA_SQL" --project "$PROJECT" --format='value(ipAddresses[0].ipAddress)' 2>/dev/null || true)
[ -n "$QA_PRIVATE_IP" ] || { echo "cannot describe $QA_SQL in project $PROJECT -- is gcloud authenticated?" >&2; exit 1; }
case "$(host_of "$QA_SOMA_URL")" in
  "$QA_PRIVATE_IP"|"$QA_PRIVATE_IP":*) ;;
  *) echo "REFUSED: $QA_ENV's SOMA_DB_URL points at $(host_of "$QA_SOMA_URL"), but $QA_SQL is $QA_PRIVATE_IP." >&2
     echo "The instance this would replace is not the one QA reads." >&2
     exit 1 ;;
esac

if [ -f "$PROD_ENV" ]; then
  for pair in MODELS_BUCKET R2_BUCKET; do
    q=$(value_of "$pair" "$QA_ENV"); p=$(value_of "$pair" "$PROD_ENV")
    if [ -n "$q" ] && [ "$q" = "$p" ]; then
      echo "REFUSED: $pair is \`$q\` in BOTH $QA_ENV and $PROD_ENV." >&2
      echo "A QA runner writes replays and reads models by digest; on production's bucket the" >&2
      echo "object it overwrites is a competitor's." >&2
      exit 1
    fi
  done
  for s in SOMA_SESSION_SECRET RUNNER_TOKEN_SECRET ORION_ADMIN_KEY; do
    q=$(value_of "$s" "$QA_ENV"); p=$(value_of "$s" "$PROD_ENV")
    if [ -n "$q" ] && [ "$q" = "$p" ]; then
      echo "REFUSED: $s is the same value in $QA_ENV and $PROD_ENV." >&2
      echo "A credential QA mints would then verify on production." >&2
      exit 1
    fi
  done
fi

command -v docker  > /dev/null || { echo "docker is required" >&2; exit 1; }
command -v gcloud  > /dev/null || { echo "gcloud is required -- the restore is a managed operation" >&2; exit 1; }
[ -x "$CUTOVER_DIR/cutover.sh" ] || {
  echo "no $CUTOVER_DIR/cutover.sh -- the migration lives in soma, not here." >&2
  echo "Check soma out at the candidate's tag, or point SOMA_CUTOVER_DIR at one." >&2
  exit 1; }

SOMA_IMAGE=$(value_of SOMA_IMAGE "$QA_ENV")
[ -n "$SOMA_IMAGE" ] || { echo "$QA_ENV names no SOMA_IMAGE -- that is the candidate being tested." >&2; exit 1; }

WORK=$(mktemp -d); chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

if command -v psql > /dev/null; then
  run_psql() { psql "$@"; }
else
  run_psql() { docker run --rm -i --network "$DOCKER_NETWORK" -v "$WORK:/w" "$PSQL_IMAGE" psql "$@"; }
fi

# ---- which backup ------------------------------------------------------------------------------------
# The LATEST SUCCESSFUL one, because a failed backup is still listed. Nothing is triggered on
# production: this reads the list its automatic schedule already filled.
if [ -z "$BACKUP_ID" ]; then
  BACKUP_ID=$(gcloud sql backups list --instance "$PROD_SQL" --project "$PROJECT" \
                --filter='status=SUCCESSFUL' --sort-by='~windowStartTime' --limit 1 \
                --format='value(id)' 2>/dev/null || true)
fi
[ -n "$BACKUP_ID" ] || { echo "no SUCCESSFUL backup of $PROD_SQL to restore -- is its backup schedule on?" >&2; exit 1; }
BACKUP_WHEN=$(gcloud sql backups describe "$BACKUP_ID" --instance "$PROD_SQL" --project "$PROJECT" \
                --format='value(windowStartTime)' 2>/dev/null || echo '?')

echo "==> production $PROD_SQL   backup $BACKUP_ID ($BACKUP_WHEN)"
echo "    restores onto $QA_SQL ($QA_PRIVATE_IP), replacing it whole"

# The candidate's digest, exactly as soma's entrypoint computes it: the migration files' content,
# concatenated in filename order. Read out of the image, so it is the bytes bootstrap will hash.
docker image inspect "$SOMA_IMAGE" > /dev/null 2>&1 || docker pull -q "$SOMA_IMAGE" > /dev/null
cid=$(docker create "$SOMA_IMAGE"); mkdir -p "$WORK/migrations"
docker cp "$cid:/pkg/soma/migrations/." "$WORK/migrations/" > /dev/null
docker rm "$cid" > /dev/null
if command -v sha256sum > /dev/null; then sum() { sha256sum | cut -d' ' -f1; }; else sum() { shasum -a 256 | cut -d' ' -f1; }; fi
# shellcheck disable=SC2086
CAND_DIGEST=$(cat $(ls -1 "$WORK"/migrations/*.sql) | sum)
echo "    candidate schema  sha256:${CAND_DIGEST:0:12}...  ($SOMA_IMAGE)"

if [ "$GO" = 0 ]; then
  echo
  echo "This is the dry run: nothing has been changed. It would"
  echo "  1  stop the QA stack (tinybrains-qa)"
  echo "  2  RESTORE backup $BACKUP_ID onto $QA_SQL -- replacing every database and role on it"
  echo "  3  reset QA's own postgres/soma/runner_gate passwords, which the restore overwrites"
  echo "  4  migrate $(db_name "$QA_SOMA_URL") to sha256:${CAND_DIGEST:0:12}... when it differs"
  if [ "$SKIP_MODELS" = 0 ]; then echo "  5  copy $(value_of MODELS_BUCKET "$PROD_ENV" 2>/dev/null) into $(value_of MODELS_BUCKET "$QA_ENV")"; fi
  if [ "$UP" = 1 ]; then echo "  6  bring QA up"; fi
  echo
  echo "Run it with --yes. Production is only ever READ, and only its backup LIST."
  exit 0
fi

# ---- 1  stop QA -------------------------------------------------------------------------------------
echo "==> 1  stopping the QA stack"
./tb qa web down --remove-orphans || true

# ---- 2  the restore ---------------------------------------------------------------------------------
if [ "$SKIP_RESTORE" = 1 ]; then
  echo "==> 2  restore SKIPPED (--skip-restore): the instance keeps the backup it already holds"
else
echo "==> 2  restoring (several minutes)"
# WAIT ON THE OPERATION, NOT ON THE INSTANCE'S STATE. A restoring instance reports RUNNABLE and
# even accepts connections partway through -- already authenticating as the ROLES THE BACKUP
# CARRIES, which are production's. A wait that watched the state would therefore return early, and
# step 3 would reset passwords that the rest of the restore then overwrote: QA's own URLs would
# fail against its own instance, with nothing to show why.
OP=$(gcloud sql backups restore "$BACKUP_ID" \
       --restore-instance "$QA_SQL" --backup-instance "$PROD_SQL" \
       --project "$PROJECT" --quiet --async --format='value(name)' 2>&1 | tail -1)
[ -n "$OP" ] || { echo "the restore was not accepted" >&2; exit 1; }
echo "    operation $OP"
gcloud sql operations wait "$OP" --project "$PROJECT" --timeout 3600 2>&1 | sed 's/^/    /'
status=$(gcloud sql operations describe "$OP" --project "$PROJECT" --format='value(status)' 2>/dev/null || true)
[ "$status" = "DONE" ] || { echo "the restore did not finish (status: ${status:-unknown})" >&2; exit 1; }
err=$(gcloud sql operations describe "$OP" --project "$PROJECT" --format='value(error.errors[0].message)' 2>/dev/null || true)
[ -z "$err" ] || { echo "the restore reported: $err" >&2; exit 1; }
echo "    restore DONE; $QA_SQL now carries $PROD_SQL's cluster"
fi

# ---- 3  QA's own passwords --------------------------------------------------------------------------
# THE RESTORE BROUGHT PRODUCTION'S ROLES. Roles are cluster-wide, so a backup carries them and their
# passwords: right now every role on QA's instance authenticates with production's secret. Each one
# QA connects as is reset here, before anything is pointed at it.
echo "==> 3  resetting QA's credentials, which the restore replaced with production's"
QA_ROOT_PW="${QA_ROOT_PW:-$(value_of QA_SQL_ROOT_PASSWORD "$QA_ENV")}"
[ -n "$QA_ROOT_PW" ] || { echo "$QA_ENV needs QA_SQL_ROOT_PASSWORD -- the superuser this resets the others through" >&2; exit 1; }
gcloud sql users set-password postgres --instance "$QA_SQL" --project "$PROJECT" \
  --password "$QA_ROOT_PW" --quiet 2>&1 | sed 's/^/    /'
echo "    postgres: reset"

SOMA_ROLE=$(u="${QA_SOMA_URL#*://}"; u="${u%%:*}"; printf '%s' "$u")
SOMA_PW=$(u="${QA_SOMA_URL#*://}"; u="${u#*:}"; printf '%s' "${u%%@*}")
GATE_PW=$(value_of RUNNER_GATE_DB_PASSWORD "$QA_ENV")
ADMIN_AS_ROOT="postgresql://postgres:$QA_ROOT_PW@$QA_PRIVATE_IP:5432/postgres?sslmode=require"
# NOT A `DO $$ ... $$` BLOCK. psql substitutes :'x' before sending, but a dollar-quoted body is
# passed to the server verbatim -- so `:'g'` inside one arrives as literal text and the server
# answers `syntax error at or near ":"`. \gexec builds the statement in psql, where the
# substitution happens, and runs what comes back.
run_psql "$ADMIN_AS_ROOT" -X -q -v ON_ERROR_STOP=1 -v r="$SOMA_ROLE" -v p="$SOMA_PW" -v g="${GATE_PW:-}" <<'SQL'
ALTER ROLE :"r" WITH LOGIN PASSWORD :'p';
SELECT format('ALTER ROLE runner_gate WITH LOGIN PASSWORD %L', :'g')
 WHERE :'g' <> '' AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'runner_gate')\gexec
SQL
echo "    $SOMA_ROLE: reset;  runner_gate: $([ -n "$GATE_PW" ] && echo reset || echo 'left as restored')"

for u in "$QA_SOMA_URL" "$QA_STATE_URL" "$QA_ADMIN_URL"; do
  [ -n "$u" ] || continue
  run_psql -X -At "$u" -c 'SELECT 1' > /dev/null || {
    echo "cannot connect with $(db_name "$u")'s URL from $QA_ENV after the restore" >&2; exit 1; }
done
echo "    every URL in $QA_ENV connects"

LIVE_DIGEST=$(run_psql -X -At "$QA_SOMA_URL" -c "SELECT coalesce((SELECT digest FROM public.soma_schema), '')" 2>/dev/null || true)
echo "    restored schema   sha256:${LIVE_DIGEST:0:12}..."
echo "    table            rows"
for t in users model_versions matches seasons notifications; do
  n=$(run_psql -X -At "$QA_SOMA_URL" -c "SELECT count(*) FROM $t" 2>/dev/null || echo '-')
  printf '    %-16s %s\n' "$t" "$n"
done

# ---- 4  the migration -------------------------------------------------------------------------------
if [ "$LIVE_DIGEST" = "$CAND_DIGEST" ]; then
  echo "==> 4  no migration needed -- the backup is already on the candidate's schema"
else
  echo "==> 4  migrating onto the candidate's schema"
  SOMA_IMAGE="$SOMA_IMAGE" FROM_DIGEST="${FROM_DIGEST:-$LIVE_DIGEST}" DOCKER_NETWORK="$DOCKER_NETWORK" \
    "$CUTOVER_DIR/cutover.sh" "$QA_SOMA_URL" --commit
  NOW=$(run_psql -X -At "$QA_SOMA_URL" -c "SELECT digest FROM public.soma_schema" 2>/dev/null || true)
  [ "$NOW" = "$CAND_DIGEST" ] || {
    echo "REFUSED: after the cutover the database is on sha256:${NOW:0:12}..., not the candidate's." >&2
    echo "QA's bootstrap would refuse it by name. The cutover rolled back." >&2
    exit 1; }
  echo "    now on sha256:${NOW:0:12}... -- the candidate's bootstrap will find it current"
fi

# ---- 5  the models bucket ---------------------------------------------------------------------------
# Two DIFFERENT credentials, source and destination, which is why this is rclone with two remotes
# and not `aws s3 sync`. The env file is written 600 rather than passed on the command line, where
# `ps` would show both secrets.
if [ "$SKIP_MODELS" = 0 ] && [ -f "$PROD_ENV" ]; then
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
    echo "RCLONE_CONFIG_DST_NO_CHECK_BUCKET=true"
  } > "$WORK/rclone.env"
  # --size-only: a model is immutable under its digest, so the name IS the checksum.
  docker run --rm --env-file "$WORK/rclone.env" "$RCLONE_IMAGE" \
    copy "src:$SRC_BUCKET" "dst:$DST_BUCKET" --size-only --transfers 4 --stats-one-line --stats 30s \
    2>&1 | sed 's/^/    /'
else
  echo "==> 5  models skipped -- a copied submission will not load in QA"
fi

# ---- 6  up ------------------------------------------------------------------------------------------
echo
if [ "$UP" = 1 ]; then
  SIGS="${SIG_DIR:-qa/web/keys/signatures}"
  if [ -z "$(ls -A "$SIGS" 2>/dev/null)" ]; then
    echo "REFUSED: $SIGS is empty -- the node stops at its boot apply rather than serving unsigned." >&2
    echo "  TB_ENV=qa scripts/setup/sign-plugins.sh" >&2
    exit 1
  fi
  echo "==> 6  bringing QA up on the refreshed database"
  ./tb qa web up -d
  echo
  echo "    ./tb qa web logs -f soma"
  echo "    https://$(value_of SITE_HOST "$QA_ENV")/"
else
  echo "QA's data is production's, on the candidate's schema. To start it:"
  echo "  TB_ENV=qa scripts/setup/sign-plugins.sh   # after a new image"
  echo "  ./tb qa web up -d"
fi
