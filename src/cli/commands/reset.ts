import { Command } from "commander";
import chalk from "chalk";

import { createTaskClient } from "../../lib/task-client-factory.js";
import { requireProjectOrAllInMultiMode } from "./project-task-support.js";
import { resolveProjectContext } from "./project-context.js";
import { wrapLocalRunStore } from "./local-store-adapter.js";
import { printDryRunNotice } from "./cli-output.js";
import { ForemanStore } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import type { Run } from "../../lib/store.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { existsSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { archiveWorktreeReports } from "../../lib/archive-reports.js";
import type { ITaskClient } from "../../lib/task-client.js";
import { PIPELINE_LIMITS } from "../../lib/config.js";
import { getSeedRetryTargetStatus, mapRunStatusToSeedStatus } from "../../lib/run-status.js";
import { deleteWorkerConfigFile } from "../../orchestrator/dispatcher.js";
import { MergeQueue } from "../../orchestrator/merge-queue.js";
import { PostgresMergeQueue } from "../../orchestrator/postgres-merge-queue.js";
import type { StateMismatch } from "../../lib/run-status.js";
import { getWorkspaceRoot } from "../../lib/workspace-paths.js";
import { loadProjectConfig, resolveDefaultBranch } from "../../lib/project-config.js";
import { GhCli } from "../../lib/gh-cli.js";
import { ElixirServerClient } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
// Re-export for callers that import these from this module (backward compatibility).
export { mapRunStatusToSeedStatus } from "../../lib/run-status.js";
export type { StateMismatch } from "../../lib/run-status.js";

/**
 * Minimal interface capturing the subset of task-client methods used by
 * detectAndFixMismatches.
 */
export type IShowUpdateClient = Pick<ITaskClient, "show" | "update"> & {
  resetToReady?: ITaskClient["resetToReady"];
};

interface ResetRunStore {
  getRunsByStatus(status: Run["status"], projectId: string): Promise<Run[]>;
  getActiveRuns(projectId: string): Promise<Run[]>;
  getRunsForSeed(seedId: string, projectId: string): Promise<Run[]>;
  updateRun(runId: string, updates: Partial<Pick<Run, "status" | "completed_at">>): Promise<void>;
  logEvent(projectId: string, eventType: "stuck", data: Record<string, unknown>, runId?: string): Promise<void>;
}

interface ResetMergeQueue {
  list(): Promise<Array<{ id: number; seed_id: string; status: string }>>;
  remove(id: number): Promise<void>;
  missingFromQueue(): Promise<Array<{ run_id: string; seed_id: string }>>;
}

function wrapLocalMergeQueue(queue: MergeQueue): ResetMergeQueue {
  return {
    list: async () => queue.list(),
    remove: async (id) => queue.remove(id),
    missingFromQueue: async () => queue.missingFromQueue(),
  };
}

// ── Orphan-worktree sweep ─────────────────────────────────────────────────────

/** Minimal VCS surface used by the orphan-worktree sweep. */
export interface OrphanSweepVcs {
  removeWorkspace(repoPath: string, workspacePath: string): Promise<void>;
  deleteBranch(
    repoPath: string,
    branchName: string,
    options?: { force?: boolean },
  ): Promise<{ deleted: boolean }>;
}

export interface OrphanSweepResult {
  worktreesRemoved: number;
  branchesDeleted: number;
}

/**
 * Remove orphaned worktree directories under the project's workspace root.
 *
 * A directory is an orphan when it does NOT belong to a truly active run
 * (status `pending` or `running`). "failed" and "stuck" are terminal states —
 * their agents have stopped, so their worktrees are safe to remove.
 *
 * IMPORTANT: the active keep-set is read from the SAME store the rest of the
 * reset flow uses (the async {@link ResetRunStore} — Postgres-backed for
 * registered projects). Reading the local synchronous store here would make
 * live Postgres-backed active runs invisible to the keep-set and cause their
 * worktrees to be destroyed as "orphans".
 */
