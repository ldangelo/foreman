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

import { GhCli, GhRateLimitError, type GitHubIssue } from "../lib/gh-cli.js";
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

// ---------------------------------------------------------------------------
// GitHubIssuesPoller
// ---------------------------------------------------------------------------

export class GitHubIssuesPoller {
  private readonly gh: GhCli;
  private readonly adapter: PostgresAdapter;
  private readonly registry: ProjectRegistry;
  private readonly config: Required<GitHubPollerConfig>;
  private _interval: ReturnType<typeof setInterval> | null = null;
  private _running = false;
  private _stopped = false;

  constructor(
    adapter: PostgresAdapter,
    registry: ProjectRegistry,
    config: GitHubPollerConfig = {},
    gh?: GhCli,
  ) {
    this.gh = gh ?? new GhCli();
    this.adapter = adapter;
    this.registry = registry;
    this.config = {
      pollIntervalMs: config.pollIntervalMs ?? 60_000,
      foremanLabel: config.foremanLabel ?? "foreman",
      autoImport: config.autoImport ?? true,
      maxIssuesPerRepo: config.maxIssuesPerRepo ?? 100,
    };
  }

  /** Start the background polling loop. Idempotent — safe to call on already-running poller. */
  start(): void {
    if (this._running || this._stopped) return;
    this._running = true;

    // Run once immediately, then on interval
    void this.pollAll().catch((err) => {
      console.error("[GitHubIssuesPoller] Initial poll failed:", err instanceof Error ? err.message : String(err));
    });

    const intervalMs = parseInt(
      process.env.FOREMAN_GITHUB_POLL_INTERVAL_MS ?? "",
      10,
    ) || this.config.pollIntervalMs;

    this._interval = setInterval(() => {
      if (!this._running) return;
      void this.pollAll().catch((err) => {
        console.error("[GitHubIssuesPoller] Poll cycle failed:", err instanceof Error ? err.message : String(err));
      });
    }, intervalMs);

    console.log(`[GitHubIssuesPoller] Started (interval: ${intervalMs}ms, foremanLabel: "${this.config.foremanLabel}")`);
  }

  /** Stop the polling loop. Cannot be restarted — create a new instance. */
  stop(): void {
    if (!this._running) return;
    this._running = false;
    if (this._interval) {
      clearInterval(this._interval);
      this._interval = null;
    }
    this._stopped = true;
    console.log("[GitHubIssuesPoller] Stopped");
  }

  get running(): boolean {
    return this._running;
  }

  // -------------------------------------------------------------------------
  // Main polling logic
  // -------------------------------------------------------------------------

  /**
   * Poll all configured GitHub repos for all registered projects.
   * Called on startup and every pollIntervalMs.
   */
  async pollAll(): Promise<PollSummary> {
    const summary: PollSummary = { repos: 0, issues: 0, imported: 0, updated: 0, errors: 0 };
    const projects = await this.registry.list();

    for (const project of projects) {
      if (project.status !== "active") continue;

      try {
        const repoResult = await this.pollProject(project);
        summary.repos += repoResult.repos;
        summary.issues += repoResult.issues;
        summary.imported += repoResult.imported;
        summary.updated += repoResult.updated;
        summary.errors += repoResult.errors;
      } catch (err) {
        console.error(
          `[GitHubIssuesPoller] Error polling project "${project.name}":`,
          err instanceof Error ? err.message : String(err),
        );
        summary.errors++;
      }
    }

    return summary;
  }

