#!/usr/bin/env bash
# Assert what the config split put in two places.
#
#   scripts/check/configs.sh
#
# There are two instance templates and three values that live in both or are derived across the
# boundary. Each fails SILENTLY when it disagrees:
#
#   forfeit_strikes == strike_ceiling   count would judge a trial by a rule the wave did not play by
#   prior_mu / prior_sigma              two priors on one ladder
#   engine_digest is DERIVED            a literal is the one failure that is silent everywhere --
#                                       the wave claims nothing, for ever, and the replica looks
#                                       healthy doing it
#
# It also parses both templates through orion-server, so a config that would refuse to boot fails
# here instead of at 3am. That half needs the orion image; without docker it is skipped and said so.
#
# Exit 0 means both templates are consistent and parse.
set -uo pipefail
cd "$(dirname "$0")/../.."

SOMA=compose/orion/soma.toml.tmpl
KALAM=compose/orion/kalam.toml.tmpl
fail=0

ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1" >&2; fail=1; }
skip() { printf '  skip  %s\n' "$1"; }

for f in "$SOMA" "$KALAM"; do
  [ -r "$f" ] || { echo "missing $f" >&2; exit 1; }
done

# A [vars] scalar, as written. Not a TOML parse: these are templates with ${NAME:-default} in them,
# which no TOML reader accepts until orion-server has expanded them.
var() {  # $1 file, $2 key
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" "$1" \
    | head -1 | sed 's/[[:space:]]*#.*$//' | sed 's/[[:space:]]*$//'
}

echo "==> values that must agree across the split"

# ---- 1. the forfeit rule -----------------------------------------------------
# THIS USED TO BE AN EQUALITY and is now an absence, which is the stronger check. The ceiling is
# pinned onto matches.strike_ceiling by pair and read from the row by both the wave that applies it
# and the clock that judges its result, so there is no longer a second copy to keep in step. A
# `strike_ceiling` reappearing in Kalam's config is dead config that a future edit would wire back
# up, recreating exactly the hazard the column removed.
fs=$(var "$SOMA" forfeit_strikes)
sc=$(var "$KALAM" strike_ceiling)
if [ -z "$fs" ]; then
  bad "forfeit_strikes is missing from $SOMA -- it is pair's fallback when a season declares none, and matches.strike_ceiling is NOT NULL"
elif [ -n "$sc" ]; then
  bad "$KALAM still sets strike_ceiling = $sc -- Kalam reads the ceiling off the match row now, and a second copy is what the column exists to prevent"
else
  ok "forfeit_strikes = $fs in $SOMA only; Kalam reads matches.strike_ceiling"
fi

# ---- 2. the rating prior -----------------------------------------------------
# Both readers are in soma.toml.tmpl today; this compares against kalam.toml.tmpl only if it ever
# grows a copy, so the day it matters the check already exists.
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

# A baseline's first fold reads the prior as its own, so the seed must carry the same number.
# Anchored on the INSERT's own line rather than grepped loosely over the file: an unanchored match
# on "25.0" also matches 125.0, a comment, or a number that means something else entirely.
seed=compose/db-init/30-seed.sql
if [ -r "$seed" ]; then
  mu=$(var "$SOMA" prior_mu)
  if grep -qE "SELECT[^;]*, *${mu%.0}(\.[0-9]+)?, *[0-9]" "$seed" || grep -qE "^ *SELECT .*\b${mu}\b" "$seed"; then
    ok "prior_mu $mu is what $seed writes"
  else
    bad "prior_mu is $mu but $seed does not seed it -- a baseline's first fold would use another prior"
  fi
fi

# ---- 2b. the fallbacks a season's rules coalesce against ---------------------
# Every rule in seasons.rules is read `coalesce(rule, <var>)`, so "a season that declares nothing
# behaves exactly as the deploy does" is only true while the var it falls back to still exists.
# Deleting one "because it moved to the season" is how that quietly stops being true.
for k in burst steady_cap settled_sigma cross_class_fraction repair_cap presets \
         opset_min opset_max op_allowlist prior_mu prior_sigma sigma_inflation \
         ts_beta ts_tau ts_draw_probability; do
  if [ -z "$(var "$SOMA" "$k")" ]; then
    bad "$k is missing from $SOMA -- it is the fallback a season's rules coalesce against"
  fi
done
ok "every [vars] fallback a season rule coalesces against is present"

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
# An empty `public_keys` is not an error anywhere: the node loads whatever it is sent and says
# nothing. A posture that is on for one unit and off for the other is worse than off for both,
# because the unchecked node is the one nobody remembers.
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
# The same shape of silence as an empty trust list: the plane answers everyone and nothing says so.
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

# A shared `forbid` row makes the wave a fleet-wide singleton, so N-1 replicas idle while looking
# healthy (decision 41).
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

# The OUTER bound on a draining wave is shutdown_force_timeout_secs, not the cron key, because the
# cron worker is a supervised task. A force below the cron timeout silently caps the drain.
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

# Kalam used to vendor the cartridge, so two committed copies of one component existed and could
# drift -- and when they did NOTHING ERRORED: the ladder played a component ants does not ship, with
# a viewer built against the other. It happened once, from an edit that changed no behaviour at all.
#
# There is now ONE copy. kalam's artifact image takes the component from the cartridge's image, so
# the two cannot disagree by construction and there is nothing left to compare. What can still go
# wrong is a package volume left over from an older image, which is a different check: the digest
# the replicas derive against what the loader wrote onto the game row.
KALAM_VOL="${COMPOSE_PROJECT_NAME:-$(basename "$(cd .. && pwd)")}_kalam-pkg"
if command -v docker > /dev/null 2>&1 && docker volume inspect "$KALAM_VOL" > /dev/null 2>&1; then
  vol=$(docker run --rm -v "$KALAM_VOL":/pkg:ro busybox sha256sum /pkg/plugins/tb-ants/tb-ants.wasm 2>/dev/null | cut -d' ' -f1)
  img=$(docker run --rm "${ANTS_REF:-tinybrains/ants:dev}" sha256sum /artifacts/tb-ants.wasm 2>/dev/null | cut -d' ' -f1)
  if [ -z "$vol" ] || [ -z "$img" ]; then
    skip "engine volume (could not read one of the two)"
  elif [ "$vol" = "$img" ]; then
    ok "the package volume carries the engine ${ANTS_REF:-tinybrains/ants:dev} ships (${vol%${vol#????????}}...)"
  else
    bad "the kalam package volume is stale -- it is not the engine ${ANTS_REF:-tinybrains/ants:dev} ships
       image    sha256:$img
       volume   sha256:$vol
     docker compose build kalam-artifacts && docker compose run --rm --no-deps kalam-artifacts"
  fi
else
  skip "engine volume (no docker, or the stack has not been up: docker compose up -d)"
fi

if [ "$fail" -eq 0 ]; then
  echo "==> configs agree"
else
  echo "==> CONFIGS DISAGREE" >&2
fi
exit "$fail"
