/**
 * task-ordering.ts — Determine execution order for child tasks in an epic.
 *
 * Primary: use bv --robot-next to get graph-aware ordering.
 * Fallback: topological sort of child bead dependencies with priority tiebreaker.
 */
interface TaskOrderingDependencyRef {
    id: string;
}
export interface TaskOrderingIssueDetail {
    id: string;
    title: string;
    type: string;
    priority: string;
    description?: string | null;
    children?: string[];
    dependencies: Array<string | TaskOrderingDependencyRef>;
}
export interface TaskOrderingClient {
    show(id: string): Promise<TaskOrderingIssueDetail>;
}
export interface OrderedTask {
    seedId: string;
    seedTitle: string;
    seedDescription?: string;
}
export declare class CircularDependencyError extends Error {
    readonly cycle: string[];
    constructor(cycle: string[]);
}
/**
 * Get ordered list of child tasks for an epic bead.
 *
 * Tries bv --robot-next first for graph-aware ordering.
 * Falls back to topological sort of br dependencies with priority as tiebreaker.
 *
 * @param epicId      - The parent epic bead ID.
 * @param brClient    - BeadsRustClient for querying bead details.
 * @param projectPath - Project root for bv invocation.
 * @param useBv       - Whether to attempt bv ordering (default: true).
 * @returns Ordered list of child tasks.
 */
export declare function getTaskOrder(epicId: string, brClient: TaskOrderingClient, projectPath: string, useBv?: boolean): Promise<OrderedTask[]>;
export {};
//# sourceMappingURL=task-ordering.d.ts.map