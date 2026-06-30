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
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
const execFileAsync = promisify(execFile);
// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------
/** Base error for all GhCli failures. */
export class GhError extends Error {
    name = "GhError";
}
/** Thrown when `gh` is not installed or not on PATH. */
export class GhNotInstalledError extends GhError {
    name = "GhNotInstalledError";
    constructor() {
        super("GitHub CLI (gh) is required but not installed. Install it from https://cli.github.com");
    }
}
/**
 * Thrown when `gh` auth fails — e.g. no credentials stored, or token revoked.
 * Subclass of GhCloneError so callers that catch clone errors also catch auth.
 */
export class GhNotAuthenticatedError extends GhError {
    name = "GhNotAuthenticatedError";
    exitCode;
    constructor(stderr, exitCode) {
        super(`GitHub authentication required: ${stderr.trim() || "Not authenticated"}`);
        this.exitCode = exitCode;
    }
}
/** Thrown when `gh repo clone` fails for any reason (including auth). */
export class GhCloneError extends GhError {
    name = "GhCloneError";
    exitCode;
    constructor(message, stderr, exitCode) {
        super(message);
        this.exitCode = exitCode;
        // Attach stderr for debugging without cluttering the message
        if (stderr.trim()) {
            this.stderr = stderr.trim();
        }
    }
}
/** Thrown when `gh api` returns a non-success status. */
export class GhApiError extends GhError {
    name = "GhApiError";
    exitCode;
    status;
    stderr;
    constructor(message, stderr, exitCode, status) {
        super(message);
        this.exitCode = exitCode;
        this.stderr = stderr.trim();
        this.status = status;
    }
}
/** Thrown when GitHub API returns 403 with rate limit exceeded message. */
export class GhRateLimitError extends GhApiError {
    name = "GhRateLimitError";
    retryAfter;
    constructor(message, retryAfter) {
        super(message, message, 1, 403);
        this.retryAfter = retryAfter;
    }
}
/** Thrown when a GitHub resource (issue, repo, user, etc.) is not found (404). */
export class GhNotFoundError extends GhApiError {
    name = "GhNotFoundError";
    resourcePath;
    constructor(resourcePath) {
        super(`GitHub resource not found: ${resourcePath}`, "HTTP 404: Not Found", 1, 404);
        this.resourcePath = resourcePath;
    }
}
// ---------------------------------------------------------------------------
// GhCli
// ---------------------------------------------------------------------------
export class GhCli {
    ghPath;
    constructor(options = {}) {
        this.ghPath = options.ghPath ?? "gh";
    }
    /**
     * Run a `gh` command and return the result.
     * Does NOT throw on non-zero exit — caller decides what to do with the exit code.
     */
    async execGh(args, options = {}) {
        if (options.input !== undefined) {
            return await new Promise((resolve, reject) => {
                const child = spawn(this.ghPath, args, {
                    cwd: options.cwd,
                    stdio: ["pipe", "pipe", "pipe"],
                });
                let stdout = "";
                let stderr = "";
                let timedOut = false;
                const timeout = setTimeout(() => {
                    timedOut = true;
                    child.kill("SIGTERM");
                }, options.timeout ?? 60_000);
                child.stdout.setEncoding("utf8");
                child.stderr.setEncoding("utf8");
                child.stdout.on("data", (chunk) => {
                    stdout += chunk;
                });
                child.stderr.on("data", (chunk) => {
                    stderr += chunk;
                });
                child.on("error", (err) => {
                    clearTimeout(timeout);
                    if (err.code === "ENOENT") {
                        reject(new GhNotInstalledError());
                        return;
                    }
                    reject(err);
                });
                child.on("close", (code) => {
                    clearTimeout(timeout);
                    if (timedOut) {
                        resolve({ stdout: stdout.trimEnd(), stderr: stderr.trimEnd(), exitCode: 124 });
                        return;
                    }
                    resolve({ stdout: stdout.trimEnd(), stderr: stderr.trimEnd(), exitCode: code ?? 1 });
                });
                child.stdin.end(options.input, "utf8");
            });
        }
        try {
            const { stdout, stderr } = await execFileAsync(this.ghPath, args, {
                timeout: options.timeout ?? 60_000,
                cwd: options.cwd,
                encoding: "utf8",
                maxBuffer: 50 * 1024 * 1024, // 50 MB — large enough for `gh api` responses
            });
            return { stdout: stdout.trimEnd(), stderr: stderr.trimEnd(), exitCode: 0 };
        }
        catch (err) {
            const execError = err;
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
    async authStatus() {
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
            return Object.values(hosts).some((entries) => Array.isArray(entries) && entries.some((entry) => entry?.active === true || entry?.state === "success"));
        }
        catch {
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
    async checkAuth() {
        const installed = await this.isInstalled();
        if (!installed) {
            throw new GhNotInstalledError();
        }
        const authenticated = await this.authStatus();
        if (!authenticated) {
            throw new GhNotAuthenticatedError("Run 'gh auth login' to authenticate with GitHub.", 1);
        }
    }
    /**
     * Check whether `gh` is installed and can be invoked.
     * Unlike `authStatus()`, this does not require authentication — it only
     * checks that the `gh` binary is on PATH.
     */
    async isInstalled() {
        try {
            const result = await this.execGh(["--version"], { timeout: 5_000 });
            return result.exitCode === 0;
        }
        catch {
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
    async repoClone(url, targetPath) {
        const result = await this.execGh(["repo", "clone", url, targetPath, "--", "--depth=1"], { timeout: 300_000 } // 5 min — large repos can be slow
        );
        if (result.exitCode === 0)
            return;
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
        const isAuthFailure = authIndicators.some((indicator) => stderr.toLowerCase().includes(indicator));
        if (isAuthFailure) {
            throw new GhNotAuthenticatedError(stderr, result.exitCode);
        }
        throw new GhCloneError(`Failed to clone repository '${url}' to '${targetPath}': ${stderr || "Unknown error"}`, stderr, result.exitCode);
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
    async api(endpoint, options = {}) {
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
            input: options.body,
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
                const retryAfter = retryMatch ? parseInt(retryMatch[1], 10) : 3600;
                throw new GhRateLimitError(`GitHub API rate limit exceeded. ${result.stderr || "Retry after " + retryAfter + " seconds."}`, retryAfter);
            }
            throw new GhApiError(`GitHub API error for '${endpoint}': ${result.stderr || `Exit code ${result.exitCode}`}`, result.stderr, result.exitCode, status);
        }
        // Empty response (e.g. 204 No Content)
        if (!result.stdout) {
            return undefined;
        }
        try {
            return JSON.parse(result.stdout);
        }
        catch {
            // gh api --jq can return non-JSON; return as string
            return result.stdout;
        }
    }
    // ---------------------------------------------------------------------------
    // Repository metadata helpers (built on top of api())
    // ---------------------------------------------------------------------------
    /**
     * Fetch repository metadata from the GitHub API.
     */
    async getRepoMetadata(owner, repo) {
        const data = await this.api(`/repos/${owner}/${repo}`);
        return {
            defaultBranch: data.default_branch,
            visibility: data.visibility === "public" ||
                data.visibility === "private" ||
                data.visibility === "internal"
                ? data.visibility
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
    async getIssue(owner, repo, issueNumber) {
        return this.api(`/repos/${owner}/${repo}/issues/${issueNumber}`);
    }
    /**
     * List issues for a repository.
     *
     * @param owner - Repository owner
     * @param repo - Repository name
     * @param options - Filter options (labels, milestone, assignee, state, since)
     * @returns Array of GitHub issues (excludes pull requests)
     */
    async listIssues(owner, repo, options = {}) {
        const params = new URLSearchParams();
        if (options.labels)
            params.set("labels", options.labels);
        if (options.milestone)
            params.set("milestone", options.milestone);
        if (options.assignee)
            params.set("assignee", options.assignee);
        if (options.state)
            params.set("state", options.state);
        if (options.since)
            params.set("since", options.since);
        params.set("per_page", "100");
        const query = params.toString() ? `?${params.toString()}` : "";
        const issues = await this.api(`/repos/${owner}/${repo}/issues${query}`);
        return issues.filter((issue) => issue.pull_request === undefined);
    }
    /**
     * Create a new issue.
     *
     * @param owner - Repository owner
     * @param repo - Repository name
     * @param options - Issue creation options
     * @returns The created GitHub issue
     */
    async createIssue(owner, repo, options) {
        const body = {
            title: options.title,
        };
        if (options.body)
            body.body = options.body;
        if (options.labels && options.labels.length > 0)
            body.labels = options.labels;
        if (options.milestone)
            body.milestone = options.milestone;
        if (options.assignee && options.assignee.length > 0)
            body.assignees = options.assignee;
        return this.api(`/repos/${owner}/${repo}/issues`, {
            method: "POST",
            body: JSON.stringify(body),
        });
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
    async updateIssue(owner, repo, issueNumber, options) {
        const body = {};
        if (options.title !== undefined)
            body.title = options.title;
        if (options.body !== undefined)
            body.body = options.body;
        if (options.state !== undefined)
            body.state = options.state;
        if (options.labels !== undefined)
            body.labels = options.labels;
        if (options.milestone !== undefined)
            body.milestone = options.milestone;
        if (options.assignees !== undefined)
            body.assignees = options.assignees;
        return this.api(`/repos/${owner}/${repo}/issues/${issueNumber}`, {
            method: "PATCH",
            body: JSON.stringify(body),
        });
    }
    /**
     * List all labels for a repository.
     */
    async listLabels(owner, repo) {
        const labels = [];
        for (let page = 1;; page++) {
            const batch = await this.api(`/repos/${owner}/${repo}/labels?per_page=100&page=${page}`);
            labels.push(...batch);
            if (batch.length < 100) {
                break;
            }
        }
        return labels;
    }
    /**
     * Create a repository label.
     */
    async createLabel(owner, repo, label) {
        return this.api(`/repos/${owner}/${repo}/labels`, {
            method: "POST",
            body: JSON.stringify(label),
        });
    }
    /**
     * Update an existing repository label.
     */
    async updateLabel(owner, repo, currentName, label) {
        return this.api(`/repos/${owner}/${repo}/labels/${encodeURIComponent(currentName)}`, {
            method: "PATCH",
            body: JSON.stringify(label),
        });
    }
    /**
     * Ensure a set of repository labels exists with the expected color/description.
     */
    async ensureLabels(owner, repo, labels) {
        const existing = await this.listLabels(owner, repo);
        const existingByName = new Map(existing.map((label) => [label.name, label]));
        const result = {
            created: [],
            updated: [],
            unchanged: [],
        };
        for (const label of labels) {
            const current = existingByName.get(label.name);
            if (!current) {
                await this.createLabel(owner, repo, label);
                result.created.push(label.name);
                continue;
            }
            const desiredDescription = label.description ?? "";
            const currentDescription = current.description ?? "";
            if (current.color !== label.color || currentDescription !== desiredDescription) {
                await this.updateLabel(owner, repo, current.name, label);
                result.updated.push(label.name);
            }
            else {
                result.unchanged.push(label.name);
            }
        }
        return result;
    }
    /**
     * List all milestones for a repository.
     */
    async listMilestones(owner, repo) {
        return this.api(`/repos/${owner}/${repo}/milestones?per_page=100`);
    }
    /**
     * Get a GitHub user by username.
     *
     * @throws GhNotFoundError if the user does not exist
     */
    async getUser(username) {
        return this.api(`/users/${username}`);
    }
    // ---------------------------------------------------------------------------
    // Webhook operations (TRD-037, TRD-038)
    // ---------------------------------------------------------------------------
    /**
     * Create a webhook for a repository.
     * Requires admin:repo_hook or repo scope.
     */
    async createWebhook(owner, repo, webhookUrl, secret) {
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
        return this.api(`/repos/${owner}/${repo}/hooks`, { method: "POST", body: JSON.stringify(body) });
    }
    /**
     * List webhooks for a repository.
     */
    async listWebhooks(owner, repo) {
        return this.api(`/repos/${owner}/${repo}/hooks`);
    }
    /**
     * Delete a webhook by ID.
     */
    async deleteWebhook(owner, repo, webhookId) {
        await this.api(`/repos/${owner}/${repo}/hooks/${webhookId}`, { method: "DELETE" });
    }
    // ---------------------------------------------------------------------------
    // Issue Linking (TRD-041)
    // ---------------------------------------------------------------------------
    /**
     * Link an issue to a pull request via the Issue Links API.
     * Creates a "connects" relationship from the PR to the issue.
     * Requires a PR branch that references the issue.
     */
    async linkIssueToPullRequest(owner, repo, issueNumber, prNumber) {
        await this.api(`/repos/${owner}/${repo}/issues/${issueNumber}/links`, {
            method: "POST",
            body: JSON.stringify({
                issue: {
                    number: issueNumber,
                },
                pull_request: {
                    number: prNumber,
                },
            }),
        });
    }
    /**
     * Remove a link between an issue and a pull request.
     */
    async unlinkIssueFromPullRequest(owner, repo, issueNumber, relation) {
        await this.api(`/repos/${owner}/${repo}/issues/${issueNumber}/links/${relation}`, { method: "DELETE" });
    }
}
//# sourceMappingURL=gh-cli.js.map