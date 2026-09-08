#!/usr/bin/env bash
# The trust root for plugin components -- docs/deployment.md §11, tracker §3.4.
#
#   devops/scripts/trust-keygen.sh [--force]
#
# Makes the Ed25519 key pair this stack signs plugin components with, and tells the instance
# configs about its public half. Run it once per machine; `sign-plugins.sh` uses what it writes.
#
# WHAT ORION ACTUALLY CHECKS (crates/orion-server/src/plugin/trust.rs). `[plugins.trust]
# public_keys` is a list of raw 32-byte Ed25519 public keys, base64. When it is NON-EMPTY every
# plugin upload must carry a detached signature over **the digest string** -- the ASCII of
# `sha256:<64 hex>`, not the component bytes -- and it is verified twice: when the upload arrives,
# and again by every node that loads the version. So a plugin row that reached the state database
# by some other path (an import, a peer's activation) is still checked by the node that runs it.
# With no keys configured nothing is checked and any signature, or none, passes.
#
# WHY THE PRIVATE HALF IS NOT IN THE REPOSITORY. The signature is a release artifact: whoever holds
# the key signs, and the server only ever verifies -- it has no signing path at all. A key committed
# beside the thing it signs proves nothing, so this writes it to `devops/keys/`, which is ignored,
# and a deployment uses its own key from its orchestrator's secret store. That is also why
# `*.wasm.sig` is ignored in `jodi/` and `kalam/`: the committed artifact is the component, and the
# signature over it belongs to whoever built the release.
#
# WHAT IT WRITES
#   devops/keys/tinybrains-dev.pem        the private key, mode 0600, git-ignored
#   devops/.env  TB_TRUST_PUBLIC_KEY=...  the public half, which both instance configs read
#
# Overwriting an existing key orphans every signature made with it -- every plugin would then be
# refused at load, on a node that looks healthy -- so that needs --force and says so.
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_DIR=keys
KEY="$KEY_DIR/tinybrains-dev.pem"
ENV_FILE=.env
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

command -v openssl > /dev/null || { echo "openssl is required" >&2; exit 1; }
# LibreSSL's openssl(1) -- what macOS ships as /usr/bin/openssl -- has no `pkeyutl -rawin`, which is
# how an Ed25519 signature over a message rather than a hash is made. Check now, with the fix.
if ! openssl genpkey -algorithm ed25519 -out /dev/null 2>/dev/null; then
  echo "this openssl does not do Ed25519 -- on macOS, 'brew install openssl' and put it first" >&2
  exit 1
fi

if [ -f "$KEY" ] && [ "$FORCE" = 0 ]; then
  echo "$KEY already exists."
  echo "Re-generating orphans every signature made with it: each plugin would be refused at load,"
  echo "on a node whose /health says ok. Pass --force only if you will re-run sign-plugins.sh and"
  echo "reload every package afterwards."
  echo
  echo "  TB_TRUST_PUBLIC_KEY=$(openssl pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64)"
  exit 0
fi

mkdir -p "$KEY_DIR"
openssl genpkey -algorithm ed25519 -out "$KEY"
chmod 600 "$KEY"
echo "==> wrote $KEY (mode 600, git-ignored)"

# The public half as Orion wants it: the RAW 32 bytes, base64. `-pubout -outform DER` is a
# SubjectPublicKeyInfo whose last 32 bytes are the key itself -- Ed25519's SPKI header is a fixed
# 12 bytes, so the tail is exact rather than a guess.
PUB=$(openssl pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64)
if [ "$(printf '%s' "$PUB" | base64 -d | wc -c | tr -d ' ')" != "32" ]; then
  echo "the extracted public key is not 32 bytes -- refusing to write it" >&2
  exit 1
fi
echo "==> public key $PUB"

touch "$ENV_FILE"
if grep -q '^TB_TRUST_PUBLIC_KEY=' "$ENV_FILE"; then
  tmp=$(mktemp)
  grep -v '^TB_TRUST_PUBLIC_KEY=' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
  echo "    replaced the old TB_TRUST_PUBLIC_KEY in $ENV_FILE"
fi
printf 'TB_TRUST_PUBLIC_KEY=%s\n' "$PUB" >> "$ENV_FILE"
echo "==> $ENV_FILE now carries TB_TRUST_PUBLIC_KEY"
echo
echo "Next:"
echo "  devops/scripts/sign-plugins.sh          sign every plugin component with this key"
echo "  docker compose up -d --force-recreate soma kalam-1   pick up the new config"
echo "  docker compose run --rm loader load     re-upload the packages, now with signatures"
