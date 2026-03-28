/**
 * Session log types and prompt builder for /ensemble:sessionlog.
 *
 * Exported in a separate module so unit tests can import these
 * without triggering the agent-worker.ts entry-point (main().catch(process.exit)).
 */
/** Metadata passed to the session-log command. */
export interface SessionLogData {
    seedId: string;
    seedTitle: string;
    status: "completed" | "failed" | "stuck";
    phases: string;
    costUsd: number;
    turns: number;
    toolCalls: number;
    filesChanged: number;
    devRetries: number;
    qaVerdict: string;
}
/**
 * Build the prompt string for invoking /ensemble:sessionlog.
 * Exported for unit testing.
 */
export declare function buildSessionLogPrompt(data: SessionLogData): string;
//# sourceMappingURL=agent-worker-session-log.d.ts.map