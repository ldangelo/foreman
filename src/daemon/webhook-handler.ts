/**
 * GitHub webhook handler for ForemanDaemon.
 *
 * Handles:
 * - push events: record bead:synced events and rebase active worktrees (TRD-063)
 * - pull_request events: record bead:synced when PR is closed+merged
 *
 * HMAC-SHA256 verification uses the webhook secret from FOREMAN_WEBHOOK_SECRET.
 *
 * @module src/daemon/webhook-handler
 */

import { createHmac, timingSafeEqual, randomBytes } from "node:crypto";
import type { FastifyRequest, FastifyReply } from "fastify";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import { ProjectRegistry } from "../lib/project-registry.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
import { WorktreeManager } from "../lib/worktree-manager.js";

export interface WebhookContext {
  adapter: PostgresAdapter;
  registry: ProjectRegistry;
}

export interface GitHubPushPayload {
  ref: string;
  forced: boolean;
  repository: {
    clone_url: string;
    full_name: string;
  };
  pusher: {
    name: string;
  };
}

export interface GitHubPrPayload {
  action: string;
  pull_request: {
    merged: boolean;
    number: number;
    title: string;
    base: { ref: string; sha: string };
    head: { ref: string; sha: string };
  };
  repository: {
    full_name: string;
  };
}

// ── HMAC Verification ─────────────────────────────────────────────────────────

/**
 * Verify GitHub webhook signature using HMAC-SHA256.
 * GitHub sends: X-Hub-Signature-256: sha256=<hex>
 * Uses timing-safe comparison to prevent timing attacks.
 */
export function verifyGitHubSignature(
  rawBody: Buffer,
  signature: string | undefined,
  secret: string,
): boolean {
  if (!signature || !secret) return false;

  const expected = `sha256=${createHmac("sha256", secret)
    .update(rawBody)
    .digest("hex")}`;

  try {
    return timingSafeEqual(
      Buffer.from(expected, "utf8"),
      Buffer.from(signature, "utf8"),
    );
  } catch {
    return false;
  }
}

// ── Event Parsing ───────────────────────────────────────────────────────────

