import type { MigrationBuilder } from "node-pg-migrate";
/**
 * Migration: Create GitHub integration tables.
 *
 * - github_repos: Repository configuration for GitHub integration
 * - github_sync_events: Audit log for sync operations
 *
 * Also extends the tasks table with GitHub-specific columns.
 *
 * TRD: TRD-2026-012 (GitHub Issues Integration), TRD-007
 */
export declare function up(pgm: MigrationBuilder): Promise<void>;
export declare function down(pgm: MigrationBuilder): Promise<void>;
//# sourceMappingURL=00000000000013-create-github-tables.d.ts.map