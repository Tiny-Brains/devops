#!/usr/bin/env bash
# Assert what the config split put in two places -- docs/deployment.md §3.
#
# Until docs/deployment.md there was one orion.toml.tmpl and one [vars] block, so a value two packages had to
# agree on agreed by being written once. There are now two templates, and three values live in both
# or are derived across the boundary. Each one fails SILENTLY when it disagrees:
#
#   forfeit_strikes == strike_ceiling   count would judge a trial by a rule the wave did not play
#                                       by -- a seat forfeits at 5 strikes and count expects 3, and
#                                       nothing anywhere says so
#   prior_mu / prior_sigma              two priors on one ladder. SAFE TODAY, because both readers
#                                       are in soma.toml.tmpl -- the check is here for the day Soma
#                                       gets a server of its own, which is the split this whole
#                                       topology exists to make cheap (docs/deployment.md §16.4)
#   engine_digest is DERIVED            a literal digest in kalam.toml.tmpl is the one failure that
#                                       is silent everywhere: the wave claims nothing, for ever,
#                                       and the replica looks healthy doing it
#
# It also parses both templates through orion-server, so a config that would refuse to boot fails
# here instead of at 3am. That half needs the orion image; without docker it is skipped and said so.
#
#   devops/scripts/check-configs.sh
#
# Exit 0 means both templates are consistent and parse. Run it before shipping a config change.
set -uo pipefail
cd "$(dirname "$0")/.."

SOMA=orion/soma.toml.tmpl
KALAM=orion/kalam.toml.tmpl
fail=0

ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1" >&2; fail=1; }
skip() { printf '  skip  %s\n' "$1"; }

for f in "$SOMA" "$KALAM"; do
  [ -r "$f" ] || { echo "missing $f" >&2; exit 1; }
done

# A [vars] scalar, as written. Deliberately not a TOML parse: these files are templates with
# ${NAME:-default} substitutions in them, which no TOML reader will accept until orion-server has
# expanded them. Matching the literal is what a reader does, and what a reviewer checks.
var() {  # $1 file, $2 key
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" "$1" \
    | head -1 | sed 's/[[:space:]]*#.*$//' | sed 's/[[:space:]]*$//'
}

echo "==> values that must agree across the split"

# ---- 1. the forfeit rule -----------------------------------------------------
fs=$(var "$SOMA" forfeit_strikes)
sc=$(var "$KALAM" strike_ceiling)
if [ -z "$fs" ] || [ -z "$sc" ]; then
  bad "forfeit_strikes ($SOMA) / strike_ceiling ($KALAM): one of them is missing"
elif [ "$fs" != "$sc" ]; then
  bad "forfeit_strikes = $fs but strike_ceiling = $sc -- count would judge by a rule the wave did not play by"
else
  ok "forfeit_strikes == strike_ceiling == $fs"
fi

# ---- 2. the rating prior -----------------------------------------------------
# Both readers are in soma.toml.tmpl today, so this asserts the pair is present and internally
# consistent, and compares against kalam.toml.tmpl only if it ever grows a copy. Written now so
# that the day it matters the check already exists rather than being remembered.
for k in prior_mu prior_sigma; do
  a=$(var "$SOMA" "$k"); b=$(var "$KALAM" "$k")
  if [ -z "$a" ]; then
    bad "$k is missing from $SOMA"
  elif [ -n "$b" ] && [ "$a" != "$b" ]; then
    bad "$k = $a in $SOMA but $b in $KALAM -- two priors on one ladder"
  elif [ -n "$b" ]; then
    ok "$k == $a in both"
  else
    ok "$k = $a (soma only, as expected while Soma and Jodi share a config)"
  fi
done

# The seed gives the baselines their prior, and a baseline's first fold reads [vars] as its own.
seed=db-init/30-seed.sql
if [ -r "$seed" ]; then
  mu=$(var "$SOMA" prior_mu)
  if grep -q "$mu" "$seed"; then
    ok "prior_mu $mu appears in $seed"
  else
    bad "prior_mu is $mu but $seed does not mention it -- a baseline's first fold would use another prior"
  fi
fi

# ---- 3. the engine digest is derived, never typed ----------------------------
ed=$(var "$KALAM" engine_digest)
case "$ed" in
  '"${KALAM_ENGINE_DIGEST}"')
    ok "engine_digest is the derived substitution, not a literal" ;;
  *sha256:*)
    bad "engine_digest is a literal ($ed) -- it must be \${KALAM_ENGINE_DIGEST}, derived from the vendored wasm. A pinned digest that disagrees makes the wave claim nothing, for ever" ;;
  *)
    bad "engine_digest is $ed -- expected \"\${KALAM_ENGINE_DIGEST}\"" ;;
esac

