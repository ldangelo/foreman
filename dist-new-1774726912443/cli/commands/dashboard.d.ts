import { Command } from "commander";
import { ForemanStore, type Project, type Run, type RunProgress, type Metrics, type Event } from "../../lib/store.js";
/**
 * Task counts fetched from the br backend for display in dashboard --simple.
 */
export interface DashboardTaskCounts {
    total: number;
    ready: number;
    inProgress: number;
    completed: number;
    blocked: number;
}
/**
 * Fetch br task counts for the compact status view (used by --simple mode).
 * Returns zeros if br is not initialized or binary is missing.
 */
export declare function fetchDashboardTaskCounts(projectPath: string): Promise<DashboardTaskCounts>;
export interface DashboardState {
    projects: Project[];
    activeRuns: Map<string, Run[]>;
    completedRuns: Map<string, Run[]>;
    progresses: Map<string, RunProgress | null>;
    metrics: Map<string, Metrics>;
    events: Map<string, Event[]>;
    lastUpdated: Date;
}
/**
 * Format a single event as a compact timeline line.
 */
export declare function renderEventLine(event: Event): string;
/**
 * Render a summary line for a project header.
 */
export declare function renderProjectHeader(project: Project, activeCount: number, metrics: Metrics): string;
/**
 * Render the full dashboard display as a string.
 */
export declare function renderDashboard(state: DashboardState): string;
/**
 * Collect dashboard data from the store.
 */
export declare function pollDashboard(store: ForemanStore, projectId?: string, eventsLimit?: number): DashboardState;
/**
 * Render a simplified single-project dashboard view.
 * Used by `dashboard --simple` for a compact status display similar to
 * `foreman status --watch` but using the dashboard's data layer.
 *
 * Shows: task counts (from br), active agents, costs — no event timeline,
 * no recently-completed section, no multi-project header.
 */
export declare function renderSimpleDashboard(state: DashboardState, counts: DashboardTaskCounts, projectId?: string): string;
export declare const dashboardCommand: Command;
//# sourceMappingURL=dashboard.d.ts.map