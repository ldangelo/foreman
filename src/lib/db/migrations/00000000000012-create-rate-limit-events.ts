import type { MigrationBuilder } from "node-pg-migrate";

export async function up(pgm: MigrationBuilder): Promise<void> {
  // rate_limit_events is already created by 00000000000004-add-legacy-run-compat.
  // Keep this historical migration idempotent on fresh databases that run both.
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
      references: "projects",
      onDelete: "CASCADE",
    },
    run_id: {
      type: "uuid",
      notNull: false,
      references: "runs",
      onDelete: "CASCADE",
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
  }, { ifNotExists: true });

  pgm.createIndex("rate_limit_events", ["model", "recorded_at"], { ifNotExists: true });
  pgm.createIndex("rate_limit_events", ["project_id", "recorded_at"], { ifNotExists: true });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropIndex("rate_limit_events", ["model", "recorded_at"], { ifExists: true });
  pgm.dropIndex("rate_limit_events", ["project_id", "recorded_at"], { ifExists: true });
}
