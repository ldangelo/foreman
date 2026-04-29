/**
 * GhCli — thin wrapper around GitHub CLI (`gh`) commands.
 *
 * All GitHub operations go through this class. Uses `gh` exclusively for auth,
 * cloning, and API calls. `gh` manages credentials via OS keychain — Foreman
 * never handles tokens directly.
 *
 * Design decisions:
 * - `gh` path is configurable (default: `gh` from PATH) for testing.
 * - `authStatus()` returns boolean — does not throw on unauthenticated state.
 * - `repoClone()` throws descriptive errors — callers handle auth failures.
 * - `api()` wraps `gh api` with full response/error passthrough.
 *
 * @module gh-cli
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

export interface GhCliOptions {
  /** Path to `gh` binary. Defaults to `gh` from PATH. */
  ghPath?: string;
}

export interface GhApiOptions {
  method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
  body?: string;
  jq?: string;
  silent?: boolean;
}

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

/** Base error for all GhCli failures. */
export class GhError extends Error {
  override readonly name = "GhError" as string;
}

/** Thrown when `gh` is not installed or not on PATH. */
export class GhNotInstalledError extends GhError {
  override readonly name = "GhNotInstalledError" as string;

  constructor() {
    super(
      "GitHub CLI (gh) is required but not installed. Install it from https://cli.github.com"
    );
  }
}

/**
 * Thrown when `gh` auth fails — e.g. no credentials stored, or token revoked.
 * Subclass of GhCloneError so callers that catch clone errors also catch auth.
 */
export class GhNotAuthenticatedError extends GhError {
  override readonly name = "GhNotAuthenticatedError" as string;
  readonly exitCode: number;

  constructor(stderr: string, exitCode: number) {
    super(`GitHub authentication required: ${stderr.trim() || "Not authenticated"}`);
    this.exitCode = exitCode;
  }
}

/** Thrown when `gh repo clone` fails for any reason (including auth). */
export class GhCloneError extends GhError {
  override readonly name = "GhCloneError" as string;
  readonly exitCode: number;

  constructor(message: string, stderr: string, exitCode: number) {
    super(message);
    this.exitCode = exitCode;
    // Attach stderr for debugging without cluttering the message
    if (stderr.trim()) {
      (this as unknown as { stderr: string }).stderr = stderr.trim();
    }
  }
}

/** Thrown when `gh api` returns a non-success status. */
export class GhApiError extends GhError {
  override readonly name = "GhApiError" as string;
  readonly exitCode: number;
  readonly status?: number;
  readonly stderr: string;

  constructor(
    message: string,
    stderr: string,
    exitCode: number,
    status?: number
  ) {
    super(message);
    this.exitCode = exitCode;
    this.stderr = stderr.trim();
    this.status = status;
  }
}

/** Thrown when GitHub API returns 403 with rate limit exceeded message. */
export class GhRateLimitError extends GhApiError {
  override readonly name = "GhRateLimitError" as string;
  readonly retryAfter: number;

  constructor(message: string, retryAfter: number) {
    super(message, message, 1, 403);
    this.retryAfter = retryAfter;
  }
}

/** Thrown when a GitHub resource (issue, repo, user, etc.) is not found (404). */
export class GhNotFoundError extends GhApiError {
  override readonly name = "GhNotFoundError" as string;
  readonly resourcePath: string;

  constructor(resourcePath: string) {
    super(
      `GitHub resource not found: ${resourcePath}`,
      "HTTP 404: Not Found",
      1,
      404,
    );
    this.resourcePath = resourcePath;
  }
}

// ---------------------------------------------------------------------------
// GhCli
// ---------------------------------------------------------------------------

export class GhCli {
  private readonly ghPath: string;

  constructor(options: GhCliOptions = {}) {
    this.ghPath = options.ghPath ?? "gh";
  }

