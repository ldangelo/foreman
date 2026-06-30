import type { MigrationBuilder } from "node-pg-migrate";
/**
 * Legacy migration placeholder kept for existing databases.
 *
 * Some developer DBs already recorded this migration, so the source tree must
 * continue to expose the same version to keep later migrations in order.
 */
export declare const up: (_pgm: MigrationBuilder) => void;
export declare const down: (_pgm: MigrationBuilder) => void;
//# sourceMappingURL=00000000000021-drop-bead-write-queue.d.ts.map