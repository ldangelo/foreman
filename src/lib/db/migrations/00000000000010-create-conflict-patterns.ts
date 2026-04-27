import type { MigrationBuilder } from "node-pg-migrate";

export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.createTable("conflict_patterns", {
    id: { type: "bigserial", primaryKey: true },
    project_id: { type: "uuid", notNull: true },
    file_path: { type: "text", notNull: true },
    file_extension: { type: "text", notNull: true },
    tier: { type: "integer", notNull: true },
    success: { type: "integer", notNull: true },
    failure_reason: { type: "text", notNull: false },
    merge_queue_id: { type: "bigint", notNull: false },
    seed_id: { type: "text", notNull: false },
    recorded_at: { type: "timestamp with time zone", notNull: true },
  });

  pgm.addConstraint("conflict_patterns", "conflict_patterns_project_id_fkey", {
    foreignKeys: {
      columns: ["project_id"],
      references: "projects(id)",
      onDelete: "CASCADE",
    },
  });
  pgm.addConstraint("conflict_patterns", "conflict_patterns_merge_queue_id_fkey", {
    foreignKeys: {
      columns: ["merge_queue_id"],
      references: "merge_queue(id)",
      onDelete: "SET NULL",
    },
  });
  pgm.createIndex("conflict_patterns", ["project_id", "file_extension", "tier"], { ifNotExists: true });
  pgm.createIndex("conflict_patterns", ["merge_queue_id"], { ifNotExists: true });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropTable("conflict_patterns", { ifExists: true });
}
