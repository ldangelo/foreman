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
export interface GitHubLabelDefinition {
    name: string;
    color: string;
    description?: string;
}
export interface EnsureLabelsResult {
    created: string[];
    updated: string[];
    unchanged: string[];
}
/** Base error for all GhCli failures. */
export declare class GhError extends Error {
    readonly name: string;
}
/** Thrown when `gh` is not installed or not on PATH. */
export declare class GhNotInstalledError extends GhError {
    readonly name: string;
    constructor();
}
/**
 * Thrown when `gh` auth fails — e.g. no credentials stored, or token revoked.
 * Subclass of GhCloneError so callers that catch clone errors also catch auth.
 */
export declare class GhNotAuthenticatedError extends GhError {
    readonly name: string;
    readonly exitCode: number;
    constructor(stderr: string, exitCode: number);
}
/** Thrown when `gh repo clone` fails for any reason (including auth). */
export declare class GhCloneError extends GhError {
    readonly name: string;
    readonly exitCode: number;
    constructor(message: string, stderr: string, exitCode: number);
}
/** Thrown when `gh api` returns a non-success status. */
export declare class GhApiError extends GhError {
    readonly name: string;
    readonly exitCode: number;
    readonly status?: number;
    readonly stderr: string;
    constructor(message: string, stderr: string, exitCode: number, status?: number);
}
/** Thrown when GitHub API returns 403 with rate limit exceeded message. */
export declare class GhRateLimitError extends GhApiError {
    readonly name: string;
    readonly retryAfter: number;
    constructor(message: string, retryAfter: number);
}
/** Thrown when a GitHub resource (issue, repo, user, etc.) is not found (404). */
export declare class GhNotFoundError extends GhApiError {
    readonly name: string;
    readonly resourcePath: string;
    constructor(resourcePath: string);
}
export declare class GhCli {
    private readonly ghPath;
    constructor(options?: GhCliOptions);
    /**
     * Run a `gh` command and return the result.
     * Does NOT throw on non-zero exit — caller decides what to do with the exit code.
     */
    private execGh;
    /**
     * Check whether `gh` is authenticated.
     *
     * Runs `gh auth status --json`. Returns `true` only if authenticated
     * and exit code is 0. Returns `false` in all other cases (not logged in,
     * token expired, network error, gh not installed).
     */
    authStatus(): Promise<boolean>;
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
    checkAuth(): Promise<void>;
    /**
     * Check whether `gh` is installed and can be invoked.
     * Unlike `authStatus()`, this does not require authentication — it only
     * checks that the `gh` binary is on PATH.
     */
    isInstalled(): Promise<boolean>;
    /**
     * Clone a GitHub repository using `gh repo clone`.
     *
     * @param url  - Full repo URL (e.g. `https://github.com/owner/repo` or `owner/repo`)
     * @param targetPath - Absolute directory path to clone into
     * @throws GhNotAuthenticatedError on auth failure
     * @throws GhCloneError on any other clone failure
     */
    repoClone(url: string, targetPath: string): Promise<void>;
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
    api<T = unknown>(endpoint: string, options?: GhApiOptions): Promise<T>;
    /**
     * Fetch repository metadata from the GitHub API.
     */
    getRepoMetadata(owner: string, repo: string): Promise<{
        defaultBranch: string;
        visibility: "public" | "private" | "internal";
        fullName: string;
    }>;
    /**
     * Get a single issue by number.
     *
     * @throws GhNotFoundError if the issue does not exist
     * @throws GhRateLimitError on rate limit
     */
    getIssue(owner: string, repo: string, issueNumber: number): Promise<GitHubIssue>;
    /**
     * List issues for a repository.
     *
     * @param owner - Repository owner
     * @param repo - Repository name
     * @param options - Filter options (labels, milestone, assignee, state, since)
     * @returns Array of GitHub issues (excludes pull requests)
     */
    listIssues(owner: string, repo: string, options?: ListIssuesOptions): Promise<GitHubIssue[]>;
    /**
     * Create a new issue.
     *
     * @param owner - Repository owner
     * @param repo - Repository name
     * @param options - Issue creation options
     * @returns The created GitHub issue
     */
    createIssue(owner: string, repo: string, options: CreateIssueOptions): Promise<GitHubIssue>;
    /**
     * Update an existing issue.
     *
     * @param owner - Repository owner
     * @param repo - Repository name
     * @param issueNumber - Issue number to update
     * @param options - Fields to update
     * @returns The updated GitHub issue
     */
    updateIssue(owner: string, repo: string, issueNumber: number, options: UpdateIssueOptions): Promise<GitHubIssue>;
    /**
     * List all labels for a repository.
     */
    listLabels(owner: string, repo: string): Promise<GitHubLabel[]>;
    /**
     * Create a repository label.
     */
    createLabel(owner: string, repo: string, label: GitHubLabelDefinition): Promise<GitHubLabel>;
    /**
     * Update an existing repository label.
     */
    updateLabel(owner: string, repo: string, currentName: string, label: GitHubLabelDefinition): Promise<GitHubLabel>;
    /**
     * Ensure a set of repository labels exists with the expected color/description.
     */
    ensureLabels(owner: string, repo: string, labels: GitHubLabelDefinition[]): Promise<EnsureLabelsResult>;
    /**
     * List all milestones for a repository.
     */
    listMilestones(owner: string, repo: string): Promise<GitHubMilestone[]>;
    /**
     * Get a GitHub user by username.
     *
     * @throws GhNotFoundError if the user does not exist
     */
    getUser(username: string): Promise<GitHubUser>;
    /**
     * Create a webhook for a repository.
     * Requires admin:repo_hook or repo scope.
     */
    createWebhook(owner: string, repo: string, webhookUrl: string, secret: string): Promise<{
        id: number;
        url: string;
    }>;
    /**
     * List webhooks for a repository.
     */
    listWebhooks(owner: string, repo: string): Promise<Array<{
        id: number;
        url: string;
        active: boolean;
    }>>;
    /**
     * Delete a webhook by ID.
     */
    deleteWebhook(owner: string, repo: string, webhookId: number): Promise<void>;
    /**
     * Link an issue to a pull request via the Issue Links API.
     * Creates a "connects" relationship from the PR to the issue.
     * Requires a PR branch that references the issue.
     */
    linkIssueToPullRequest(owner: string, repo: string, issueNumber: number, prNumber: number): Promise<void>;
    /**
     * Remove a link between an issue and a pull request.
     */
    unlinkIssueFromPullRequest(owner: string, repo: string, issueNumber: number, relation: string): Promise<void>;
}
/** GitHub issue as returned by the API. */
export interface GitHubIssue {
    id: number;
    number: number;
    title: string;
    body: string | null;
    state: "open" | "closed";
    user: {
        login: string;
        id: number;
    };
    labels: Array<{
        id: number;
        name: string;
        color: string;
    }>;
    assignees: Array<{
        login: string;
        id: number;
    }>;
    milestone: {
        id: number;
        title: string;
        number: number;
    } | null;
    created_at: string;
    updated_at: string;
    closed_at: string | null;
    url: string;
    html_url: string;
    /** Present for pull requests returned by GitHub's issues API; filtered by listIssues(). */
    pull_request?: unknown;
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
//# sourceMappingURL=gh-cli.d.ts.map