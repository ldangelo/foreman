/**
 * JiraTriggerEvent — structured event emitted when a Jira status transition
 * triggers a Foreman workflow.
 *
 * This event is emitted via the Foreman event system (REQ-009) and includes
 * all metadata needed for observability, debugging, and audit trails.
 */
// ── Event emission ─────────────────────────────────────────────────────────────
/**
 * Emit a JiraTriggerEvent to all configured observers.
 *
 * Current observers:
 * - Console log (always)
 * - Foreman event bus (future)
 * - Sentinel dashboard via tRPC (future)
 */
export function emitJiraTriggerEvent(event) {
    // Always log to console for observability
    const logLevel = event.triggered ? "info" : "debug";
    const prefix = `[JiraTriggerEvent][${event.source}]`;
    if (logLevel === "info") {
        console.log(`${prefix} ${event.issueKey}: ${event.transition.from} → ${event.transition.to} → ${event.workflowName} (task: ${event.taskId ?? "none"})`);
    }
    else {
        console.debug(`${prefix} ${event.issueKey}: SKIPPED (${event.skipReason})`);
    }
    // TODO: Emit to Foreman event bus when implemented (TRD-028)
    // eventBus.emit("jira:trigger", event);
}
//# sourceMappingURL=jira-trigger-event.js.map