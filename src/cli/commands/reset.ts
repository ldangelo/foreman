import { Command } from "commander";
import chalk from "chalk";

import { createTaskClient } from "../../lib/task-client-factory.js";
import { resolveRepoRootProjectPath, requireProjectOrAllInMultiMode } from "./project-task-support.js";
import { ForemanStore } from "../../lib/store.js";
import type { Run } from "../../lib/store.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { existsSync, readdirSync } from "node:fs";
import { archiveWorktreeReports } from "../../lib/archive-reports.js";
import type { ITaskClient } from "../../lib/task-client.js";
import { PIPELINE_LIMITS } from "../../lib/config.js";
import { mapRunStatusToSeedStatus } from "../../lib/run-status.js";
import { deleteWorkerConfigFile } from "../../orchestrator/dispatcher.js";
import { MergeQueue } from "../../orchestrator/merge-queue.js";
import type { StateMismatch } from "../../lib/run-status.js";
import { getWorkspaceRoot } from "../../lib/workspace-paths.js";
import { loadProjectConfig, resolveDefaultBranch } from "../../lib/project-config.js";
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
  store: Pick<ForemanStore, "getRunsByStatus" | "getActiveRuns" | "updateRun">,
  seeds: IShowUpdateClient,
  mergeQueue: MergeQueue,
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

  const completedRuns = store.getRunsByStatus("completed", projectId);

  // Build a set of seed IDs that have active (pending/running) dispatched runs.
  const activeRuns = store.getActiveRuns(projectId);
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
  const mqEntries = mergeQueue.list();
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
        store.updateRun(run.id, { status: "reset", completed_at: new Date().toISOString() });

        // Remove any MQ entries for this seed (conflict/failed ones).
        const seedMqEntries = mqEntries.filter((e) => e.seed_id === run.seed_id);
        for (const entry of seedMqEntries) {
          mergeQueue.remove(entry.id);
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
  store: Pick<ForemanStore, "getRunsByStatus" | "getActiveRuns">,
  seeds: IShowUpdateClient,
  projectId: string,
  resetSeedIds: ReadonlySet<string>,
  opts?: { dryRun?: boolean },
): Promise<MismatchResult> {
  const dryRun = opts?.dryRun ?? false;

  // Check terminal run statuses not already handled by the reset loop
  const checkStatuses = ["completed", "merged", "pr-created", "conflict", "test-failed"] as const;
  const terminalRuns = checkStatuses.flatMap((s) => store.getRunsByStatus(s, projectId));

  // Short-circuit: nothing to check, skip the extra DB read for active runs.
  if (terminalRuns.length === 0) return { mismatches: [], fixed: 0, errors: [] };

  // Build a set of seed IDs that have active (pending/running) runs.
  // We skip those to avoid clobbering seeds that were just dispatched.
  const activeRuns = store.getActiveRuns(projectId);
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
  store: Pick<ForemanStore, "getActiveRuns" | "updateRun" | "logEvent">,
  projectId: string,
  opts?: {
    stuckTimeoutMinutes?: number;
    dryRun?: boolean;
  },
): Promise<StuckDetectionResult> {
  const stuckTimeout = opts?.stuckTimeoutMinutes ?? PIPELINE_LIMITS.stuckDetectionMinutes;
  const dryRun = opts?.dryRun ?? false;

  // Only look at "running" (not pending/failed/stuck — those are handled elsewhere)
  const activeRuns = store.getActiveRuns(projectId).filter((r) => r.status === "running");

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
            store.updateRun(run.id, { status: "stuck" });
            store.logEvent(
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

const RETRY_READY_STATUSES = new Set([
  "backlog",
  "ready",
  "in-progress",
  "blocked",
  "conflict",
  "failed",
  "stuck",
  "explorer",
  "developer",
  "qa",
  "reviewer",
  "finalize",
]);

function getResetTargetStatus(currentStatus: string): "open" | "ready" | null {
  if (currentStatus === "open" || currentStatus === "ready") {
    return currentStatus === "ready" ? "ready" : "open";
  }

  if (currentStatus === "closed" || currentStatus === "completed" || currentStatus === "merged") {
    return null;
  }

  if (RETRY_READY_STATUSES.has(currentStatus)) {
    return "ready";
  }

  return "open";
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
export async function resetSeedToOpen(
  seedId: string,
  seeds: IShowUpdateClient,
  opts?: { dryRun?: boolean; force?: boolean },
): Promise<ResetSeedResult> {
  const dryRun = opts?.dryRun ?? false;
  try {
    const seedDetail = await seeds.show(seedId);
    const targetStatus = getResetTargetStatus(seedDetail.status);

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
  .description("Reset failed/stuck runs: kill agents, remove worktrees, and reset tasks to a retryable status")
  .option("--bead <id>", "Reset a specific bead by ID (clears all runs for that bead, including stale pending ones)")
  .option("--all", "Reset ALL active runs, not just failed/stuck ones")
  .option("--detect-stuck", "Run stuck detection first, adding newly-detected stuck runs to the reset list")
  .option(
    "--timeout <minutes>",
    "Stuck detection timeout in minutes (used with --detect-stuck)",
    String(PIPELINE_LIMITS.stuckDetectionMinutes),
  )
  .option("--dry-run", "Show what would be reset without doing it")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (opts, cmd) => {
    const dryRun = opts.dryRun as boolean | undefined;
    const all = opts.all as boolean | undefined;
    const detectStuck = opts.detectStuck as boolean | undefined;
    const beadFilter = opts.bead as string | undefined;
    const timeoutMinutes = parseInt(opts.timeout as string, 10);

    if (isNaN(timeoutMinutes)) {
      console.error(
        chalk.red(`Error: --timeout must be a positive integer, got "${opts.timeout as string}"`),
      );
      process.exit(1);
    }

    // Warn if --timeout is explicitly set but --detect-stuck is not (it would be a no-op)
    if (!detectStuck && cmd.getOptionValueSource("timeout") === "user") {
      console.warn(chalk.yellow("Warning: --timeout has no effect without --detect-stuck\n"));
    }

    try {
      // Require --project in multi-project mode
      await requireProjectOrAllInMultiMode(opts.project, opts.all ?? false);
      const projectPath = await resolveRepoRootProjectPath(opts);
      const vcs = await VcsBackendFactory.create({ backend: 'auto' }, projectPath);
      // Save current branch so we can restore it after worktree/branch cleanup,
      // which can change HEAD as a side effect of git worktree remove / branch -D.
      let originalBranch: string | undefined;
      try { originalBranch = await vcs.getCurrentBranch(projectPath); } catch { /* ignore */ }

      const { taskClient } = await createTaskClient(projectPath);
      const seeds: IShowUpdateClient = taskClient;
      const store = ForemanStore.forProject(projectPath);
      const project = store.getProjectByPath(projectPath);

      if (!project) {
        console.error(chalk.red("No project registered for this path. Run 'foreman init' first."));
        process.exit(1);
      }

      const mergeQueue = new MergeQueue(store.getDb());

      // Optional: run stuck detection first, mark newly-stuck runs in the store
      if (detectStuck) {
        console.log(chalk.bold("Detecting stuck runs...\n"));
        const detectionResult = await detectStuckRuns(store, project.id, {
          stuckTimeoutMinutes: timeoutMinutes,
          dryRun,
        });

        if (detectionResult.stuck.length > 0) {
          console.log(chalk.yellow.bold(`Found ${detectionResult.stuck.length} newly stuck run(s):`));
          for (const run of detectionResult.stuck) {
            const elapsed = run.started_at
              ? Math.round((Date.now() - new Date(run.started_at).getTime()) / 60000)
              : 0;
            console.log(
              `  ${chalk.yellow(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)} ${elapsed}m`,
            );
          }
          console.log();
        } else {
          console.log(chalk.dim("  No newly stuck runs detected.\n"));
        }

        if (detectionResult.errors.length > 0) {
          for (const err of detectionResult.errors) {
            console.log(chalk.red(`  Warning: ${err}`));
          }
          console.log();
        }
      }

      // Find runs to reset
      let runs: Run[];

      if (beadFilter) {
        // --seed: get ALL runs for this seed regardless of status, so stale pending/running are included
        runs = store.getRunsForSeed(beadFilter, project.id);
        if (runs.length === 0) {
          console.log(chalk.yellow(`No runs found for bead ${beadFilter}.\n`));
        } else {
          console.log(chalk.bold(`Resetting all ${runs.length} run(s) for bead ${beadFilter}:\n`));
        }
      } else {
        const statuses = all
          ? ["pending", "running", "failed", "stuck", "conflict", "test-failed"] as const
          : ["failed", "stuck", "conflict", "test-failed"] as const;
        runs = statuses.flatMap((s) => store.getRunsByStatus(s, project.id));
      }

      if (dryRun) {
        console.log(chalk.yellow("(dry run — no changes will be made)\n"));
      }

      if (!beadFilter && runs.length === 0) {
        console.log(chalk.yellow("No active runs to reset.\n"));
      } else if (!beadFilter) {
        console.log(chalk.bold(`Resetting ${runs.length} run(s):\n`));
      }

      // Collect unique seed IDs to reset
      const seedIds = new Set<string>();
      let killed = 0;
      let worktreesRemoved = 0;
      let branchesDeleted = 0;
      let runsMarkedFailed = 0;
      let mqEntriesRemoved = 0;
      let seedsReset = 0;
      let prsClosed = 0;
      const errors: string[] = [];
      const closedPrSeeds = new Set<string>();

      for (const run of runs) {
        const pid = extractPid(run.session_key);
        const branchName = `foreman/${run.seed_id}`;

        console.log(`  ${chalk.cyan(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)} status=${run.status}`);

        if (!closedPrSeeds.has(run.seed_id)) {
          console.log(`    ${chalk.yellow("close")} PR for branch ${branchName}`);
          try {
            const result = await closeForemanPullRequest(projectPath, branchName, { dryRun });
            if (result.action === "closed") {
              prsClosed++;
              console.log(`    ${chalk.green("closed")} PR ${result.prUrl ?? ""}`.trim());
            } else if (result.action === "dry-run") {
              console.log(`    ${chalk.dim("would close")} PR ${result.prUrl ?? ""}`.trim());
            }
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            errors.push(`Failed to close PR for ${run.seed_id}: ${msg}`);
            console.log(`    ${chalk.red("error")} closing PR: ${msg}`);
          }
          closedPrSeeds.add(run.seed_id);
        }

        // 1. Kill the agent process if alive
        if (pid && isAlive(pid)) {
          console.log(`    ${chalk.yellow("kill")} pid ${pid}`);
          if (!dryRun) {
            try {
              process.kill(pid, "SIGTERM");
              killed++;
            } catch (err: unknown) {
              const msg = err instanceof Error ? err.message : String(err);
              errors.push(`Failed to kill pid ${pid} for ${run.seed_id}: ${msg}`);
              console.log(`    ${chalk.red("error")} killing pid ${pid}: ${msg}`);
            }
          }
        }

        // 2. Remove the worktree
        if (run.worktree_path) {
          console.log(`    ${chalk.yellow("remove")} worktree ${run.worktree_path}`);
          if (!dryRun) {
            try {
              await archiveWorktreeReports(projectPath, run.worktree_path, run.seed_id).catch(() => {});
              await vcs.removeWorkspace(projectPath, run.worktree_path);
              worktreesRemoved++;
            } catch (err: unknown) {
              const msg = err instanceof Error ? err.message : String(err);
              // Worktree/workspace may already be gone — not an error
              if (!msg.includes("is not a working tree") && !msg.includes("doesn't exist")) {
                errors.push(`Failed to remove worktree for ${run.seed_id}: ${msg}`);
                console.log(`    ${chalk.red("error")} removing worktree: ${msg}`);
              } else {
                worktreesRemoved++;
              }
            }
          }
        }

        // 3. Delete the branch — switch to main first if it is currently checked out
        console.log(`    ${chalk.yellow("delete")} branch ${branchName}`);
        if (!dryRun) {
          const { execFile } = await import("node:child_process");
          const { promisify } = await import("node:util");
          try {
            const delResult = await vcs.deleteBranch(projectPath, branchName, { force: true });
            if (delResult.deleted) branchesDeleted++;
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            if (msg.includes("used by worktree")) {
              // Branch is HEAD of the main worktree — switch to main then retry
              try {
                console.log(`    ${chalk.dim("checkout")} main (branch is current HEAD)`);
                await vcs.checkoutBranch(projectPath, "main");
                const retryResult = await vcs.deleteBranch(projectPath, branchName, { force: true });
                if (retryResult.deleted) branchesDeleted++;
              } catch (retryErr: unknown) {
                const retryMsg = retryErr instanceof Error ? retryErr.message : String(retryErr);
                errors.push(`Failed to delete branch ${branchName}: ${retryMsg}`);
                console.log(`    ${chalk.red("error")} deleting branch: ${retryMsg}`);
              }
            } else {
              errors.push(`Failed to delete branch ${branchName}: ${msg}`);
              console.log(`    ${chalk.red("error")} deleting branch: ${msg}`);
            }
          }

          // 3b. Delete the remote branch to prevent stale remote tracking refs.
          // reconcile() checks refs/remotes/origin/foreman/<seedId> to recover
          // runs that crashed after pushing but before updating their status.
          // If the local branch is deleted but the remote ref persists, reconcile()
          // will falsely mark the newly re-dispatched (empty) run as "completed"
          // and insert a merge queue entry that immediately fails with "no-commits".
          console.log(`    ${chalk.yellow("delete")} remote branch origin/${branchName}`);
          try {
            await promisify(execFile)("git", ["push", "origin", "--delete", branchName], { cwd: projectPath });
          } catch {
            // Non-fatal: remote branch may not exist (never pushed, or already deleted)
          }
        }

        // 4. Mark run as "reset" — keeps history/events intact but signals to
        //    doctor that this run was intentionally cleared (not an active failure).
        console.log(`    ${chalk.yellow("mark")} run as reset`);
        if (!dryRun) {
          store.updateRun(run.id, {
            status: "reset",
            completed_at: new Date().toISOString(),
          });
          runsMarkedFailed++;
        }

        // 5. Clean up orphaned worker config file (if it still exists)
        if (!dryRun) {
          await deleteWorkerConfigFile(run.id);
        }

        // 5b. Remove merge queue entries for this seed
        const mqEntries = mergeQueue.list().filter((e) => e.seed_id === run.seed_id);
        if (mqEntries.length > 0) {
          console.log(`    ${chalk.yellow("remove")} ${mqEntries.length} merge queue entry(ies)`);
          if (!dryRun) {
            for (const entry of mqEntries) {
              mergeQueue.remove(entry.id);
              mqEntriesRemoved++;
            }
          }
        }

        seedIds.add(run.seed_id);
        console.log();
      }

      // 5. Reset seeds to a retryable status
      for (const seedId of seedIds) {
        const result = await resetSeedToOpen(seedId, seeds, { dryRun, force: !!beadFilter });
        switch (result.action) {
          case "skipped-closed":
            console.log(
              `  ${chalk.dim("skip")} seed ${chalk.cyan(seedId)} is already closed — not reopening`,
            );
            break;
          case "already-open":
            console.log(
              `  ${chalk.dim("skip")} bead ${chalk.cyan(seedId)} is already ${result.targetStatus ?? "retryable"}`,
            );
            break;
          case "reset":
            console.log(
              `  ${chalk.yellow("reset")} bead ${chalk.cyan(seedId)} → ${result.targetStatus ?? "retryable"}`,
            );
            seedsReset++;
            break;
          case "not-found":
            console.log(`    ${chalk.dim("skip")} bead ${seedId} no longer exists`);
            break;
          case "error":
            errors.push(`Failed to reset bead ${seedId}: ${result.error ?? "unknown error"}`);
            console.log(`    ${chalk.red("error")} resetting bead: ${result.error ?? "unknown error"}`);
            break;
        }
      }

      // 5c. Mark all completed runs with no MQ entry as "reset" — their branches
      //     have been removed or were never queued, so they can never be merged.
      //     Leaving them as "completed" triggers the MQ-011 doctor warning.
      if (!dryRun) {
        const unqueuedCompleted = mergeQueue.missingFromQueue();
        for (const entry of unqueuedCompleted) {
          store.updateRun(entry.run_id, { status: "reset", completed_at: new Date().toISOString() });
          runsMarkedFailed++;
        }
        if (unqueuedCompleted.length > 0) {
          console.log(`  ${chalk.yellow("reset")} ${unqueuedCompleted.length} completed run(s) with no merge queue entry`);
        }
      }

      // 6. Prune stale worktree entries and remote tracking refs
      if (!dryRun) {
        try {
          const { execFile } = await import("node:child_process");
          const { promisify } = await import("node:util");
          // git worktree prune only applies to git backends — jj manages workspaces separately
          const { GitBackend } = await import("../../lib/vcs/git-backend.js");
          if (vcs instanceof GitBackend) {
            await promisify(execFile)("git", ["worktree", "prune"], { cwd: projectPath });
          }
          // Prune stale remote tracking refs so reconcile() doesn't see deleted
          // remote branches and falsely recover newly-dispatched empty runs.
          await promisify(execFile)("git", ["fetch", "--prune"], { cwd: projectPath });
        } catch {
          // Non-critical
        }
      }

      // 6b. Clean up orphaned worktrees — directories in .foreman-worktrees/ that either have
      //     no SQLite run record OR only have completed/merged runs (finalize should remove them
      //     but sometimes fails to do so)
      if (!dryRun) {
        const worktreesDir = getWorkspaceRoot(projectPath);
        if (existsSync(worktreesDir)) {
          // Paths that still have truly active runs (pending or running) — keep these.
          // "failed" and "stuck" are terminal states: their agents have stopped, so
          // their worktrees are safe to remove during cleanup. Including them in the
          // "active" set was the bug: it prevented orphaned worktrees from being
          // cleaned up when a run had no worktree_path recorded in the DB.
          const activeStatuses = ["pending", "running"] as const;
          const activeRuns = activeStatuses.flatMap((s) => store.getRunsByStatus(s, project.id));
          const activeWorktreePaths = new Set(activeRuns.map((r) => r.worktree_path).filter(Boolean));

          let entries: string[] = [];
          try {
            entries = readdirSync(worktreesDir);
          } catch {
            // Directory may have been removed already
          }

          for (const entry of entries) {
            const fullPath = `${worktreesDir}/${entry}`;
            // Skip if this worktree belongs to an active run (may still be in use)
            if (activeWorktreePaths.has(fullPath)) continue;

            console.log(`  ${chalk.yellow("orphan")} worktree ${fullPath}`);
            try {
              await vcs.removeWorkspace(projectPath, fullPath);
              worktreesRemoved++;
            } catch (err: unknown) {
              const msg = err instanceof Error ? err.message : String(err);
              if (!msg.includes("is not a working tree") && !msg.includes("doesn't exist")) {
                console.log(`    ${chalk.red("error")} removing orphaned worktree: ${msg}`);
              }
            }
            // Delete the corresponding branch if it exists
            const orphanBranch = `foreman/${entry}`;
            try {
              const delResult = await vcs.deleteBranch(projectPath, orphanBranch, { force: true });
              if (delResult.deleted) {
                branchesDeleted++;
                console.log(`    ${chalk.yellow("delete")} orphan branch ${orphanBranch}`);
              }
            } catch {
              // Branch may not exist — skip silently
            }
          }
        }
      }

      // 6c. Purge all remaining conflict/failed merge queue entries (catches seeds not
      //     in this reset batch that are still clogging the queue)
      if (!dryRun) {
        const staleEntries = mergeQueue.list().filter(
          (e) => e.status === "conflict" || e.status === "failed",
        );
        for (const entry of staleEntries) {
          mergeQueue.remove(entry.id);
          mqEntriesRemoved++;
        }
        if (staleEntries.length > 0) {
          console.log(`  ${chalk.yellow("purged")} ${staleEntries.length} stale merge queue entry(ies)`);
        }
      }

      // 7. Detect and fix seed/run state mismatches for terminal runs
      console.log(chalk.bold("\nChecking for bead/run state mismatches..."));
      const mismatchResult = await detectAndFixMismatches(store, seeds, project.id, seedIds, { dryRun });

      if (mismatchResult.mismatches.length > 0) {
        for (const m of mismatchResult.mismatches) {
          const action = dryRun
            ? chalk.yellow("(would fix)")
            : chalk.green("fixed");
          console.log(
            `  ${chalk.yellow("mismatch")} ${chalk.cyan(m.seedId)}: ` +
            `run=${m.runStatus}, bead=${m.actualSeedStatus} → ${m.expectedSeedStatus} ${action}`,
          );
        }
      } else {
        console.log(chalk.dim("  No mismatches found."));
      }

      // 8. Detect and handle stale branches for completed (review) runs.
      //    This covers beads stuck in 'review' status from failed merge attempts.
      console.log(chalk.bold("\nChecking for stale / already-merged review branches..."));
      const staleResult = await detectAndHandleStaleBranches(
        store,
        seeds,
        mergeQueue,
        projectPath,
        project.id,
        seedIds, // skip seeds already handled by the main reset loop
        { dryRun },
      );

      for (const r of staleResult.results) {
        if (r.action === "skip") continue;
        if (r.action === "error") {
          console.log(`  ${chalk.red("error")} ${chalk.cyan(r.seedId)}: ${r.error ?? r.reason}`);
        } else if (r.action === "close") {
          console.log(
            `  ${dryRun ? chalk.yellow("(would close)") : chalk.green("close")} ` +
            `bead ${chalk.cyan(r.seedId)} — ${r.reason}`,
          );
        } else {
          console.log(
            `  ${dryRun ? chalk.yellow("(would reset)") : chalk.yellow("reset")} ` +
            `bead ${chalk.cyan(r.seedId)} → open — ${r.reason}`,
          );
        }
      }

      if (staleResult.results.filter((r) => r.action !== "skip" && r.action !== "error").length === 0) {
        console.log(chalk.dim("  No stale review branches found."));
      }

      // Summary
      console.log(chalk.bold("\nSummary:"));
      if (dryRun) {
        console.log(chalk.yellow(`  Would reset ${runs.length} runs across ${seedIds.size} beads`));
        if (mismatchResult.mismatches.length > 0) {
          console.log(chalk.yellow(`  Would fix ${mismatchResult.mismatches.length} mismatch(es)`));
        }
        if (staleResult.closed > 0) {
          console.log(chalk.yellow(`  Would close ${staleResult.closed} already-merged bead(s)`));
        }
        if (staleResult.reset > 0) {
          console.log(chalk.yellow(`  Would reset ${staleResult.reset} stale review bead(s) to open`));
        }
      } else {
        console.log(`  Processes killed:   ${killed}`);
        console.log(`  Worktrees removed:  ${worktreesRemoved}`);
        console.log(`  Branches deleted:   ${branchesDeleted}`);
        console.log(`  Runs marked reset:   ${runsMarkedFailed}`);
        console.log(`  MQ entries removed:  ${mqEntriesRemoved}`);
        console.log(`  PRs closed:         ${prsClosed}`);
        console.log(`  Beads reset:        ${seedsReset}`);
        console.log(`  Mismatches fixed:   ${mismatchResult.fixed}`);
        console.log(`  Beads closed (merged): ${staleResult.closed}`);
        console.log(`  Beads reset (review):  ${staleResult.reset}`);
      }

      const allErrors = [...errors, ...mismatchResult.errors, ...staleResult.errors];
      if (allErrors.length > 0) {
        console.log(chalk.red(`\n  Errors (${allErrors.length}):`));
        for (const err of allErrors) {
          console.log(chalk.red(`    ${err}`));
        }
      }

      // Restore the original branch — worktree removal and branch deletion can
      // change HEAD as a side effect.
      if (originalBranch) {
        try {
          const currentBranch = await vcs.getCurrentBranch(projectPath);
          if (currentBranch !== originalBranch) {
            await vcs.checkoutBranch(projectPath, originalBranch);
            console.log(chalk.dim(`Restored branch: ${originalBranch}`));
          }
        } catch {
          console.warn(chalk.yellow(`Warning: could not restore branch '${originalBranch}'. Run: git checkout ${originalBranch}`));
        }
      }

      console.log(chalk.dim("\nRe-run with: foreman run"));

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });

function extractPid(sessionKey: string | null): number | null {
  if (!sessionKey) return null;
  const m = sessionKey.match(/pid-(\d+)/);
  return m ? parseInt(m[1], 10) : null;
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}
