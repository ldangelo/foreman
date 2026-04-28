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
export async function up(pgm: MigrationBuilder): Promise<void> {
  // -------------------------------------------------------------------------
  // github_repos: Per-project GitHub repository configuration
  // -------------------------------------------------------------------------
  pgm.createTable("github_repos", {
    id: {
      type: "uuid",
      notNull: true,
      primaryKey: true,
      default: pgm.func("gen_random_uuid()"),
    },
    project_id: {
      type: "uuid",
      notNull: true,
    },
    owner: {
      type: "varchar(255)",
      notNull: true,
    },
    repo: {
      type: "varchar(255)",
      notNull: true,
    },
    auth_type: {
      type: "varchar(32)",
      notNull: true,
    },
    auth_config: {
      type: "jsonb",
      notNull: true,
      default: "'{}'",
    },
    default_labels: {
      type: "text[]",
      notNull: true,
      default: "'{}'",
    },
    auto_import: {
      type: "boolean",
      notNull: true,
      default: false,
    },
    webhook_secret: {
      type: "text",
      notNull: false,
    },
    webhook_enabled: {
      type: "boolean",
      notNull: true,
      default: false,
    },
    sync_strategy: {
      type: "varchar(64)",
      notNull: true,
      default: "github-wins",
    },
    last_sync_at: {
      type: "timestamp with time zone",
      notNull: false,
    },
    created_at: {
      type: "timestamp with time zone",
      notNull: true,
      default: "now()",
    },
    updated_at: {
      type: "timestamp with time zone",
      notNull: true,
      default: "now()",
    },
  });

  pgm.addConstraint(
    "github_repos",
    "github_repos_project_id_owner_repo_unique",
    {
      unique: ["project_id", "owner", "repo"],
    },
  );

  pgm.sql(`
    ALTER TABLE github_repos
    ADD CONSTRAINT github_repos_auth_type_check
    CHECK (auth_type IN ('pat', 'app'))
  `);

  pgm.sql(`
    ALTER TABLE github_repos
    ADD CONSTRAINT github_repos_sync_strategy_check
    CHECK (sync_strategy IN ('foreman-wins', 'github-wins', 'manual', 'last-write-wins'))
  `);

  pgm.addConstraint("github_repos", "github_repos_project_id_fkey", {
    foreignKeys: {
      columns: ["project_id"],
      references: "projects(id)",
      onDelete: "CASCADE",
    },
  });

  pgm.createIndex("github_repos", ["project_id"], { ifNotExists: true });

  // -------------------------------------------------------------------------
  // github_sync_events: Audit log for sync operations
  // -------------------------------------------------------------------------
  pgm.createTable("github_sync_events", {
    id: {
      type: "uuid",
      notNull: true,
      primaryKey: true,
      default: pgm.func("gen_random_uuid()"),
    },
    project_id: {
      type: "uuid",
      notNull: true,
    },
    external_id: {
      type: "text",
      notNull: true,
    },
    event_type: {
      type: "varchar(64)",
      notNull: true,
    },
    direction: {
      type: "varchar(32)",
      notNull: true,
    },
    github_payload: {
      type: "jsonb",
      notNull: false,
    },
    foreman_changes: {
      type: "jsonb",
      notNull: false,
    },
    conflict_detected: {
      type: "boolean",
      notNull: true,
      default: false,
    },
    resolved_with: {
      type: "varchar(32)",
      notNull: false,
    },
    processed_at: {
      type: "timestamp with time zone",
      notNull: true,
      default: "now()",
    },
  });

  pgm.sql(`
    ALTER TABLE github_sync_events
    ADD CONSTRAINT github_sync_events_direction_check
    CHECK (direction IN ('to_github', 'from_github'))
  `);

  pgm.addConstraint("github_sync_events", "github_sync_events_project_id_fkey", {
    foreignKeys: {
      columns: ["project_id"],
      references: "projects(id)",
      onDelete: "CASCADE",
    },
  });

  pgm.createIndex("github_sync_events", ["project_id"], {
    ifNotExists: true,
  });
  pgm.createIndex("github_sync_events", ["external_id"], {
    ifNotExists: true,
  });
  pgm.createIndex("github_sync_events", ["processed_at"], {
    ifNotExists: true,
  });

  // -------------------------------------------------------------------------
  // Extend tasks table with GitHub-specific columns
  // -------------------------------------------------------------------------
  pgm.addColumns("tasks", {
    external_repo: {
      type: "text",
      notNull: false,
    },
    github_issue_number: {
      type: "integer",
      notNull: false,
    },
    github_milestone: {
      type: "text",
      notNull: false,
    },
    sync_enabled: {
      type: "boolean",
      notNull: true,
      default: false,
    },
    last_sync_at: {
      type: "timestamp with time zone",
      notNull: false,
    },
  });

  // Performance indexes for GitHub sync operations
  pgm.createIndex("tasks", ["external_repo"], {
    ifNotExists: true,
    where: "external_repo IS NOT NULL",
  });

  pgm.createIndex(
    "tasks",
    ["external_repo", "github_issue_number"],
    {
      ifNotExists: true,
      where: "external_repo IS NOT NULL AND github_issue_number IS NOT NULL",
    },
  );
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropTable("github_sync_events", { ifExists: true });
  pgm.dropTable("github_repos", { ifExists: true });

  pgm.dropColumns("tasks", [
    "last_sync_at",
    "sync_enabled",
    "github_milestone",
    "github_issue_number",
    "external_repo",
  ], { ifExists: true });
}
