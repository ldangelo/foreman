export async function up(pgm) {
    pgm.sql(`ALTER TABLE events DROP CONSTRAINT IF EXISTS events_event_type_check`);
    pgm.sql(`ALTER TABLE events ADD CONSTRAINT events_event_type_check CHECK (
    event_type IN (
      'run:queued','run:started','run:success','run:failure','run:cancelled',
      'task:claimed','task:approved','task:rejected','task:reset','bead:synced','bead:conflict',
      'dispatch','claim','complete','fail','merge','stuck','restart','recover','conflict','test-fail','pr-created',
      'sentinel-start','sentinel-pass','sentinel-fail','phase-start','heartbeat'
    )
  )`);
}
export async function down(pgm) {
    pgm.sql(`ALTER TABLE events DROP CONSTRAINT IF EXISTS events_event_type_check`);
    pgm.sql(`ALTER TABLE events ADD CONSTRAINT events_event_type_check CHECK (
    event_type IN (
      'run:queued','run:started','run:success','run:failure','run:cancelled',
      'task:claimed','task:approved','task:rejected','task:reset','bead:synced','bead:conflict',
      'dispatch','claim','complete','fail','merge','stuck','restart','recover','conflict','test-fail','pr-created',
      'sentinel-start','sentinel-pass','sentinel-fail'
    )
  )`);
}
//# sourceMappingURL=00000000000011-expand-registered-observability-event-types.js.map