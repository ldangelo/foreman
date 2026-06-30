import type { MigrationBuilder } from "node-pg-migrate";
/**
 * Allow Foreman events to reference either a pipeline run or a sentinel run.
 *
 * Sentinel runs live in sentinel_runs, not runs. Previous migrations added
 * sentinel event types to events.event_type, but events.run_id remained NOT NULL
 * and FK'd only to runs(id), so recording sentinel-start/pass/fail failed at
 * runtime. This migration adds a sentinel_run_id FK and enforces that each event
 * references exactly one run owner.
 */
export declare function up(pgm: MigrationBuilder): Promise<void>;
export declare function down(pgm: MigrationBuilder): Promise<void>;
//# sourceMappingURL=00000000000024-add-sentinel-events.d.ts.map