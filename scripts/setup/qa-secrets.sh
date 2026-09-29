#!/usr/bin/env bash
# The QA stack's five secrets, three minted here and two taken from production ON PURPOSE.
#
#   scripts/setup/qa-secrets.sh [--force]
#
# Writes into .env.qa, which docker-compose.qa.yml reads. Run it on the production machine, after
# `cp .env.qa.example .env.qa` and before scripts/setup/qa-db.sh.
#
#   ORION_ADMIN_KEY          minted, QA's own. 64 hex; production refuses a plaintext key under 32.
#   SOMA_SESSION_SECRET      minted, QA's own. A shared one would make a QA-issued session a
#                            credential production's node would also verify.
#   RUNNER_TOKEN_SECRET      minted, QA's own, and a DIFFERENT value from the session secret.
#
#   TB_TRUST_PUBLIC_KEY      COPIED from .env. One machine, one Ed25519 trust root: a signature
#                            belongs to whoever holds the key, not to a stack. The signatures
#                            themselves are not shared -- QA's images carry the candidate's engine,
#                            so they are signed into keys/signatures-qa/ (this script prints the
#                            command) and one directory holding two digests under
#                            `tb-ants.wasm.sig` is what sign-plugins.sh refuses by name.
#
#   RUNNER_GATE_DB_PASSWORD  COPIED from .env, and it MUST STAY COPIED.
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
# from .env.qa's comments, because each one is created in someone else's dashboard.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROD_ENV="${PROD_ENV:-prod/web/.env}"
QA_ENV="${QA_ENV:-qa/web/.env}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

command -v openssl > /dev/null || { echo "openssl is required" >&2; exit 1; }

[ -f "$QA_ENV" ] || {
  echo "no $QA_ENV -- start from the template:" >&2
  echo "  cp .env.qa.example $QA_ENV" >&2
  exit 1
}
[ -f "$PROD_ENV" ] || {
  echo "no $PROD_ENV -- this script runs ON THE PRODUCTION MACHINE, where .env is the live" >&2
  echo "deployment's environment. It reads the trust key and the gate password from it." >&2
  exit 1
}

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

# ---- the two that come from production ------------------------------------------------------------
TRUST=$(value_of TB_TRUST_PUBLIC_KEY "$PROD_ENV")
GATE=$(value_of RUNNER_GATE_DB_PASSWORD "$PROD_ENV")

[ -n "$TRUST" ] || { echo "$PROD_ENV carries no TB_TRUST_PUBLIC_KEY -- is this the production machine?" >&2; exit 1; }
[ -n "$GATE" ]  || { echo "$PROD_ENV carries no RUNNER_GATE_DB_PASSWORD -- is this the production machine?" >&2; exit 1; }

put TB_TRUST_PUBLIC_KEY "$TRUST"
put RUNNER_GATE_DB_PASSWORD "$GATE"
echo "==> copied from $PROD_ENV (both must match, see this script's header)"
echo "    TB_TRUST_PUBLIC_KEY      $TRUST"
echo "    RUNNER_GATE_DB_PASSWORD  ${GATE:0:4}... (the cluster-wide runner_gate role)"

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
echo "  SIG_OUT=keys/signatures-qa ENV_FILE=$QA_ENV scripts/setup/sign-plugins.sh"
echo "  docker compose -f docker-compose.qa.yml --env-file $QA_ENV up -d"
