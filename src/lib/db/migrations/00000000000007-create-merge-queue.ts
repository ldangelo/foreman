import type { MigrationBuilder } from "node-pg-migrate";

export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.createTable("merge_queue", {
    id: {
      type: "bigserial",
      primaryKey: true,
    },
    project_id: {
      type: "uuid",
      notNull: true,
    },
    branch_name: {
      type: "text",
      notNull: true,
    },
    seed_id: {
      type: "text",
      notNull: true,
    },
    run_id: {
      type: "uuid",
      notNull: true,
    },
    operation: {
      type: "text",
      notNull: true,
      default: "auto_merge",
      check: "operation IN ('auto_merge','create_pr')",
    },
    agent_name: {
      type: "text",
      notNull: false,
    },
    files_modified: {
      type: "jsonb",
      notNull: true,
      default: pgm.func("'[]'::jsonb"),
    },
    enqueued_at: {
      type: "timestamp with time zone",
      notNull: true,
      default: "now()",
    },
    started_at: {
      type: "timestamp with time zone",
      notNull: false,
    },
    completed_at: {
      type: "timestamp with time zone",
      notNull: false,
    },
    status: {
      type: "text",
      notNull: true,
      default: "pending",
      check: "status IN ('pending','merging','merged','conflict','failed')",
    },
    resolved_tier: {
      type: "integer",
      notNull: false,
    },
    error: {
      type: "text",
      notNull: false,
    },
    retry_count: {
      type: "integer",
      notNull: true,
      default: 0,
    },
    last_attempted_at: {
      type: "timestamp with time zone",
      notNull: false,
    },
  });

  pgm.addConstraint("merge_queue", "merge_queue_project_id_fkey", {
    foreignKeys: {
      columns: ["project_id"],
      references: "projects(id)",
      onDelete: "CASCADE",
    },
  });

  pgm.addConstraint("merge_queue", "merge_queue_run_id_fkey", {
    foreignKeys: {
      columns: ["run_id"],
      references: "runs(id)",
      onDelete: "CASCADE",
    },
  });

  pgm.createIndex("merge_queue", ["project_id", "status", "enqueued_at"], { ifNotExists: true });
  pgm.createIndex("merge_queue", ["project_id", "seed_id"], { ifNotExists: true });
  pgm.createIndex("merge_queue", ["project_id", "run_id"], { ifNotExists: true });
  pgm.createIndex("merge_queue", ["project_id", "branch_name", "run_id"], { ifNotExists: true, unique: true });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropTable("merge_queue", { ifExists: true });
}
