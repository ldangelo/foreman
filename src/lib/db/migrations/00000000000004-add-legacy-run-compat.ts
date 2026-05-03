import type { MigrationBuilder } from "node-pg-migrate";

/**
 * Add compatibility storage for legacy Foreman run/cost/event APIs.
 *
 * This keeps the newer TRD-032 pipeline tables intact while extending the
 * shared Postgres schema so PostgresAdapter can mirror the existing SQLite
 * ForemanStore run/cost/event behavior.
 */
export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.sql(`
    ALTER TABLE runs ADD COLUMN IF NOT EXISTS seed_id varchar(255);
    ALTER TABLE runs ADD COLUMN IF NOT EXISTS agent_type varchar(255);
    ALTER TABLE runs ADD COLUMN IF NOT EXISTS session_key varchar(255);
    ALTER TABLE runs ADD COLUMN IF NOT EXISTS worktree_path text;
    ALTER TABLE runs ADD COLUMN IF NOT EXISTS completed_at timestamptz;
    ALTER TABLE runs ADD COLUMN IF NOT EXISTS progress text;
    ALTER TABLE runs ADD COLUMN IF NOT EXISTS base_branch varchar(255);
    ALTER TABLE runs ADD COLUMN IF NOT EXISTS merge_strategy varchar(16) DEFAULT 'auto';
    ALTER TABLE runs ALTER COLUMN branch DROP NOT NULL;
    ALTER TABLE runs DROP CONSTRAINT IF EXISTS runs_status_check;

    ALTER TABLE events ALTER COLUMN run_id DROP NOT NULL;
    ALTER TABLE events ADD COLUMN IF NOT EXISTS details text;
    ALTER TABLE events DROP CONSTRAINT IF EXISTS events_event_type_check;
  `);

  pgm.createTable("costs", {
    id: {
      type: "uuid",
      notNull: true,
      primaryKey: true,
      default: pgm.func("gen_random_uuid()"),
    },
    run_id: {
      type: "uuid",
      notNull: true,
      references: "runs",
      onDelete: "CASCADE",
    },
    tokens_in: {
      type: "integer",
      notNull: true,
    },
    tokens_out: {
      type: "integer",
      notNull: true,
    },
    cache_read: {
      type: "integer",
      notNull: true,
      default: 0,
    },
    estimated_cost: {
      type: "numeric(12,6)",
      notNull: true,
    },
    recorded_at: {
      type: "timestamptz",
      notNull: true,
      default: pgm.func("now()"),
    },
  }, { ifNotExists: true });
  pgm.createIndex("costs", "run_id", { ifNotExists: true });
  pgm.createIndex("costs", "recorded_at", { ifNotExists: true });

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
      type: "varchar(255)",
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
      type: "timestamptz",
      notNull: true,
      default: pgm.func("now()"),
    },
  }, { ifNotExists: true });
  pgm.createIndex("rate_limit_events", ["project_id", "recorded_at"], { ifNotExists: true, name: "idx_rate_limit_events_project" });
  pgm.createIndex("rate_limit_events", ["model", "recorded_at"], { ifNotExists: true, name: "idx_rate_limit_events_model" });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropIndex("rate_limit_events", ["model", "recorded_at"], { ifExists: true, name: "idx_rate_limit_events_model" });
  pgm.dropIndex("rate_limit_events", ["project_id", "recorded_at"], { ifExists: true, name: "idx_rate_limit_events_project" });
  pgm.dropTable("rate_limit_events", { ifExists: true });
  pgm.dropTable("costs", { ifExists: true });

  pgm.sql(`
    ALTER TABLE events DROP COLUMN IF EXISTS details;
    ALTER TABLE events ALTER COLUMN run_id SET NOT NULL;

    ALTER TABLE runs DROP COLUMN IF EXISTS merge_strategy;
    ALTER TABLE runs DROP COLUMN IF EXISTS base_branch;
    ALTER TABLE runs DROP COLUMN IF EXISTS progress;
    ALTER TABLE runs DROP COLUMN IF EXISTS completed_at;
    ALTER TABLE runs DROP COLUMN IF EXISTS worktree_path;
    ALTER TABLE runs DROP COLUMN IF EXISTS session_key;
    ALTER TABLE runs DROP COLUMN IF EXISTS agent_type;
    ALTER TABLE runs DROP COLUMN IF EXISTS seed_id;
    ALTER TABLE runs ALTER COLUMN branch SET NOT NULL;
  `);
}
