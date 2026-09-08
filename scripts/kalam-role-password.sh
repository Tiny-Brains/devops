#!/usr/bin/env bash
# Give the `kalam` role its password, on a database volume that already exists.
#
#   devops/scripts/kalam-role-password.sh          # from KALAM_DB_PASSWORD in .env
#
# Soma's migration creates the role with LOGIN and NO PASSWORD, deliberately: the credential is
# deployment configuration and a committed migration must ship no secret. Until it is set the role
# cannot log in, which is the safe default and also an obscure startup failure if you forget --
# Kalam's entrypoint gets "password authentication failed for user kalam".
#
# db-init/40-kalam-role.sh does this on a FRESH volume. This script is for the volume you already
# have, which db-init will never touch again.
set -euo pipefail
cd "$(dirname "$0")/.."

PW="${KALAM_DB_PASSWORD:-}"
if [ -z "$PW" ] && [ -r .env ]; then
  PW=$(grep -E '^KALAM_DB_PASSWORD=' .env | tail -1 | cut -d= -f2-)
fi
[ -n "$PW" ] || { echo "set KALAM_DB_PASSWORD in devops/.env" >&2; exit 1; }

DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"

# Through stdin rather than -c: psql expands :'var' in a script, not in a -c string, and a -c
# that looks right and is not expanded fails with a syntax error at the colon.
docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d postgres -q -v ON_ERROR_STOP=1 -v pw="$PW" <<'SQL'
ALTER ROLE kalam WITH LOGIN PASSWORD :'pw';
SQL
echo "==> the kalam role can log in"
