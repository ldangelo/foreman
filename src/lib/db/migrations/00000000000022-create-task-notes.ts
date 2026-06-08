import type { MigrationBuilder } from "node-pg-migrate";

/**
 * Migration 00000000000021: append-only task notes timeline.
 *
 * Notes record what each pipeline phase/user/system learned or did without
 * mutating the task description.
 */
export const up = (pgm: MigrationBuilder) => {
  pgm.createTable("task_notes", {
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
    task_id: {
      type: "text",
      notNull: true,
      references: "tasks",
      onDelete: "CASCADE",
    },
    run_id: {
      type: "uuid",
      notNull: false,
      references: "runs",
      onDelete: "SET NULL",
    },
    phase: {
      type: "varchar(64)",
      notNull: false,
    },
    author: {
      type: "text",
      notNull: true,
    },
    kind: {
      type: "varchar(32)",
      notNull: true,
      default: "'progress'",
      check: "kind IN ('progress', 'issue', 'blocker', 'review', 'qa', 'final', 'failure', 'manual', 'system')",
    },
    body: {
      type: "text",
      notNull: true,
    },
    metadata: {
      type: "jsonb",
      notNull: false,
    },
    created_at: {
      type: "timestamptz",
      notNull: true,
      default: pgm.func("now()"),
    },
  });

  pgm.createIndex("task_notes", ["project_id", "task_id", "created_at"], { ifNotExists: true });
  pgm.createIndex("task_notes", ["run_id", "phase"], { ifNotExists: true, where: "run_id IS NOT NULL" });

  pgm.sql(`
    COMMENT ON TABLE task_notes IS
      'Append-only task timeline entries written by users, agents, phases, and Foreman system paths.';
    COMMENT ON COLUMN task_notes.kind IS
      'progress, issue, blocker, review, qa, final, failure, manual, or system.';
  `);
};

export const down = (pgm: MigrationBuilder) => {
  pgm.dropTable("task_notes", { ifExists: true });
};
