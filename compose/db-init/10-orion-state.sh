#!/bin/bash
# Orion's own state -- channels, workflows, connectors, traces, audit -- is not Soma's data. Same
# server, separate database, so Soma's schema can be dropped without losing the loaded package.
# Runs once, on first initialisation of the volume.
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
    CREATE DATABASE orion_state OWNER $POSTGRES_USER;
SQL
