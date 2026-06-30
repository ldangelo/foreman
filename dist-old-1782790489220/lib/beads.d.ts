import type { ITaskClient, Issue, UpdateOptions } from "./task-client.js";
export interface Bead {
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
export interface BeadDetail extends Bead {
    description: string | null;
    notes: string | null;
    acceptance: string | null;
    design: string | null;
    dependencies: string[];
    children: string[];
}
export interface BeadGraph {
    nodes: Bead[];
    edges: {
        from: string;
        to: string;
        type: string;
    }[];
}
/**
 * Unwrap the sd CLI JSON envelope.
 *
 * sd wraps responses in `{ success, command, issues/issue/... }`.
 * This extracts the inner data so callers get arrays/objects directly:
 *   - `{ issues: [...] }` → returns the array
 *   - `{ issue: {...} }`  → returns the object
 *   - `{ success: false, error: "..." }` → throws
 *   - Everything else (primitives, bare arrays, no envelope) → pass-through
 */
export declare function unwrapBdResponse(raw: any): any;
export declare function execBd(args: string[], cwd?: string): Promise<any>;
export declare class BeadsClient implements ITaskClient {
    private projectPath;
    constructor(projectPath: string);
    /** Verify that the sd binary is reachable. */
    ensureSdInstalled(): Promise<void>;
    /** Check whether .seeds/ exists in the project. */
    isInitialized(): Promise<boolean>;
    /** Run `sd init`. */
    init(): Promise<void>;
    /** Create a new bead (task/epic/bug). Returns a Bead by fetching after create. */
    create(title: string, opts?: {
        type?: string;
        priority?: string;
        parent?: string;
        description?: string;
        labels?: string[];
    }): Promise<Bead>;
    /** List beads with optional filters. */
    list(opts?: {
        status?: string;
        assignee?: string;
        type?: string;
    }): Promise<Bead[]>;
    /** Return tasks whose blockers are all resolved. Satisfies ITaskClient.ready(). */
    ready(): Promise<Issue[]>;
    /** Show full detail for one bead. */
    show(id: string): Promise<BeadDetail>;
    /** Update fields on a bead. Satisfies ITaskClient.update(). */
    update(id: string, opts: UpdateOptions): Promise<void>;
    /** Close a bead, optionally with a reason. */
    close(id: string, reason?: string): Promise<void>;
    /** Declare a dependency: childId depends on parentId. */
    addDependency(childId: string, parentId: string): Promise<void>;
    /** Get the dependency graph, optionally scoped to an epic. */
    getGraph(epicId?: string): Promise<BeadGraph>;
    /** Trigger bead compaction. */
    compact(): Promise<void>;
    private requireInit;
}
//# sourceMappingURL=beads.d.ts.map