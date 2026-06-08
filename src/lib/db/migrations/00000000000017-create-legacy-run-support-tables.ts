import type { MigrationBuilder } from "node-pg-migrate";

export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.createTable("costs", {
    id: {
      type: "uuid",
      notNull: true,
      primaryKey: true,
      default: pgm.func("gen_random_uuid()"),
    },
    run_id: {
      type: "uuid",
      notNull: true,
      references: "runs(id)",
      onDelete: "CASCADE",
    },
    tokens_in: {
      type: "integer",
      notNull: true,
    },
    tokens_out: {
      type: "integer",
      notNull: true,
    },
    cache_read: {
      type: "integer",
      notNull: true,
      default: 0,
    },
    estimated_cost: {
      type: "numeric(12,6)",
      notNull: true,
    },
    recorded_at: {
      type: "timestamp with time zone",
      notNull: true,
      default: "now()",
    },
  }, { ifNotExists: true });
  pgm.createIndex("costs", "run_id", { ifNotExists: true });
  pgm.createIndex("costs", "recorded_at", { ifNotExists: true });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropTable("costs", { ifExists: true });
}
