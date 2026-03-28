import type { ITaskClient, Issue, UpdateOptions } from "./task-client.js";
export interface BrIssue {
    id: string;
    title: string;
    type: string;
    priority: string;
    status: string;
    assignee: string | null;
    parent: string | null;
    created_at: string;
    updated_at: string;
}
export interface BrIssueDetail extends BrIssue {
    description: string | null;
    labels: string[];
    estimate_minutes: number | null;
    dependencies: string[];
    children: string[];
    notes?: string | null;
}
export interface BrComment {
    id: number;
    issue_id: string;
    author: string;
    text: string;
    created_at: string;
}
/**
 * Unwrap the br CLI JSON response.
 *
 * br returns objects directly (not wrapped in an envelope like sd).
 * Arrays are returned as-is.  On failure, br exits non-zero (caught in execBr).
 */
export declare function unwrapBrResponse(raw: unknown): unknown;
export declare function execBr(args: string[], cwd?: string): Promise<unknown>;
export declare class BeadsRustClient implements ITaskClient {
    private projectPath;
    constructor(projectPath: string);
    /** Verify that the br binary is reachable. */
    ensureBrInstalled(): Promise<void>;
    /** Check whether .beads/ exists in the project. */
    isInitialized(): Promise<boolean>;
    /** Create a new issue. Returns a BrIssue. */
    create(title: string, opts?: {
        type?: string;
        priority?: string;
        parent?: string;
        description?: string;
        labels?: string[];
        estimate?: number;
    }): Promise<BrIssue>;
    /** List issues with optional filters. */
    list(opts?: {
        status?: string;
        type?: string;
        label?: string;
        limit?: number;
    }): Promise<BrIssue[]>;
    /** Show full detail for one issue. */
    show(id: string): Promise<BrIssueDetail>;
    /** Update fields on an issue. Satisfies ITaskClient.update(). */
    update(id: string, opts: UpdateOptions): Promise<void>;
    /** Close an issue, optionally with a reason. */
    close(id: string, reason?: string): Promise<void>;
    /** Declare a dependency: childId depends on parentId. */
    addDependency(childId: string, parentId: string): Promise<void>;
    /** Return all open, unblocked issues (equivalent to `br ready`). Satisfies ITaskClient.ready(). */
    ready(): Promise<Issue[]>;
    /** Search issues by query string. */
    search(query: string, opts?: {
        status?: string;
        label?: string;
    }): Promise<BrIssue[]>;
    /**
     * Fetch comments for an issue and return them as a formatted markdown string.
     * Returns null if there are no comments or the fetch fails.
     */
    comments(id: string): Promise<string | null>;
    private requireInit;
}
//# sourceMappingURL=beads-rust.d.ts.map