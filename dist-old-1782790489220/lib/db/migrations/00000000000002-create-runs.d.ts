/**
 * TRD-032: Runs, Events, and Messages tables
 *
 * Migrations create:
 * - `runs`: pipeline run execution records with project_id FK
 * - `events`: immutable event log (run state transitions, task state changes)
 * - `messages`: terminal output captured per run step
 */
import type { MigrationBuilder } from "node-pg-migrate";
export declare function up(migration: MigrationBuilder): Promise<void>;
export declare function down(migration: MigrationBuilder): Promise<void>;
//# sourceMappingURL=00000000000002-create-runs.d.ts.map