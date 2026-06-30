const LEGACY_EVENT_TYPES = [
    "run:queued",
    "run:started",
    "run:success",
    "run:failure",
    "run:cancelled",
    "task:claimed",
    "task:approved",
    "task:rejected",
    "task:reset",
    "bead:synced",
    "bead:conflict",
];
const FOREMAN_EVENT_TYPES = [
    "dispatch",
    "claim",
    "complete",
    "fail",
    "merge",
    "stuck",
    "restart",
    "recover",
    "conflict",
    "test-fail",
    "pr-created",
    "pr-stale",
    "merge-queue-enqueue",
    "merge-queue-dequeue",
    "merge-queue-resolve",
    "merge-queue-fallback",
    "merge-cleanup-fallback",
    "sentinel-start",
    "sentinel-pass",
    "sentinel-fail",
    "heartbeat",
    "guardrail-veto",
    "guardrail-corrected",
    "worktree-rebased",
    "worktree-rebase-failed",
    "phase-start",
    "phase-complete",
];
function eventTypeList(types) {
    return types.map((type) => `'${type}'`).join(",");
}
export async function up(pgm) {
    pgm.sql(`ALTER TABLE events DROP CONSTRAINT IF EXISTS events_event_type_check`);
    pgm.sql(`ALTER TABLE events ADD CONSTRAINT events_event_type_check CHECK (
    event_type IN (${eventTypeList([...LEGACY_EVENT_TYPES, ...FOREMAN_EVENT_TYPES])})
  )`);
}
export async function down(pgm) {
    pgm.sql(`ALTER TABLE events DROP CONSTRAINT IF EXISTS events_event_type_check`);
    pgm.sql(`ALTER TABLE events ADD CONSTRAINT events_event_type_check CHECK (
    event_type IN (${eventTypeList([
        ...LEGACY_EVENT_TYPES,
        "dispatch",
        "claim",
        "complete",
        "fail",
        "merge",
        "stuck",
        "restart",
        "recover",
        "conflict",
        "test-fail",
        "pr-created",
        "sentinel-start",
        "sentinel-pass",
        "sentinel-fail",
        "phase-start",
        "heartbeat",
    ])})
  )`);
}
//# sourceMappingURL=00000000000020-expand-run-event-types.js.map