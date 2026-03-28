import { Command } from "commander";
import type { TaskBackend } from "../../lib/feature-flags.js";
/**
 * Read the last `tool_call` event from a Pi JSONL `.out` log file.
 * Returns a short description string, or null if none can be found.
 *
 * Reads the last 8 KB of the file to avoid loading large logs into memory.
 */
export declare function getLastPiActivity(runId: string): Promise<string | null>;
/**
 * Returns the active task backend. Exported for testing.
 * TRD-024: Always returns 'br'; sd backend removed.
 */
export declare function getStatusBackend(): TaskBackend;
/**
 * Status counts returned by fetchStatusCounts.
 */
export interface StatusCounts {
    total: number;
    ready: number;
    inProgress: number;
    completed: number;
    blocked: number;
}
/**
 * Fetch task status counts using the br backend.
 *
 * TRD-024: sd backend removed. Always uses BeadsRustClient (br CLI).
 */
export declare function fetchStatusCounts(projectPath: string): Promise<StatusCounts>;
/**
 * Render a compact task-count header for use in the live dashboard view.
 * Shows br task counts (ready, in-progress, blocked, completed) as a
 * one-line summary suitable for prepending to the dashboard display.
 */
export declare function renderLiveStatusHeader(counts: StatusCounts): string;
export declare const statusCommand: Command;
//# sourceMappingURL=status.d.ts.map