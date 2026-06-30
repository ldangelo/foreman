import { MigrationBuilder } from "node-pg-migrate";
/**
 * Initial migration: create projects table and schema_migrations tracking table.
 *
 * The projects table stores all project metadata managed by ForemanDaemon and
 * is the source of truth for the multi-project orchestrator (TRD-2026-011).
 *
 * @module db/migrations/00000000000000-create-projects
 */
export declare const up: (pgm: MigrationBuilder) => void;
export declare const down: (pgm: MigrationBuilder) => void;
//# sourceMappingURL=00000000000000-create-projects.d.ts.map