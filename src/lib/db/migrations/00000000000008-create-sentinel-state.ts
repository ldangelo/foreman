import type { MigrationBuilder } from "node-pg-migrate";

export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.createTable("sentinel_configs", {
    id: { type: "bigserial", primaryKey: true },
    project_id: { type: "uuid", notNull: true, unique: true },
    branch: { type: "text", notNull: true, default: "main" },
    test_command: { type: "text", notNull: true, default: "npm test" },
    interval_minutes: { type: "integer", notNull: true, default: 30 },
    failure_threshold: { type: "integer", notNull: true, default: 2 },
    enabled: { type: "integer", notNull: true, default: 1 },
    pid: { type: "integer", notNull: false },
    created_at: { type: "timestamp with time zone", notNull: true, default: "now()" },
    updated_at: { type: "timestamp with time zone", notNull: true, default: "now()" },
  });
  pgm.addConstraint("sentinel_configs", "sentinel_configs_project_id_fkey", {
    foreignKeys: {
      columns: ["project_id"],
      references: "projects(id)",
      onDelete: "CASCADE",
    },
  });

  pgm.createTable("sentinel_runs", {
    id: { type: "uuid", primaryKey: true },
    project_id: { type: "uuid", notNull: true },
    branch: { type: "text", notNull: true },
    commit_hash: { type: "text", notNull: false },
    status: { type: "text", notNull: true, check: "status IN ('running','passed','failed','error')" },
    test_command: { type: "text", notNull: true },
    output: { type: "text", notNull: false },
    failure_count: { type: "integer", notNull: true, default: 0 },
    started_at: { type: "timestamp with time zone", notNull: true },
    completed_at: { type: "timestamp with time zone", notNull: false },
  });
  pgm.addConstraint("sentinel_runs", "sentinel_runs_project_id_fkey", {
    foreignKeys: {
      columns: ["project_id"],
      references: "projects(id)",
      onDelete: "CASCADE",
    },
  });
  pgm.createIndex("sentinel_runs", ["project_id", "started_at"], { ifNotExists: true });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropTable("sentinel_runs", { ifExists: true });
  pgm.dropTable("sentinel_configs", { ifExists: true });
}