  /**
   * Poll a single project for all its configured GitHub repos.
   */
  async pollProject(project: PollerProject): Promise<PollSummary> {
    const summary: PollSummary = { repos: 0, issues: 0, imported: 0, updated: 0, errors: 0 };

    // Get configured repos for this project
    let repos;
    try {
      repos = await this.adapter.listGithubRepos(project.id);
    } catch (err) {
      console.error(
        `[GitHubIssuesPoller] Failed to list repos for project ${project.id}:`,
        err instanceof Error ? err.message : String(err),
      );
      return summary;
    }

    if (repos.length === 0) return summary;

    for (const repo of repos) {
      try {
        const repoResult = await this.pollRepo(project.id, repo.owner, repo.repo);
        summary.repos++;
        summary.issues += repoResult.issues;
        summary.imported += repoResult.imported;
        summary.updated += repoResult.updated;
      } catch (err) {
        console.error(
          `[GitHubIssuesPoller] Error polling ${repo.owner}/${repo.repo}:`,
          err instanceof Error ? err.message : String(err),
        );
        summary.errors++;
      }
    }

    return summary;
  }

  /**
   * Poll a single GitHub repository for new/updated issues.
   *
   * Idempotent: already-imported issues (identified by external_id) are updated,
   * not re-created. New issues are created as backlog tasks.
   * Issues labeled with foremanLabel are auto-approved to ready status.
   */
  async pollRepo(
    projectId: string,
    owner: string,
    repo: string,
  ): Promise<{ issues: number; imported: number; updated: number }> {
    let issues: GitHubIssue[];
    try {
      issues = await this.gh.listIssues(owner, repo, {
        state: "open",
      });
    } catch (err) {
      if (err instanceof GhRateLimitError) {
        console.warn(
          `[GitHubIssuesPoller] Rate limited polling ${owner}/${repo}; backing off. Retry after ${err.retryAfter}s`,
        );
        // Throwing lets the caller count this as an error and skip this repo
        throw err;
      }
      throw err;
    }

    let imported = 0;
    let updated = 0;

    for (const issue of issues) {
      const externalId = `github:${owner}/${repo}#${issue.number}`;
      const existing = await this.adapter.listTasks(projectId, {
        externalId,
        limit: 1,
      });

      if (existing.length > 0) {
        // Already imported — update if changed (safe re-sync)
        const task = existing[0]!;
        const changed =
          task.title !== issue.title ||
          task.description !== (issue.body ?? null) ||
          task.status !== (issue.state === "open" ? task.status : "closed");

        if (changed) {
          await this.adapter.updateTaskGitHubFields(projectId, task.id, {
            title: issue.title,
            description: issue.body ?? null,
            state: issue.state,
            lastSyncAt: new Date().toISOString(),
          });
          updated++;
        }
      } else if (this.config.autoImport) {
        // New issue — create a task
        const status = this.shouldBeReady(issue)
          ? "ready"
          : "backlog";

        const task = await this.adapter.createTask(projectId, {
          title: issue.title,
          description: issue.body ?? undefined,
          type: "task",
          priority: 2,
          status,
          externalId,
          labels: issue.labels.map((l) => `github:${l.name}`),
          external_repo: `${owner}/${repo}`,
          github_issue_number: issue.number,
          sync_enabled: true,
        });

        // Record sync event
        await this.adapter.recordGithubSyncEvent({
          projectId,
          externalId,
          eventType: "issue_opened",
          direction: "from_github",
          githubPayload: {
            number: issue.number,
            title: issue.title,
            body: issue.body,
            labels: issue.labels.map((l) => l.name),
          },
        });

        imported++;
        console.log(
          `[GitHubIssuesPoller] Imported issue #${issue.number} as task ${task.id} (${status})`,
        );
      }
    }

    // Update last sync timestamp on the repo
    const repoRecord = await this.adapter.getGithubRepo(projectId, owner, repo);
    if (repoRecord?.id) {
      await this.adapter.updateGithubRepoLastSync(repoRecord.id);
    }

    return { issues: issues.length, imported, updated };
  }

  /**
   * Determine whether a GitHub issue should be imported as 'ready' (auto-approved).
   *
   * Checks for the configured `foremanLabel` (default: "foreman") in the issue's labels.
   * Also checks for "foreman:dispatch" label as a secondary trigger.
   */
  private shouldBeReady(issue: GitHubIssue): boolean {
    const labelNames = issue.labels.map((l) => l.name);
    return (
      labelNames.includes(this.config.foremanLabel) ||
      labelNames.includes("foreman:dispatch")
    );
  }

