import type { MigrationBuilder } from "node-pg-migrate";

export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.createTable("merge_costs", {
    id: { type: "bigserial", primaryKey: true },
    project_id: { type: "uuid", notNull: true },
    session_id: { type: "text", notNull: true },
    merge_queue_id: { type: "bigint", notNull: false },
    file_path: { type: "text", notNull: true },
    tier: { type: "integer", notNull: true },
    model: { type: "text", notNull: true },
    input_tokens: { type: "integer", notNull: true },
    output_tokens: { type: "integer", notNull: true },
    estimated_cost_usd: { type: "double precision", notNull: true },
    actual_cost_usd: { type: "double precision", notNull: true },
    recorded_at: { type: "timestamp with time zone", notNull: true },
  });

  pgm.addConstraint("merge_costs", "merge_costs_project_id_fkey", {
    foreignKeys: {
      columns: ["project_id"],
      references: "projects(id)",
      onDelete: "CASCADE",
    },
  });
  pgm.addConstraint("merge_costs", "merge_costs_merge_queue_id_fkey", {
    foreignKeys: {
      columns: ["merge_queue_id"],
      references: "merge_queue(id)",
      onDelete: "SET NULL",
    },
  });

  pgm.createIndex("merge_costs", ["project_id", "recorded_at"], { ifNotExists: true });
  pgm.createIndex("merge_costs", ["session_id"], { ifNotExists: true });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropTable("merge_costs", { ifExists: true });
}
