import type { MigrationBuilder } from "node-pg-migrate";
/**
 * Migration: Add canonical PR identity columns to runs table.
 *
 * `commit_sha` already exists on the base runs schema; this migration adds only
 * the PR-specific identity columns needed for canonical PR tracking.
 */
export declare function up(migration: MigrationBuilder): Promise<void>;
export declare function down(migration: MigrationBuilder): Promise<void>;
//# sourceMappingURL=00000000000016-add-pr-identity-columns.d.ts.map