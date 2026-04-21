/* eslint-disable @typescript-eslint/no-explicit-any */
import { MigrationBuilder } from "node-pg-migrate";

/**
 * Migration 00000000000001: create tasks table with project_id FK.
 *
 * Schema mirrors the existing SQLite `tasks` table from NativeTaskStore (store.ts)
 * but scoped per-project for the multi-project orchestrator.
 *
 * Key design decisions:
 * - project_id is the primary isolation boundary — all queries include it.
 * - id is TEXT (bead UUID) to match native task store compatibility.
 * - external_id is unique per project (not globally), allowing the same Jira/Linear ID
 *   in different projects without conflict.
 * - status CHECK mirrors the SQLite constraint for consistency.
 *
 * @module db/migrations/00000000000001-create-tasks
 */

export const up = (pgm: MigrationBuilder) => {
  // ── Tasks table ─────────────────────────────────────────────────────────

  pgm.createTable("tasks", {
    id: {
      type: "text",
      primaryKey: true,
      notNull: true,
      comment: "Bead/task UUID (e.g. bd-xxxx). Matches native task store.",
    },
    project_id: {
      type: "uuid",
      notNull: true,
      references: "projects",
      onDelete: "CASCADE",
      comment: "Owner project. Cascade-deletes tasks when project is removed.",
    },
    title: {
      type: "text",
      notNull: true,
      comment: "Human-readable task title",
    },
    description: {
      type: "text",
      notNull: false,
      comment: "Optional description/bead body",
    },
    type: {
      type: "varchar(32)",
      notNull: true,
      default: "'task'",
      comment: "Task type: task, bug, story, epic, chore",
    },
    priority: {
      type: "integer",
      notNull: true,
      default: 2,
      check: "priority >= 0 AND priority <= 4",
      comment: "P0=critical, P1=high, P2=medium, P3=low, P4=backlog",
    },
    status: {
      type: "varchar(32)",
      notNull: true,
      default: "'backlog'",
      check: `status IN (
        'backlog', 'ready', 'in-progress',
        'explorer', 'developer', 'qa', 'reviewer', 'finalize',
        'merged', 'closed', 'conflict', 'failed', 'stuck', 'blocked'
      )`,
      comment: "Lifecycle status",
    },
    run_id: {
      type: "text",
      notNull: false,
      references: "runs",
      onDelete: "SET NULL",
      comment: "Run executing this task. Null when not claimed.",
    },
    branch: {
      type: "text",
      notNull: false,
      comment: "Git branch for this task's work",
    },
    external_id: {
      type: "text",
      notNull: false,
      comment: "External ID (e.g. Jira issue key). Unique per project.",
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
    approved_at: {
      type: "timestamptz",
      notNull: false,
      comment: "When the task was approved by a human (human gate cleared)",
    },
    closed_at: {
      type: "timestamptz",
      notNull: false,
      comment: "When the task reached a terminal state (merged/closed)",
    },
  });

  // ── Indexes ────────────────────────────────────────────────────────────

  pgm.createIndex("tasks", "project_id", { ifNotExists: true });
  pgm.createIndex("tasks", "status", { ifNotExists: true });
  pgm.createIndex("tasks", "run_id", {
    ifNotExists: true,
    where: "run_id IS NOT NULL",
  });
  pgm.createIndex("tasks", "created_at", { ifNotExists: true });
  pgm.createIndex("tasks", "priority", { ifNotExists: true });

  // ── Unique constraint ──────────────────────────────────────────────────

  // external_id unique per project. Multiple NULLs allowed (SQL standard).
  pgm.addConstraint("tasks", "tasks_external_id_per_project_unique", {
    unique: ["project_id", "external_id"],
  });

  // ── Comments ─────────────────────────────────────────────────────────

  pgm.sql(`
    COMMENT ON TABLE tasks IS
      'Per-project task table. project_id is the isolation boundary; all queries include it.';
    COMMENT ON COLUMN tasks.project_id IS
      'Owner project. Tasks are cascade-deleted when the project is removed.';
    COMMENT ON COLUMN tasks.priority IS
      'P0=critical, P1=high, P2=medium (default), P3=low, P4=backlog.';
    COMMENT ON COLUMN tasks.status IS
      'backlog=unstarted, ready=dispatchable, in-progress=executing, explorer/developer/qa/reviewer/finalize=running phases, merged/closed=terminal, conflict/failed/stuck/blocked=needs-attention.';
    COMMENT ON COLUMN tasks.run_id IS
      'NULL when not claimed by any run. Set to NULL when the owning run is deleted.';
    COMMENT ON COLUMN tasks.external_id IS
      'External system ID (Jira, Linear, GitHub issue). Unique per project, not global.';
  `);

  // ── Task dependencies table ────────────────────────────────────────────

  pgm.createTable("task_dependencies", {
    from_task_id: {
      type: "text",
      notNull: true,
      references: "tasks",
      onDelete: "CASCADE",
      comment: "The blocking task. When it reaches a terminal state, to_task is unblocked.",
    },
    to_task_id: {
      type: "text",
      notNull: true,
      references: "tasks",
      onDelete: "CASCADE",
      comment: "The blocked task. Remains stuck until all blockers are merged/closed.",
    },
    type: {
      type: "varchar(32)",
      notNull: true,
      default: "'blocks'",
      check: "type IN ('blocks', 'parent-child')",
      comment: "blocks=dependency, parent-child=hierarchical decomposition",
    },
  });

  pgm.addConstraint("task_dependencies", "task_dependencies_pk", {
    primaryKey: ["from_task_id", "to_task_id", "type"],
  });

  pgm.createIndex("task_dependencies", "to_task_id", { ifNotExists: true });

  pgm.sql(`
    COMMENT ON TABLE task_dependencies IS
      'DAG edges for task dependencies. from_task blocks to_task when type=blocks.';
    COMMENT ON COLUMN task_dependencies.from_task_id IS
      'The blocking task.';
    COMMENT ON COLUMN task_dependencies.to_task_id IS
      'The blocked task.';
    COMMENT ON COLUMN task_dependencies.type IS
      'blocks=dependency edge, parent-child=hierarchical decomposition edge.';
  `);
};

export const down = (pgm: MigrationBuilder) => {
  pgm.dropTable("task_dependencies", { ifExists: true });
  pgm.dropTable("tasks", { ifExists: true });
};
