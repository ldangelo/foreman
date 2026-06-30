/**
 * GitHub Issues Poller — background daemon that syncs GitHub issues with Foreman tasks.
 *
 * Polling behavior:
 * - Idempotent: re-polling the same issue does not create duplicates
 * - Duplicate prevention: uses external_id = "github:owner/repo#N" to detect already-imported issues
 * - Safe re-sync: existing linked issues are updated (not recreated) on subsequent polls
 * - Respects FOREMAN_GITHUB_POLL_INTERVAL_MS env var (default: 60s)
 *
 * Import rules:
 * - New issues → backlog by default
 * - Issues labeled "foreman" (configurable via foremanLabel config) → ready
 * - Issues can be bulk-imported via `foreman issue import --label`
 *
 * Auto-close:
 * - When a Foreman task is merged, the linked GitHub issue is automatically closed
 * - See closeLinkedGithubIssue() and the integration in Refinery / auto-merge flow
 *
 * Rate limiting:
 * - Detects GhRateLimitError and backs off exponentially
 * - Logs warnings so operators can see rate limit status
 *
 * @module daemon/github-poller
 */
import { GhCli, type GitHubIssue } from "../lib/gh-cli.js";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import { ProjectRegistry } from "../lib/project-registry.js";
export interface GitHubPollerConfig {
    /** Interval between poll cycles in milliseconds. Default: 60_000 (60s). */
    pollIntervalMs?: number;
    /** GitHub label that triggers auto-ready import. Default: "foreman". */
    foremanLabel?: string;
    /** Whether to auto-import new issues on first poll. Default: true. */
    autoImport?: boolean;
    /** Max issues to fetch per repo per poll. Default: 100. */
    maxIssuesPerRepo?: number;
}
interface PollerProject {
    id: string;
    name: string;
    path: string;
    githubUrl: string | null;
    repoKey?: string | null;
    status?: string;
}
export declare function normalizeGithubIssueLabels(issue: GitHubIssue): string[];
export declare function inferTaskTypeFromGitHubLabels(issue: GitHubIssue): string;
export declare class GitHubIssuesPoller {
    private readonly gh;
    private readonly adapter;
    private readonly registry;
    private readonly config;
    private _interval;
    private _running;
    private _stopped;
    constructor(adapter: PostgresAdapter, registry: ProjectRegistry, config?: GitHubPollerConfig, gh?: GhCli);
    /** Start the background polling loop. Idempotent — safe to call on already-running poller. */
    start(): void;
    /** Stop the polling loop. Cannot be restarted — create a new instance. */
    stop(): void;
    get running(): boolean;
    /**
     * Poll all configured GitHub repos for all registered projects.
     * Called on startup and every pollIntervalMs.
     */
    pollAll(): Promise<PollSummary>;
    /**
     * Poll a single project for all its configured GitHub repos.
     */
    pollProject(project: PollerProject): Promise<PollSummary>;
    /**
     * Poll a single GitHub repository for new/updated issues.
     *
     * Idempotent: already-imported issues (identified by external_id) are updated,
     * not re-created. New issues are created as backlog tasks.
     * Issues labeled with foremanLabel are auto-approved to ready status.
     */
    pollRepo(projectId: string, owner: string, repo: string): Promise<{
        issues: number;
        imported: number;
        updated: number;
    }>;
    /**
     * Determine whether a GitHub issue should be imported as 'ready' (auto-approved).
     *
     * Checks for the configured `foremanLabel` (default: "foreman") in the issue's labels.
     * Also checks for "foreman:dispatch" label as a secondary trigger.
     */
    private shouldBeReady;
    /**
     * Manually trigger a poll for a specific project/repo.
     * Returns the same result as pollRepo for the specified repo.
     */
    pollRepoManual(projectId: string, owner: string, repo: string): Promise<{
        issues: number;
        imported: number;
        updated: number;
    }>;
}
export interface PollSummary {
    repos: number;
    issues: number;
    imported: number;
    updated: number;
    errors: number;
}
/**
 * Close a GitHub issue when its linked Foreman task is successfully merged.
 *
 * Called from:
 * - Refinery.closeNativeTaskPostMerge() — after native task merge
 * - syncBeadStatusAfterMerge() in auto-merge.ts — after beads task merge
 *
 * Idempotent: closing an already-closed issue is a no-op in GitHub's API.
 * Errors are logged but not thrown — closing the linked issue must not block
 * the merge completion flow.
 */
export declare function closeLinkedGithubIssue(adapter: PostgresAdapter, gh: GhCli, projectId: string, taskId: string): Promise<void>;
/**
 * Link a PR back to the originating GitHub issue.
 *
 * Adds a comment to the GitHub issue with a reference to the PR URL.
 * Called from Refinery.ensurePullRequestForRun() after PR creation.
 *
 * Errors are logged but not thrown — PR linking must not block PR creation.
 */
export declare function linkPrToGithubIssue(gh: GhCli, projectId: string, taskId: string, prUrl: string): Promise<void>;
export {};
//# sourceMappingURL=github-poller.d.ts.map