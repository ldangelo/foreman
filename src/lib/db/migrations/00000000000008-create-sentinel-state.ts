import type { MigrationBuilder } from "node-pg-migrate";

export async function up(pgm: MigrationBuilder): Promise<void> {
  // Sentinel storage is created by 00000000000006-add-sentinel-compat.
  // Keep this migration idempotent for databases that already applied the
  // compatibility migration before this historical sentinel-state migration.
  pgm.createTable("sentinel_configs", {
    id: { type: "bigserial", primaryKey: true },
    project_id: { type: "uuid", notNull: true, unique: true, references: "projects", onDelete: "CASCADE" },
    branch: { type: "text", notNull: true, default: "main" },
    test_command: { type: "text", notNull: true, default: "npm test" },
    interval_minutes: { type: "integer", notNull: true, default: 30 },
    failure_threshold: { type: "integer", notNull: true, default: 2 },
    enabled: { type: "integer", notNull: true, default: 1 },
    pid: { type: "integer", notNull: false },
    created_at: { type: "timestamp with time zone", notNull: true, default: "now()" },
    updated_at: { type: "timestamp with time zone", notNull: true, default: "now()" },
  }, { ifNotExists: true });

  pgm.createTable("sentinel_runs", {
    id: { type: "uuid", primaryKey: true },
    project_id: { type: "uuid", notNull: true, references: "projects", onDelete: "CASCADE" },
    branch: { type: "text", notNull: true },
    commit_hash: { type: "text", notNull: false },
    status: { type: "text", notNull: true, check: "status IN ('running','passed','failed','error')" },
    test_command: { type: "text", notNull: true },
    output: { type: "text", notNull: false },
    failure_count: { type: "integer", notNull: true, default: 0 },
    started_at: { type: "timestamp with time zone", notNull: true },
    completed_at: { type: "timestamp with time zone", notNull: false },
  }, { ifNotExists: true });

  pgm.createIndex("sentinel_runs", ["project_id", "started_at"], {
    ifNotExists: true,
    name: "sentinel_runs_project_id_started_at_index",
  });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropIndex("sentinel_runs", ["project_id", "started_at"], {
    ifExists: true,
    name: "sentinel_runs_project_id_started_at_index",
  });
}
