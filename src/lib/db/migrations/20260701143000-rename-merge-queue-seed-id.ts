import type { MigrationBuilder } from "node-pg-migrate";

export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.sql(`
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = 'merge_queue'
          AND column_name = 'seed_id'
      ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = 'merge_queue'
          AND column_name = 'task_id'
      ) THEN
        ALTER TABLE merge_queue RENAME COLUMN seed_id TO task_id;
      END IF;
    END $$;
  `);

  pgm.createIndex("merge_queue", ["project_id", "task_id"], { ifNotExists: true });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.sql(`
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = 'merge_queue'
          AND column_name = 'task_id'
      ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = 'merge_queue'
          AND column_name = 'seed_id'
      ) THEN
        ALTER TABLE merge_queue RENAME COLUMN task_id TO seed_id;
      END IF;
    END $$;
  `);
}
