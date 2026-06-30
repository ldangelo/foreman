export type ForemanServerCommand = {
    command_id: string;
    command_type: string;
    schema_version?: number;
    payload?: Record<string, unknown>;
    metadata?: Record<string, unknown>;
};
export type ForemanServerOk = {
    ok: true;
    events: string[];
    projection_version: number;
    correlation_id: string;
};
export type ForemanServerError = {
    ok: false;
    error: {
        code: "VALIDATION_FAILED" | "CONFLICT" | "UNAUTHORIZED" | "UNSUPPORTED" | "INTERNAL";
        message: string;
        details: Record<string, unknown>;
        retryable: boolean;
        correlation_id?: string;
    };
};
export type ForemanServerResponse = ForemanServerOk | ForemanServerError;
export type ElixirProject = {
    project_id?: string;
    id?: string;
    name?: string;
    path: string;
    status?: string;
    default_branch?: string;
    config?: Record<string, unknown>;
    health?: Record<string, unknown>;
    updated_at?: string;
};
export type ElixirTask = {
    task_id?: string;
    id?: string;
    project_id?: string;
    title?: string;
    description?: string | null;
    task_type?: string;
    type?: string;
    priority?: number;
    status?: string;
    external_id?: string | null;
    updated_at?: string;
    created_at?: string;
    closed_at?: string | null;
    approved_at?: string | null;
    annotations?: Array<{
        body: string;
        author?: string;
        created_at?: string;
    }>;
    dependencies?: string[];
    run_id?: string | null;
};
export type ElixirRun = Record<string, unknown> & {
    run_id?: string;
    id?: string;
    project_id?: string;
    task_id?: string;
    status?: string;
};
export type ElixirInboxMessage = Record<string, unknown> & {
    message_id?: string;
    run_id?: string;
    project_id?: string;
    unread?: boolean;
};
export type ElixirEvent = Record<string, unknown> & {
    event_id?: string;
    run_id?: string;
    project_id?: string;
    type?: string;
    event_type?: string;
};
export declare class ElixirServerClient {
    private readonly baseUrl;
    private readonly authToken?;
    constructor(baseUrl: string, authToken?: string | undefined);
    sendCommand(command: ForemanServerCommand): Promise<ForemanServerResponse>;
    listProjects(): Promise<ElixirProject[]>;
    listTasks(): Promise<ElixirTask[]>;
    getTask(taskId: string): Promise<ElixirTask | null>;
    listRuns(opts?: {
        projectId?: string;
    }): Promise<ElixirRun[]>;
    schedulerTick(): Promise<unknown>;
    listInbox(opts?: {
        runId?: string;
        projectId?: string;
        limit?: number;
        unread?: boolean;
    }): Promise<ElixirInboxMessage[]>;
    listEvents(opts?: {
        runId?: string;
        projectId?: string;
        limit?: number;
    }): Promise<ElixirEvent[]>;
    getRunLogs(runId: string, view?: "compact" | "raw"): Promise<unknown[]>;
    getRunReport(runId: string): Promise<unknown>;
    getDebugTimeline(runId: string): Promise<unknown>;
    private getJson;
    private headers;
}
//# sourceMappingURL=elixir-server-client.d.ts.map