  /**
   * Run a `gh` command and return the result.
   * Does NOT throw on non-zero exit — caller decides what to do with the exit code.
   */
  private async execGh(
    args: string[],
    options: { timeout?: number; cwd?: string } = {}
  ): Promise<{ stdout: string; stderr: string; exitCode: number }> {
    try {
      const { stdout, stderr } = await execFileAsync(this.ghPath, args, {
        timeout: options.timeout ?? 60_000,
        cwd: options.cwd,
        encoding: "utf8",
        maxBuffer: 50 * 1024 * 1024, // 50 MB — large enough for `gh api` responses
      });
      return { stdout: stdout.trimEnd(), stderr: stderr.trimEnd(), exitCode: 0 };
    } catch (err: unknown) {
      const execError = err as {
        code?: number;
        killed?: boolean;
        stderr?: string;
        stdout?: string;
      };
      if (execError.code === 127 || execError.code === undefined) {
        throw new GhNotInstalledError();
      }
      return {
        stdout: (execError.stdout ?? "").trimEnd(),
        stderr: (execError.stderr ?? "").trimEnd(),
        exitCode: execError.code ?? 1,
      };
    }
  }

  /**
   * Check whether `gh` is authenticated.
   *
   * Runs `gh auth status --json`. Returns `true` only if authenticated
   * and exit code is 0. Returns `false` in all other cases (not logged in,
   * token expired, network error, gh not installed).
   */
  async authStatus(): Promise<boolean> {
    const result = await this.execGh(["auth", "status", "--json", "hosts"], {
      timeout: 10_000,
    });
    if (result.exitCode !== 0) {
      return false;
    }
    // gh auth status --json outputs a JSON array even when not authenticated
    // but the structure differs; check for auth token presence
    try {
      const parsed = JSON.parse(result.stdout);
      const hosts = parsed?.hosts;
      if (!hosts || typeof hosts !== "object") {
        return false;
      }
      return Object.values(hosts).some((entries) =>
        Array.isArray(entries) && entries.some((entry) => entry?.active === true || entry?.state === "success"),
      );
    } catch {
      return false;
    }
  }

  /**
   * Verify GitHub CLI is available and authenticated.
   *
   * Calls `gh auth status` and throws `GhNotInstalledError` if gh is not
   * installed, or `GhNotAuthenticatedError` if not logged in.
   * Use this at the entry point of any command that requires GitHub access.
   *
   * @throws GhNotInstalledError if gh binary is not found
   * @throws GhNotAuthenticatedError if gh is not logged in
   */
  async checkAuth(): Promise<void> {
    const installed = await this.isInstalled();
    if (!installed) {
      throw new GhNotInstalledError();
    }
    const authenticated = await this.authStatus();
    if (!authenticated) {
      throw new GhNotAuthenticatedError(
        "Run 'gh auth login' to authenticate with GitHub.",
        1
      );
    }
  }

  /**
   * Check whether `gh` is installed and can be invoked.
   * Unlike `authStatus()`, this does not require authentication — it only
   * checks that the `gh` binary is on PATH.
   */
  async isInstalled(): Promise<boolean> {
    try {
      const result = await this.execGh(["--version"], { timeout: 5_000 });
      return result.exitCode === 0;
    } catch {
      return false;
    }
  }

  /**
   * Clone a GitHub repository using `gh repo clone`.
   *
   * @param url  - Full repo URL (e.g. `https://github.com/owner/repo` or `owner/repo`)
   * @param targetPath - Absolute directory path to clone into
   * @throws GhNotAuthenticatedError on auth failure
   * @throws GhCloneError on any other clone failure
   */
  async repoClone(url: string, targetPath: string): Promise<void> {
    const result = await this.execGh(
      ["repo", "clone", url, targetPath, "--", "--depth=1"],
      { timeout: 300_000 } // 5 min — large repos can be slow
    );

    if (result.exitCode === 0) return;

    const stderr = result.stderr;

    // gh returns exit code 1 for most failures including auth
    // Exit code 4 = template not found (unlikely for clone)
    // Check stderr for auth-related messages
    const authIndicators = [
      "authentication",
      "not authenticated",
      "auth",
      "login",
      "credentials",
      "token",
      "gh auth login",
    ];
    const isAuthFailure = authIndicators.some((indicator) =>
      stderr.toLowerCase().includes(indicator)
    );

    if (isAuthFailure) {
      throw new GhNotAuthenticatedError(stderr, result.exitCode);
    }

    throw new GhCloneError(
      `Failed to clone repository '${url}' to '${targetPath}': ${stderr || "Unknown error"}`,
      stderr,
      result.exitCode
    );
  }

