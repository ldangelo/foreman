# Foreman Dev Setup

## Starting After Reboot

```bash
# 1. Start postgres
docker start foreman-postgres

# 2. Wait for it to accept connections, then verify
for i in $(seq 1 30); do
  docker exec foreman-postgres pg_isready -U postgres >/dev/null 2>&1 && break
  [ "$i" -eq 30 ] && { echo "foreman-postgres did not become ready" >&2; exit 1; }
  sleep 1
done
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
script (`set -euo pipefail`) — the integrity check and ID-loss check below
MUST both abort the procedure before the corrupt database is replaced. See
`'/Users/ldangelo/.omp/agent/managed-skills/beads-corrupt-db-recovery-safe'` for the full recipe and traps
(notably: never `br sync --import-only --rebuild` / `--force-jsonl` here —
that treats the JSONL as authoritative and can silently drop DB-only issues
that `.recover` still holds).

```bash
set -euo pipefail
cd /path/to/foreman

# Backup first
cp -R .beads /tmp/beads-backup-$(date +%s)

# Recover into a fresh scratch dir (never reuse a stale /tmp path across runs)
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

cd .beads
sqlite3 beads.db ".recover" > "$work_dir/rec.sql"
sqlite3 "$work_dir/rec.db" < "$work_dir/rec.sql"

integrity=$(sqlite3 "$work_dir/rec.db" "pragma integrity_check;")
if [ "$integrity" != "ok" ]; then
  echo "ABORTING: recovered database failed integrity_check: $integrity" >&2
  exit 1
fi

# CRITICAL: compare IDs before swapping — fail closed on any loss
sqlite3 "$work_dir/rec.db" "select id from issues;" 2>/dev/null | tr '|' '\n' | sort > "$work_dir/rec_ids"
sqlite3 beads.db "select id from issues;" 2>/dev/null | tr '|' '\n' | sort > "$work_dir/corrupt_ids"
comm -23 "$work_dir/corrupt_ids" "$work_dir/rec_ids" > "$work_dir/lost_ids"
lost_count=$(wc -l < "$work_dir/lost_ids" | tr -d ' ')
echo "Lost from recovered DB: $lost_count"

if [ "$lost_count" -gt 0 ]; then
  while read -r id; do
    if grep -q "\"$id\"" issues.jsonl; then
      echo "$id in JSONL — must be restored via 'br sync --reconcile-additive' (or manual re-import) before proceeding"
    else
      echo "$id MISSING from both recovered DB and JSONL — unrecoverable"
    fi
  done < "$work_dir/lost_ids"
  echo "ABORTING: $lost_count issue(s) lost by .recover; resolve every one above before swapping in the recovered DB." >&2
  exit 1
fi

# Swap in recovered DB atomically — only reached when both checks above passed.
# Stage the copy + chmod in the same directory as the target, then rename, so a
# failure between copy and activation never leaves beads.db missing.
cp "$work_dir/rec.db" beads.db.new
chmod 600 beads.db.new
mv beads.db.new beads.db
rm -f beads.db-shm beads.db-wal beads.db-wal-cert beads.db-wal-cert-head

# Clean orphaned FK rows
sqlite3 beads.db "
  delete from events where issue_id is not null and issue_id not in (select id from issues);
  delete from export_hashes where issue_id is not null and issue_id not in (select id from issues);
  delete from capacity_occupancy where issue_id is not null and issue_id not in (select id from issues);
"

# Verify
post_integrity=$(sqlite3 beads.db "pragma integrity_check;")
if [ "$post_integrity" != "ok" ]; then
  echo "ABORTING: beads.db failed integrity_check after swap: $post_integrity" >&2
  exit 1
fi
br doctor
```

## Container Recovery (if foreman-postgres lost)

The container uses named volume `foreman-postgres-data` (stable across recreation).
Do NOT run `docker volume prune` — anonymous volumes may still hold data.
`docker run -v` silently creates a missing named volume as empty, so verify the
volume already exists before recreating the container — an empty volume means
data loss, not a fresh init.

```bash
# Confirm the named volume still exists before recreating the container
docker volume inspect foreman-postgres-data >/dev/null || {
  echo "foreman-postgres-data does not exist — this would create an EMPTY volume." >&2
  echo "Restore from backup instead of continuing, unless this is intentionally a fresh init." >&2
  exit 1
}

# Stop if running
docker stop foreman-postgres 2>/dev/null
docker rm foreman-postgres 2>/dev/null

# Start container (reuses existing named volume automatically).
# Bound to loopback only — the documented password (postgres) is not safe to
# expose on every host interface.
docker run -d \
  --name foreman-postgres \
  -v foreman-postgres-data:/var/lib/postgresql/data \
  -p 127.0.0.1:55432:5432 \
  -e POSTGRES_PASSWORD=postgres \
  postgres:16
```
