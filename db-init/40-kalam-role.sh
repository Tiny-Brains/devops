#!/bin/sh
# Give the `kalam` role its password. Runs once, on first initialisation of the volume, after
# 20-soma-schema.sql has created the role.
#
# The role is created by the migration with LOGIN and no password, so that the committed migration
# ships no secret; the credential is deployment configuration and this is the deployment repo.
# Without this the role exists and cannot log in, and Kalam fails at startup with "password
# authentication failed for user kalam".
#
# For a volume that already exists, db-init never runs again: use scripts/kalam-role-password.sh.
set -eu
: "${KALAM_DB_PASSWORD:?KALAM_DB_PASSWORD is required -- see .env.example}"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v pw="$KALAM_DB_PASSWORD" \
     -c "ALTER ROLE kalam WITH LOGIN PASSWORD :'pw'"
