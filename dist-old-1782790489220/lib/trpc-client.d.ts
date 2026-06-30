/**
 * TrpcClient — typed tRPC client that connects to ForemanDaemon via Unix socket.
 *
 * Primary transport: Unix socket at ~/.foreman/daemon.sock
 * Fallback transport: localhost:3847 (HTTP)
 *
 * The daemon serves tRPC over HTTP through Fastify, so we use httpBatchLink
 * with a custom fetch implementation that connects via Unix socket.
 *
 * @module lib/trpc-client
 */
import type { appRouter } from "../daemon/router.js";
/** AppRouter type — use `typeof appRouter` to extract. */
export type AppRouter = typeof appRouter;
export declare function decodeUnixSocketUrl(url: URL): {
    socketPath: string;
    requestPath: string;
};
export interface TrpcClientOptions {
    /** Path to the Unix socket. Defaults to ~/.foreman/daemon.sock. */
    socketPath?: string;
    /** HTTP fallback URL when Unix socket is not available. */
    httpUrl?: string;
    /** Abort signal to cancel in-flight requests. */
    signal?: AbortSignal;
}
/** A fully-typed tRPC client for ForemanDaemon. */
export interface TrpcClient {
    /** Typed proxy to the daemon's projects procedures. */
    readonly projects: TRPCProjectsClient;
    /** Typed proxy to the daemon's tasks procedures. */
    readonly tasks: TRPCTasksClient;
    /** Typed proxy to the daemon's runs/events/messages procedures. */
    readonly runs: TRPCRunsClient;
    /** Typed proxy to the daemon's agent mail procedures. */
    readonly mail: TRPCMailClient;
    /** Typed proxy to the daemon's Jira issue tracker procedures (PRD-2026-013). */
    readonly jira: TRPCJiraClient;
}
/** Tasks sub-router client. */
export interface TRPCTasksClient {
    list(input: {
        projectId: string;
        status?: string[];
        runId?: string;
        limit?: number;
    }): Promise<unknown>;
    get(input: {
        projectId: string;
        taskId: string;
    }): Promise<unknown>;
    create(input: {
        projectId: string;
        id?: string;
        title?: string;
        description?: string;
        type?: string;
        priority?: number;
        status?: string;
        externalId?: string;
        branch?: string;
        createdAt?: string;
        updatedAt?: string;
        approvedAt?: string;
        closedAt?: string;
    }): Promise<unknown>;
    update(input: {
        projectId: string;
        taskId: string;
        updates: {
            title?: string;
            description?: string;
            type?: string;
            priority?: number;
            status?: string;
            branch?: string;
            external_id?: string;
        };
    }): Promise<unknown>;
    delete(input: {
        projectId: string;
        taskId: string;
    }): Promise<unknown>;
    addNote(input: {
        projectId: string;
        taskId: string;
        runId?: string | null;
        phase?: string | null;
        author: string;
        kind?: "progress" | "issue" | "blocker" | "review" | "qa" | "final" | "failure" | "manual" | "system";
        body: string;
        metadata?: Record<string, unknown> | null;
    }): Promise<unknown>;
    listNotes(input: {
        projectId: string;
        taskId: string;
        limit?: number;
        newestFirst?: boolean;
    }): Promise<unknown>;
    claim(input: {
        projectId: string;
        taskId: string;
        runId: string;
    }): Promise<unknown>;
    approve(input: {
        projectId: string;
        taskId: string;
    }): Promise<unknown>;
    close(input: {
        projectId: string;
        taskId: string;
    }): Promise<unknown>;
    reset(input: {
        projectId: string;
        taskId: string;
    }): Promise<unknown>;
    retry(input: {
        projectId: string;
        taskId: string;
    }): Promise<unknown>;
    addDependency(input: {
        projectId: string;
        fromTaskId: string;
        toTaskId: string;
        type?: "blocks" | "parent-child";
    }): Promise<unknown>;
    listDependencies(input: {
        projectId: string;
        taskId: string;
        direction?: "incoming" | "outgoing";
    }): Promise<unknown>;
    removeDependency(input: {
        projectId: string;
        fromTaskId: string;
        toTaskId: string;
        type?: "blocks" | "parent-child";
    }): Promise<unknown>;
    /** Get the current GitHub PR state for a task. */
    getPrState(input: {
        projectId: string;
        taskId: string;
    }): Promise<unknown>;
}
/** Projects sub-router client. */
export interface TRPCProjectsClient {
    list(input?: {
        status?: "active" | "paused" | "archived";
        search?: string;
    }): Promise<unknown>;
    get(input: {
        id: string;
    }): Promise<unknown>;
    add(input: {
        githubUrl: string;
        name?: string;
        defaultBranch?: string;
        status?: "active" | "paused" | "archived";
    }): Promise<unknown>;
    update(input: {
        id: string;
        updates: {
            name?: string;
            path?: string;
            status?: "active" | "paused" | "archived";
            jira?: {
                apiUrl?: string;
                email?: string;
                apiToken?: string;
                pollIntervalSeconds?: number;
                webhookEnabled?: boolean;
                webhookSecretEnvVar?: string;
                projects?: Array<{
                    key: string;
                    startStatus?: string[];
                    endStatus?: string[];
                    issueTypeWorkflowMap?: Record<string, string>;
                    debounceWindowSeconds?: number;
                }>;
            };
        };
    }): Promise<unknown>;
    remove(input: {
        id: string;
        force?: boolean;
    }): Promise<unknown>;
    sync(input: {
        id: string;
    }): Promise<unknown>;
    stats(input: {
        projectId: string;
    }): Promise<unknown>;
    listNeedsHuman(input: {
        projectId: string;
    }): Promise<unknown>;
}
/** Runs / events / messages sub-router client (TRD-033/034/035). */
export interface TRPCRunsClient {
    create(input: {
        projectId: string;
        beadId: string;
        runNumber: number;
        branch: string;
        commitSha?: string;
        trigger?: string;
    }): Promise<unknown>;
    list(input: {
        projectId: string;
        beadId?: string;
        status?: string;
        limit?: number;
    }): Promise<unknown>;
    listActive(input: {
        projectId: string;
        beadId?: string;
    }): Promise<unknown>;
    get(input: {
        runId: string;
    }): Promise<unknown>;
    getProgress(input: {
        runId: string;
    }): Promise<unknown>;
    updateStatus(input: {
        runId: string;
        status: string;
        startedAt?: string;
        finishedAt?: string;
    }): Promise<unknown>;
    finalize(input: {
        runId: string;
        status: string;
        finishedAt?: string;
    }): Promise<unknown>;
    logEvent(input: {
        projectId: string;
        runId: string;
        taskId?: string;
        eventType: string;
        payload?: Record<string, unknown>;
    }): Promise<unknown>;
    listEvents(input: {
        runId: string;
    }): Promise<unknown>;
    sendMessage(input: {
        runId: string;
        stepKey?: string;
        stream: string;
        chunk: string;
        lineNumber: number;
    }): Promise<unknown>;
    listMessages(input: {
        runId: string;
        stepKey?: string;
    }): Promise<unknown>;
}
/** Agent mail sub-router client (TRD-036). */
export interface TRPCMailClient {
    send(input: {
        projectId: string;
        runId: string;
        senderAgentType: string;
        recipientAgentType: string;
        subject: string;
        body: string;
    }): Promise<unknown>;
    list(input: {
        projectId: string;
        runId: string;
        agentType?: string;
        unreadOnly?: boolean;
    }): Promise<unknown>;
    listGlobal(input: {
        projectId: string;
        limit?: number;
    }): Promise<unknown>;
    markRead(input: {
        projectId: string;
        messageId: string;
    }): Promise<unknown>;
    markAllRead(input: {
        projectId: string;
        runId: string;
        agentType: string;
    }): Promise<unknown>;
    delete(input: {
        projectId: string;
        messageId: string;
    }): Promise<unknown>;
}
/** Jira issue tracker sub-router client (PRD-2026-013). */
export interface TRPCJiraClient {
    configure(input: {
        apiUrl: string;
        email: string;
        apiToken: string;
        projects: Array<{
            key: string;
            startStatus: string[];
            endStatus?: string[];
            issueTypeWorkflowMap: Record<string, string>;
            debounceWindowSeconds?: number;
        }>;
        webhookEnabled: boolean;
        webhookSecretEnvVar?: string;
        pollIntervalSeconds?: number;
    }): Promise<unknown>;
    getStatus(input?: {
        projectId?: string;
    }): Promise<unknown>;
    testConnection(input: {
        apiUrl: string;
        email: string;
        apiToken: string;
    }): Promise<unknown>;
    enableWebhook(input: {
        projectId?: string;
        webhookSecret: string;
    }): Promise<unknown>;
    disableWebhook(input?: {
        projectId?: string;
    }): Promise<unknown>;
}
/**
 * Create a tRPC client that connects to ForemanDaemon.
 *
 * @example
 * const client = createTrpcClient();
 * const projects = await client.projects.list({ status: "active" });
 */
export declare function createTrpcClient(options?: TrpcClientOptions): TrpcClient;
//# sourceMappingURL=trpc-client.d.ts.map