#!/usr/bin/env bash
set -euo pipefail

compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "Docker Compose not found. Install Docker Desktop, Colima, or OrbStack and retry." >&2
    exit 1
  fi
}

wait_for_postgres() {
  local container="${POSTGRES_CONTAINER_NAME:-foreman-postgres}"
  local health="starting"

  for _ in $(seq 1 60); do
    health=$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo starting)
    echo "postgres health: $health"
    if [ "$health" = "healthy" ]; then
      return 0
    fi
    sleep 1
  done

  echo "Postgres did not become healthy in time." >&2
  return 1
}

ensure_hindsight_database() {
  if [ -n "${HINDSIGHT_API_DATABASE_URL:-}" ]; then
    return 0
  fi

  local user="${POSTGRES_USER:-postgres}"
  local foreman_db="${POSTGRES_DB:-foreman}"
  local hindsight_db="${HINDSIGHT_DB_NAME:-hindsight}"

  compose exec -T postgres psql -U "$user" -d "$foreman_db" -v ON_ERROR_STOP=1 \
    -c 'CREATE EXTENSION IF NOT EXISTS vector;'

  if ! compose exec -T postgres psql -U "$user" -d "$foreman_db" -tAc "SELECT 1 FROM pg_database WHERE datname = '${hindsight_db}'" | grep -q 1; then
    compose exec -T postgres createdb -U "$user" "$hindsight_db"
  fi

  compose exec -T postgres psql -U "$user" -d "$hindsight_db" -v ON_ERROR_STOP=1 \
    -c 'CREATE EXTENSION IF NOT EXISTS vector;'
}

services=("$@")
if [ "${#services[@]}" -eq 0 ] || [ "${services[0]}" = "all" ]; then
  services=(postgres hindsight)
fi

compose up -d "${services[@]}"
wait_for_postgres
ensure_hindsight_database
