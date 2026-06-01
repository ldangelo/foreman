/**
 * JiraApiClient — thin wrapper around Jira REST API.
 * Supports both Jira Cloud (REST API v3) and Jira Server/Data Center (REST API v2).
 * Uses Basic Auth for authentication.
 */

// ---------------------------------------------------------------------------
// Configuration types (daemon-level, not project-level)
// ---------------------------------------------------------------------------

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
}

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
  constructor(
    public readonly retryAfterSeconds: number,
    message: string,
  ) {
    super(message);
    this.name = "JiraRateLimitError";
  }
}

export class JiraApiError extends JiraError {
  constructor(
    public readonly statusCode: number,
    message: string,
  ) {
    super(message);
    this.name = "JiraApiError";
  }
}

// ---------------------------------------------------------------------------
// JiraApiClient
// ---------------------------------------------------------------------------

export class JiraApiClient {
  private readonly baseUrl: string;
  private readonly authHeader: string;
  private readonly timeoutMs: number;
  /** API version: "cloud" (REST v3) or "server" (REST v2) */
  private readonly apiVersion: "cloud" | "server";

  constructor(config: JiraApiClientConfig) {
    this.baseUrl = config.apiUrl.replace(/\/$/, "");
    // Server uses username, Cloud uses email for Basic Auth
    const credentials = Buffer.from(`${config.email}:${config.apiToken}`).toString("base64");
    this.authHeader = `Basic ${credentials}`;
    this.timeoutMs = config.timeoutMs ?? 30_000;
    this.apiVersion = config.apiVersion ?? "cloud";
  }

  /**
   * Get the API path prefix based on version.
   * - Cloud: /rest/api/3/...
   * - Server: /rest/api/2/...
   */
  private apiPath(path: string): string {
    const version = this.apiVersion === "server" ? "2" : "3";
    return `/rest/api/${version}${path}`;
  }

  /**
   * Authenticate — validates credentials by fetching current user.
   * Throws JiraNotAuthenticatedError if credentials are invalid.
   */
  async authenticate(): Promise<void> {
    try {
      await this.get(this.apiPath("/myself"));
    } catch (err) {
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
  async search(jql: string, options?: { maxResults?: number }): Promise<SearchResult> {
    const params = new URLSearchParams({
      jql,
      maxResults: String(options?.maxResults ?? 50),
    });
    return this.get<SearchResult>(`${this.apiPath("/search")}?${params}`);
  }

  /**
   * Get a single issue by key.
   * @param issueKey e.g., "PROJ-123"
   */
  async getIssue(issueKey: string): Promise<JiraIssue> {
    return this.get<JiraIssue>(this.apiPath(`/issue/${encodeURIComponent(issueKey)}`));
  }

  /**
   * List available projects for this Jira instance.
   */
  async listProjects(): Promise<JiraProject[]> {
    const result = await this.get<{ values: JiraProject[] }>(this.apiPath("/project"));
    return result.values ?? [];
  }

  /**
   * Handle rate limit by waiting for the specified duration.
   */
  handleRateLimit(retryAfterSeconds: number): Promise<void> {
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
  async addComment(issueKey: string, comment: string): Promise<void> {
    await this.post(this.apiPath(`/issue/${encodeURIComponent(issueKey)}/comment`), {
      body: comment,
    });
  }

  /**
   * Transition an issue to a new status.
   * Useful for workflow automation (e.g., move to "In Review").
   */
  async transitionIssue(
    issueKey: string,
    transitionId: string,
  ): Promise<void> {
    await this.post(
      this.apiPath(`/issue/${encodeURIComponent(issueKey)}/transitions`),
      { transition: { id: transitionId } },
    );
  }

  // -------------------------------------------------------------------------
  // Private methods
  // -------------------------------------------------------------------------

  private async get<T>(path: string): Promise<T> {
    const response = await this.fetch(path, { method: "GET" });
    return this.parseResponse<T>(response);
  }

  private async post<T>(path: string, body: unknown): Promise<T> {
    const response = await this.fetch(path, {
      method: "POST",
      body: JSON.stringify(body),
    });
    return this.parseResponse<T>(response);
  }

  private async fetch(path: string, options: RequestInit): Promise<Response> {
    const url = `${this.baseUrl}${path}`;
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), this.timeoutMs);

    try {
      const response = await fetch(url, {
        ...options,
        headers: {
          Authorization: this.authHeader,
          "Content-Type": "application/json",
          Accept: "application/json",
          ...options.headers,
        },
        signal: controller.signal,
      });
      return response;
    } finally {
      clearTimeout(timeoutId);
    }
  }

  private async parseResponse<T>(response: Response): Promise<T> {
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
      throw new JiraRateLimitError(
        seconds,
        `Jira rate limit exceeded. Retry after ${seconds} seconds.`,
      );
    }

    if (!response.ok) {
      const body = await response.text().catch(() => "");
      throw new JiraApiError(
        response.status,
        `Jira API error ${response.status}: ${body}`.slice(0, 500),
      );
    }

    return response.json();
  }
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface JiraIssue {
  key: string;
  fields: {
    summary: string;
    status: { name: string };
    issuetype: { name: string };
    project: { key: string };
    updated: string;
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