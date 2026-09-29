#!/usr/bin/env bash
# The admin credential for every Orion in this stack.
#
#   scripts/setup/admin-key.sh [--force]
#
# Writes ORION_ADMIN_KEY into .env, read as `[admin_auth] api_keys` by Soma's instance config and by
# the Soma node's own package load, and attached by orion-ui behind the site's sign-in.
#
# Orion accepts either the key or `sha256:<64 hex>` of it, so a deployment keeps the digest in
# config and the key in its secret store; this prints the digest for that. It REPLACES rather than
# rotates, which is right for a dev stack and is not what a deployment should do -- `api_keys` is a
# list so the new key can sit beside the old while clients roll.
set -euo pipefail
cd "$(dirname "$0")/../.."

. "$(dirname "$0")/../lib.sh"
tb_paths

# WHICH DEPLOYMENT. Default this stack's .env; a second stack on the same machine passes its own
# (ENV_FILE=, or --env-file). Hard-coding `.env` here meant a caller aiming at another file
# silently rewrote THIS one.
ENV_FILE="${ENV_FILE:-$TB_WEB_ENV}"
FORCE=0
while true; do
  case "${1:-}" in
    --force)    FORCE=1; shift ;;
    --env-file) ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
    --env)      TB_ENV="${2:?--env needs dev, qa or prod}"; tb_paths; ENV_FILE="$TB_WEB_ENV"; shift 2 ;;
    *)          break ;;
  esac
done

command -v openssl > /dev/null || { echo "openssl is required" >&2; exit 1; }

digest_of() { printf '%s' "$1" | openssl dgst -sha256 -r | cut -d' ' -f1; }

touch "$ENV_FILE"
# A VALUE, not the name: .env.example declares ORION_ADMIN_KEY= blank, so a fresh copy has the name
# and nothing else, and matching the name alone kept every fresh install's key empty -- compose then
# refuses to start, pointing back at the init.sh that "already" made it.
if grep -Eq '^ORION_ADMIN_KEY=.+' "$ENV_FILE" && [ "$FORCE" = 0 ]; then
  existing=$(grep '^ORION_ADMIN_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2-)
  echo "$ENV_FILE already carries an admin key."
  echo "Replacing it locks out every client that still holds the old one until they are all"
  echo "restarted together, so that needs --force. For a real rotation, add the new key beside the"
  echo "old one in api_keys, roll the clients, then drop the old."
  echo
  echo "  digest form: sha256:$(digest_of "$existing")"
  exit 0
fi

# 64 hex characters. A plaintext entry must be at least 32; a production config refuses shorter.
KEY=$(openssl rand -hex 32)

if grep -q '^ORION_ADMIN_KEY=' "$ENV_FILE"; then
  # .env.example declares the name with no value, so a fresh .env has one to remove, not replace.
  if grep -Eq '^ORION_ADMIN_KEY=.+' "$ENV_FILE"; then
    echo "==> replaced the old ORION_ADMIN_KEY"
  fi
  # cat, not mv: $ENV_FILE may be a symlink into a deployment directory (see admin-user.sh).
  # `|| true`: grep -v exits 1 when every line matched, which set -e would take as a failure
  # halfway through a rewrite. An empty $tmp is the correct content in that case.
  tmp=$(mktemp); grep -v '^ORION_ADMIN_KEY=' "$ENV_FILE" > "$tmp" || true; cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
fi
printf 'ORION_ADMIN_KEY=%s\n' "$KEY" >> "$ENV_FILE"
echo "==> $ENV_FILE now carries ORION_ADMIN_KEY"
echo "    digest form, for a deployment that keeps no secret in config:"
echo "      sha256:$(digest_of "$KEY")"
echo
echo "Next:"
echo "  docker compose up -d --force-recreate soma orion-ui   # the node reloads its package itself"
echo
echo "The Orion UI on :8081 proxies to this admin plane and will ask for the key in the browser."