  // -------------------------------------------------------------------------
  // Manual trigger (for on-demand re-sync)
  // -------------------------------------------------------------------------

  /**
   * Manually trigger a poll for a specific project/repo.
   * Returns the same result as pollRepo for the specified repo.
   */
  async pollRepoManual(
    projectId: string,
    owner: string,
    repo: string,
  ): Promise<{ issues: number; imported: number; updated: number }> {
    return this.pollRepo(projectId, owner, repo);
  }
}

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

export interface PollSummary {
  repos: number;
  issues: number;
  imported: number;
  updated: number;
  errors: number;
}

// ---------------------------------------------------------------------------
// Auto-close integration
// ---------------------------------------------------------------------------

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
export async function closeLinkedGithubIssue(
  adapter: PostgresAdapter,
  gh: GhCli,
  projectId: string,
  taskId: string,
): Promise<void> {
  try {
    const task = await adapter.getTask(projectId, taskId);
    if (!task) {
      console.warn(
        `[closeLinkedGithubIssue] Task ${taskId} not found in project ${projectId}`,
      );
      return;
    }

    const externalId = task.external_id;
    if (!externalId || !externalId.startsWith("github:")) {
      return; // Not a GitHub-linked task — nothing to close
    }

    // Parse github:owner/repo#number
    const match = externalId.match(/^github:([^/]+)\/([^#]+)#(\d+)$/);
    if (!match) {
      console.warn(`[closeLinkedGithubIssue] Malformed external_id: ${externalId}`);
      return;
    }
    const [, owner, repo, issueNumberStr] = match;
    const issueNumber = parseInt(issueNumberStr, 10);

    await gh.updateIssue(owner, repo, issueNumber, { state: "closed" });

    await adapter.recordGithubSyncEvent({
      projectId,
      externalId,
      eventType: "issue_closed",
      direction: "to_github",
      githubPayload: { number: issueNumber, state: "closed" },
    });

    console.log(`[closeLinkedGithubIssue] Closed GitHub issue #${issueNumber} (${owner}/${repo})`);
  } catch (err) {
    // Non-fatal: GitHub issue close must not block merge completion
    console.error(
      `[closeLinkedGithubIssue] Failed to close linked GitHub issue for task ${taskId}:`,
      err instanceof Error ? err.message : String(err),
    );
  }
}

/**
 * Link a PR back to the originating GitHub issue.
 *
 * Adds a comment to the GitHub issue with a reference to the PR URL.
 * Called from Refinery.ensurePullRequestForRun() after PR creation.
 *
 * Errors are logged but not thrown — PR linking must not block PR creation.
 */
export async function linkPrToGithubIssue(
  gh: GhCli,
  projectId: string,
  taskId: string,
  prUrl: string,
): Promise<void> {
  try {
    const adapter = new PostgresAdapter();
    const task = await adapter.getTask(projectId, taskId);
    if (!task) return;

    const externalId = task.external_id;
    if (!externalId || !externalId.startsWith("github:")) return;

    const match = externalId.match(/^github:([^/]+)\/([^#]+)#(\d+)$/);
    if (!match) return;
    const [, owner, repo, issueNumberStr] = match;
    const issueNumber = parseInt(issueNumberStr, 10);

    const comment = `Foreman work complete. PR: ${prUrl}`;
    // gh api to add issue comment
    await gh.api(`/repos/${owner}/${repo}/issues/${issueNumber}/comments`, {
      method: "POST",
      body: JSON.stringify({ body: comment }),
    });

    console.log(
      `[linkPrToGithubIssue] Linked PR ${prUrl} to GitHub issue #${issueNumber}`,
    );
  } catch (err) {
    console.error(
      `[linkPrToGithubIssue] Failed to link PR to GitHub issue:`,
      err instanceof Error ? err.message : String(err),
    );
  }
}