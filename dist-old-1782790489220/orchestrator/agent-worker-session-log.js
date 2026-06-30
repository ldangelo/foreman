/**
 * Session log types and prompt builder for /ensemble:sessionlog.
 *
 * Exported in a separate module so unit tests can import these
 * without triggering the agent-worker.ts entry-point (main().catch(process.exit)).
 */
/**
 * Build the prompt string for invoking /ensemble:sessionlog.
 * Exported for unit testing.
 */
export function buildSessionLogPrompt(data) {
    const summary = [
        `Seed: ${data.seedId}`,
        `Title: ${data.seedTitle}`,
        `Status: ${data.status}`,
        `Phases: ${data.phases}`,
        `Cost: $${data.costUsd.toFixed(4)}`,
        `Turns: ${data.turns}`,
        `Tool calls: ${data.toolCalls}`,
        `Files changed: ${data.filesChanged}`,
        `Dev retries: ${data.devRetries}`,
        `QA verdict: ${data.qaVerdict}`,
    ].join("\n");
    return `/ensemble:sessionlog ${summary}\n\nSave the session log to the SessionLogs/ directory.`;
}
//# sourceMappingURL=agent-worker-session-log.js.map