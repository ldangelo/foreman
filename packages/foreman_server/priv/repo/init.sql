-- Foreman Postgres cluster init script (TRD-041 / AC-021-1).
--
-- PostgreSQL 16 cannot enable `data_checksums` as a GUC: `ALTER SYSTEM SET
-- data_checksums` is rejected at runtime. Checksums MUST be enabled at cluster
-- initialization via the compose service `POSTGRES_INITDB_ARGS: --data-checksums`
-- (compose.yaml). This script only handles GUCs that ARE configurable at runtime.
--
-- Mounted by compose.yaml into the postgres container at
-- /docker-entrypoint-initdb.d so it runs once, on first start of a fresh
-- data volume. Existing named volumes must be recreated via
-- `devbox run db:reset` before these settings take effect.
--
-- Verify with: SHOW data_checksums; SHOW wal_level;

ALTER SYSTEM SET wal_level = replica;