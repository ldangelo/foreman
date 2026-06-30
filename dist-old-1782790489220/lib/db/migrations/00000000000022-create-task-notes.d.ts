import type { MigrationBuilder } from "node-pg-migrate";
/**
 * Migration 00000000000021: append-only task notes timeline.
 *
 * Notes record what each pipeline phase/user/system learned or did without
 * mutating the task description.
 */
export declare const up: (pgm: MigrationBuilder) => void;
export declare const down: (pgm: MigrationBuilder) => void;
//# sourceMappingURL=00000000000022-create-task-notes.d.ts.map