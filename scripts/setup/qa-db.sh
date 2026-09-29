#!/usr/bin/env bash
# The QA stack's two databases, on PRODUCTION'S Postgres server.
#
#   scripts/setup/qa-db.sh            create soma_qa and orion_state_qa, then check them
#   scripts/setup/qa-db.sh --drop     remove both (the QA half of teardown)
#
# WHY THIS EXISTS AND BOOTSTRAP DOES NOT DO IT. soma's bootstrap creates the literal database
# `orion_state` -- the name is hard-coded, not read from ORION_STATE_DB_URL -- and then MIGRATES into
# whatever that URL names. On a server where production already owns `orion_state`, its create step
# is a no-op and the migrate step runs against a database nobody made. Bootstrap never touches
# SOMA_DB_URL's database either. So both are made here, once, before the QA stack's first `up`.
#
# WHAT IT REFUSES, and each one is a production outage it is standing in front of:
#
#   the gate password       ONLY WHEN THE TWO SHARE A SERVER: qa/web/.env's RUNNER_GATE_DB_PASSWORD
#                           must then equal prod/web/.env's, because `runner_gate` is a cluster-wide
#                           ROLE and bootstrap runs `ALTER ROLE runner_gate WITH LOGIN PASSWORD` on
#                           every bring-up -- a QA stack with its own value rewrites production's
#                           gate password at its first start, production's runners then fail to
#                           connect, and nothing in production's logs names QA. Where QA has a
#                           server of its own the role is its own and nothing needs to match.
#   the same database       qa/web/.env's SOMA_DB_URL or ORION_STATE_DB_URL naming a database prod/web/.env also
#                           names. That is not a QA stack, it is a second node writing production's
#                           ladder under a candidate schema.
#   a live QA database      --drop stops if the QA stack still has sessions open, rather than
#                           killing them.
#
# It does NOT create the role, grant anything or apply the schema: the migration creates
# `runner_gate` if the server has none and grants it per-database, and bootstrap applies the schema
# and sets the password. This makes two empty databases owned by the role the URLs connect as.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROD_ENV="${PROD_ENV:-prod/web/.env}"
QA_ENV="${QA_ENV:-qa/web/.env}"
DROP=0
[ "${1:-}" = "--drop" ] && DROP=1

for f in "$QA_ENV" "$PROD_ENV"; do
  [ -f "$f" ] || { echo "no $f -- run this on the production machine, after qa-secrets.sh" >&2; exit 1; }
done

value_of() { { grep -E "^$1=.+" "$2" 2>/dev/null || true; } | tail -1 | cut -d= -f2-; }

# `psql` when the machine has one, otherwise the image -- which is how SQL is run against Cloud SQL
# from the production VM. --network host so a private-IP instance is reachable exactly as the
# containers reach it; DOCKER_NETWORK points a rehearsal at a local stack's Postgres, which
# publishes no port (`container:<name>`), and cutover.sh and qa-refresh.sh take the same name.
if command -v psql > /dev/null; then
  run_psql() { psql "$@"; }
else
  command -v docker > /dev/null || { echo "neither psql nor docker is available" >&2; exit 1; }
  run_psql() { docker run --rm -i --network "${DOCKER_NETWORK:-host}" postgres:16-alpine psql "$@"; }
fi

ADMIN_DB=$(value_of SOMA_ADMIN_DB_URL "$QA_ENV")
QA_SOMA_URL=$(value_of SOMA_DB_URL "$QA_ENV")
QA_STATE_URL=$(value_of ORION_STATE_DB_URL "$QA_ENV")
[ -n "$ADMIN_DB" ] && [ -n "$QA_SOMA_URL" ] && [ -n "$QA_STATE_URL" ] || {
  echo "$QA_ENV needs SOMA_ADMIN_DB_URL, SOMA_DB_URL and ORION_STATE_DB_URL filled in." >&2
  exit 1
}

# The database name is the path segment, with any ?query stripped.
db_name() { local u="${1%%\?*}"; printf '%s' "${u##*/}"; }
QA_SOMA=$(db_name "$QA_SOMA_URL")
QA_STATE=$(db_name "$QA_STATE_URL")

# ---- the refusals ---------------------------------------------------------------------------------
PROD_SOMA=$(db_name "$(value_of SOMA_DB_URL "$PROD_ENV")")
PROD_STATE=$(db_name "$(value_of ORION_STATE_DB_URL "$PROD_ENV")")
for pair in "$QA_SOMA:$PROD_SOMA" "$QA_SOMA:$PROD_STATE" "$QA_STATE:$PROD_SOMA" "$QA_STATE:$PROD_STATE"; do
  if [ -n "${pair#*:}" ] && [ "${pair%%:*}" = "${pair#*:}" ]; then
    echo "REFUSED: $QA_ENV names the database \`${pair%%:*}\`, which $PROD_ENV names too." >&2
    echo "QA must have databases of its own on this server -- soma_qa and orion_state_qa." >&2
    exit 1
  fi
done

