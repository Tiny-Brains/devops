#!/usr/bin/env bash
# Register the cartridge: write games.manifest and games.reference_observations.
#
#   devops/scripts/seed-cartridge.sh
#
# WHAT THIS IS. DESIGN.md §3 says a cartridge declares itself once, at registration, in seven keys.
# Layer 08 §8 gives that declaration a home -- `games.manifest` -- because admission reads two
# things out of it that are the GAME'S rather than the platform's: `budgets.adapter_ops_max`, the
# operation budget an adapter is validated under, and `budgets.flop_caps`, the FLOP ceiling per
# weight class. Putting them in Jodi's [vars] would make a second cartridge a config change; here
# a second cartridge is a plugin in Kalam's package plus a row in this table.
#
# And `games.reference_observations` is the fixture admission validates an adapter AGAINST. THE
# WORST CASE MUST BE IN IT or the gate is theatre: the operation budget is checked per call during
# a real match, so an adapter validated only against a small sample and then struck on every turn
# has been admitted by a check that did not test it. Layer 04 §3.6 states the requirement; this is
# what answers it.
#
# WHY A SCRIPT AND NOT db-init/30-seed.sql. The same reason engine-digest.sh is a script: the seed
# runs once, on first initialisation of the volume, and these two documents are generated from the
# cartridge repo and change with it. Re-running this is how a manifest change reaches a database
# that already exists.
#
# WHAT IS STILL OWED, AND IT IS THE HONEST GAP. The reference set below is ONE observation, taken
# from axon's test fixture -- a real worst-case Ants view (128x128, 90 ants, 670 water runs) dumped
# from the spike engine, and the measurement that raised adapter_ops_max to a million. It is enough
# to admit a model and not enough to call the gate finished. The proper form is a generator in
# ants/: run the engine on the largest preset to a busy turn from a committed seed, dump every live
# seat's view, and commit the result as ants/reference/observations.json. That is layer 05's item.
set -euo pipefail
cd "$(dirname "$0")/.."

DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"
DB_NAME="${DB_NAME:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_DB)}"

GAME="${GAME:-ants}"
MANIFEST="${MANIFEST:-../ants/cartridge.json}"
# Preferred once ants publishes it; the fixture is the fallback and the reason this script warns.
REFERENCE="${REFERENCE:-../ants/reference/observations.json}"
FALLBACK="${FALLBACK:-../axon/tests/fixtures/ants-observation.json}"

[ -r "$MANIFEST" ] || { echo "no manifest at $MANIFEST" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

if [ -r "$REFERENCE" ]; then
  cp "$REFERENCE" "$TMP/obs.json"
  echo "==> reference observations: $REFERENCE"
else
  # One observation, wrapped as the array the column holds.
  python3 -c "import json,sys; json.dump([json.load(open(sys.argv[1]))], open(sys.argv[2],'w'))" \
      "$FALLBACK" "$TMP/obs.json"
  echo "==> reference observations: $FALLBACK (ONE case -- ants/reference/observations.json is owed)"
fi

python3 - "$MANIFEST" "$TMP/obs.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
o = json.load(open(sys.argv[2]))
assert isinstance(o, list) and o, "the reference set must be a non-empty array of observations"
b = m.get("budgets", {})
assert b.get("adapter_ops_max"), "the manifest declares no budgets.adapter_ops_max"
assert b.get("flop_caps"), "the manifest declares no budgets.flop_caps"
print(f"    manifest: {m['game']} {m['version']}, "
      f"adapter_ops_max={b['adapter_ops_max']}, {len(b['flop_caps'])} flop caps")
print(f"    reference set: {len(o)} observation(s)")
PY

echo "==> writing games.manifest and games.reference_observations for '$GAME'"
# The two documents are passed as dollar-quoted literals in a generated statement rather than
# copied into the container: they are kilobytes, and quoting them once here beats a temp table and
# a COPY that has to be read back.
python3 - "$MANIFEST" "$TMP/obs.json" "$GAME" > "$TMP/seed.sql" <<'GEN'
import json, sys
manifest = json.dumps(json.load(open(sys.argv[1])), separators=(",", ":"))
obs      = json.dumps(json.load(open(sys.argv[2])), separators=(",", ":"))
game     = sys.argv[3]

def lit(s):                       # a dollar-quoted literal cannot be broken by the content
    assert "$tbjson$" not in s
    return "$tbjson$" + s + "$tbjson$"

print("UPDATE games SET manifest = " + lit(manifest) + "::jsonb,")
print("                 reference_observations = " + lit(obs) + "::jsonb")
print(" WHERE slug = " + lit(game) + ";")
print("SELECT slug, manifest -> 'budgets' ->> 'adapter_ops_max' AS adapter_ops_max,")
print("       jsonb_array_length(reference_observations) AS observations")
print("  FROM games WHERE slug = " + lit(game) + ";")
GEN
docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -q -v ON_ERROR_STOP=1 < "$TMP/seed.sql"
echo "==> registered"
