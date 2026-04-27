import type { MigrationBuilder } from "node-pg-migrate";

export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.createTable("agent_messages", {
    id: {
      type: "uuid",
      notNull: true,
      primaryKey: true,
      default: pgm.func("gen_random_uuid()"),
    },
    project_id: {
      type: "uuid",
      notNull: true,
    },
    run_id: {
      type: "uuid",
      notNull: true,
    },
    sender_agent_type: {
      type: "varchar(64)",
      notNull: true,
    },
    recipient_agent_type: {
      type: "varchar(64)",
      notNull: true,
    },
    subject: {
      type: "varchar(255)",
      notNull: true,
    },
    body: {
      type: "text",
      notNull: true,
    },
    read: {
      type: "integer",
      notNull: true,
      default: 0,
    },
    created_at: {
      type: "timestamp with time zone",
      notNull: true,
      default: "now()",
    },
    deleted_at: {
      type: "timestamp with time zone",
      notNull: false,
    },
  });

  pgm.addConstraint("agent_messages", "agent_messages_project_id_fkey", {
    foreignKeys: {
      columns: ["project_id"],
      references: "projects(id)",
      onDelete: "CASCADE",
    },
  });

  pgm.addConstraint("agent_messages", "agent_messages_run_id_fkey", {
    foreignKeys: {
      columns: ["run_id"],
      references: "runs(id)",
      onDelete: "CASCADE",
    },
  });

  pgm.createIndex("agent_messages", "project_id", { ifNotExists: true });
  pgm.createIndex("agent_messages", "run_id", { ifNotExists: true });
  pgm.createIndex("agent_messages", "recipient_agent_type", { ifNotExists: true });
  pgm.createIndex("agent_messages", "created_at", { ifNotExists: true });
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.dropTable("agent_messages", { ifExists: true });
}
