/**
 * JiraApiClient — thin wrapper around Jira REST API.
 * Supports both Jira Cloud (REST API v3) and Jira Server/Data Center (REST API v2).
 * Uses Basic Auth for authentication.
 */
// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------
export class JiraError extends Error {
    constructor(message = "") {
        super(message);
        this.name = "JiraError";
    }
}
export class JiraNotAuthenticatedError extends JiraError {
    constructor(message = "") {
        super(message);
        this.name = "JiraNotAuthenticatedError";
    }
}
export class JiraNotFoundError extends JiraError {
    constructor(message = "") {
        super(message);
        this.name = "JiraNotFoundError";
    }
}
export class JiraRateLimitError extends JiraError {
    retryAfterSeconds;
    constructor(retryAfterSeconds, message) {
        super(message);
        this.retryAfterSeconds = retryAfterSeconds;
        this.name = "JiraRateLimitError";
    }
}
export class JiraApiError extends JiraError {
    statusCode;
    constructor(statusCode, message) {
        super(message);
        this.statusCode = statusCode;
        this.name = "JiraApiError";
    }
}
// ---------------------------------------------------------------------------
// JiraApiClient
// ---------------------------------------------------------------------------
export class JiraApiClient {
    baseUrl;
    authHeader;
    timeoutMs;
    /** API version: "cloud" (REST v3) or "server" (REST v2) */
    apiVersion;
    /** Fetch function (can be injected for testing) */
    fetchFn;
    constructor(config) {
        this.baseUrl = config.apiUrl.replace(/\/$/, "");
        // Server uses username, Cloud uses email for Basic Auth
        const credentials = Buffer.from(`${config.email}:${config.apiToken}`).toString("base64");
        this.authHeader = `Basic ${credentials}`;
        this.timeoutMs = config.timeoutMs ?? 30_000;
        this.apiVersion = config.apiVersion ?? "cloud";
        this.fetchFn = config.fetchFn ?? globalThis.fetch;
    }
    /**
    /**
     * Get the API path prefix based on version.
     * - Cloud: /rest/api/3/...
     * - Server: /rest/api/2/...
     */
    apiPath(path) {
        const version = this.apiVersion === "server" ? "2" : "3";
        return `/rest/api/${version}${path}`;
    }
    /**
     * Authenticate — validates credentials by fetching current user.
     * Throws JiraNotAuthenticatedError if credentials are invalid.
     */
    async authenticate() {
        try {
            await this.get(this.apiPath("/myself"));
        }
        catch (err) {
            if (err instanceof JiraNotAuthenticatedError) {
                throw err;
            }
            throw err;
        }
    }
    /**
     * Search issues using JQL.
     * @param jql JQL query string
     * @param options.maxResults Maximum results to return (default: 50)
     */
    async search(jql, options) {
        const params = new URLSearchParams({
            jql,
            maxResults: String(options?.maxResults ?? 50),
        });
        return this.get(`${this.apiPath("/search")}?${params}`);
    }
    /**
     * Get a single issue by key.
     * @param issueKey e.g., "PROJ-123"
     */
    async getIssue(issueKey) {
        return this.get(this.apiPath(`/issue/${encodeURIComponent(issueKey)}`));
    }
    /**
     * List available projects for this Jira instance.
     */
    async listProjects() {
        const result = await this.get(this.apiPath("/project"));
        return result.values ?? [];
    }
    /**
     * Get all valid statuses for a project, grouped by issue type.
     * Useful for auto-detecting workflow stages.
     */
    async getProjectStatuses(projectKey) {
        return this.get(this.apiPath(`/project/${encodeURIComponent(projectKey)}/statuses`));
    }
    /**
     * Get available transitions for an issue.
     * Returns transitions that can be executed from the issue's current status.
     */
    async getIssueTransitions(issueKey) {
        const result = await this.get(this.apiPath(`/issue/${encodeURIComponent(issueKey)}/transitions`));
        return result.transitions ?? [];
    }
    /**
     * Handle rate limit by waiting for the specified duration.
     */
    handleRateLimit(retryAfterSeconds) {
        return new Promise((resolve) => {
            setTimeout(resolve, retryAfterSeconds * 1000);
        });
    }
    // -------------------------------------------------------------------------
    // Write operations (for workflow feedback to Jira)
    // -------------------------------------------------------------------------
    /**
     * Add a comment to an issue.
     * Useful for workflow feedback (e.g., "Foreman task created").
     */
    async addComment(issueKey, comment) {
        await this.post(this.apiPath(`/issue/${encodeURIComponent(issueKey)}/comment`), {
            body: comment,
        });
    }
    /**
     * Transition an issue to a new status.
     * Useful for workflow automation (e.g., move to "In Review").
     */
    async transitionIssue(issueKey, transitionId) {
        await this.post(this.apiPath(`/issue/${encodeURIComponent(issueKey)}/transitions`), { transition: { id: transitionId } });
    }
    /**
     * Create a new issue.
     * @param projectKey The Jira project key (e.g., "PROJ")
     * @param issueType The issue type name (e.g., "Bug", "Task")
     * @param summary The issue summary/title
     * @param description Optional description (supports Atlassian Document Format)
     * @param labels Optional labels
     */
    async createIssue(options) {
        const fields = {
            project: { key: options.projectKey },
            issuetype: { name: options.issueType },
            summary: options.summary,
        };
        if (options.description) {
            // Use Atlassian Document Format for description
            fields.description = {
                type: "doc",
                version: 1,
                content: [
                    {
                        type: "paragraph",
                        content: [{ type: "text", text: options.description }],
                    },
                ],
            };
        }
        if (options.labels) {
            fields.labels = options.labels;
        }
        if (options.priority) {
            fields.priority = { name: options.priority };
        }
        const result = await this.post(this.apiPath("/issue"), { fields });
        return { key: result.key, id: result.id };
    }
    // -------------------------------------------------------------------------
    // Private methods
    // -------------------------------------------------------------------------
    async get(path) {
        const response = await this.fetch(path, { method: "GET" });
        return this.parseResponse(response);
    }
    async post(path, body) {
        const response = await this.fetch(path, {
            method: "POST",
            body: JSON.stringify(body),
        });
        return this.parseResponse(response);
    }
    async fetch(path, options) {
        const url = `${this.baseUrl}${path}`;
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), this.timeoutMs);
        try {
            const response = await this.fetchFn(url, {
                ...options,
                headers: {
                    Authorization: this.authHeader,
                    "Content-Type": "application/json",
                    Accept: "application/json",
                    ...options.headers,
                },
                signal: controller.signal,
            });
            clearTimeout(timeoutId);
            return response;
        }
        finally {
            clearTimeout(timeoutId);
        }
    }
    async parseResponse(response) {
        if (response.status === 401 || response.status === 403) {
            const message = response.status === 401
                ? "Jira authentication failed. Check email and API token."
                : "Jira access forbidden. Check permissions.";
            throw new JiraNotAuthenticatedError(message);
        }
        if (response.status === 404) {
            throw new JiraNotFoundError(`Jira resource not found: ${response.url}`);
        }
        if (response.status === 429) {
            const retryAfter = response.headers.get("Retry-After");
            const seconds = retryAfter ? parseInt(retryAfter, 10) : 60;
            throw new JiraRateLimitError(seconds, `Jira rate limit exceeded. Retry after ${seconds} seconds.`);
        }
        if (!response.ok) {
            const body = await response.text().catch(() => "");
            throw new JiraApiError(response.status, `Jira API error ${response.status}: ${body}`.slice(0, 500));
        }
        return response.json();
    }
}
//# sourceMappingURL=jira-api-client.js.map