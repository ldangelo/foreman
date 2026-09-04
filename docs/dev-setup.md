# Foreman Dev Setup

## Starting After Reboot

```bash
# 1. Start postgres
docker start foreman-postgres

# 2. Verify it's up
docker exec foreman-postgres psql -U postgres -c '\l'

# 3. Start foreman server
cd /path/to/foreman
devbox run server
```

Server runs on `http://127.0.0.1:4766`. No `.env` needed — `dev.exs` defaults are correct.

## Database Names

- `foreman_dev` — application data (Ecto)
- `foreman_eventstore_dev` — event store (Commanded)

Both on `localhost:55432`, user `postgres`, password `postgres`.

## Beads DB Recovery

If `br` commands fail with `database disk image malformed`, run this as one
script (`set -euo pipefail`) — the ID-loss check below MUST abort the
procedure before the corrupt database is replaced. See
`skill://beads-corrupt-db-recovery-safe` for the full recipe and traps
(notably: never `br sync --import-only --rebuild` / `--force-jsonl` here —
that treats the JSONL as authoritative and can silently drop DB-only issues
that `.recover` still holds).

```bash
set -euo pipefail
cd /path/to/foreman

# Backup first
cp -R .beads /tmp/beads-backup-$(date +%s)

# Recover
cd .beads
sqlite3 beads.db ".recover" > /tmp/rec.sql
sqlite3 /tmp/rec.db < /tmp/rec.sql
sqlite3 /tmp/rec.db "pragma integrity_check;"   # must print "ok"

# CRITICAL: compare IDs before swapping — fail closed on any loss
sqlite3 /tmp/rec.db "select id from issues;" 2>/dev/null | tr '|' '\n' | sort > /tmp/rec_ids
sqlite3 beads.db "select id from issues;" 2>/dev/null | tr '|' '\n' | sort > /tmp/corrupt_ids
comm -23 /tmp/corrupt_ids /tmp/rec_ids > /tmp/lost_ids
lost_count=$(wc -l < /tmp/lost_ids | tr -d ' ')
echo "Lost from recovered DB: $lost_count"

if [ "$lost_count" -gt 0 ]; then
  missing=0
  while read -r id; do
    if grep -q "\"$id\"" issues.jsonl; then
      echo "$id in JSONL — must be restored via 'br sync --reconcile-additive' (or manual re-import) before proceeding"
    else
      echo "$id MISSING from both recovered DB and JSONL — unrecoverable"
      missing=$((missing + 1))
    fi
  done < /tmp/lost_ids
  echo "ABORTING: $lost_count issue(s) lost by .recover; resolve every one above before swapping in the recovered DB." >&2
  exit 1
fi

# Swap in recovered DB — only reached when the loss check above passed with zero losses
rm -f beads.db beads.db-shm beads.db-wal beads.db-wal-cert beads.db-wal-cert-head
cp /tmp/rec.db beads.db && chmod 600 beads.db

# Clean orphaned FK rows
sqlite3 beads.db "
  delete from events where issue_id is not null and issue_id not in (select id from issues);
  delete from export_hashes where issue_id is not null and issue_id not in (select id from issues);
  delete from capacity_occupancy where issue_id is not null and issue_id not in (select id from issues);
"

# Verify
br doctor
```

## Container Recovery (if foreman-postgres lost)

The container uses named volume `foreman-postgres-data` (stable across recreation).
Do NOT run `docker volume prune` — anonymous volumes may still hold data.

```bash
# Stop if running
docker stop foreman-postgres 2>/dev/null
docker rm foreman-postgres 2>/dev/null

# Start container (reuses existing named volume automatically)
docker run -d \
  --name foreman-postgres \
  -v foreman-postgres-data:/var/lib/postgresql/data \
  -p 55432:5432 \
  -e POSTGRES_PASSWORD=postgres \
  postgres:16
```