  /**
   * Call the GitHub API via `gh api`.
   *
   * @param endpoint - API endpoint path (e.g. `/repos/owner/repo`)
   * @param options - HTTP method, request body, jq filter, silent flag
   * @returns Parsed JSON response
   * @throws GhNotFoundError on 404
   * @throws GhRateLimitError on 403 rate limit exceeded
   * @throws GhApiError on other non-success status
   */
  async api<T = unknown>(
    endpoint: string,
    options: GhApiOptions = {}
  ): Promise<T> {
    const args = ["api", endpoint];

    if (options.method && options.method !== "GET") {
      args.push("--method", options.method);
    }
    if (options.body !== undefined) {
      args.push("--input", "-");
    }
    if (options.jq) {
      args.push("--jq", options.jq);
    }
    if (options.silent) {
      args.push("--silent");
    }

    // gh api --paginate auto-fetches all pages; not enabled by default to keep
    // behavior predictable. Callers that need pagination can call repeatedly or
    // use --paginate.
    // args.push("--paginate"); // disabled by default

    const result = await this.execGh(args, {
      timeout: 30_000,
    });

    if (result.exitCode !== 0) {
      // Parse gh error output for status code
      // gh outputs errors like: HTTP 404: Not Found (https://api.github.com/repos/...)
      const statusMatch = result.stderr.match(/HTTP (\d{3})/);
      const status = statusMatch ? parseInt(statusMatch[1], 10) : undefined;

      // Detect specialized error types
      if (status === 404) {
        throw new GhNotFoundError(endpoint);
      }
      if (status === 403 || result.stderr.toLowerCase().includes("rate limit")) {
        // Try to extract retry-after seconds from gh error message
        const retryMatch = result.stderr.match(/retry after (\d+) seconds?/i);
        const retryAfter = retryMatch ? parseInt(retryMatch[1]!, 10) : 3600;
        throw new GhRateLimitError(
          `GitHub API rate limit exceeded. ${result.stderr || "Retry after " + retryAfter + " seconds."}`,
          retryAfter,
        );
      }

      throw new GhApiError(
        `GitHub API error for '${endpoint}': ${result.stderr || `Exit code ${result.exitCode}`}`,
        result.stderr,
        result.exitCode,
        status,
      );
    }

    // Empty response (e.g. 204 No Content)
    if (!result.stdout) {
      return undefined as T;
    }

    try {
      return JSON.parse(result.stdout) as T;
    } catch {
      // gh api --jq can return non-JSON; return as string
      return result.stdout as unknown as T;
    }
  }

  // ---------------------------------------------------------------------------
  // Repository metadata helpers (built on top of api())
  // ---------------------------------------------------------------------------

  /**
   * Fetch repository metadata from the GitHub API.
   */
  async getRepoMetadata(owner: string, repo: string): Promise<{
    defaultBranch: string;
    visibility: "public" | "private" | "internal";
    fullName: string;
  }> {
    const data = await this.api<{
      default_branch: string;
      visibility: string;
      full_name: string;
    }>(`/repos/${owner}/${repo}`);

    return {
      defaultBranch: data.default_branch,
      visibility:
        data.visibility === "public" ||
        data.visibility === "private" ||
        data.visibility === "internal"
          ? (data.visibility as "public" | "private" | "internal")
          : "private",
      fullName: data.full_name,
    };
  }

  // ---------------------------------------------------------------------------
  // Issue CRUD (built on top of api())
  // ---------------------------------------------------------------------------

  /**
   * Get a single issue by number.
   *
   * @throws GhNotFoundError if the issue does not exist
   * @throws GhRateLimitError on rate limit
   */
  async getIssue(owner: string, repo: string, issueNumber: number): Promise<GitHubIssue> {
    return this.api<GitHubIssue>(
      `/repos/${owner}/${repo}/issues/${issueNumber}`,
    );
  }

