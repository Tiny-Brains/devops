#!/usr/bin/env bash
# The QA stack's five secrets, three minted here and two taken from production ON PURPOSE.
#
#   scripts/setup/qa-secrets.sh [--force]
#
# Writes into qa/web/.env, which compose/web.qa.yml reads. Run it on the production machine, after
# `cp examples/web.qa.env.example qa/web/.env` and before scripts/setup/qa-db.sh.
#
#   ORION_ADMIN_KEY          minted, QA's own. 64 hex; production refuses a plaintext key under 32.
#   SOMA_SESSION_SECRET      minted, QA's own. A shared one would make a QA-issued session a
#                            credential production's node would also verify.
#   RUNNER_TOKEN_SECRET      minted, QA's own, and a DIFFERENT value from the session secret.
#
#   TB_TRUST_PUBLIC_KEY      COPIED from .env. One machine, one Ed25519 trust root: a signature
#                            belongs to whoever holds the key, not to a stack. The signatures
#                            themselves are not shared -- QA's images carry the candidate's engine,
#                            so they are signed into qa/web/keys/signatures/ (this script prints the
#                            command) and one directory holding two digests under
#                            `tb-ants.wasm.sig` is what sign-plugins.sh refuses by name.
#
#   RUNNER_GATE_DB_PASSWORD  COPIED from production ONLY WHERE THE TWO SHARE A POSTGRES SERVER,
#                            and where they do it MUST STAY COPIED.
#                            `runner_gate` is a PostgreSQL ROLE and roles are cluster-wide: QA's
#                            databases and production's live on one server and share one role.
#                            soma's bootstrap runs `ALTER ROLE runner_gate WITH LOGIN PASSWORD` on
#                            EVERY bring-up, so a QA stack holding its own value rewrites
#                            production's gate password the first time it starts -- and what you see
#                            then is every production runner failing to connect, with nothing in
#                            production's logs mentioning QA. qa-db.sh re-checks this before it
#                            touches the server.
#
# Nothing here reads or writes a bucket, a database or a GitHub App: those are filled in by hand
# from examples/web.qa.env.example's comments, because each one is created in someone else's dashboard.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROD_ENV="${PROD_ENV:-prod/web/.env}"
QA_ENV="${QA_ENV:-qa/web/.env}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

command -v openssl > /dev/null || { echo "openssl is required" >&2; exit 1; }

[ -f "$QA_ENV" ] || {
  echo "no $QA_ENV -- start from the template:" >&2
  echo "  cp examples/web.qa.env.example $QA_ENV" >&2
  exit 1
}
# PRODUCTION'S FILE IS OPTIONAL, AND ON A QA MACHINE IT IS ABSENT ON PURPOSE. QA owns its own
# trust key, its own Postgres and therefore its own `runner_gate` role; there is nothing of
# production's for it to copy. The copying path below is only for a QA stack that still shares a
# machine and a Postgres server with production.
STANDALONE=1
if [ -f "$PROD_ENV" ]; then STANDALONE=0; fi

# A VALUE, not the name: the template declares every name with an empty value, so `^NAME=` matches
# a blank the same as a filled one -- the bug admin-key.sh carries a comment about.
value_of() { { grep -E "^$1=.+" "$2" 2>/dev/null || true; } | tail -1 | cut -d= -f2-; }

put() {   # $1 name, $2 value -- replace in place or append
  local name="$1" val="$2" tmp
  if grep -q "^$name=" "$QA_ENV"; then
    # cat, not mv: $QA_ENV may be a symlink into a deployment directory (see admin-user.sh).
    # `|| true`: see admin-key.sh -- grep -v exits 1 when every line matched.
    tmp=$(mktemp); grep -v "^$name=" "$QA_ENV" > "$tmp" || true; cat "$tmp" > "$QA_ENV"; rm -f "$tmp"
  fi
  printf '%s=%s\n' "$name" "$val" >> "$QA_ENV"
}

# ---- what comes from production, where there is a production here at all ----------------------------
if [ "$STANDALONE" = 1 ]; then
  echo "==> QA is standalone: no $PROD_ENV on this machine, so nothing is copied"
  # The trust root is QA's own, and it is not minted here -- trust-keygen.sh writes both halves,
  # because the private one has to exist before `plugin pubkey` can name the public one.
  if [ -z "$(value_of TB_TRUST_PUBLIC_KEY "$QA_ENV")" ]; then
    echo "    TB_TRUST_PUBLIC_KEY is empty -- QA signs with its own key, so mint it first:" >&2
    echo "      scripts/setup/trust-keygen.sh --env qa" >&2
    exit 1
  fi
  echo "    TB_TRUST_PUBLIC_KEY      already set (QA's own root)"
  QA_PG=standalone; PROD_PG=none
