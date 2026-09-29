#!/usr/bin/env bash
# Make a GitHub account an admin of this deployment, by its GitHub id, as `github:<id>`.
#
#   scripts/setup/admin-user.sh <github-login>            # look the id up and add it to .env
#   scripts/setup/admin-user.sh --print <github-login>    # print it only, for a deployment's own secrets
#   scripts/setup/admin-user.sh --env-file qa/web/.env <login>   # a second stack on this machine
#
# WHY THE ID. Soma makes an account an admin at sign-in when its identity's `provider:subject` is in
# SOMA_ADMIN_IDS. A login is the wrong key: a provider frees a renamed login for anyone to register, so
# a list of logins hands the platform to whoever takes yours after you rename. A subject never changes
# and is never reused, so the login is looked up once, here, and only `github:<id>` is kept. (Another
# provider's admin is added to SOMA_ADMIN_IDS by hand, as `<provider>:<subject>`.)
#
# The id is not a secret, but it lives in .env, which is never committed; a deployment sets the same
# variable in its own environment. Several ids are comma-separated, and this adds to what is there.
# Everyone else is made an admin by an admin, on the site's Users admin page.
set -euo pipefail
cd "$(dirname "$0")/../.."

. "$(dirname "$0")/../lib.sh"
tb_paths

# WHICH DEPLOYMENT. The default is this stack's .env; a second stack on the same machine (the QA
# one, README *A QA stack beside production*) passes its own, and its admin list is its own.
ENV_FILE="${ENV_FILE:-$TB_WEB_ENV}"
PRINT=0
while true; do
  case "${1:-}" in
    --print)    PRINT=1; shift ;;
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    --env)      TB_ENV="${2:?--env needs dev, qa or prod}"; tb_paths; ENV_FILE="$TB_WEB_ENV"; shift 2 ;;
    *)          break ;;
  esac
done
LOGIN="${1:?usage: $0 [--print] [--env-file <path>] <github-login>}"
[ "$PRINT" = 1 ] || [ -f "$ENV_FILE" ] || { echo "no $ENV_FILE to add an admin to" >&2; exit 1; }
API="${GITHUB_API_BASE:-https://api.github.com}"

# GitHub's own rule: letters, digits and single hyphens, at most 39 characters.
printf '%s' "$LOGIN" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$' \
  || { echo "'$LOGIN' is not a GitHub login" >&2; exit 2; }

body=$(curl -fsS -H 'Accept: application/vnd.github+json' "$API/users/$LOGIN") \
  || { echo "GitHub has no user '$LOGIN' (or $API is unreachable)" >&2; exit 1; }
read -r ID KIND WHO < <(printf '%s' "$body" | python3 -c '
import json, sys
u = json.load(sys.stdin)
print(u.get("id", ""), u.get("type", ""), u.get("login", "") + (" (" + u["name"] + ")" if u.get("name") else ""))')
[ -n "$ID" ] || { echo "GitHub answered without an id for '$LOGIN'" >&2; exit 1; }
# An organisation has an id too, and nobody can sign in as one.
[ "$KIND" = "User" ] || { echo "'$LOGIN' is a GitHub $KIND, not a user: nobody signs in as one" >&2; exit 1; }

echo "==> $WHO is GitHub id $ID"
ENTRY="github:$ID"
if [ "$PRINT" = 1 ]; then
  echo "    add '$ENTRY' to SOMA_ADMIN_IDS in the Soma service's environment (comma-separated)"
  exit 0
fi

touch "$ENV_FILE"
have=$(grep '^SOMA_ADMIN_IDS=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d ' ' || true)
case ",$have," in
  *",$ENTRY,"*) echo "    already in $ENV_FILE"; exit 0 ;;
esac
list="${have:+$have,}$ENTRY"
if grep -q '^SOMA_ADMIN_IDS=' "$ENV_FILE"; then
  tmp=$(mktemp)
  # THROUGH the path, not over it: $ENV_FILE may be a symlink into a deployment's own directory,
  # and `mv` would replace the link with a copy that then drifts.
  sed "s|^SOMA_ADMIN_IDS=.*|SOMA_ADMIN_IDS=$list|" "$ENV_FILE" > "$tmp" && cat "$tmp" > "$ENV_FILE" && rm -f "$tmp"
else
  printf 'SOMA_ADMIN_IDS=%s\n' "$list" >> "$ENV_FILE"
fi
echo "==> $ENV_FILE: SOMA_ADMIN_IDS=$list"
echo
echo "Next: docker compose up -d soma, then sign in at http://localhost:5173 -- the role is written at"
echo "sign-in, so a session from before this needs signing out and in again."
