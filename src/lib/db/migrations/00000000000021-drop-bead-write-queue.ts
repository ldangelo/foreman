import type { MigrationBuilder } from "node-pg-migrate";

/**
 * Legacy migration placeholder kept for existing databases.
 *
 * Some developer DBs already recorded this migration, so the source tree must
 * continue to expose the same version to keep later migrations in order.
 */
export const up = (_pgm: MigrationBuilder) => {
  // no-op
};

export const down = (_pgm: MigrationBuilder) => {
  // no-op
};
