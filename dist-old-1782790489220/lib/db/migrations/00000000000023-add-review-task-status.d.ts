import { MigrationBuilder } from "node-pg-migrate";
/**
 * Migration 00000000000023: allow native tasks to wait in PR review.
 *
 * Finalize already maps completed pushed work to `review`; native Postgres
 * databases created before that status existed rejected it, leaving tasks stuck
 * in phase statuses such as `reviewer` even when no reviewer was running.
 */
export declare const up: (pgm: MigrationBuilder) => void;
export declare const down: (pgm: MigrationBuilder) => void;
//# sourceMappingURL=00000000000023-add-review-task-status.d.ts.map