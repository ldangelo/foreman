/**
 * JiraTaskClient — ITaskClient adapter for Jira.
 * Maps Foreman's generic task operations to Jira issue operations.
 */
import type { Issue, ITaskClient, CreateOptions, UpdateOptions } from "../lib/task-client.js";
export interface JiraLifecycleConfig {
    /** Statuses that indicate an issue is ready to be worked on (e.g., "To Do", "Open", "Ready") */
    startStatuses?: string[];
    /** Statuses that indicate work is in progress (e.g., "In Progress", "In Review", "QA") */
    inProgressStatuses?: string[];
    /** Statuses that indicate the issue is done (e.g., "Done", "Closed", "Resolved") */
    doneStatuses?: string[];
    /** Auto-detect lifecycle from project statuses. Uses status categories. Default: true */
    autoDetect?: boolean;
}
export interface JiraTaskClientConfig {
    apiUrl: string;
    email: string;
    apiToken: string;
    projectKey: string;
    apiVersion?: "cloud" | "server";
    /** Optional lifecycle config for transitioning issues. If not provided, auto-detects. */
    lifecycle?: JiraLifecycleConfig;
}
/**
 * JiraTaskClient implements ITaskClient for Jira.
 * This allows sentinel to file bugs in Jira instead of GitHub when Jira is configured.
 */
export declare class JiraTaskClient implements ITaskClient {
    private readonly client;
    private readonly projectKey;
    private readonly lifecycle;
    private cachedProjectStatuses;
    constructor(config: JiraTaskClientConfig);
    /**
     * Detect lifecycle stages from project statuses.
     * Uses Jira's status categories (TODO, IN_PROGRESS, DONE) for auto-detection.
     */
    private detectLifecycle;
    /**
     * Infer lifecycle stages from project status data.
     * Maps Jira status categories to our lifecycle stages.
     */
    private inferLifecycleFromStatuses;
    /**
     * Get the effective lifecycle config (from cache or detection).
     */
    private getLifecycle;
    /**
     * Create a new issue in Jira.
     */
    create(title: string, opts?: CreateOptions): Promise<Issue>;
    /**
     * List issues in the project with optional filters.
     */
    list(opts?: {
        status?: string;
        type?: string;
    }): Promise<Issue[]>;
    /**
     * Return open issues that are ready to work on.
     */
    ready(): Promise<Issue[]>;
    /**
     * Get full details for an issue.
     */
    show(id: string): Promise<{
        status: string;
        description?: string | null;
        notes?: string | null;
    }>;
    /**
     * Claim an issue — transition it from start status to in-progress.
     *
     * This is the key integration point for Sentinel: when Sentinel picks up
     * an issue from the ready queue, it calls claim() to transition it to
     * a working status.
     *
     * Returns the updated issue, or throws if no valid transition exists.
     */
    claim(id: string): Promise<Issue>;
    /**
     * Release an issue — transition it back to a start status or close it.
     * Useful when Sentinel is done with an issue.
     */
    release(id: string, close?: boolean): Promise<Issue>;
    /**
    /**
     * Update fields on an issue.
     */
    update(_id: string, _opts: UpdateOptions): Promise<void>;
    /**
     * Close an issue.
     */
    close(_id: string, _reason?: string): Promise<void>;
    /**
     * Authenticate and verify connection.
     */
    authenticate(): Promise<void>;
}
/**
 * Create a JiraTaskClient from project config.
 */
export declare function createJiraTaskClientFromConfig(projectConfig: {
    apiUrl?: string;
    email?: string;
    apiToken?: string;
    projects?: Array<{
        key: string;
    }>;
}): Promise<JiraTaskClient | null>;
//# sourceMappingURL=jira-task-client.d.ts.map