export async function cleanOrphanWorktrees(
  store: Pick<ResetRunStore, "getRunsByStatus">,
  vcs: OrphanSweepVcs,
  projectPath: string,
  worktreesDir: string,
  projectId: string,
  opts?: {
    readdir?: (dir: string) => string[];
    logger?: (msg: string) => void;
  },
): Promise<OrphanSweepResult> {
  const log = opts?.logger ?? ((msg: string) => console.log(msg));
  const readdir =
    opts?.readdir ??
    ((dir: string) => {
      try {
        return readdirSync(dir);
      } catch {
        // Directory may have been removed already
        return [];
      }
    });

  let worktreesRemoved = 0;
  let branchesDeleted = 0;

  // Paths that still have truly active runs (pending or running) — keep these.
  // "failed" and "stuck" are terminal states: their agents have stopped, so
  // their worktrees are safe to remove during cleanup.
  const activeStatuses = ["pending", "running"] as const;
  const activeRunGroups = await Promise.all(
    activeStatuses.map((s) => store.getRunsByStatus(s, projectId)),
  );
  const activeRuns = activeRunGroups.flat();
  const activeWorktreePaths = new Set(
    activeRuns.map((r) => (r.worktree_path ? resolve(r.worktree_path) : null)).filter(Boolean),
  );

  for (const entry of readdir(worktreesDir)) {
    const fullPath = resolve(worktreesDir, entry);
    // Skip if this worktree belongs to an active run (may still be in use)
    if (activeWorktreePaths.has(fullPath)) continue;

    log(`  ${chalk.yellow("orphan")} worktree ${fullPath}`);
    try {
      await vcs.removeWorkspace(projectPath, fullPath);
      worktreesRemoved++;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!msg.includes("is not a working tree") && !msg.includes("doesn't exist")) {
        log(`    ${chalk.red("error")} removing orphaned worktree: ${msg}`);
      }
    }
    // Delete the corresponding branch if it exists
    const orphanBranch = `foreman/${entry}`;
    try {
      const delResult = await vcs.deleteBranch(projectPath, orphanBranch, { force: true });
      if (delResult.deleted) {
        branchesDeleted++;
        log(`    ${chalk.yellow("delete")} orphan branch ${orphanBranch}`);
      }
    } catch {
      // Branch may not exist — skip silently
    }
  }

  return { worktreesRemoved, branchesDeleted };
}

// ── GitHub Issue Link unlinking (TRD-043) ─────────────────────────────────────

/**
 * Attempt to unlink a task's GitHub issue from any associated PR.
 * Called when a task is reset to "ready" — the previous PR branch is discarded.
 *
 * Silently ignores errors (non-fatal — the unlink is a best-effort cleanup).
 */
