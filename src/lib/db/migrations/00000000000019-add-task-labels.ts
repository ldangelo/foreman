/* eslint-disable @typescript-eslint/no-explicit-any */
import { MigrationBuilder } from "node-pg-migrate";

/**
 * Migration 00000000000019: add labels to tasks.
 *
 * GitHub/Jira importers preserve source labels here so workflow selection can
 * honor labels such as `workflow:feature` while still keeping the normalized
 * task `type` column for type-based workflows.
 */
export const up = (pgm: MigrationBuilder) => {
  pgm.addColumn("tasks", {
    labels: {
      type: "text[]",
      notNull: false,
      comment: "Source task labels used for workflow routing and metadata.",
    },
  });

  pgm.createIndex("tasks", "labels", {
    ifNotExists: true,
    method: "gin",
  });
};

export const down = (pgm: MigrationBuilder) => {
  pgm.dropIndex("tasks", "labels", { ifExists: true });
  pgm.dropColumn("tasks", "labels", { ifExists: true });
};
