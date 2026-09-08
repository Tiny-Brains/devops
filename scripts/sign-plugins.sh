#!/usr/bin/env bash
# Sign every plugin component in the workspace -- docs/deployment.md §11, tracker §3.4.
#
#   devops/scripts/sign-plugins.sh [path/to/key.pem]
#
# Writes `<component>.sig` beside each component: the detached Ed25519 signature, base64, over the
# DIGEST STRING `sha256:<64 hex>` -- the ASCII text, not the bytes it names. That is what Orion
# verifies (crates/orion-server/src/plugin/trust.rs), and it is why a release pipeline can sign
# without ever holding the component: the digest is the identity a generation, a trace and a
# package already carry.
#
# Each package's `load-package.sh` sends the `.sig` beside a component as the upload's `signature`
# field. No signature file means no field, which a node with keys refuses and a node without keys
# accepts -- the same posture Orion has.
#
# THE SIGNATURE IS NOT COMMITTED. The component is: `jodi/plugins/*/tb-*.wasm` and
# `kalam/plugins/tb-ants/tb-ants.wasm` are the artifacts, because the loader image has no Rust
# toolchain. The signature over one belongs to whoever built that release, so it is git-ignored and
# re-made here from whatever key this machine holds.
#
# Re-run it after `kalam/scripts/vendor-engine.sh`, after any plugin rebuild, and after
# `trust-keygen.sh --force`. A stale signature is not silent: it fails at load, naming the digest
# it does not verify over.
set -euo pipefail
cd "$(dirname "$0")/.."

KEY="${1:-${TB_SIGNING_KEY:-keys/tinybrains-dev.pem}}"
if [ ! -r "$KEY" ]; then
  echo "no signing key at $KEY -- run devops/scripts/trust-keygen.sh, or pass one" >&2
  exit 1
fi

command -v openssl > /dev/null || { echo "openssl is required" >&2; exit 1; }
command -v jq > /dev/null || { echo "jq is required" >&2; exit 1; }

echo "==> signing with $KEY"
echo "    public key $(openssl pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64)"

signed=0
# Every package that ships plugins. A package's plugin.json names its component; the digest is the
# hash of that file, which is exactly what the server recomputes on upload.
for manifest in ../jodi/plugins/*/plugin.json ../kalam/plugins/*/plugin.json; do
  [ -e "$manifest" ] || continue
  dir=$(dirname "$manifest")
  name=$(jq -r '.name' "$manifest")
  component="$dir/$(jq -r '.component' "$manifest")"
  if [ ! -r "$component" ]; then
    echo "  FAIL  $name names $component, which is not readable" >&2
    exit 1
  fi

  digest="sha256:$(shasum -a 256 "$component" | cut -d' ' -f1)"

  # The message is the digest string with NO trailing newline. `printf '%s'` rather than `echo`,
  # because one byte of difference is a signature that verifies nowhere and says only "does not
  # verify over sha256:..." when it fails.
  msg=$(mktemp)
  printf '%s' "$digest" > "$msg"
  sig=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$msg" | base64 | tr -d '\n')
  rm -f "$msg"

  if [ "$(printf '%s' "$sig" | base64 -d | wc -c | tr -d ' ')" != "64" ]; then
    echo "  FAIL  $name produced a signature that is not 64 bytes" >&2
    exit 1
  fi

  printf '%s\n' "$sig" > "$component.sig"
  echo "  ok    $name  ${digest:0:19}...  -> $(basename "$component").sig"
  signed=$((signed + 1))
done

[ "$signed" -gt 0 ] || { echo "no plugin components found -- is the workspace checked out beside devops/?" >&2; exit 1; }
echo "==> $signed component(s) signed"
