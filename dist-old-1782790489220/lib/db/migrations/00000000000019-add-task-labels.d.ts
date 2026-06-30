import { MigrationBuilder } from "node-pg-migrate";
/**
 * Migration 00000000000019: add labels to tasks.
 *
 * GitHub/Jira importers preserve source labels here so workflow selection can
 * honor labels such as `workflow:feature` while still keeping the normalized
 * task `type` column for type-based workflows.
 */
export declare const up: (pgm: MigrationBuilder) => void;
export declare const down: (pgm: MigrationBuilder) => void;
//# sourceMappingURL=00000000000019-add-task-labels.d.ts.map