import type { MigrationBuilder } from "node-pg-migrate";

export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.createTable("rate_limit_events", {
    id: {
      type: "uuid",
      notNull: true,
      primaryKey: true,
      default: pgm.func("gen_random_uuid()"),
    },
    project_id: {
      type: "uuid",
      notNull: true,
    },
    run_id: {
      type: "uuid",
      notNull: false,
    },
    model: {
      type: "varchar(255)",
      notNull: true,
    },
    phase: {
      type: "varchar(64)",
      notNull: false,
    },
    error: {
      type: "text",
      notNull: true,
    },
    retry_after_seconds: {
      type: "integer",
      notNull: false,
    },
    recorded_at: {
      type: "timestamp with time zone",
      notNull: true,
      default: "now()",
    },
  });

  pgm.addConstraint("rate_limit_events", "rate_limit_events_project_id_fkey", {
    foreignKeys: {
      columns: ["project_id"],
      references: "projects(id)",
      onDelete: "CASCADE",
    },
  });

  pgm.addConstraint("rate_limit_events", "rate_limit_events_run_id_fkey", {
    foreignKeys: {
      columns: ["run_id"],
      references: "runs(id)",
      onDelete: "CASCADE",
    },
  });

  pgm.createIndex("rate_limit_events", ["model", "recorded_at"], { ifNotExists: true });
  pgm.createIndex("rate_limit_events", ["project_id", "recorded_at"], { ifNotExists: true });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropTable("rate_limit_events", { ifExists: true });
}
