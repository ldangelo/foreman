#!/usr/bin/env bash
set -e

hindsight_db="${HINDSIGHT_DB_NAME:-hindsight}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -c 'CREATE EXTENSION IF NOT EXISTS vector;'

if ! psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -tAc "SELECT 1 FROM pg_database WHERE datname = '${hindsight_db}'" | grep -q 1; then
  createdb --username "$POSTGRES_USER" "$hindsight_db"
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$hindsight_db" \
  -c 'CREATE EXTENSION IF NOT EXISTS vector;'