# THE GATE PASSWORD IS A CLUSTER-WIDE FACT, so whether it must match depends on whether the two
# environments are on ONE SERVER. `runner_gate` is a ROLE, and roles belong to a cluster: where QA
# and production share a server they share the role, and soma's bootstrap runs
#     ALTER ROLE runner_gate WITH LOGIN PASSWORD ...
# on every bring-up -- so a QA stack holding its own value would rewrite PRODUCTION'S gate password,
# and every production runner would fail to connect with nothing in production's logs naming QA.
# Where QA has a server of its own, that role is its own too, and a shared password would be
# production's secret kept somewhere it is not needed.
host_of() {   # everything between the @ and the path, so host:port
  local u="${1#*@}"; printf '%s' "${u%%/*}"
}
QA_HOSTPORT=$(host_of "$QA_SOMA_URL")
PROD_HOSTPORT=$(host_of "$(value_of SOMA_DB_URL "$PROD_ENV")")
QA_GATE_PW=$(value_of RUNNER_GATE_DB_PASSWORD "$QA_ENV")
PROD_GATE_PW=$(value_of RUNNER_GATE_DB_PASSWORD "$PROD_ENV")
if [ "$QA_HOSTPORT" = "$PROD_HOSTPORT" ]; then
  if [ "$QA_GATE_PW" != "$PROD_GATE_PW" ]; then
    echo "REFUSED: RUNNER_GATE_DB_PASSWORD differs between $QA_ENV and $PROD_ENV," >&2
    echo "and both name the same server ($QA_HOSTPORT), where \`runner_gate\` is ONE role." >&2
    echo >&2
    echo "soma's bootstrap runs \`ALTER ROLE runner_gate WITH LOGIN PASSWORD\` on every bring-up, so" >&2
    echo "starting QA with a different value would rewrite PRODUCTION'S gate password -- every" >&2
    echo "production runner then fails to connect, and production's logs say nothing about QA." >&2
    echo >&2
    echo "  scripts/setup/qa-secrets.sh     copies the value across" >&2
    exit 1
  fi
  echo "==> checks passed: one server, separate databases, one shared runner_gate password"
else
  if [ -n "$PROD_GATE_PW" ] && [ "$QA_GATE_PW" = "$PROD_GATE_PW" ]; then
    echo "==> note: QA is on its own server ($QA_HOSTPORT) but carries production's gate password."
    echo "    It does no harm and it is not needed -- QA's \`runner_gate\` is QA's own role now."
  fi
  echo "==> checks passed: QA has a server of its own ($QA_HOSTPORT), so no role is shared"
fi

psql_admin() { run_psql -X "$ADMIN_DB" -q -v ON_ERROR_STOP=1 "$@"; }

exists() { run_psql -X "$ADMIN_DB" -At -c "SELECT 1 FROM pg_database WHERE datname = '$1'"; }

# ---- --drop ---------------------------------------------------------------------------------------
if [ "$DROP" = 1 ]; then
  for db in "$QA_SOMA" "$QA_STATE"; do
    [ -n "$(exists "$db")" ] || { echo "    gone  $db"; continue; }
    open=$(run_psql -X "$ADMIN_DB" -At -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$db'")
    if [ "${open:-0}" -gt 0 ]; then
      echo "REFUSED: $db still has $open connection(s) open." >&2
      echo "Stop the QA stack first:" >&2
      echo "  ./tb qa web down" >&2
      exit 1
    fi
    psql_admin -c "DROP DATABASE $db"
    echo "    drop  $db"
  done
  echo "==> the QA databases are gone. The runner_gate ROLE stays: it is production's."
  echo "    Still to remove by hand: the two R2 buckets and their token, the QA OAuth App, the"
  echo "    DNS record, compose/caddy/conf.d/qa.caddy, and qa/web/keys/signatures/."
  exit 0
fi

# ---- create ---------------------------------------------------------------------------------------
echo "==> waiting for postgres"
i=0
until run_psql -X "$ADMIN_DB" -At -c 'SELECT 1' > /dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || { echo "the server did not answer in time" >&2; run_psql -X "$ADMIN_DB" -c 'SELECT 1'; exit 1; }
  sleep 2
done

for db in "$QA_SOMA" "$QA_STATE"; do
  if [ -n "$(exists "$db")" ]; then
    echo "    have  $db"
    continue
  fi
  # CREATE DATABASE cannot run inside a transaction block, so it is built as text and run by \gexec
  # -- the same shape bootstrap uses, and what makes it a no-op when the database is already there.
  psql_admin <<SQL
SELECT format('CREATE DATABASE $db OWNER %I', current_user)
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '$db')\gexec
SQL
  echo "    make  $db"
done

# Both URLs must actually connect as themselves before the stack is told they will: a typo in the
# password or the host shows up here, not as a bootstrap that half-ran.
for u in "$QA_SOMA_URL" "$QA_STATE_URL"; do
  run_psql -X "$u" -At -c 'SELECT 1' > /dev/null || {
    echo "cannot connect with $(db_name "$u")'s URL from $QA_ENV" >&2; exit 1; }
done
echo "==> both QA databases exist and their URLs connect"

# What the server's connection budget now looks like. The f1-micro allows 60; production's node
# takes 27 and qa/web/.env's pools take 12.
used=$(run_psql -X "$ADMIN_DB" -At -c 'SELECT count(*) FROM pg_stat_activity') || used=?
max=$(run_psql -X "$ADMIN_DB" -At -c 'SHOW max_connections') || max=?
echo "    connections in use now: $used of $max"

echo
echo "Next:"
echo "  TB_ENV=qa scripts/setup/sign-plugins.sh prod/web/keys/tinybrains-dev.pem"
echo "  scripts/setup/qa-refresh.sh --yes --up"
echo
echo "These two databases are EMPTY. QA is meant to hold production's rows, and qa-refresh.sh is"
echo "what puts them there -- it drops these again, copies production in, and runs the candidate's"
echo "own migrations over the copy. Bringing the stack up on empty databases instead is a valid"
echo "stack and a test of the code only: the rows that break a release are a season's own."