/** Extract branch name from a git ref string (e.g. "refs/heads/main" → "main"). */
export function extractBranchFromRef(ref: string): string {
  return ref.replace(/^refs\/heads\//, "");
}

/**
 * Generate a cryptographically random webhook secret.
 * Used when enabling webhooks for a repository.
 */
export function generateWebhookSecret(): string {
  return randomBytes(32).toString("hex");
}

// ── Webhook Request Handler ─────────────────────────────────────────────────────

export type WebhookHandler = (
  request: FastifyRequest<{ Body: unknown }>,
  reply: FastifyReply,
) => Promise<void>;

export interface WebhookConfig {
  /** HMAC secret for verifying GitHub webhook payloads. */
  secret: string;
  /** Label that should import issues directly to ready. */
  foremanLabel?: string;
}

/**
 * Create a webhook handler bound to the given context and config.
 */
export function createWebhookHandler(
  ctx: WebhookContext,
  config: WebhookConfig,
): WebhookHandler {
  return async (request, reply) => {
    const rawBody = request.body as unknown;

    // ── Verify signature ────────────────────────────────────────────────────
    const signature = request.headers["x-hub-signature-256"] as string | undefined;
    const bodyBuffer = Buffer.from(JSON.stringify(rawBody));
    if (!verifyGitHubSignature(bodyBuffer, signature, config.secret)) {
      request.log.warn("[webhook] Invalid signature — rejecting");
      return reply.code(401).send({ error: "Invalid signature" });
    }

    // ── Parse event ────────────────────────────────────────────────────────
    const event = request.headers["x-github-event"] as string | undefined;
    if (!event) {
      return reply.code(400).send({ error: "Missing X-GitHub-Event header" });
    }

    request.log.info({ event }, "[webhook] Received GitHub event");

    switch (event) {
      case "push":
        return handlePush(ctx, request, reply, rawBody as GitHubPushPayload);

      case "pull_request":
        return handlePullRequest(ctx, request, reply, rawBody as GitHubPrPayload);

      case "issues":
        return handleIssue(ctx, config, request, reply, rawBody as GitHubIssueWebhookPayload);

      default:
        // GitHub sends many event types — acknowledge but ignore unknowns
        return reply.code(200).send({ received: true, ignored: true });
    }
  };
}

function shouldSkipIssueImport(issue: GitHubIssueWebhookPayload["issue"], config: WebhookConfig): boolean {
  return issue.labels.some((label) => label.name === "foreman:skip");
}

function shouldReadyIssueImport(issue: GitHubIssueWebhookPayload["issue"], config: WebhookConfig): boolean {
  const foremanLabel = config.foremanLabel ?? "foreman";
  return issue.labels.some(
    (label) => label.name === foremanLabel || label.name === "foreman:dispatch",
  );
}

// ── Push Event Handler ─────────────────────────────────────────────────────────

/**
 * Handle GitHub push events: record bead:synced events for active runs on the pushed branch.
 *
 * For each project whose clone URL matches the repository, find active runs
 * with a worktree on the pushed branch, record a bead:synced event, and
 * rebase the worktree onto the updated base branch (TRD-063).
 */
async function handlePush(
  ctx: WebhookContext,
  request: FastifyRequest,
  reply: FastifyReply,
  payload: GitHubPushPayload,
): Promise<void> {
  const branch = extractBranchFromRef(payload.ref);
  const repoName = payload.repository.full_name;
  const forced = payload.forced;

  if (forced) {
    request.log.warn({ branch, repo: repoName }, "[webhook:push] Forced push detected");
  }

  // Find projects with matching clone URL
  const projects = await ctx.registry.list();
  const matching = projects.filter((p) =>
    p.githubUrl?.includes(repoName),
  );

  let eventsRecorded = 0;
  let rebasesAttempted = 0;
  let rebasesSucceeded = 0;

  for (const project of matching) {
    try {
      // Create VcsBackend for the project repo (TRD-063)
      let vcsBackend: Awaited<ReturnType<typeof VcsBackendFactory.create>> | null = null;
      try {
        vcsBackend = await VcsBackendFactory.create({ backend: "auto" }, project.path);
      } catch {
        request.log.warn({ project: project.name }, "[webhook:push] Could not create VcsBackend — skipping rebase");
      }

      const worktreeManager = new WorktreeManager();

      // Find runs that are pending/running on this branch
      const runs = await ctx.adapter.listPipelineRuns(project.id, {
        beadId: undefined,
        status: undefined, // get all, filter below
      });

      for (const run of runs) {
        if (run.branch === branch && (run.status === "pending" || run.status === "running")) {
          // Record bead:synced event
          await ctx.adapter.recordPipelineEvent({
            projectId: project.id,
            runId: run.id,
            eventType: "bead:synced",
            payload: {
              reason: forced ? "forced-push" : "push",
              branch,
              pusher: payload.pusher.name,
              repository: repoName,
            },
          });
          eventsRecorded++;

          // TRD-063: Auto-rebase the worktree onto the updated base branch
          if (vcsBackend) {
            let rebaseSuccess = false;
            let worktreePath: string | null = null;
            try {
              worktreePath = worktreeManager.getWorktreePath(project.id, run.bead_id);
              const rebaseResult = await vcsBackend.rebase(worktreePath, branch);
              rebasesAttempted++;

              if (rebaseResult.success) {
                rebasesSucceeded++;
                rebaseSuccess = true;
                request.log.info(
                  { runId: run.id, worktreePath, branch },
                  "[webhook:push] Worktree rebased successfully",
                );
              } else if (rebaseResult.hasConflicts) {
                request.log.warn(
                  { runId: run.id, worktreePath, branch, conflictingFiles: rebaseResult.conflictingFiles },
                  "[webhook:push] Rebase conflict — marking run as conflicted",
                );
                // Record conflict event so dispatcher can handle it
                await ctx.adapter.recordPipelineEvent({
                  projectId: project.id,
                  runId: run.id,
                  eventType: "bead:rebase-conflict",
                  payload: {
                    worktreePath,
                    branch,
                    conflictingFiles: rebaseResult.conflictingFiles ?? [],
                  },
                });
              }
            } catch (err) {
              const msg = err instanceof Error ? err.message : String(err);
              request.log.error(
                { runId: run.id, worktreePath: worktreePath ?? "unknown", branch, err: msg },
                "[webhook:push] Rebase failed",
              );
            }
          }
        }
      }
    } catch (err) {
      request.log.error({ project: project.name, err }, "[webhook:push] Error processing push");
    }
  }

  request.log.info(
    { branch, repo: repoName, forced, eventsRecorded, rebasesAttempted, rebasesSucceeded },
    "[webhook:push] Push event processed",
  );

  return reply.code(200).send({
    received: true,
    event: "push",
    branch,
    forced,
    eventsRecorded,
    rebasesAttempted,
    rebasesSucceeded,
  });
}

// ── Pull Request Event Handler ────────────────────────────────────────────────

/**
 * Handle GitHub pull_request events: record bead:synced when PR is closed and merged.
 *
 * Records a bead:synced event with PR metadata so the sentinel can transition
 * associated runs to completed/merged on next poll cycle.
 */
async function handlePullRequest(
  ctx: WebhookContext,
  request: FastifyRequest,
  reply: FastifyReply,
  payload: GitHubPrPayload,
): Promise<void> {
  if (payload.action !== "closed" || !payload.pull_request.merged) {
    return reply.code(200).send({ received: true, ignored: true });
  }

  const prBranch = payload.pull_request.head.ref;
  const baseBranch = payload.pull_request.base.ref;
  const projectFullName = payload.repository.full_name;
  const prNumber = payload.pull_request.number;
  const prTitle = payload.pull_request.title;
  const headSha = payload.pull_request.head.sha;

  // Find projects with matching GitHub URL
  const projects = await ctx.registry.list();
  const matching = projects.filter((p) =>
    p.githubUrl?.includes(projectFullName),
  );

  let eventsRecorded = 0;
  for (const project of matching) {
    try {
      // Find runs for this branch that are success/running
      const runs = await ctx.adapter.listPipelineRuns(project.id, {
        beadId: undefined,
        status: undefined,
      });

      for (const run of runs) {
        if (
          (run.branch === prBranch || run.branch === baseBranch || run.commit_sha === headSha) &&
          (run.status === "success" || run.status === "running")
        ) {
          await ctx.adapter.recordPipelineEvent({
            projectId: project.id,
            runId: run.id,
            eventType: "bead:synced",
            payload: {
              reason: "pr-merged",
              pr: prNumber,
              title: prTitle,
              merged_by_sha: headSha,
              branch: prBranch,
            },
          });
          eventsRecorded++;
        }
      }
    } catch (err) {
      request.log.error({ project: project.name, err }, "[webhook:pr] Error recording event");
    }
  }

  request.log.info(
    { pr: prNumber, title: prTitle, eventsRecorded },
    "[webhook:pr] PR merged — events recorded",
  );

  return reply.code(200).send({
    received: true,
    event: "pull_request",
    merged: true,
    pr: prNumber,
    eventsRecorded,
  });
}

// ---------------------------------------------------------------------------
// Issue Event Handler (TRD-030, TRD-032, TRD-033, TRD-034, TRD-035)
// ---------------------------------------------------------------------------

export interface GitHubIssueWebhookPayload {
  action: string;
  issue: {
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
  };
  repository: {
    id: number;
    full_name: string;
    clone_url: string;
  };
  label?: { name: string; color: string };
  assignee?: { login: string; id: number };
}

/**
 * Handle GitHub issues events: opened, closed, reopened, labeled, unlabeled, assigned, unassigned.
 */
async function handleIssue(
  ctx: WebhookContext,
  config: WebhookConfig,
  request: FastifyRequest,
  reply: FastifyReply,
  payload: GitHubIssueWebhookPayload,
): Promise<void> {
  const { action, issue, repository, label, assignee } = payload;
  const repoFullName = repository.full_name;
  const [owner, repo] = repoFullName.split("/");
  const externalId = `github:${owner}/${repo}#${issue.number}`;
  const externalRepo = `${owner}/${repo}`;

  request.log.info(
    { action, issueNumber: issue.number, repo: repoFullName },
    "[webhook:issue] Processing issue event",
  );

  const projects = await ctx.registry.list();
  const matching = projects.filter((p) =>
    p.githubUrl?.includes(repoFullName),
  );

  for (const project of matching) {
    let repoConfig = await ctx.adapter.getGithubRepo(project.id, owner, repo);
    if (!repoConfig) {
      repoConfig = await ctx.adapter.upsertGithubRepo({
        projectId: project.id,
        owner,
        repo,
        webhookSecret: null,
        webhookEnabled: true,
      });
    }

    switch (action) {
      case "opened": {
        const existing = await ctx.adapter.listTasks(project.id, {
          externalId,
          limit: 1,
        });
        if (existing.length === 0) {
          if (!repoConfig.auto_import) {
            request.log.info(
              { issueNumber: issue.number, repo: repoFullName },
              "[webhook:issue] Auto-import disabled; skipping task creation",
            );
            break;
          }

          if (shouldSkipIssueImport(issue, config)) {
            request.log.info(
              { issueNumber: issue.number, repo: repoFullName },
              "[webhook:issue] foreman:skip present; skipping task creation",
            );
            break;
          }

          const foremanLabels = issue.labels.map((l) => `github:${l.name}`);
          for (const dl of repoConfig.default_labels) {
            if (!foremanLabels.includes(dl)) {
              foremanLabels.push(dl);
            }
          }
          const shouldAutoDispatch = shouldReadyIssueImport(issue, config);

          const task = await ctx.adapter.createTask(project.id, {
            title: issue.title,
            description: issue.body ?? undefined,
            type: "task",
            priority: mapPriorityLabel(issue.labels),
            status: shouldAutoDispatch ? "ready" : "backlog",
            externalId,
            labels: foremanLabels,
            milestone: issue.milestone?.title,
            external_repo: externalRepo,
            github_issue_number: issue.number,
            sync_enabled: true,
          });

          await ctx.adapter.recordGithubSyncEvent({
            projectId: project.id,
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

          request.log.info(
            { taskId: task.id, issueNumber: issue.number, repo: repoFullName, shouldAutoDispatch },
            "[webhook:issue] Task created from GitHub issue",
          );
        }
        break;
      }

      case "closed": {
        const existing = await ctx.adapter.listTasks(project.id, {
          externalId,
          limit: 1,
        });
        if (existing.length > 0) {
          await ctx.adapter.updateTaskGitHubFields(project.id, existing[0]!.id, {
            state: "closed",
            lastSyncAt: new Date().toISOString(),
          });
          await ctx.adapter.recordGithubSyncEvent({
            projectId: project.id,
            externalId,
            eventType: "issue_closed",
            direction: "from_github",
            githubPayload: { number: issue.number, state: "closed" },
          });
        }
        break;
      }

      case "reopened": {
        const existing = await ctx.adapter.listTasks(project.id, {
          externalId,
          limit: 1,
        });
        if (existing.length > 0) {
          await ctx.adapter.updateTaskGitHubFields(project.id, existing[0]!.id, {
            state: "open",
            lastSyncAt: new Date().toISOString(),
          });
          await ctx.adapter.recordGithubSyncEvent({
            projectId: project.id,
            externalId,
            eventType: "issue_reopened",
            direction: "from_github",
            githubPayload: { number: issue.number, state: "open" },
          });
        }
        break;
      }

      case "labeled": {
        if (!label) break;
        const existing = await ctx.adapter.listTasks(project.id, {
          externalId,
          limit: 1,
        });
        if (existing.length > 0) {
          const task = existing[0]!;
          const currentLabels = task.labels ?? [];
          const newLabel = `github:${label.name}`;
          if (!currentLabels.includes(newLabel)) {
            await ctx.adapter.updateTaskGitHubFields(project.id, task.id, {
              labels: [...currentLabels, newLabel],
              lastSyncAt: new Date().toISOString(),
            });
          }
          await ctx.adapter.recordGithubSyncEvent({
            projectId: project.id,
            externalId,
            eventType: "issue_labeled",
            direction: "from_github",
            githubPayload: { number: issue.number, label: label.name },
          });
        }
        break;
      }

      case "unlabeled": {
        if (!label) break;
        const existing = await ctx.adapter.listTasks(project.id, {
          externalId,
          limit: 1,
        });
        if (existing.length > 0) {
          const task = existing[0]!;
          const currentLabels = task.labels ?? [];
          const removedLabel = `github:${label.name}`;
          await ctx.adapter.updateTaskGitHubFields(project.id, task.id, {
            labels: currentLabels.filter((l: string) => l !== removedLabel),
            lastSyncAt: new Date().toISOString(),
          });
          await ctx.adapter.recordGithubSyncEvent({
            projectId: project.id,
            externalId,
            eventType: "issue_unlabeled",
            direction: "from_github",
            githubPayload: { number: issue.number, label: label.name },
          });
        }
        break;
      }

      case "assigned": {
        request.log.info(
          { issueNumber: issue.number, assignee: assignee?.login },
          "[webhook:issue] Assigned event received",
        );
        break;
      }

      case "unassigned": {
        request.log.info(
          { issueNumber: issue.number, assignee: assignee?.login },
          "[webhook:issue] Unassigned event received",
        );
        break;
      }

      default:
        request.log.info({ action }, "[webhook:issue] Ignored action");
    }
  }

  return reply.code(200).send({
    received: true,
    event: "issues",
    action,
    issueNumber: issue.number,
    repo: repoFullName,
  });
}

function mapPriorityLabel(labels: Array<{ name: string }>): number {
  const priorityLabel = labels.find((l) => l.name.startsWith("foreman:priority:"));
  if (priorityLabel) {
    const priority = parseInt(priorityLabel.name.split(":")[2]!, 10);
    if (priority >= 0 && priority <= 4) return priority;
  }
  return 2;
}
