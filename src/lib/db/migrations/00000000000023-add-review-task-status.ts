import { MigrationBuilder } from "node-pg-migrate";

const TASK_STATUS_CHECK = `status IN (
  'backlog', 'ready', 'in-progress', 'review',
  'explorer', 'developer', 'qa', 'reviewer', 'finalize',
  'merged', 'closed', 'conflict', 'failed', 'stuck', 'blocked'
)`;

const TASK_STATUS_CHECK_DOWN = `status IN (
  'backlog', 'ready', 'in-progress',
  'explorer', 'developer', 'qa', 'reviewer', 'finalize',
  'merged', 'closed', 'conflict', 'failed', 'stuck', 'blocked'
)`;

/**
 * Migration 00000000000023: allow native tasks to wait in PR review.
 *
 * Finalize already maps completed pushed work to `review`; native Postgres
 * databases created before that status existed rejected it, leaving tasks stuck
 * in phase statuses such as `reviewer` even when no reviewer was running.
 */
export const up = (pgm: MigrationBuilder) => {
  pgm.dropConstraint("tasks", "tasks_status_check", { ifExists: true });
  pgm.addConstraint("tasks", "tasks_status_check", {
    check: TASK_STATUS_CHECK,
  });
  pgm.sql("COMMENT ON COLUMN tasks.status IS 'backlog=unstarted, ready=dispatchable, in-progress=executing, review=awaiting PR/merge review, explorer/developer/qa/reviewer/finalize=running phases, merged/closed=terminal, conflict/failed/stuck/blocked=needs-attention.'");
};

export const down = (pgm: MigrationBuilder) => {
  pgm.sql("UPDATE tasks SET status = 'blocked' WHERE status = 'review'");
  pgm.dropConstraint("tasks", "tasks_status_check", { ifExists: true });
  pgm.addConstraint("tasks", "tasks_status_check", {
    check: TASK_STATUS_CHECK_DOWN,
  });
};
