/**
 * Jira Issues Poller — background daemon that monitors Jira status transitions
 * and dispatches Foreman workflows when issues enter configured start statuses.
 */
import type { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import type { JiraProjectConfig, JiraConfig } from "../lib/project-config.js";
import { JiraApiClient } from "./jira-api-client.js";
export type { JiraIssueStateRow, JiraIssueStateInput } from "../lib/db/postgres-adapter.js";
export interface JiraPollerConfig {
    /**
     * Poll interval in milliseconds. Default: 60_000 (1 minute).
     * Can be overridden via FOREMAN_JIRA_POLL_INTERVAL_MS env var.
     */
    pollIntervalMs?: number;
    /**
     * Callback invoked when a status transition to a startStatus is detected.
     * Called with the Jira issue and the matching project config.
     */
    onTransition: (issue: JiraIssue, projectConfig: JiraProjectConfig) => Promise<void>;
}
/**
 * Jira issue as returned by the Jira API.
 */
export interface JiraIssue {
    key: string;
    fields: {
        summary: string;
        status: {
            name: string;
        };
        issuetype: {
            name: string;
        };
        project: {
            key: string;
        };
        updated: string;
    };
}
export interface JiraSearchResult {
    issues: JiraIssue[];
    total: number;
}
/**
 * Result of a single poll cycle across all projects.
 */
export interface JiraPollSummary {
    projects: number;
    issues: number;
    transitions: number;
    errors: number;
}
/**
 * Background poller that periodically fetches issues from configured Jira projects,
 * detects status transitions to configured startStatus values, and invokes the
 * transition callback.
 *
 * State for each tracked issue is persisted to the `jira_issue_states` database table
 * so transitions are not re-triggered on sentinel restart.
 */
export declare class JiraIssuesPoller {
    private readonly adapter;
    private readonly client;
    private readonly jiraConfig;
    private readonly onTransition;
    private readonly _foremanTag?;
    private _interval;
    private _running;
    private _stopped;
    /**
     * In-memory state for all tracked issues.
     * Loaded from DB on start, updated on each poll cycle.
     * Key: `jiraProjectKey:issueKey`
     */
    private _state;
    constructor(adapter: PostgresAdapter, client: JiraApiClient, jiraConfig: JiraConfig, onTransition: (issue: JiraIssue, projectConfig: JiraProjectConfig, foremanTag?: string) => Promise<void>, foremanTag?: string);
    /** Start the background polling loop. Idempotent — safe to call on already-running poller. */
    start(): void;
    /** Stop the polling loop. Cannot be restarted — create a new instance. */
    stop(): void;
    get running(): boolean;
    /**
     * Poll all configured Jira projects for status transitions.
     */
    pollAll(): Promise<JiraPollSummary>;
    /**
     * Poll a single Jira project for issues in startStatus.
     *
     * Builds a JQL query for all issues in the project's startStatus values,
     * fetches current state from Jira, detects transitions, persists state,
     * and invokes the onTransition callback.
     */
    pollProject(projectConfig: JiraProjectConfig): Promise<{
        issues: number;
        transitions: number;
    }>;
    /**
     * Load issue state from the database into memory.
     * Exposed for testing purposes.
     */
    loadState(): Promise<void>;
    /**
     * Persist current issue state to the database.
     * Uses upsert semantics — inserts or updates each tracked issue.
     * Called after every poll cycle and on graceful shutdown.
     */
    saveState(projectKey: string): Promise<void>;
    /**
     * Manually trigger a poll for a specific project.
     */
    pollProjectManual(projectConfig: JiraProjectConfig): Promise<{
        issues: number;
        transitions: number;
    }>;
}
//# sourceMappingURL=jira-poller.d.ts.map