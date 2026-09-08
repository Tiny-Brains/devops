#!/usr/bin/env bash
# The admin credential for every Orion in this stack -- docs/deployment.md §11.
#
#   devops/scripts/admin-key.sh [--force]
#
# The admin API installs channels, workflows, connectors and plugins, and reads and writes
# connector secrets. It is the trust root for putting anything into a server -- which is why the
# plugin signature above it is described as a check that survives the upload rather than a second
# principal. Locally every admin port is bound to 127.0.0.1; the moment a loader has to reach a
# replica across a network, an unauthenticated admin plane is the whole game.
#
# WHAT IT WRITES
#   devops/.env  ORION_ADMIN_KEY=<64 hex>
#
# One variable, read in two places: `[admin_auth] api_keys` in both instance configs, and
# ORION_ADMIN_API_KEY for the loader and the three packages' load-package.sh, which have taken it
# since they were written.
#
# A DEPLOYMENT DOES NOT HAVE TO KEEP THE SECRET IN CONFIG. Orion accepts either the key or
# `sha256:<64 hex>` of it in `api_keys`, so config at rest can hold the digest while the
# orchestrator's secret store holds the key. This script prints the digest for that.
#
# Rotation is why `api_keys` is a list: add the new key beside the old, roll every client, then
# drop the old one. This script replaces rather than rotates, which is right for a dev stack and
# is not what a deployment should do.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=.env
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

command -v openssl > /dev/null || { echo "openssl is required" >&2; exit 1; }

touch "$ENV_FILE"
if grep -q '^ORION_ADMIN_KEY=' "$ENV_FILE" && [ "$FORCE" = 0 ]; then
  existing=$(grep '^ORION_ADMIN_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2-)
  echo "$ENV_FILE already carries an admin key."
  echo "Replacing it locks out every client that still holds the old one until they are all"
  echo "restarted together, so that needs --force. For a real rotation, add the new key beside the"
  echo "old one in api_keys, roll the clients, then drop the old -- which is what the list is for."
  echo
  echo "  digest form: sha256:$(printf '%s' "$existing" | openssl dgst -sha256 -r | cut -d' ' -f1)"
  exit 0
fi

# 64 hex characters. The floor for a plaintext entry is 32; a production config refuses shorter.
KEY=$(openssl rand -hex 32)
DIGEST="sha256:$(printf '%s' "$KEY" | openssl dgst -sha256 -r | cut -d' ' -f1)"

if grep -q '^ORION_ADMIN_KEY=' "$ENV_FILE"; then
  tmp=$(mktemp); grep -v '^ORION_ADMIN_KEY=' "$ENV_FILE" > "$tmp"; mv "$tmp" "$ENV_FILE"
  echo "==> replaced the old ORION_ADMIN_KEY"
fi
printf 'ORION_ADMIN_KEY=%s\n' "$KEY" >> "$ENV_FILE"
echo "==> $ENV_FILE now carries ORION_ADMIN_KEY"
echo "    digest form, for a deployment that keeps no secret in config:"
echo "      $DIGEST"
echo
echo "Next:"
echo "  docker compose --profile fleet up -d --force-recreate soma kalam-1 kalam-2"
echo "  docker compose run --rm loader load"
echo
echo "The Orion UI on :8081 proxies to this admin plane and will ask for the key in the browser."
