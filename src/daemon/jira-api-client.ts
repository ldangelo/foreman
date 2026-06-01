/**
 * JiraApiClient — thin wrapper around Jira Cloud REST API v3.
 * Uses Basic Auth (email + API token) for authentication.
 */

import { createHmac } from "node:crypto";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface JiraApiClientConfig {
  apiUrl: string;
  email: string;
  apiToken: string;
  timeoutMs?: number;
}

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

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

export class JiraError extends Error {
  override readonly name = "JiraError" as string;
}

export class JiraNotAuthenticatedError extends JiraError {
  override readonly name = "JiraNotAuthenticatedError" as string;
}

export class JiraNotFoundError extends JiraError {
  override readonly name = "JiraNotFoundError" as string;
}

export class JiraRateLimitError extends JiraError {
  override readonly name = "JiraRateLimitError" as string;
  constructor(
    public readonly retryAfterSeconds: number,
    message: string,
  ) {
    super(message);
  }
}

export class JiraApiError extends JiraError {
  override readonly name = "JiraApiError" as string;
  constructor(
    public readonly statusCode: number,
    message: string,
  ) {
    super(message);
  }
}

// ---------------------------------------------------------------------------
// JiraApiClient
// ---------------------------------------------------------------------------

export class JiraApiClient {
  private readonly baseUrl: string;
  private readonly authHeader: string;
  private readonly timeoutMs: number;

  constructor(config: JiraApiClientConfig) {
    this.baseUrl = config.apiUrl.replace(/\/$/, "");
    const credentials = Buffer.from(`${config.email}:${config.apiToken}`).toString("base64");
    this.authHeader = `Basic ${credentials}`;
    this.timeoutMs = config.timeoutMs ?? 30_000;
  }

  /**
   * Authenticate — validates credentials by fetching current user.
   * Throws JiraNotAuthenticatedError if credentials are invalid.
   */
  async authenticate(): Promise<void> {
    try {
      await this.get("/rest/api/3/myself");
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
    return this.get<SearchResult>(`/rest/api/3/search?${params}`);
  }

  /**
   * Get a single issue by key.
   * @param issueKey e.g., "PROJ-123"
   */
  async getIssue(issueKey: string): Promise<JiraIssue> {
    return this.get<JiraIssue>(`/rest/api/3/issue/${encodeURIComponent(issueKey)}`);
  }

  /**
   * List available projects for this Jira instance.
   */
  async listProjects(): Promise<JiraProject[]> {
    const result = await this.get<{ values: JiraProject[] }>("/rest/api/3/project");
    return result.values ?? [];
  }

  /**
   * Handle rate limit by waiting for the specified duration.
   */
  handleRateLimit(retryAfterSeconds: number): Promise<void> {
    const { promise, resolve } = Promise.withResolvers<void>();
    setTimeout(resolve, retryAfterSeconds * 1000);
    return promise;
  }

  // -------------------------------------------------------------------------
  // Private methods
  // -------------------------------------------------------------------------

  private async get<T>(path: string): Promise<T> {
    const response = await this.fetch(path, { method: "GET" });
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

  private async parseResponse(response: Response): Promise<unknown> {
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