async function unlinkGitHubIssueIfNeeded(
  seedId: string,
  store: ForemanStore | PostgresStore,
): Promise<void> {
  try {
    // ForemanStore.getTaskById is sync; PostgresStore.getTaskById is async
    const task = await ("getTaskById" in store
      ? (store as ForemanStore).getTaskById(seedId)
      : null) as { external_id: string | null } | null;

    if (!task) return;
    const externalId = task.external_id ?? "";
    if (!externalId.startsWith("github:")) return;

    // Parse external_id: github:{owner}/{repo}#{issue_number}
    const match = externalId.match(/^github:([^/]+)\/([^#]+)#(\d+)$/);
    if (!match) return;
    const [, owner, repo, issueNum] = match;
    const issueNumber = parseInt(issueNum, 10);

    // We don't have the PR number stored — use "connected" as the relation key.
    // GitHub issue links use "connected" as the default relation name.
    const gh = new GhCli();
    await gh.unlinkIssueFromPullRequest(owner, repo, issueNumber, "connected");
  } catch {
    // Non-fatal: log and continue
  }
}

// ── Stale-branch detection types ─────────────────────────────────────────────

/**
 * Signature for an injected async execFile function.
 * Matches node:child_process.promisify(execFile) but can be swapped in tests.
 */
export type ExecFileAsyncFn = (
  cmd: string,
  args: string[],
  options?: { cwd?: string },
) => Promise<{ stdout: string; stderr: string }>;

export interface PullRequestCleanupResult {
  action: "closed" | "none" | "dry-run";
  prUrl?: string;
  reason?: string;
}

export async function closeForemanPullRequest(
  projectPath: string,
  branchName: string,
  opts?: {
    dryRun?: boolean;
    execFileAsync?: ExecFileAsyncFn;
  },
): Promise<PullRequestCleanupResult> {
  const execFn = opts?.execFileAsync ?? (await getDefaultExecFileAsync());

  let prStateRaw = "";
  try {
    const { stdout } = await execFn(
      "gh",
      ["pr", "view", branchName, "--json", "state,headRefName,url", "--jq", "."],
      { cwd: projectPath },
    );
    prStateRaw = stdout.trim();
  } catch {
    return { action: "none", reason: "no-associated-pr" };
  }

  let prState: { state?: string; headRefName?: string; url?: string } = {};
  try {
    prState = JSON.parse(prStateRaw) as { state?: string; headRefName?: string; url?: string };
  } catch {
    return { action: "none", reason: "unparseable-pr-state" };
  }

  if (prState.headRefName !== branchName) {
    return { action: "none", prUrl: prState.url, reason: "head-branch-mismatch" };
  }
  if (prState.state !== "OPEN") {
    return { action: "none", prUrl: prState.url, reason: "pr-not-open" };
  }
  if (opts?.dryRun) {
    return { action: "dry-run", prUrl: prState.url, reason: "would-close-open-pr" };
  }

  await execFn(
    "gh",
    [
      "pr",
      "close",
      branchName,
      "--comment",
      "Closed automatically by `foreman reset` before rerun.",
    ],
    { cwd: projectPath },
  );

  return { action: "closed", prUrl: prState.url };
}

/**
 * Result of stale-branch analysis for a single completed run.
 *
 * - "close"  — branch is merged into target; bead should be closed.
 * - "reset"  — branch not merged; bead should be reset to open for retry.
 * - "skip"   — skipped (active MQ entry, active run, or already in reset set).
 * - "error"  — an error occurred; see `error` field.
 */
export interface StaleBranchResult {
  seedId: string;
  runId: string;
  branchName: string;
  action: "close" | "reset" | "skip" | "error";
  reason: string;
  error?: string;
}

/** Aggregate output from `detectAndHandleStaleBranches()`. */
export interface StaleBranchDetectionOutput {
  results: StaleBranchResult[];
  closed: number;
  reset: number;
  errors: string[];
}

// ── Git helpers ───────────────────────────────────────────────────────────────

/**
 * Count commits in `branchName` that are NOT in `targetBranch`.
 * Returns 0 if the branch doesn't exist or on any error.
 */
export async function countCommitsAhead(
  projectPath: string,
  targetBranch: string,
  branchName: string,
  execFn?: ExecFileAsyncFn,
): Promise<number> {
  const fn = execFn ?? (await getDefaultExecFileAsync());
  try {
    const { stdout } = await fn(
      "git",
      ["rev-list", "--count", `${targetBranch}..${branchName}`],
      { cwd: projectPath },
    );
    return parseInt(stdout.trim(), 10) || 0;
  } catch {
    return 0;
  }
}

/**
 * Check whether `branchName` is an ancestor of `targetBranch`
 * (i.e., all of the branch's commits are reachable from the target).
 * Returns false on any error.
 */
export async function isBranchMergedIntoTarget(
  projectPath: string,
  targetBranch: string,
  branchName: string,
  execFn?: ExecFileAsyncFn,
): Promise<boolean> {
  const fn = execFn ?? (await getDefaultExecFileAsync());
  try {
    await fn(
      "git",
      ["merge-base", "--is-ancestor", branchName, targetBranch],
      { cwd: projectPath },
    );
    return true;
  } catch {
    return false;
  }
}

/** Lazily import and promisify node:child_process.execFile. */
async function getDefaultExecFileAsync(): Promise<ExecFileAsyncFn> {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  return promisify(execFile) as ExecFileAsyncFn;
}

// ── Stale-branch detection ────────────────────────────────────────────────────

/**
 * Detect and handle completed runs whose branches are stale or already merged.
 *
 * For each "completed" run (bead in "review" status):
 * - If an active MQ entry (pending/merging) exists → skip (merge is in progress).
 * - If the branch is merged into the target branch → action "close" (work landed).
 * - If the branch is NOT merged (has commits ahead or is simply stale) → action
 *   "reset" (work needs to be re-tried).
 *
 * Seeds in `skipSeedIds` (already being reset by the main loop) are skipped.
 * Seeds with active (pending/running) dispatched runs are also skipped.
 *
 * When `dryRun` is false:
 * - "close" → update bead to "closed", mark run as "reset"
 * - "reset" → update bead to "open",   mark run as "reset"
 * In both cases the MQ entry for the seed is removed so the run is not
 * re-processed by the refinery.
 */
export async function detectAndHandleStaleBranches(
  store: Pick<ResetRunStore, "getRunsByStatus" | "getActiveRuns" | "updateRun">,
  seeds: IShowUpdateClient,
  mergeQueue: ResetMergeQueue,
  projectPath: string,
  projectId: string,
  skipSeedIds: ReadonlySet<string>,
  opts?: {
    dryRun?: boolean;
    execFileAsync?: ExecFileAsyncFn;
  },
): Promise<StaleBranchDetectionOutput> {
  const dryRun = opts?.dryRun ?? false;
  const execFn = opts?.execFileAsync;

  const completedRuns = await store.getRunsByStatus("completed", projectId);

  // Build a set of seed IDs that have active (pending/running) dispatched runs.
  const activeRuns = await store.getActiveRuns(projectId);
  const activeSeedIds = new Set(activeRuns.map((r) => r.seed_id));

  // Deduplicate by seed_id: keep the most recently created run per seed.
  const latestBySeed = new Map<string, Run>();
  for (const run of completedRuns) {
    if (skipSeedIds.has(run.seed_id)) continue;
    if (activeSeedIds.has(run.seed_id)) continue;
    const existing = latestBySeed.get(run.seed_id);
    if (!existing || run.created_at > existing.created_at) {
      latestBySeed.set(run.seed_id, run);
    }
  }

  const results: StaleBranchResult[] = [];
  let closed = 0;
  let reset = 0;
  const errors: string[] = [];

  // Detect the target branch once (e.g. "dev" or "main") — used for all checks.
  let targetBranch: string;
  try {
    const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
    targetBranch = await resolveDefaultBranch(
      projectPath,
      (path) => vcs.detectDefaultBranch(path),
      loadProjectConfig(projectPath),
    );
  } catch {
    targetBranch = "dev";
  }

  // Snapshot MQ entries once so we don't call list() in a tight loop.
  const mqEntries = await mergeQueue.list();
  const activeMqSeedIds = new Set(
    mqEntries
      .filter((e) => e.status === "pending" || e.status === "merging")
      .map((e) => e.seed_id),
  );

  for (const run of latestBySeed.values()) {
    const branchName = `foreman/${run.seed_id}`;

    // Skip if the merge is actively pending/in-progress — don't interrupt the refinery.
    if (activeMqSeedIds.has(run.seed_id)) {
      results.push({
        seedId: run.seed_id,
        runId: run.id,
        branchName,
        action: "skip",
        reason: "active merge queue entry (pending or merging)",
      });
      continue;
    }

    try {
      // Check if the branch's commits have already landed in the target.
      const merged = await isBranchMergedIntoTarget(projectPath, targetBranch, branchName, execFn);

      let action: "close" | "reset";
      let reason: string;

      if (merged) {
        action = "close";
        reason = `branch ${branchName} is merged into ${targetBranch}`;
      } else {
        // Branch is not merged — reset bead so it can be re-dispatched.
        action = "reset";
        reason = `branch ${branchName} is NOT merged into ${targetBranch}`;
      }

      results.push({ seedId: run.seed_id, runId: run.id, branchName, action, reason });

      if (!dryRun) {
        // Update bead status.
        try {
          if (action === "close") {
            await seeds.update(run.seed_id, { status: "closed" });
            closed++;
          } else {
            // Try "open" first (beads), fall back to "ready" (native task store)
            try {
              await seeds.update(run.seed_id, { status: "open" });
            } catch {
              await seeds.update(run.seed_id, { status: "ready" });
            }
            reset++;
          }
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          if (!msg.includes("not found")) {
            errors.push(`Failed to update bead ${run.seed_id}: ${msg}`);
          }
        }

        // Mark the run as reset regardless of action.
        await store.updateRun(run.id, { status: "reset", completed_at: new Date().toISOString() });

        // Remove any MQ entries for this seed (conflict/failed ones).
        const seedMqEntries = mqEntries.filter((e) => e.seed_id === run.seed_id);
        for (const entry of seedMqEntries) {
          await mergeQueue.remove(entry.id);
        }
      } else {
        if (action === "close") closed++;
        else reset++;
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      errors.push(`Failed to check branch status for ${run.seed_id}: ${msg}`);
      results.push({
        seedId: run.seed_id,
        runId: run.id,
        branchName,
        action: "error",
        reason: "git check failed",
        error: msg,
      });
    }
  }

  return { results, closed, reset, errors };
}

// ── State mismatch detection ─────────────────────────────────────────────

export interface MismatchResult {
  mismatches: StateMismatch[];
  fixed: number;
  errors: string[];
}

/**
 * Detect and fix seed/run state mismatches.
 *
 * Checks all terminal runs (completed, merged, etc.) for seeds that are still
 * stuck in "in_progress". Seeds that are already included in the `resetSeedIds`
 * set are skipped — those will be handled by the main reset loop.
 *
 * Seeds with active (pending/running) runs are skipped to avoid the race
 * condition where auto-dispatch has just marked a seed as in_progress but the
 * reset sees the old terminal run and incorrectly overwrites the status.
 *
 * For each mismatch found, the seed status is updated to the expected value
 * (unless dryRun is true).
 */
export async function detectAndFixMismatches(
  store: Pick<ResetRunStore, "getRunsByStatus" | "getActiveRuns">,
  seeds: IShowUpdateClient,
  projectId: string,
  resetSeedIds: ReadonlySet<string>,
  opts?: { dryRun?: boolean },
): Promise<MismatchResult> {
  const dryRun = opts?.dryRun ?? false;

  // Check terminal run statuses not already handled by the reset loop
  const checkStatuses = ["completed", "merged", "pr-created", "conflict", "test-failed"] as const;
  const terminalRuns = (await Promise.all(checkStatuses.map((s) => store.getRunsByStatus(s, projectId)))).flat();

  // Short-circuit: nothing to check, skip the extra DB read for active runs.
  if (terminalRuns.length === 0) return { mismatches: [], fixed: 0, errors: [] };

  // Build a set of seed IDs that have active (pending/running) runs.
  // We skip those to avoid clobbering seeds that were just dispatched.
  const activeRuns = await store.getActiveRuns(projectId);
  const activeSeedIds = new Set(activeRuns.map((r) => r.seed_id));

  // Deduplicate by seed_id: keep the most recently created run per seed
  const latestBySeed = new Map<string, Run>();
  for (const run of terminalRuns) {
    // Skip seeds already being reset by the main loop
    if (resetSeedIds.has(run.seed_id)) continue;

    // Skip seeds that have an active run — they are being dispatched right now
    if (activeSeedIds.has(run.seed_id)) continue;

    const existing = latestBySeed.get(run.seed_id);
    if (!existing || run.created_at > existing.created_at) {
      latestBySeed.set(run.seed_id, run);
    }
  }

  const mismatches: StateMismatch[] = [];
  const errors: string[] = [];
  let fixed = 0;

  for (const run of latestBySeed.values()) {
    const expectedSeedStatus = mapRunStatusToSeedStatus(run.status);
    try {
      const seedDetail = await seeds.show(run.seed_id);

      if (seedDetail.status !== expectedSeedStatus) {
        mismatches.push({
          seedId: run.seed_id,
          runId: run.id,
          runStatus: run.status,
          actualSeedStatus: seedDetail.status,
          expectedSeedStatus,
        });

        if (!dryRun) {
          try {
            await seeds.update(run.seed_id, { status: expectedSeedStatus });
            fixed++;
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            errors.push(`Failed to fix mismatch for seed ${run.seed_id}: ${msg}`);
          }
        }
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!msg.includes("not found") && !msg.includes("Issue not found")) {
        errors.push(`Could not check seed ${run.seed_id}: ${msg}`);
      }
      // Seed not found — skip silently
    }
  }

  return { mismatches, fixed, errors };
}

// ── Stuck-run detection ───────────────────────────────────────────────────

export interface StuckDetectionResult {
  /** Runs newly identified as stuck during detection. */
  stuck: Run[];
  /** Any errors that occurred during detection (non-fatal). */
  errors: string[];
}

/**
 * Detect stuck active runs by:
 *  1. Timeout check — if elapsed time > stuckTimeoutMinutes, the run is stuck.
 *
 * Updates the store for each newly-detected stuck run and returns the list.
 * Runs that are already in "stuck" status are not re-detected here (they will
 * be picked up by the main reset loop).
 */
export async function detectStuckRuns(
  store: Pick<ResetRunStore, "getActiveRuns" | "updateRun" | "logEvent">,
  projectId: string,
  opts?: {
    stuckTimeoutMinutes?: number;
    dryRun?: boolean;
  },
): Promise<StuckDetectionResult> {
  const stuckTimeout = opts?.stuckTimeoutMinutes ?? PIPELINE_LIMITS.stuckDetectionMinutes;
  const dryRun = opts?.dryRun ?? false;

  // Only look at "running" (not pending/failed/stuck — those are handled elsewhere)
  const activeRuns = (await store.getActiveRuns(projectId)).filter((r) => r.status === "running");

  const stuck: Run[] = [];
  const errors: string[] = [];
  const now = Date.now();

  for (const run of activeRuns) {
    try {
      // Timeout check — if elapsed time exceeds stuckTimeout
      if (run.started_at) {
        const startedAt = new Date(run.started_at).getTime();
        const elapsedMinutes = (now - startedAt) / (1000 * 60);

        if (elapsedMinutes > stuckTimeout) {
          if (!dryRun) {
            await store.updateRun(run.id, { status: "stuck" });
            await store.logEvent(
              run.project_id,
              "stuck",
              { seedId: run.seed_id, elapsedMinutes: Math.round(elapsedMinutes), detectedBy: "timeout" },
              run.id,
            );
          }
          stuck.push({ ...run, status: "stuck" });
          continue;
        }
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      errors.push(`Could not check run ${run.seed_id}: ${msg}`);
    }
  }

  return { stuck, errors };
}

// ── Seed status reset helper ─────────────────────────────────────────────

export interface ResetSeedResult {
  /** "reset" — seed was updated to open */
  action: "reset" | "skipped-closed" | "already-open" | "not-found" | "error";
  seedId: string;
  previousStatus?: string;
  targetStatus?: string;
  error?: string;
}

/**
 * Reset a single seed back to a retryable status.
 *
 * - Native tasks are reset to "ready"; beads are reset to "open".
 * - Closed/completed tasks are left unchanged.
 * - If the seed is already retryable ("open" or "ready"), the update is skipped
 *   (idempotent).
 * - If the seed is not found, returns "not-found" without throwing.
 * - In dry-run mode, the `show()` check still runs (read-only) but `update()`
 *   is skipped — the returned `action` accurately reflects what would happen.
 */
async function syncElixirResetToReady(seedId: string): Promise<void> {
  const manager = new ElixirServerManager();
  const status = await manager.ensureRunning();
  const client = new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
  const commandId = `reset-${seedId}-${Date.now()}`;
  const response = await client.sendCommand({
    command_id: commandId,
    command_type: "task.update",
    payload: {
      task_id: seedId,
      status: "ready",
      run_id: null,
      failure_reason: null,
      failure_output: null,
    },
    metadata: { source: "foreman-reset", correlation_id: commandId },
  });

  if (!response.ok) {
    throw new Error(response.error.message);
  }
}

export async function resetSeedToOpen(
  seedId: string,
  seeds: IShowUpdateClient,
  opts?: { dryRun?: boolean; force?: boolean },
): Promise<ResetSeedResult> {
  const dryRun = opts?.dryRun ?? false;
  try {
    const seedDetail = await seeds.show(seedId);
    const targetStatus = getSeedRetryTargetStatus(seedDetail.status, { command: "reset" });

    if (targetStatus == null) {
      return { action: "skipped-closed", seedId, previousStatus: seedDetail.status };
    }

    if (seedDetail.status === targetStatus) {
      return { action: "already-open", seedId, previousStatus: seedDetail.status, targetStatus };
    }

    if (!dryRun) {
      if (targetStatus === "ready" && typeof seeds.resetToReady === "function") {
        await seeds.resetToReady(seedId);
      } else {
        await seeds.update(seedId, { status: targetStatus });
      }
    }
    return { action: "reset", seedId, previousStatus: seedDetail.status, targetStatus };
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("not found")) {
      return { action: "not-found", seedId };
    }
    return { action: "error", seedId, error: msg };
  }
}

export const resetCommand = new Command("reset")
  .description("Removed after Elixir cutover; use Elixir-backed retry/recovery workflows")
  .option("--task <id>", "Removed legacy local run-store reset")
  .option("--bead <id>", "Removed legacy alias")
  .option("--all", "Removed legacy local run-store reset")
  .option("--detect-stuck", "Removed legacy stuck detection")
  .option("--timeout <minutes>", "Removed legacy stuck detection timeout")
  .option("--dry-run", "Removed legacy dry run")
  .option("--preserve-worktree", "Removed legacy worktree preservation")
  .option("--retry-failed-phase", "Removed legacy failed-phase retry")
  .option("--project <name>", "Registered project name (unused; reset removed)")
  .option("--project-path <absolute-path>", "Absolute project path (unused; reset removed)")
  .action(async () => {
    console.error(chalk.red("Error: foreman reset was removed after the Elixir backend cutover."));
    console.error(chalk.dim("  Use Elixir-backed retry/recovery workflows instead of the legacy local run-store reset path."));
    process.exit(1);
  });
