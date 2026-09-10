#!/usr/bin/env bash
# Sign every plugin component this deployment will load.
#
#   scripts/setup/sign-plugins.sh [path/to/key.pem]
#
# Writes `<component>.sig` into `keys/signatures/`: the detached Ed25519 signature, base64, over the
# DIGEST STRING `sha256:<64 hex>` -- the ASCII text, not the bytes it names. That is what Orion
# verifies, and it is why a release pipeline can sign without ever holding the component.
#
# WHY A DIRECTORY OF OUR OWN, RATHER THAN A FILE BESIDE EACH COMPONENT. A signature is deployment
# state: it belongs to whoever holds the trust key, not to the package. This script used to write
# into ../jodi and ../kalam -- one repository reaching into another's working tree -- which stopped
# being possible when a package became an immutable image several deployments can share. Each
# package's `load-package.sh` now reads `PLUGIN_SIG_DIR`, which compose points here.
#
# WHERE THE COMPONENTS COME FROM. Every package that ships plugins now ships as an artifact image,
# so components are read out of the volume its `-artifacts` one-shot populated -- never a checkout.
# `from_checkout` is kept for a package that has not been converted; a source that is not there is
# skipped rather than fatal. Bring the stack up before signing, or there is nothing to sign.
#
# Re-run after any plugin or engine rebuild, and after trust-keygen.sh --force. A stale signature is
# not silent: it fails at load, naming the digest it does not verify over.
set -euo pipefail
cd "$(dirname "$0")/../.."

KEY="${1:-${TB_SIGNING_KEY:-keys/tinybrains-dev.pem}}"
if [ ! -r "$KEY" ]; then
  echo "no signing key at $KEY -- run scripts/setup/trust-keygen.sh, or pass one" >&2
  exit 1
fi

command -v openssl > /dev/null || { echo "openssl is required" >&2; exit 1; }
command -v jq > /dev/null || { echo "jq is required" >&2; exit 1; }
command -v docker > /dev/null || { echo "docker is required, to read the package volumes" >&2; exit 1; }

OUT=keys/signatures
mkdir -p "$OUT"

echo "==> signing with $KEY"
echo "    public key $(openssl pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64)"
echo "    into $OUT/"

# Compose derives its project name from the parent directory; a volume is <project>_<name>.
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$(cd .. && pwd)")}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A converted package: copy its plugins out of the volume the artifact image populated.
from_volume() {
  local name="$1" vol="${PROJECT}_$2"
  docker volume inspect "$vol" > /dev/null 2>&1 || { echo "    skip  $name (no volume $vol yet -- docker compose up ${name}-artifacts)"; return 1; }
  mkdir -p "$work/$name"
  docker run --rm -v "$vol":/pkg:ro -v "$work/$name":/out busybox \
    sh -c 'cp -a /pkg/plugins/. /out/ 2>/dev/null || true'
  [ -n "$(ls -A "$work/$name" 2>/dev/null)" ] || { echo "    skip  $name (volume $vol carries no plugins)"; return 1; }
  echo "$work/$name"
}

# An unconverted package: still a sibling checkout with its components committed.
from_checkout() {
  local name="$1" dir="$2"
  [ -d "$dir/plugins" ] || { echo "    skip  $name (no $dir/plugins)"; return 1; }
  echo "$dir/plugins"
}

sign_one() {
  local manifest="$1"
  local dir name component digest msg sig
  dir=$(dirname "$manifest")
  name=$(jq -r '.name' "$manifest")
  component="$dir/$(jq -r '.component' "$manifest")"
  if [ ! -r "$component" ]; then
    echo "  FAIL  $name names $(basename "$component"), which is not readable" >&2
    exit 1
  fi

  digest="sha256:$(shasum -a 256 "$component" | cut -d' ' -f1)"

  # The message is the digest string with NO trailing newline: one byte of difference is a
  # signature that verifies nowhere.
  msg=$(mktemp)
  printf '%s' "$digest" > "$msg"
  sig=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$msg" | base64 | tr -d '\n')
  rm -f "$msg"

  if [ "$(printf '%s' "$sig" | base64 -d | wc -c | tr -d ' ')" != "64" ]; then
    echo "  FAIL  $name produced a signature that is not 64 bytes" >&2
    exit 1
  fi

  printf '%s\n' "$sig" > "$OUT/$(basename "$component").sig"
  echo "  ok    $name  ${digest:0:19}...  -> $(basename "$component").sig"
  signed=$((signed + 1))
}

signed=0
for spec in "jodi:volume:jodi-pkg" "kalam:volume:kalam-pkg"; do
  pkg=${spec%%:*}; rest=${spec#*:}; kind=${rest%%:*}; where=${rest#*:}
  case "$kind" in
    volume)   root=$(from_volume   "$pkg" "$where") || continue ;;
    checkout) root=$(from_checkout "$pkg" "$where") || continue ;;
  esac
  for manifest in "$root"/*/plugin.json; do
    [ -e "$manifest" ] || continue
    sign_one "$manifest"
  done
done

[ "$signed" -gt 0 ] || { echo "no plugin components found -- bring the package volumes up first" >&2; exit 1; }
echo "==> $signed component(s) signed into $OUT/"