  /**
   * List issues for a repository.
   *
   * @param owner - Repository owner
   * @param repo - Repository name
   * @param options - Filter options (labels, milestone, assignee, state, since)
   * @returns Array of GitHub issues (excludes pull requests)
   */
  async listIssues(
    owner: string,
    repo: string,
    options: ListIssuesOptions = {},
  ): Promise<GitHubIssue[]> {
    const params = new URLSearchParams();
    if (options.labels) params.set("labels", options.labels);
    if (options.milestone) params.set("milestone", options.milestone);
    if (options.assignee) params.set("assignee", options.assignee);
    if (options.state) params.set("state", options.state);
    if (options.since) params.set("since", options.since);
    params.set("per_page", "100");

    const query = params.toString() ? `?${params.toString()}` : "";
    return this.api<GitHubIssue[]>(
      `/repos/${owner}/${repo}/issues${query}`,
    );
  }

  /**
   * Create a new issue.
   *
   * @param owner - Repository owner
   * @param repo - Repository name
   * @param options - Issue creation options
   * @returns The created GitHub issue
   */
  async createIssue(
    owner: string,
    repo: string,
    options: CreateIssueOptions,
  ): Promise<GitHubIssue> {
    const body: Record<string, unknown> = {
      title: options.title,
    };
    if (options.body) body.body = options.body;
    if (options.labels && options.labels.length > 0) body.labels = options.labels;
    if (options.milestone) body.milestone = options.milestone;
    if (options.assignee && options.assignee.length > 0) body.assignees = options.assignee;

    return this.api<GitHubIssue>(
      `/repos/${owner}/${repo}/issues`,
      {
        method: "POST",
        body: JSON.stringify(body),
      },
    );
  }

  /**
   * Update an existing issue.
   *
   * @param owner - Repository owner
   * @param repo - Repository name
   * @param issueNumber - Issue number to update
   * @param options - Fields to update
   * @returns The updated GitHub issue
   */
  async updateIssue(
    owner: string,
    repo: string,
    issueNumber: number,
    options: UpdateIssueOptions,
  ): Promise<GitHubIssue> {
    const body: Record<string, unknown> = {};
    if (options.title !== undefined) body.title = options.title;
    if (options.body !== undefined) body.body = options.body;
    if (options.state !== undefined) body.state = options.state;
    if (options.labels !== undefined) body.labels = options.labels;
    if (options.milestone !== undefined) body.milestone = options.milestone;
    if (options.assignees !== undefined) body.assignees = options.assignees;

    return this.api<GitHubIssue>(
      `/repos/${owner}/${repo}/issues/${issueNumber}`,
      {
        method: "PATCH",
        body: JSON.stringify(body),
      },
    );
  }

  /**
   * List all labels for a repository.
   */
  async listLabels(owner: string, repo: string): Promise<GitHubLabel[]> {
    return this.api<GitHubLabel[]>(`/repos/${owner}/${repo}/labels`);
  }

  /**
   * List all milestones for a repository.
   */
  async listMilestones(owner: string, repo: string): Promise<GitHubMilestone[]> {
    return this.api<GitHubMilestone[]>(
      `/repos/${owner}/${repo}/milestones?per_page=100`,
    );
  }

  /**
   * Get a GitHub user by username.
   *
   * @throws GhNotFoundError if the user does not exist
   */
  async getUser(username: string): Promise<GitHubUser> {
    return this.api<GitHubUser>(`/users/${username}`);
  }

  // ---------------------------------------------------------------------------
  // Webhook operations (TRD-037, TRD-038)
  // ---------------------------------------------------------------------------