# ---- 4. neither unit is left unchecked ---------------------------------------
# `[plugins.trust] public_keys` empty is not an error anywhere: the node loads whatever it is sent
# and says nothing. A trust posture that is on for one unit and off for the other is worse than one
# that is off for both, because the unchecked node is the one nobody remembers. docs/deployment.md §11.
for f in "$SOMA" "$KALAM"; do
  keys=$(grep -A1 '^\[plugins\.trust\]' "$f" | grep '^public_keys' | cut -d= -f2- | tr -d ' ')
  case "$keys" in
    '[]'|'')
      bad "$f has no plugins.trust.public_keys -- that node verifies no signature and reports nothing about it" ;;
    *'${TB_TRUST_PUBLIC_KEY}'*)
      ok "$f trusts \${TB_TRUST_PUBLIC_KEY}" ;;
    *)
      bad "$f pins a literal trust key ($keys) -- it must be \${TB_TRUST_PUBLIC_KEY}, so a deployment sets its own from a secret store" ;;
  esac
done

# ---- 5. the admin plane is not open -------------------------------------------
# `admin_auth.enabled = false` is the same shape of silence as an empty trust list: the plane
# answers everyone and nothing says so. docs/deployment.md §11 gates it on "before anything is reachable off
# loopback", which is a date nobody notices passing.
for f in "$SOMA" "$KALAM"; do
  if ! grep -q '^\[admin_auth\]' "$f"; then
    bad "$f has no [admin_auth] block -- its admin plane installs anything anyone asks it to"
  elif grep -A2 '^\[admin_auth\]' "$f" | grep -q '^enabled = true'; then
    ok "$f enables admin_auth"
  else
    bad "$f has [admin_auth] but does not enable it"
  fi
done

echo "==> the split itself"

# Kalam must not be in cluster mode (decision 41): a shared `forbid` row makes the wave a
# fleet-wide singleton and N-1 replicas idle while looking healthy.
if grep -q '^\[cluster\]' "$KALAM"; then
  bad "$KALAM has a [cluster] block -- decision 41: a replica must be its own scheduler, or exactly one replica ever plays"
else
  ok "kalam has no [cluster] block"
fi

# Soma must be, for the mirror-image reason.
if grep -q '^\[cluster\]' "$SOMA"; then
  ok "soma is in cluster mode"
else
  bad "$SOMA has no [cluster] block -- Jodi's clocks are cluster-wide singletons only when the state database is shared"
fi

# A cluster may not migrate at boot; entrypoint.sh runs `migrate` as the deploy step.
if grep -qE '^[[:space:]]*auto_migrate[[:space:]]*=[[:space:]]*false' "$SOMA"; then
  ok "soma sets auto_migrate = false"
else
  bad "$SOMA must set auto_migrate = false -- cluster.enabled with auto_migrate is refused at startup"
fi

# docs/deployment.md §6.1: the OUTER bound on a draining wave is shutdown_force_timeout_secs, not the cron
# key, because the cron worker is a supervised task. A force below the cron timeout silently caps
# the drain -- which is exactly the 30 s the build measured and mis-explained.
kf=$(var "$KALAM" shutdown_force_timeout_secs); kf=${kf##*:-}; kf=${kf%\}}
kc=$(var "$KALAM" shutdown_timeout_secs);       kc=${kc##*:-}; kc=${kc%\}}
if [ -n "$kf" ] && [ -n "$kc" ] && [ "$kf" -ge "$kc" ] 2>/dev/null; then
  ok "kalam drain: force ${kf}s >= cron ${kc}s, so the cron deadline is the one that bites"
else
  bad "kalam shutdown_force_timeout_secs (${kf:-?}) is below cron.shutdown_timeout_secs (${kc:-?}) -- the force key is the OUTER deadline, so the wave would be cut at ${kf:-?}s whatever cron says (docs/deployment.md §6.1)"
fi

echo "==> both templates parse"
if command -v docker > /dev/null 2>&1 && docker image inspect tinybrains-soma > /dev/null 2>&1; then
  for f in "$SOMA" "$KALAM"; do
    if docker run --rm --entrypoint orion-server \
         -e ORION_STATE_DB_URL=postgres://u:p@db:5432/orion_state \
         -e REDIS_URL=redis://redis:6379 \
         -e KALAM_ENGINE_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000 \
         -e R2_ENDPOINT=http://minio:9000 \
         -e TB_TRUST_PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
         -e ORION_ADMIN_KEY=0000000000000000000000000000000000000000000000000000000000000000 \
         -v "$PWD/$f:/tmp/c.toml:ro" tinybrains-soma -c /tmp/c.toml validate-config > /dev/null 2>&1; then
      ok "$f parses"
    else
      bad "$f does not parse -- run the same command without >/dev/null to see why"
    fi
  done
else
  skip "orion-server parse (no docker, or the image is not built yet: docker compose build soma)"
fi

if [ "$fail" -eq 0 ]; then
  echo "==> configs agree"
else
  echo "==> CONFIGS DISAGREE" >&2
fi
exit "$fail"
