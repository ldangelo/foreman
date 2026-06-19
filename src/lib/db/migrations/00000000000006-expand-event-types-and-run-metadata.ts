import type { MigrationBuilder } from "node-pg-migrate";

export async function up(pgm: MigrationBuilder): Promise<void> {
  pgm.addColumns("runs", {
    agent_type: { type: "varchar(64)", notNull: false },
    session_key: { type: "text", notNull: false },
    worktree_path: { type: "text", notNull: false },
    progress: { type: "jsonb", notNull: false, default: null },
    base_branch: { type: "varchar(255)", notNull: false },
    merge_strategy: {
      type: "varchar(16)",
      notNull: false,
      check: "merge_strategy IN ('auto','pr','none')",
    },
  }, { ifNotExists: true });

  pgm.createIndex("runs", "agent_type", { ifNotExists: true });

  pgm.sql(`ALTER TABLE events DROP CONSTRAINT IF EXISTS events_event_type_check`);
  pgm.sql(`ALTER TABLE events ADD CONSTRAINT events_event_type_check CHECK (
    event_type IN (
      'run:queued','run:started','run:success','run:failure','run:cancelled',
      'task:claimed','task:approved','task:rejected','task:reset','bead:synced','bead:conflict',
      'dispatch','claim','complete','fail','merge','stuck','restart','recover','conflict','test-fail','pr-created'
    )
  )`);
}

export async function down(pgm: MigrationBuilder): Promise<void> {
  pgm.sql(`ALTER TABLE events DROP CONSTRAINT IF EXISTS events_event_type_check`);
  pgm.sql(`ALTER TABLE events ADD CONSTRAINT events_event_type_check CHECK (
    event_type IN (
      'run:queued','run:started','run:success','run:failure','run:cancelled',
      'task:claimed','task:approved','task:rejected','task:reset','bead:synced','bead:conflict'
    )
  )`);

  pgm.dropIndex("runs", "agent_type", { ifExists: true });
  pgm.dropColumns("runs", [
    "agent_type",
    "session_key",
    "worktree_path",
    "progress",
    "base_branch",
    "merge_strategy",
  ], { ifExists: true });
}
