import type { MigrationBuilder } from "node-pg-migrate";
/**
 * Migration: Create Jira integration tables.
 *
 * - jira_projects: Jira instance configuration per Foreman project
 * - jira_monitored_projects: Per-Jira-project monitoring config
 * - jira_issue_states: Tracks last known status per Jira issue (includes debounce)
 *
 * Also extends the tasks table with Jira-specific columns.
 *
 * TRD: TRD-2026-013 (Jira Issue Monitor), TRD-004
 */
export declare function up(pgm: MigrationBuilder): Promise<void>;
export declare function down(pgm: MigrationBuilder): Promise<void>;
//# sourceMappingURL=00000000000018-create-jira-tables.d.ts.map