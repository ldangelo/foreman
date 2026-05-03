import type { MigrationBuilder } from "node-pg-migrate";

/**
 * Add compatibility storage for Foreman sentinel persistence APIs.
 */
export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.createTable("sentinel_configs", {
    id: {
      type: "serial",
      primaryKey: true,
      notNull: true,
    },
    project_id: {
      type: "uuid",
      notNull: true,
      unique: true,
      references: "projects",
      onDelete: "CASCADE",
    },
    branch: {
      type: "text",
      notNull: true,
      default: "'main'",
    },
    test_command: {
      type: "text",
      notNull: true,
      default: "'npm test'",
    },
    interval_minutes: {
      type: "integer",
      notNull: true,
      default: 30,
    },
    failure_threshold: {
      type: "integer",
      notNull: true,
      default: 2,
    },
    enabled: {
      type: "integer",
      notNull: true,
      default: 1,
    },
    pid: {
      type: "integer",
      notNull: false,
    },
    created_at: {
      type: "timestamptz",
      notNull: true,
      default: pgm.func("now()"),
    },
    updated_at: {
      type: "timestamptz",
      notNull: true,
      default: pgm.func("now()"),
    },
  }, { ifNotExists: true });

  pgm.createTable("sentinel_runs", {
    id: {
      type: "text",
      primaryKey: true,
      notNull: true,
    },
    project_id: {
      type: "uuid",
      notNull: true,
      references: "projects",
      onDelete: "CASCADE",
    },
    branch: {
      type: "text",
      notNull: true,
    },
    commit_hash: {
      type: "text",
      notNull: false,
    },
    status: {
      type: "varchar(32)",
      notNull: true,
      default: "'running'",
      check: "status IN ('running', 'passed', 'failed', 'error')",
    },
    test_command: {
      type: "text",
      notNull: true,
    },
    output: {
      type: "text",
      notNull: false,
    },
    failure_count: {
      type: "integer",
      notNull: true,
      default: 0,
    },
    started_at: {
      type: "timestamptz",
      notNull: true,
    },
    completed_at: {
      type: "timestamptz",
      notNull: false,
    },
  }, { ifNotExists: true });

  pgm.createIndex("sentinel_runs", ["project_id", "started_at"], {
    ifNotExists: true,
    name: "idx_sentinel_runs_project",
  });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropIndex("sentinel_runs", ["project_id", "started_at"], {
    ifExists: true,
    name: "idx_sentinel_runs_project",
  });
  pgm.dropTable("sentinel_runs", { ifExists: true });
  pgm.dropTable("sentinel_configs", { ifExists: true });
}