  /**
   * Create a webhook for a repository.
   * Requires admin:repo_hook or repo scope.
   */
  async createWebhook(
    owner: string,
    repo: string,
    webhookUrl: string,
    secret: string,
  ): Promise<{ id: number; url: string }> {
    const body = {
      name: "web",
      active: true,
      events: ["issues", "pull_request"],
      config: {
        url: webhookUrl,
        content_type: "json",
        secret,
        insecure_ssl: "0",
      },
    };
    return this.api<{ id: number; url: string }>(
      `/repos/${owner}/${repo}/hooks`,
      { method: "POST", body: JSON.stringify(body) },
    );
  }

  /**
   * List webhooks for a repository.
   */
  async listWebhooks(owner: string, repo: string): Promise<Array<{ id: number; url: string; active: boolean }>> {
    return this.api<
      Array<{ id: number; url: string; active: boolean }>
    >(`/repos/${owner}/${repo}/hooks`);
  }

  /**
   * Delete a webhook by ID.
   */
  async deleteWebhook(owner: string, repo: string, webhookId: number): Promise<void> {
    await this.api<void>(
      `/repos/${owner}/${repo}/hooks/${webhookId}`,
      { method: "DELETE" },
    );
  }

  // ---------------------------------------------------------------------------
  // Issue Linking (TRD-041)
  // ---------------------------------------------------------------------------

  /**
   * Link an issue to a pull request via the Issue Links API.
   * Creates a "connects" relationship from the PR to the issue.
   * Requires a PR branch that references the issue.
   */
  async linkIssueToPullRequest(
    owner: string,
    repo: string,
    issueNumber: number,
    prNumber: number,
  ): Promise<void> {
    await this.api<void>(
      `/repos/${owner}/${repo}/issues/${issueNumber}/links`,
      {
        method: "POST",
        body: JSON.stringify({
          issue: {
            number: issueNumber,
          },
          pull_request: {
            number: prNumber,
          },
        }),
      },
    );
  }

  /**
   * Remove a link between an issue and a pull request.
   */
  async unlinkIssueFromPullRequest(
    owner: string,
    repo: string,
    issueNumber: number,
    relation: string,
  ): Promise<void> {
    await this.api<void>(
      `/repos/${owner}/${repo}/issues/${issueNumber}/links/${relation}`,
      { method: "DELETE" },
    );
  }
}

// ---------------------------------------------------------------------------
// GitHub API types (exported at module level)
// ---------------------------------------------------------------------------

/** GitHub issue as returned by the API. */
export interface GitHubIssue {
  id: number;
  number: number;
  title: string;
  body: string | null;
  state: "open" | "closed";
  user: { login: string; id: number };
  labels: Array<{ id: number; name: string; color: string }>;
  assignees: Array<{ login: string; id: number }>;
  milestone: { id: number; title: string; number: number } | null;
  created_at: string;
  updated_at: string;
  closed_at: string | null;
  url: string;
  html_url: string;
  /** Present on single-issue GET responses (not on list responses). */
  repository_url?: string;
}

/** GitHub label as returned by the API. */
export interface GitHubLabel {
  id: number;
  name: string;
  color: string;
  description: string | null;
}

/** GitHub milestone as returned by the API. */
export interface GitHubMilestone {
  id: number;
  number: number;
  title: string;
  state: "open" | "closed";
  description: string | null;
  open_issues: number;
  closed_issues: number;
}

/** GitHub user as returned by the API. */
export interface GitHubUser {
  login: string;
  id: number;
  avatar_url: string;
  html_url: string;
}

/** Options for listing issues. */
export interface ListIssuesOptions {
  /** Filter by label(s), comma-separated or repeated. */
  labels?: string;
  /** Filter by milestone number or title. */
  milestone?: string;
  /** Filter by assignee username. */
  assignee?: string;
  /** Filter by state: open, closed, all. */
  state?: "open" | "closed" | "all";
  /** Filter issues updated after this ISO timestamp. */
  since?: string;
}

/** Options for creating an issue. */
export interface CreateIssueOptions {
  title: string;
  body?: string;
  labels?: string[];
  milestone?: string;
  assignee?: string[];
}

/** Options for updating an issue. */
export interface UpdateIssueOptions {
  title?: string;
  body?: string;
  state?: "open" | "closed";
  labels?: string[];
  milestone?: string;
  assignees?: string[];
}
