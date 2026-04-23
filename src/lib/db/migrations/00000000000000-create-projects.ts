/* eslint-disable @typescript-eslint/no-explicit-any */
import { MigrationBuilder, ColumnDefinition } from "node-pg-migrate";

/**
 * Initial migration: create projects table and schema_migrations tracking table.
 *
 * The projects table stores all project metadata managed by ForemanDaemon and
 * is the source of truth for the multi-project orchestrator (TRD-2026-011).
 *
 * @module db/migrations/00000000000000-create-projects
 */

export const up = (pgm: MigrationBuilder) => {
  // ── Projects table ────────────────────────────────────────────────────────

  pgm.createTable("projects", {
    id: {
      type: "uuid",
      primaryKey: true,
      default: pgm.func("gen_random_uuid()"),
      notNull: true,
    },
    name: {
      type: "varchar(255)",
      notNull: true,
      comment: "Human-readable project name",
    },
    path: {
      type: "text",
      notNull: true,
      comment: "Absolute filesystem path to the project root",
    },
    github_url: {
      type: "text",
      notNull: false,
      comment: "GitHub repository clone URL (e.g. git@github.com:org/repo.git)",
    },
    default_branch: {
      type: "varchar(255)",
      notNull: false,
      default: "'main'",
      comment: "Default git branch for this project",
    },
    status: {
      type: "varchar(32)",
      notNull: true,
      default: "'active'",
      check: "status IN ('active', 'paused', 'archived')",
      comment: "Project lifecycle status",
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
    last_sync_at: {
      type: "timestamptz",
      notNull: false,
      comment: "Last successful git sync (fetch + timestamp update)",
    },
  });

  // ── Indexes ───────────────────────────────────────────────────────────────

  pgm.createIndex("projects", "status", { ifNotExists: true });
  pgm.createIndex("projects", "name", { ifNotExists: true });
  pgm.createIndex("projects", "path", { ifNotExists: true });

  // ── Unique constraints ────────────────────────────────────────────────────

  pgm.addConstraint(
    "projects",
    "projects_path_unique",
    {
      unique: ["path"],
      comment: "Each filesystem path may only be registered once",
    },
  );

  // ── Schema migrations tracking (node-pg-migrate convention) ───────────────

  pgm.createTable("schema_migrations", {
    version: {
      type: "varchar(255)",
      primaryKey: true,
      notNull: true,
    },
    name: {
      type: "varchar(255)",
      notNull: false,
    },
    run_at: {
      type: "timestamptz",
      notNull: true,
      default: pgm.func("now()"),
    },
  });

  pgm.sql(`
    COMMENT ON TABLE projects IS
      'Foreman multi-project orchestrator: one row per registered project.';
    COMMENT ON COLUMN projects.github_url IS
      'SSH or HTTPS clone URL. Null means the project is not a git repo or was added without a remote.';
    COMMENT ON COLUMN projects.last_sync_at IS
      'Updated by syncProject(). Null means never synced.';
  `);
};

export const down = (pgm: MigrationBuilder) => {
  pgm.dropTable("projects", { ifExists: true });
  pgm.dropTable("schema_migrations", { ifExists: true });
};
