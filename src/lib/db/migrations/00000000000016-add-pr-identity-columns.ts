import type { MigrationBuilder } from "node-pg-migrate";

/**
 * Migration: Add canonical PR identity columns to runs table.
 *
 * `commit_sha` already exists on the base runs schema; this migration adds only
 * the PR-specific identity columns needed for canonical PR tracking.
 */
export async function up(migration: MigrationBuilder): Promise<void> {
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
      check: "pr_state IN ('none','draft','open','merged','closed')",
    },
  });

  migration.addColumn("runs", {
    pr_head_sha: {
      type: "varchar(64)",
      notNull: false,
    },
  });

  migration.createIndex("runs", "pr_state", { ifNotExists: true });
}

export async function down(migration: MigrationBuilder): Promise<void> {
  migration.dropIndex("runs", "pr_state", { ifExists: true });
  migration.dropColumn("runs", "pr_head_sha");
  migration.dropColumn("runs", "pr_state");
  migration.dropColumn("runs", "pr_url");
}