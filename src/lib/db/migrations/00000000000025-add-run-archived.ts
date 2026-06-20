import type { MigrationBuilder } from "node-pg-migrate";

/**
 * Add archived column to runs table for hiding noisy historical runs.
 *
 * This enables the archive/filter behavior so old failed runs are still
 * inspectable but no longer obscure current state in foreman runs and
 * operator views.
 */
export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.sql(`
    ALTER TABLE runs ADD COLUMN IF NOT EXISTS archived boolean NOT NULL DEFAULT false;
    CREATE INDEX IF NOT EXISTS idx_runs_archived ON runs (archived) WHERE archived = true;
  `);
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.sql(`
    DROP INDEX IF EXISTS idx_runs_archived;
    ALTER TABLE runs DROP COLUMN IF EXISTS archived;
  `);
}
