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
export async function up(pgm) {
    // -------------------------------------------------------------------------
    // jira_projects: Jira instance configuration per Foreman project
    // -------------------------------------------------------------------------
    pgm.createTable("jira_projects", {
        id: {
            type: "uuid",
            primaryKey: true,
            default: pgm.func("gen_random_uuid()"),
        },
        project_id: {
            type: "uuid",
            notNull: true,
        },
        api_url: {
            type: "text",
            notNull: true,
        },
        email: {
            type: "text",
            notNull: true,
        },
        api_token_encrypted: {
            type: "text",
            notNull: true,
        },
        poll_interval_seconds: {
            type: "integer",
            default: 60,
        },
        webhook_enabled: {
            type: "boolean",
            default: false,
        },
        webhook_secret_encrypted: {
            type: "text",
        },
        last_poll_at: {
            type: "timestamptz",
        },
        created_at: {
            type: "timestamptz",
            notNull: true,
            default: pgm.func("now()"),
        },
        updated_at: {
            type: "timestamptz",
            notNull: true,
            default: pgm.func("now()"),
        },
    });
    pgm.addConstraint("jira_projects", "jira_projects_project_id_unique", {
        unique: ["project_id"],
    });
    // Create the trigger function if it doesn't exist (TRD-004 pattern)
    pgm.sql(`
    CREATE OR REPLACE FUNCTION trigger_set_updated_at()
    RETURNS TRIGGER AS $$
    BEGIN
      NEW.updated_at = NOW();
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
  `);
    pgm.sql(`
    CREATE TRIGGER set_jira_projects_updated_at
    BEFORE UPDATE ON jira_projects
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_updated_at();
  `);
    pgm.addConstraint("jira_projects", "jira_projects_project_id_fkey", {
        foreignKeys: [
            {
                columns: ["project_id"],
                references: "projects(id)",
                onDelete: "CASCADE",
            },
        ],
    });
    pgm.createIndex("jira_projects", ["project_id"], {
        ifNotExists: true,
    });
    // -------------------------------------------------------------------------
    // jira_monitored_projects: Per-Jira-project monitoring config
    // -------------------------------------------------------------------------
    pgm.createTable("jira_monitored_projects", {
        id: {
            type: "uuid",
            primaryKey: true,
            default: pgm.func("gen_random_uuid()"),
        },
        jira_project_id: {
            type: "uuid",
            notNull: true,
        },
        jira_project_key: {
            type: "text",
            notNull: true,
        },
        start_status: {
            type: "text[]",
            notNull: true,
        },
        end_status: {
            type: "text[]",
        },
        issue_type_workflow_map: {
            type: "jsonb",
            notNull: true,
            default: "{}",
        },
        debounce_window_seconds: {
            type: "integer",
            default: 60,
        },
        created_at: {
            type: "timestamptz",
            notNull: true,
            default: pgm.func("now()"),
        },
        updated_at: {
            type: "timestamptz",
            notNull: true,
            default: pgm.func("now()"),
        },
    });
    pgm.addConstraint("jira_monitored_projects", "jira_monitored_projects_key_unique", {
        unique: ["jira_project_id", "jira_project_key"],
    });
    pgm.sql(`
    CREATE TRIGGER set_jira_monitored_projects_updated_at
    BEFORE UPDATE ON jira_monitored_projects
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_updated_at();
  `);
    pgm.addConstraint("jira_monitored_projects", "jira_monitored_projects_jira_project_id_fkey", {
        foreignKeys: [
            {
                columns: ["jira_project_id"],
                references: "jira_projects(id)",
                onDelete: "CASCADE",
            },
        ],
    });
    pgm.createIndex("jira_monitored_projects", ["jira_project_id"], {
        ifNotExists: true,
    });
    // -------------------------------------------------------------------------
    // jira_issue_states: Tracks last known status per Jira issue
    // -------------------------------------------------------------------------
    pgm.createTable("jira_issue_states", {
        id: {
            type: "uuid",
            primaryKey: true,
            default: pgm.func("gen_random_uuid()"),
        },
        jira_project_id: {
            type: "uuid",
            notNull: true,
        },
        issue_key: {
            type: "text",
            notNull: true,
        },
        last_known_status: {
            type: "text",
            notNull: true,
        },
        last_triggered_at: {
            type: "timestamptz",
            comment: "Used for debounce: if NOW() - last_triggered_at < debounce_window, skip trigger",
        },
        last_updated_at: {
            type: "timestamptz",
            notNull: true,
            default: pgm.func("now()"),
        },
    });
    pgm.addConstraint("jira_issue_states", "jira_issue_states_key_unique", {
        unique: ["jira_project_id", "issue_key"],
    });
    pgm.addConstraint("jira_issue_states", "jira_issue_states_jira_project_id_fkey", {
        foreignKeys: [
            {
                columns: ["jira_project_id"],
                references: "jira_projects(id)",
                onDelete: "CASCADE",
            },
        ],
    });
    // Index for efficient issue lookups
    pgm.createIndex("jira_issue_states", ["issue_key"], {
        ifNotExists: true,
    });
    // Index for cleanup of old entries
    pgm.createIndex("jira_issue_states", ["last_updated_at"], {
        ifNotExists: true,
    });
    // Index for debounce queries: find entries where last_triggered_at is recent
    pgm.createIndex("jira_issue_states", ["last_triggered_at"], {
        ifNotExists: true,
        where: "last_triggered_at IS NOT NULL",
    });
    // -------------------------------------------------------------------------
    // Extend tasks table with Jira-specific columns
    // -------------------------------------------------------------------------
    pgm.addColumns("tasks", {
        jira_issue_key: {
            type: "text",
            comment: "e.g., 'PROJ-123' - Jira issue key for integration",
        },
        jira_project_key: {
            type: "text",
            comment: "e.g., 'PROJ' - Jira project key for integration",
        },
    });
    // Performance index for Jira issue lookups
    pgm.createIndex("tasks", ["jira_issue_key"], {
        ifNotExists: true,
        where: "jira_issue_key IS NOT NULL",
    });
}
export async function down(pgm) {
    pgm.dropIndex("tasks", ["jira_issue_key"], { ifExists: true });
    pgm.dropColumns("tasks", ["jira_issue_key", "jira_project_key"]);
    pgm.dropTable("jira_issue_states", { ifExists: true });
    pgm.dropTable("jira_monitored_projects", { ifExists: true });
    pgm.dropTable("jira_projects", { ifExists: true });
}
//# sourceMappingURL=00000000000018-create-jira-tables.js.map