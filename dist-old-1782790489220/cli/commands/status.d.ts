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
 * TRD-024: Native Postgres task store is the only supported backend.
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
export interface DaemonRunSummary {
    id: string;
    seed_id?: string;
    bead_id?: string;
    status: string;
    branch?: string | null;
    started_at?: string | null;
    queued_at?: string;
    created_at: string;
}
interface DaemonStatusSnapshot {
    projectId: string;
    counts: StatusCounts;
    failed: number;
    stuck: number;
    activeRuns: DaemonRunSummary[];
}
export declare function fetchDaemonStatusSnapshot(projectPath: string): Promise<DaemonStatusSnapshot | null>;
export declare function renderDaemonRunCard(run: DaemonRunSummary): string;
/**
 * Fetch task status counts using the shared task backend selector.
 */
export declare function fetchStatusCounts(projectPath: string): Promise<StatusCounts>;
/**
 * Render a compact task-count header for use in the live dashboard view.
 * Shows br task counts (ready, in-progress, blocked, completed) as a
 * one-line summary suitable for prepending to the dashboard display.
 */
export declare function renderLiveStatusHeader(counts: StatusCounts): string;
export declare const statusCommand: Command;
export {};
//# sourceMappingURL=status.d.ts.map