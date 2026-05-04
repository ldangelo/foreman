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

  pgm.createTable("bead_write_queue", {
    id: {
      type: "uuid",
      notNull: true,
      primaryKey: true,
      default: pgm.func("gen_random_uuid()"),
    },
    project_id: {
      type: "uuid",
      notNull: true,
      references: "projects(id)",
      onDelete: "CASCADE",
    },
    sender: {
      type: "text",
      notNull: true,
    },
    operation: {
      type: "text",
      notNull: true,
    },
    payload: {
      type: "text",
      notNull: true,
    },
    created_at: {
      type: "timestamp with time zone",
      notNull: true,
      default: "now()",
    },
    processed_at: {
      type: "timestamp with time zone",
      notNull: false,
    },
  }, { ifNotExists: true });
  pgm.createIndex("bead_write_queue", ["project_id", "processed_at", "created_at"], {
    ifNotExists: true,
    name: "idx_bead_write_queue_pending",
  });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropIndex("bead_write_queue", ["project_id", "processed_at", "created_at"], {
    ifExists: true,
    name: "idx_bead_write_queue_pending",
  });
  pgm.dropTable("bead_write_queue", { ifExists: true });
  pgm.dropTable("costs", { ifExists: true });
}
