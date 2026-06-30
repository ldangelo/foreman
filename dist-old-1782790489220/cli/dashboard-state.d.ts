import { type DashboardReadStore, type Project, type Run, type RunProgress, type Metrics, type Event, type NativeTask } from "../lib/store.js";
export declare function fetchDaemonDashboardState(projectPath: string, projectId?: string): Promise<DashboardState | null>;
/** Snapshot of a single project collected via READONLY DB connection. */
export interface ProjectSnapshot {
    project: Project;
    activeRuns: Run[];
    completedRuns: Run[];
    progresses: Map<string, RunProgress | null>;
    metrics: Metrics;
    events: Event[];
    successRate: {
        rate: number | null;
        merged: number;
        failed: number;
    };
    /** Tasks requiring human attention (conflict/failed/stuck/backlog). */
    needsHumanTasks: NativeTask[];
    /** Whether the project DB was inaccessible during snapshot. */
    offline: boolean;
}
export interface DashboardState {
    projects: Project[];
    activeRuns: Map<string, Run[]>;
    completedRuns: Map<string, Run[]>;
    progresses: Map<string, RunProgress | null>;
    metrics: Map<string, Metrics>;
    events: Map<string, Event[]>;
    lastUpdated: Date;
    /** 24-hour success rate stats per project ID. rate=null means insufficient data. Optional for backward compat. */
    successRates?: Map<string, {
        rate: number | null;
        merged: number;
        failed: number;
    }>;
    /** Cross-project "needs human" tasks (REQ-011). */
    needsHumanTasks?: NativeTask[];
    /** Whether each project is reachable (true = offline / DB inaccessible). */
    offlineProjects?: Set<string>;
}
/** Statuses that require human operator attention. */
export declare const NEEDS_HUMAN_STATUSES: readonly ["conflict", "failed", "stuck", "backlog"];
export type NeedsHumanStatus = typeof NEEDS_HUMAN_STATUSES[number];
/**
 * Sort tasks by: (1) status urgency, (2) priority (P0 first), (3) age (oldest first).
 * Satisfies REQ-011.1.
 */
export declare function sortNeedsHumanTasks(tasks: NativeTask[]): NativeTask[];
/**
 * A registered project entry as stored in the global project registry.
 * Used by multi-project dashboard aggregation.
 */
export interface RegisteredProject {
    id: string;
    name: string;
    path: string;
}
/**
 * Read the list of all registered projects from the current project's DB.
 *
 * Falls back to returning only the current working directory's project if the
 * DB doesn't have multiple registered projects (REQ-010 fallback).
 *
 * @param store - DashboardReadStore for the current project (read-only interface).
 * @returns Array of projects to include in the multi-project dashboard.
 */
export declare function readProjectRegistry(store: DashboardReadStore): RegisteredProject[];
/**
 * Read snapshots from multiple project databases concurrently using READONLY
 * connections via `Promise.all()`.  Satisfies REQ-010 and REQ-019.
 *
 * Projects whose databases are inaccessible return an offline snapshot rather
 * than crashing the dashboard (REQ-010.1).
 *
 * @param projects    - Array of registered projects.
 * @param eventsLimit - Max events per project (default: 8).
 */
export declare function readProjectSnapshot(projects: RegisteredProject[], eventsLimit?: number): Promise<ProjectSnapshot[]>;
/**
 * Aggregate ProjectSnapshot[] into a DashboardState (for renderDashboard compatibility).
 */
export declare function aggregateSnapshots(snapshots: ProjectSnapshot[]): DashboardState;
/**
 * Format a single event as a compact timeline line.
 */
export declare function renderEventLine(event: Event): string;
/**
 * Render a summary line for a project header.
 */
export declare function renderProjectHeader(project: Project, activeCount: number, metrics: Metrics): string;
/**
 * Render the "Needs Human" panel for tasks requiring operator attention.
 * Satisfies REQ-011.
 *
 * @param tasks   - Pre-sorted list of tasks needing human attention.
 * @param maxRows - Maximum rows to display (default: 10).
 */
export declare function renderNeedsHumanPanel(tasks: NativeTask[], maxRows?: number): string;
/**
 * Render a per-project agent panel section.
 * Shows active agents with progress, then recently completed agents.
 * Satisfies REQ-012.
 */
export declare function renderProjectAgentPanel(project: Project, activeRuns: Run[], completedRuns: Run[], progresses: Map<string, RunProgress | null>, metrics: Metrics, events: Event[], offline: boolean): string;
/**
 * Render the full dashboard display as a string.
 */
export declare function renderDashboard(state: DashboardState): string;
/**
 * Collect dashboard data from the store.
 * Used for single-project (local fallback) mode.
 */
export declare function pollDashboard(store: DashboardReadStore, projectId?: string, eventsLimit?: number): DashboardState;
/**
 * Approve a backlog task via a short-lived write connection.
 * Satisfies REQ-011.3 backend requirement.
 *
 * Opens a new read-write ForemanStore for the task's project, updates the
 * task status to 'ready', then immediately closes the connection.
 *
 * @param taskId     - Native task ID.
 * @param projectPath - Path to the project that owns this task.
 */
export declare function approveTask(taskId: string, projectPath: string): Promise<void>;
/**
 * Retry a failed/stuck/conflict task via a short-lived write connection.
 * Resets the task status to 'backlog' so it can be re-dispatched.
 * Satisfies REQ-011.3 backend requirement.
 *
 * @param taskId     - Native task ID.
 * @param projectPath - Path to the project that owns this task.
 */
export declare function retryTask(taskId: string, projectPath: string): Promise<void>;
//# sourceMappingURL=dashboard-state.d.ts.map