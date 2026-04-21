/**
 * TRD-032: Runs, Events, and Messages tables
 *
 * Migrations create:
 * - `runs`: pipeline run execution records with project_id FK
 * - `events`: immutable event log (run state transitions, task state changes)
 * - `messages`: terminal output captured per run step
 */

import type { MigrationBuilder } from "node-pg-migrate";

export async function up(migration: MigrationBuilder): Promise<void> {
  // ── runs ──────────────────────────────────────────────────────────────────
  migration.createTable("runs", {
    id: {
      type: "uuid",
      notNull: true,
      primaryKey: true,
      default: "gen_random_uuid()",
    },
    project_id: {
      type: "uuid",
      notNull: true,
    },
    bead_id: {
      type: "varchar(255)",
      notNull: true,
    },
    run_number: {
      type: "integer",
      notNull: true,
    },
    status: {
      type: "varchar(32)",
      notNull: true,
      check: "status IN ('pending','running','success','failure','cancelled','skipped')",
    },
    branch: {
      type: "varchar(255)",
      notNull: true,
    },
    commit_sha: {
      type: "varchar(64)",
      notNull: false,
    },
    trigger: {
      type: "varchar(32)",
      notNull: true,
      default: "'manual'",
      check: "trigger IN ('push','pr','manual','schedule','bead')",
    },
    queued_at: {
      type: "timestamp with time zone",
      notNull: true,
      default: "now()",
    },
    started_at: {
      type: "timestamp with time zone",
      notNull: false,
    },
    finished_at: {
      type: "timestamp with time zone",
      notNull: false,
    },
    created_at: {
      type: "timestamp with time zone",
      notNull: true,
      default: "now()",
    },
    updated_at: {
      type: "timestamp with time zone",
      notNull: true,
      default: "now()",
    },
  });

  migration.addConstraint("runs", "runs_project_id_fkey", {
    foreignKeys: {
      columns: ["project_id"],
      references: "projects(id)",
      onDelete: "CASCADE",
    },
  });

  migration.addConstraint("runs", "runs_unique_bead_run_number", {
    unique: ["bead_id", "run_number"],
  });

  migration.createIndex("runs", "project_id", { ifNotExists: true });
  migration.createIndex("runs", "bead_id", { ifNotExists: true });
  migration.createIndex("runs", "status", { ifNotExists: true });

  // ── events ────────────────────────────────────────────────────────────────
  migration.createTable("events", {
    id: {
      type: "uuid",
      notNull: true,
      primaryKey: true,
      default: "gen_random_uuid()",
    },
    project_id: {
      type: "uuid",
      notNull: true,
    },
    run_id: {
      type: "uuid",
      notNull: true,
    },
    task_id: {
      type: "varchar(255)",
      notNull: false,
    },
    event_type: {
      type: "varchar(64)",
      notNull: true,
      check: "event_type IN ('run:queued','run:started','run:success','run:failure','run:cancelled','task:claimed','task:approved','task:rejected','task:reset','bead:synced','bead:conflict')",
    },
    payload: {
      type: "jsonb",
      notNull: false,
      default: "'{}'",
    },
    created_at: {
      type: "timestamp with time zone",
      notNull: true,
      default: "now()",
    },
  });

  migration.addConstraint("events", "events_run_id_fkey", {
    foreignKeys: {
      columns: ["run_id"],
      references: "runs(id)",
      onDelete: "CASCADE",
    },
  });

  migration.addConstraint("events", "events_project_id_fkey", {
    foreignKeys: {
      columns: ["project_id"],
      references: "projects(id)",
      onDelete: "CASCADE",
    },
  });

  migration.createIndex("events", "run_id", { ifNotExists: true });
  migration.createIndex("events", "task_id", { ifNotExists: true });
  migration.createIndex("events", "event_type", { ifNotExists: true });
  migration.createIndex("events", "created_at", { ifNotExists: true });

  // ── messages ──────────────────────────────────────────────────────────────
  migration.createTable("messages", {
    id: {
      type: "uuid",
      notNull: true,
      primaryKey: true,
      default: "gen_random_uuid()",
    },
    run_id: {
      type: "uuid",
      notNull: true,
    },
    step_key: {
      type: "varchar(255)",
      notNull: false,
    },
    stream: {
      type: "varchar(16)",
      notNull: true,
      check: "stream IN ('stdout','stderr','system')",
    },
    chunk: {
      type: "text",
      notNull: true,
    },
    line_number: {
      type: "integer",
      notNull: true,
    },
    created_at: {
      type: "timestamp with time zone",
      notNull: true,
      default: "now()",
    },
  });

  migration.addConstraint("messages", "messages_run_id_fkey", {
    foreignKeys: {
      columns: ["run_id"],
      references: "runs(id)",
      onDelete: "CASCADE",
    },
  });

  migration.createIndex("messages", "run_id", { ifNotExists: true });
  migration.createIndex("messages", "step_key", { ifNotExists: true });
}

export async function down(migration: MigrationBuilder): Promise<void> {
  migration.dropTable("messages");
  migration.dropTable("events");
  migration.dropTable("runs");
}
