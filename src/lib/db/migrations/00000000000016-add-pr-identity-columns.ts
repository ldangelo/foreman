import type { MigrationBuilder } from "node-pg-migrate";

/**
 * Migration: Add canonical PR identity columns to runs table.
 *
 * These columns enable Foreman to:
 * - AC-1: Key PR identity to current run/head SHA, not branch name alone
 * - AC-2: Never reuse merged PRs for older heads
 * - AC-6: Use durable run/head/PR metadata for recovery
 *
 * New columns:
 * - commit_sha:     The HEAD SHA at the time this run's PR was created
 * - pr_url:         Canonical PR URL for this run (null = no PR yet)
 * - pr_state:       GitHub PR state: 'none' | 'draft' | 'open' | 'merged' | 'closed'
 * - pr_head_sha:    The branch HEAD SHA when PR was last updated (for mismatch detection)
 */
export async function up(migration: MigrationBuilder): Promise<void> {
  migration.addColumn("runs", {
    commit_sha: {
      type: "varchar(64)",
      notNull: false,
    },
  });

  migration.addColumn("runs", {
    pr_url: {
      type: "text",
      notNull: false,
    },
  });

  migration.addColumn("runs", {
    pr_state: {
      type: "varchar(16)",
      notNull: false,
      default: "'none'",
      check: "pr_state IN ('none','draft','open','merged','closed')",
    },
  });

  migration.addColumn("runs", {
    pr_head_sha: {
      type: "varchar(64)",
      notNull: false,
    },
  });

  migration.createIndex("runs", "commit_sha", { ifNotExists: true });
  migration.createIndex("runs", "pr_state", { ifNotExists: true });
}

export async function down(migration: MigrationBuilder): Promise<void> {
  migration.dropIndex("runs", "pr_head_sha", { ifExists: true });
  migration.dropIndex("runs", "pr_state", { ifExists: true });
  migration.dropIndex("runs", "commit_sha", { ifExists: true });
  migration.dropColumn("runs", "pr_head_sha");
  migration.dropColumn("runs", "pr_state");
  migration.dropColumn("runs", "pr_url");
  migration.dropColumn("runs", "commit_sha");
}