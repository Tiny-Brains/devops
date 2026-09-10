#!/usr/bin/env bash
# Bring an existing LOCAL DEVELOPMENT volume up to the current schema, keeping the accounts.
#
#   scripts/dev/resync-dev-schema.sh
#
# The schema is pre-release: 0001_init.sql is rewritten in place rather than extended. But
# compose/db-init/ runs only on FIRST initialisation of the volume, so a stack that predates a
# rewrite runs the old tables -- which shows up as `relation "clocks" does not exist`, not as
# anything obvious.
#
# `docker compose down -v` is the honest answer and also throws away your GitHub sign-in. This does
# the same job carrying `users` and `sessions` across, by dumping them, dropping the schema,
# re-applying the migrations as they stand and re-running the seed -- so it needs no upkeep when
# 0001 changes again.
#
# DEVELOPMENT ONLY. It drops every table in the database.
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"
DB_NAME="${DB_NAME:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_DB)}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/tmp/tinybrains-resync-$STAMP.sql"

psql() { docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" "$@"; }

echo "==> checking this volume is safe to rebuild"
# Accounts and submissions can be recreated by signing in; a ladder cannot, and a volume holding
# one is not a scratch volume.
PLAYED=$(psql -tAc "
    SELECT coalesce((SELECT count(*) FROM ratings), 0)
         + coalesce((SELECT count(*) FROM matches), 0)" 2>/dev/null || echo 0)
if [ "${PLAYED:-0}" -gt 0 ]; then
    echo "REFUSING: this database holds $PLAYED match/rating rows." >&2
    echo "That is not a scratch volume. Back it up and drop the tables by hand if you meant it." >&2
    exit 1
fi

echo "==> saving accounts to $BACKUP"
# `games` is deliberately NOT carried across: the seed writes it with the engine-digest placeholder
# that pair refuses to insert without, and an older row would come back holding NULL.
docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" \
    --data-only --table=users --table=sessions --no-owner --no-privileges > "$BACKUP"
psql -tAc "SELECT '    ' || count(*) || ' users, ' ||
                  (SELECT count(*) FROM sessions) || ' sessions' FROM users"

echo "==> rebuilding the schema from soma/migrations"
psql -q -v ON_ERROR_STOP=1 -c "DROP SCHEMA public CASCADE" -c "CREATE SCHEMA public"
cat "$ROOT/soma/migrations/0001_init.sql" "$ROOT/soma/migrations/0002_sessions.sql" \
    | psql -q -v ON_ERROR_STOP=1
echo "    0001_init.sql, 0002_sessions.sql"

echo "==> seeding"
psql -q -v ON_ERROR_STOP=1 < "$ROOT/devops/compose/db-init/30-seed.sql"
echo "    the game, its engine-digest placeholder, three baselines and their ratings"

echo "==> restoring accounts"
# After the seed, so the baseline users are already in place.
psql -q -v ON_ERROR_STOP=1 < "$BACKUP"

psql -q <<'SQL'
\pset footer off
SELECT 'users' AS table, count(*) FROM users
UNION ALL SELECT 'sessions', count(*) FROM sessions
UNION ALL SELECT 'games', count(*) FROM games
UNION ALL SELECT 'models', count(*) FROM models
UNION ALL SELECT 'ratings', count(*) FROM ratings
UNION ALL SELECT 'clocks', count(*) FROM clocks;
SQL

echo "==> done. The dump is kept at $BACKUP in case something above went wrong."
echo "    The seed wrote the engine-digest placeholder and no manifest; declare both again:"
echo "        docker compose run --rm loader setup"
echo "    The cron clocks will pick up the new tables on their next tick; no restart needed."
