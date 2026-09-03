# Foreman Dev Setup

## Starting After Reboot / Container Stop

```bash
# 1. Start postgres
docker start foreman-postgres

# 2. Verify it's up
docker exec foreman-postgres psql -U postgres -c '\l'

# 3. Start foreman server
cd /Users/ldangelo/Development/Fortium/foreman
devbox run server
```

Server runs on `http://127.0.0.1:4766`. No `.env` needed — `dev.exs` defaults are correct.

## Database Names

- `foreman_dev` — application data (Ecto)
- `foreman_eventstore_dev` — event store (Commanded)

Both on `localhost:55432`, user `postgres`, password `postgres`.

## Beads DB Recovery

If `br` commands fail with `database disk image malformed`:

```bash
cd /Users/ldangelo/Development/Fortium/foreman

# Backup first
cp -R .beads /tmp/beads-backup-$(date +%s)

# Recover
cd .beads
sqlite3 beads.db ".recover" > /tmp/rec.sql
sqlite3 /tmp/rec.db < /tmp/rec.sql
rm beads.db beads.db-shm beads.db-wal beads.db-wal-cert beads.db-wal-cert-head
cp /tmp/rec.db beads.db && chmod 600 beads.db

# Clean orphaned FK rows
sqlite3 beads.db "pragma foreign_key_check;"
sqlite3 beads.db "
  delete from events where issue_id is not null and issue_id not in (select id from issues);
  delete from export_hashes where issue_id is not null and issue_id not in (select id from issues);
  delete from capacity_occupancy where issue_id is not null and issue_id not in (select id from issues);
"

# Verify
br doctor
```

## Container Recovery (if foreman-postgres lost)

If the `foreman-postgres` container is gone and `docker start` fails:

1. Find the correct volume: `docker volume ls -f dangling=true` — look for one with `base` subdirectory containing PostgreSQL data
2. Recreate with stable named volume:

```bash
# Stop if running
docker stop foreman-postgres 2>/dev/null
docker rm foreman-postgres 2>/dev/null

# Create stable named volume (preserves data across container recreation)
docker volume create foreman-postgres-data

# Start container with named volume
docker run -d \
  --name foreman-postgres \
  -v foreman-postgres-data:/var/lib/postgresql/data \
  -p 55432:5432 \
  -e POSTGRES_PASSWORD=postgres \
  postgres:16
```
