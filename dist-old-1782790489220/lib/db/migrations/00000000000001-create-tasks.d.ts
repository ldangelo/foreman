import { MigrationBuilder } from "node-pg-migrate";
/**
 * Migration 00000000000001: create tasks table with project_id FK.
 *
 * Schema mirrors the existing Postgres `tasks` table from NativeTaskStore (store.ts)
 * but scoped per-project for the multi-project orchestrator.
 *
 * Key design decisions:
 * - project_id is the primary isolation boundary — all queries include it.
 * - id is TEXT (bead UUID) to match native task store compatibility.
 * - external_id is unique per project (not globally), allowing the same Jira/Linear ID
 *   in different projects without conflict.
 * - status CHECK mirrors the Postgres constraint for consistency.
 *
 * @module db/migrations/00000000000001-create-tasks
 */
export declare const up: (pgm: MigrationBuilder) => void;
export declare const down: (pgm: MigrationBuilder) => void;
//# sourceMappingURL=00000000000001-create-tasks.d.ts.map