import type { MigrationBuilder } from "node-pg-migrate";

/**
 * Add compatibility storage for Foreman mail and deferred bead-write APIs.
 */
export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.sql(`
    ALTER TABLE messages ADD COLUMN IF NOT EXISTS sender_agent_type varchar(255);
    ALTER TABLE messages ADD COLUMN IF NOT EXISTS recipient_agent_type varchar(255);
    ALTER TABLE messages ADD COLUMN IF NOT EXISTS subject text;
    ALTER TABLE messages ADD COLUMN IF NOT EXISTS body text;
    ALTER TABLE messages ADD COLUMN IF NOT EXISTS read integer DEFAULT 0;
    ALTER TABLE messages ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
  `);

  pgm.createIndex("messages", ["run_id", "recipient_agent_type"], {
    ifNotExists: true,
    name: "idx_messages_run_recipient",
  });
  pgm.createIndex("messages", ["run_id", "sender_agent_type"], {
    ifNotExists: true,
    name: "idx_messages_run_sender",
  });

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
      references: "projects",
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
      type: "timestamptz",
      notNull: true,
      default: pgm.func("now()"),
    },
    processed_at: {
      type: "timestamptz",
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

  pgm.dropIndex("messages", ["run_id", "sender_agent_type"], {
    ifExists: true,
    name: "idx_messages_run_sender",
  });
  pgm.dropIndex("messages", ["run_id", "recipient_agent_type"], {
    ifExists: true,
    name: "idx_messages_run_recipient",
  });

  pgm.sql(`
    ALTER TABLE messages DROP COLUMN IF EXISTS deleted_at;
    ALTER TABLE messages DROP COLUMN IF EXISTS read;
    ALTER TABLE messages DROP COLUMN IF EXISTS body;
    ALTER TABLE messages DROP COLUMN IF EXISTS subject;
    ALTER TABLE messages DROP COLUMN IF EXISTS recipient_agent_type;
    ALTER TABLE messages DROP COLUMN IF EXISTS sender_agent_type;
  `);
}
