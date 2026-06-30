import type { Run, RunProgress } from "../lib/store.js";
import type { NotificationBus } from "../orchestrator/notification-bus.js";
export declare function elapsed(since: string | null): string;
export declare function shortModel(model: string): string;
export declare function shortPath(path: string): string;
/**
 * Format a success rate value as a colored percentage string.
 *
 * @param rate - Value between 0 and 1, or null/undefined when there is insufficient data.
 * @returns A chalk-colored string like "87%" or "--" when rate is null/undefined.
 */
export declare function formatSuccessRate(rate: number | null | undefined): string;
/**
 * Read the last N lines from an agent's .err log file.
 * Returns an empty array if the file doesn't exist or can't be read.
 */
export declare function readLastErrorLines(runId: string, n?: number): string[];
/**
 * Render a single-line summary card for a collapsed agent.
 * Shows: indicator, status icon, seed ID, status, elapsed, model, and key
 * progress metrics on one line.
 */
export declare function renderAgentCardSummary(run: Run, progress: RunProgress | null, index?: number, attemptNumber?: number, previousStatus?: string): string;
/**
 * Render an agent card.
 * @param isExpanded - When false, delegates to the compact summary view.
 * @param index - Zero-based position in the run list; shown as a 1-based
 *   numeric prefix so users can press the matching key to toggle.
 * @param attemptNumber - If > 1, indicates this is a retry (e.g. attempt 2 of 3).
 * @param previousStatus - Status of the previous run (e.g. "failed", "stuck").
 */
export declare function renderAgentCard(run: Run, progress: RunProgress | null, isExpanded?: boolean, index?: number, attemptNumber?: number, previousStatus?: string, showErrorLogs?: boolean): string;
export interface WatchState {
    runs: Array<{
        run: Run;
        progress: RunProgress | null;
    }>;
    allDone: boolean;
    totalCost: number;
    totalTools: number;
    totalFiles: number;
    completedCount: number;
    failedCount: number;
    stuckCount: number;
    /** 24-hour success rate (0–1), or null when fewer than 3 terminal runs exist. */
    successRate?: number | null;
}
export declare function poll(store: WatchStore, runIds: string[]): Promise<WatchState>;
/**
 * Render the full watch display.
 *
 * @param showDetachHint - Show the "Ctrl+C to detach" hint (true in interactive
 *   watch mode, false in non-interactive contexts like `foreman status`).
 * @param expandedRunIds - When provided (i.e. not undefined), the function is
 *   running in interactive mode: each run is rendered collapsed or expanded
 *   based on whether its ID is in the set, and toggle key-binding hints are
 *   shown.  When omitted (undefined), all runs are rendered expanded and no
 *   key-binding hints are shown — safe for non-interactive output.
 */
export declare function renderWatchDisplay(state: WatchState, showDetachHint?: boolean, expandedRunIds?: Set<string>, notification?: string, showErrorLogs?: boolean): string;
export interface WatchResult {
    detached: boolean;
}
interface WatchStore {
    getRun(id: string): Run | null | Promise<Run | null>;
    getRunProgress(runId: string): RunProgress | null | Promise<RunProgress | null>;
    getSuccessRate(projectId: string): {
        rate: number | null;
        merged: number;
        failed: number;
    } | Promise<{
        rate: number | null;
        merged: number;
        failed: number;
    }>;
}
export declare function watchRunsInk(store: WatchStore, runIds: string[], opts?: {
    /** Optional notification bus — when provided, status/progress events wake
     *  the poll immediately instead of waiting for the next 3-second cycle. */
    notificationBus?: NotificationBus;
    /** Optional callback invoked when an agent completes and capacity may be
     *  available.  Returns IDs of newly-dispatched runs to add to the watch
     *  list.  Errors from this callback are swallowed (non-fatal). */
    autoDispatch?: () => Promise<string[]>;
}): Promise<WatchResult>;
export {};
//# sourceMappingURL=watch-ui.d.ts.map