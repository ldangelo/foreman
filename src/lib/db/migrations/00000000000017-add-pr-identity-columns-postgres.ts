import type { MigrationBuilder } from "node-pg-migrate";

/**
 * Migration: Add canonical PR identity columns to runs table (Postgres).
 *
 * Mirrors the SQLite migration (00000000000016-add-pr-identity-columns.ts).
 * Adds pr_state, pr_url, pr_head_sha, and commit_sha columns for AC-1, AC-6.
 *
 * - pr_state: GitHub PR state for canonical PR identity tracking
 * - pr_url: Canonical PR URL for this run
 * - pr_head_sha: Branch HEAD SHA when PR was last updated
 * - commit_sha: HEAD SHA at the time this run's PR was created
 */
export async function up(migration: MigrationBuilder): Promise<void> {
  migration.addColumn("runs", {
    pr_state: {
      type: "varchar(16)",
      notNull: false,
      default: null,
    },
  });

  migration.addColumn("runs", {
    pr_url: {
      type: "text",
      notNull: false,
      default: null,
    },
  });

  migration.addColumn("runs", {
    pr_head_sha: {
      type: "varchar(64)",
      notNull: false,
      default: null,
    },
  });

  migration.addColumn("runs", {
    commit_sha: {
      type: "varchar(64)",
      notNull: false,
      default: null,
    },
  });

  migration.createIndex("runs", "pr_state", { ifNotExists: true });
  migration.createIndex("runs", "commit_sha", { ifNotExists: true });
}

export async function down(migration: MigrationBuilder): Promise<void> {
  migration.dropIndex("runs", "commit_sha", { ifExists: true });
  migration.dropIndex("runs", "pr_state", { ifExists: true });
  migration.dropColumn("runs", "commit_sha");
  migration.dropColumn("runs", "pr_head_sha");
  migration.dropColumn("runs", "pr_url");
  migration.dropColumn("runs", "pr_state");
}