import type { CreateOptions, ITaskClient, Issue, UpdateOptions } from "./task-client.js";
/**
 * NativeTaskClient adapts the project-local Postgres task store to ITaskClient.
 *
 * This is primarily used by deterministic test-runtime and native-task-only
 * execution paths where the br CLI should not be required.
 */
export declare class NativeTaskClient implements ITaskClient {
    private readonly projectPath;
    private readonly opts;
    private readonly postgres;
    constructor(projectPath: string, opts?: {
        registeredProjectId?: string;
    });
    private get registeredProjectId();
    private toPostgresIssue;
    private toNativeIssue;
    private withPostgresTask;
    private normalizeStatus;
    private normalizePriority;
    private validateStatusTransition;
    private withStore;
    list(opts?: {
        status?: string;
        type?: string;
    }): Promise<Issue[]>;
    create(title: string, opts?: CreateOptions): Promise<Issue>;
    ready(): Promise<Issue[]>;
    show(id: string): Promise<Issue>;
    update(id: string, opts: UpdateOptions): Promise<void>;
    comments(id: string): Promise<string | null>;
    close(id: string, reason?: string): Promise<void>;
    resetToReady(id: string, reason?: string): Promise<void>;
}
//# sourceMappingURL=native-task-client.d.ts.map