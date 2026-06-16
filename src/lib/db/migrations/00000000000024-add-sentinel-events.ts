import type { MigrationBuilder } from "node-pg-migrate";

/**
 * Allow Foreman events to reference either a pipeline run or a sentinel run.
 *
 * Sentinel runs live in sentinel_runs, not runs. Previous migrations added
 * sentinel event types to events.event_type, but events.run_id remained NOT NULL
 * and FK'd only to runs(id), so recording sentinel-start/pass/fail failed at
 * runtime. This migration adds a sentinel_run_id FK and enforces that each event
 * references exactly one run owner.
 */
export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.addColumn("events", {
    sentinel_run_id: { type: "uuid", notNull: false },
  });

  pgm.alterColumn("events", "run_id", { notNull: false });

  pgm.addConstraint("events", "events_sentinel_run_id_fkey", {
    foreignKeys: {
      columns: "sentinel_run_id",
      references: "sentinel_runs(id)",
      onDelete: "CASCADE",
    },
  });

  pgm.createIndex("events", "sentinel_run_id", { ifNotExists: true });

  pgm.addConstraint("events", "events_single_owner_check", {
    check: "((run_id IS NOT NULL)::int + (sentinel_run_id IS NOT NULL)::int) = 1",
  });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropConstraint("events", "events_single_owner_check", { ifExists: true });
  pgm.dropIndex("events", "sentinel_run_id", { ifExists: true });
  pgm.dropConstraint("events", "events_sentinel_run_id_fkey", { ifExists: true });
  pgm.dropColumn("events", "sentinel_run_id", { ifExists: true });
  pgm.alterColumn("events", "run_id", { notNull: true });
}