else
  # The trust key always: one machine, one Ed25519 root, and a signature belongs to whoever holds it.
  TRUST=$(value_of TB_TRUST_PUBLIC_KEY "$PROD_ENV")
  [ -n "$TRUST" ] || { echo "$PROD_ENV carries no TB_TRUST_PUBLIC_KEY -- is this the production machine?" >&2; exit 1; }
  put TB_TRUST_PUBLIC_KEY "$TRUST"
  echo "==> copied from $PROD_ENV"
  echo "    TB_TRUST_PUBLIC_KEY      $TRUST"

  # THE GATE PASSWORD ONLY WHERE THE TWO SHARE A POSTGRES SERVER. `runner_gate` is a cluster-wide
  # ROLE: on one server it is one role, and soma's bootstrap resets its password on every bring-up,
  # so QA must carry production's or its first start rewrites it. On a server of its own QA's
  # `runner_gate` is its own role.
  host_of() { local u="${1#*@}"; printf '%s' "${u%%/*}"; }
  QA_PG=$(host_of "$(value_of SOMA_DB_URL "$QA_ENV")")
  PROD_PG=$(host_of "$(value_of SOMA_DB_URL "$PROD_ENV")")
  if [ -n "$QA_PG" ] && [ "$QA_PG" = "$PROD_PG" ]; then
    GATE=$(value_of RUNNER_GATE_DB_PASSWORD "$PROD_ENV")
    [ -n "$GATE" ] || { echo "$PROD_ENV carries no RUNNER_GATE_DB_PASSWORD" >&2; exit 1; }
    put RUNNER_GATE_DB_PASSWORD "$GATE"
    echo "    RUNNER_GATE_DB_PASSWORD  ${GATE:0:4}... (one server, so one runner_gate role)"
  else
    echo "==> QA is on its own Postgres (${QA_PG:-unset}), production on ${PROD_PG:-unset}"
    echo "    so RUNNER_GATE_DB_PASSWORD is QA's own and is NOT copied"
  fi
fi

# ---- the three QA mints for itself ----------------------------------------------------------------
minted=0
mint() {   # $1 name, $2 generator
  local name="$1" existing
  existing=$(value_of "$name" "$QA_ENV")
  if [ -n "$existing" ] && [ "$FORCE" = 0 ]; then
    echo "    keep  $name (already set; --force replaces it)"
    return
  fi
  put "$name" "$($2)"
  echo "    mint  $name"
  minted=$((minted + 1))
}
hex32() { openssl rand -hex 32; }

echo "==> QA's own secrets"
mint ORION_ADMIN_KEY hex32
mint SOMA_SESSION_SECRET hex32
mint RUNNER_TOKEN_SECRET hex32
# Only when QA's server is its own; where it is shared the value was copied just above.
[ "$QA_PG" = "$PROD_PG" ] || mint RUNNER_GATE_DB_PASSWORD hex32

# The two must differ: one secret signing both a session and a runner token means a token minted for
# one surface verifies on the other.
if [ "$(value_of SOMA_SESSION_SECRET "$QA_ENV")" = "$(value_of RUNNER_TOKEN_SECRET "$QA_ENV")" ]; then
  echo "SOMA_SESSION_SECRET and RUNNER_TOKEN_SECRET are the same value -- they must differ." >&2
  exit 1
fi

echo "==> $QA_ENV now carries all five ($minted newly minted)"
echo
echo "STILL TO FILL IN BY HAND, each made in someone else's dashboard -- $QA_ENV says how:"
echo "  QA_HOST                         and its DNS A record, pointed at this machine"
echo "  SOMA_IMAGE / WEB_IMAGE          the candidate release, both from one ants release"
echo "  GITHUB_CLIENT_ID / _SECRET      a SECOND OAuth App, callback https://<QA_HOST>/v1/auth/github/callback"
echo "  SOMA_ADMIN_IDS                  scripts/setup/admin-user.sh <login> --env-file $QA_ENV"
echo "  SOMA_DB_URL / ORION_STATE_DB_URL / SOMA_ADMIN_DB_URL / RUNNER_GATE_DB_URL"
echo "  R2_S3_ENDPOINT                  the same string as $PROD_ENV's -- buckets are named, not hosted"
echo "  R2_BUCKET / MODELS_BUCKET       tinybrains-{replays,models}-qa, both PRIVATE"
echo "  R2_ACCESS_KEY / R2_SECRET_KEY   a SECOND R2 token, scoped to those two buckets and nothing else"
echo
echo "Then:"
echo "  scripts/setup/qa-db.sh                                       soma_qa + orion_state_qa"
echo "  TB_ENV=qa scripts/setup/sign-plugins.sh prod/web/keys/tinybrains-dev.pem"
echo "  scripts/setup/qa-refresh.sh --yes --up            production's data, migrated, and the stack"
