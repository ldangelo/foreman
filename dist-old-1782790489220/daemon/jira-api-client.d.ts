/**
 * JiraApiClient — thin wrapper around Jira REST API.
 * Supports both Jira Cloud (REST API v3) and Jira Server/Data Center (REST API v2).
 * Uses Basic Auth for authentication.
 */
/**
 * Configuration for JiraApiClient (daemon-level, not persisted in project config).
 */
export interface JiraApiClientConfig {
    /** Jira API base URL (e.g., https://your-domain.atlassian.net) */
    apiUrl: string;
    /** Jira account email (for Basic Auth) */
    email: string;
    /** Jira API token */
    apiToken: string;
    /** API version: "cloud" (REST v3) or "server" (REST v2). Default: "cloud" */
    apiVersion?: "cloud" | "server";
    /** Request timeout in milliseconds. Default: 30000 */
    timeoutMs?: number;
    /** Optional fetch function for testing (defaults to globalThis.fetch) */
    fetchFn?: typeof globalThis.fetch;
}
export declare class JiraError extends Error {
    constructor(message?: string);
}
export declare class JiraNotAuthenticatedError extends JiraError {
    constructor(message?: string);
}
export declare class JiraNotFoundError extends JiraError {
    constructor(message?: string);
}
export declare class JiraRateLimitError extends JiraError {
    readonly retryAfterSeconds: number;
    constructor(retryAfterSeconds: number, message: string);
}
export declare class JiraApiError extends JiraError {
    readonly statusCode: number;
    constructor(statusCode: number, message: string);
}
export declare class JiraApiClient {
    private readonly baseUrl;
    private readonly authHeader;
    private readonly timeoutMs;
    /** API version: "cloud" (REST v3) or "server" (REST v2) */
    private readonly apiVersion;
    /** Fetch function (can be injected for testing) */
    private readonly fetchFn;
    constructor(config: JiraApiClientConfig);
    /**
    /**
     * Get the API path prefix based on version.
     * - Cloud: /rest/api/3/...
     * - Server: /rest/api/2/...
     */
    private apiPath;
    /**
     * Authenticate — validates credentials by fetching current user.
     * Throws JiraNotAuthenticatedError if credentials are invalid.
     */
    authenticate(): Promise<void>;
    /**
     * Search issues using JQL.
     * @param jql JQL query string
     * @param options.maxResults Maximum results to return (default: 50)
     */
    search(jql: string, options?: {
        maxResults?: number;
    }): Promise<SearchResult>;
    /**
     * Get a single issue by key.
     * @param issueKey e.g., "PROJ-123"
     */
    getIssue(issueKey: string): Promise<JiraIssue>;
    /**
     * List available projects for this Jira instance.
     */
    listProjects(): Promise<JiraProject[]>;
    /**
     * Get all valid statuses for a project, grouped by issue type.
     * Useful for auto-detecting workflow stages.
     */
    getProjectStatuses(projectKey: string): Promise<JiraProjectStatus[]>;
    /**
     * Get available transitions for an issue.
     * Returns transitions that can be executed from the issue's current status.
     */
    getIssueTransitions(issueKey: string): Promise<JiraTransition[]>;
    /**
     * Handle rate limit by waiting for the specified duration.
     */
    handleRateLimit(retryAfterSeconds: number): Promise<void>;
    /**
     * Add a comment to an issue.
     * Useful for workflow feedback (e.g., "Foreman task created").
     */
    addComment(issueKey: string, comment: string): Promise<void>;
    /**
     * Transition an issue to a new status.
     * Useful for workflow automation (e.g., move to "In Review").
     */
    transitionIssue(issueKey: string, transitionId: string): Promise<void>;
    /**
     * Create a new issue.
     * @param projectKey The Jira project key (e.g., "PROJ")
     * @param issueType The issue type name (e.g., "Bug", "Task")
     * @param summary The issue summary/title
     * @param description Optional description (supports Atlassian Document Format)
     * @param labels Optional labels
     */
    createIssue(options: {
        projectKey: string;
        issueType: string;
        summary: string;
        description?: string;
        labels?: string[];
        priority?: string;
    }): Promise<{
        key: string;
        id: string;
    }>;
    private get;
    private post;
    private fetch;
    private parseResponse;
}
export interface JiraIssue {
    key: string;
    id: string;
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
        created: string;
        priority?: {
            name: string;
        };
        labels?: string[];
    };
}
export interface JiraProject {
    key: string;
    name: string;
}
export interface SearchResult {
    issues: JiraIssue[];
    total: number;
}
/**
 * Status details returned by the project statuses endpoint.
 */
export interface JiraStatus {
    id: string;
    name: string;
    description?: string;
    iconUrl?: string;
    statusCategory?: {
        id: number;
        key: string;
        name: string;
        colorName?: string;
    };
}
/**
 * Issue type with its valid statuses, returned by project statuses endpoint.
 */
export interface JiraProjectStatus {
    id: string;
    name: string;
    self: string;
    statuses: JiraStatus[];
    subtask: boolean;
}
/**
 * A transition that can be performed on an issue.
 */
export interface JiraTransition {
    id: string;
    name: string;
    to: {
        id: string;
        name: string;
        self: string;
        statusCategory?: {
            id: number;
            key: string;
            name: string;
        };
    };
    hasScreen: boolean;
    isAvailable: boolean;
    isGlobal?: boolean;
    isInitial?: boolean;
    isConditional?: boolean;
}
//# sourceMappingURL=jira-api-client.d.ts.map