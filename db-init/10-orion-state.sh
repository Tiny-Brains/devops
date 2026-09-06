#!/bin/bash
# Orion keeps its own state -- channels, workflows, connectors, traces, audit -- and
# that is not Soma's data. Same server here, separate database, so a `psql -d soma`
# never shows engine tables and Soma's schema can be dropped without losing the
# loaded package.
#
# Runs once, on first initialisation of the postgres volume.
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
    CREATE DATABASE orion_state OWNER $POSTGRES_USER;
SQL
