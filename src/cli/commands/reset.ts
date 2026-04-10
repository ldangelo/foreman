import { Command } from "commander";
import chalk from "chalk";

import { BeadsRustClient } from "../../lib/beads-rust.js";
import { resolveRepoRootProjectPath } from "./project-task-support.js";
import { ForemanStore } from "../../lib/store.js";
import type { Run } from "../../lib/store.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { existsSync, readdirSync } from "node:fs";
import { archiveWorktreeReports } from "../../lib/archive-reports.js";
import type { UpdateOptions } from "../../lib/task-client.js";
import { PIPELINE_LIMITS } from "../../lib/config.js";
import { mapRunStatusToSeedStatus } from "../../lib/run-status.js";
import { deleteWorkerConfigFile } from "../../orchestrator/dispatcher.js";
import { MergeQueue } from "../../orchestrator/merge-queue.js";
import type { StateMismatch } from "../../lib/run-status.js";
import { getWorkspaceRoot } from "../../lib/workspace-paths.js";
import { getForemanBranchName } from "../../lib/branch-names.js";
// Re-export for callers that import these from this module (backward compatibility).
export { mapRunStatusToSeedStatus } from "../../lib/run-status.js";
export type { StateMismatch } from "../../lib/run-status.js";

/**
 * Minimal interface capturing the subset of task-client methods used by
 * detectAndFixMismatches. BeadsRustClient satisfies this interface
 * (note: show() is not on ITaskClient, hence this local type).
 */
export interface IShowUpdateClient {
  show(id: string): Promise<{ status: string }>;
  update(id: string, opts: UpdateOptions): Promise<void>;
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
    targetBranch = await vcs.detectDefaultBranch(projectPath);
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
    const branchName = getForemanBranchName(run.seed_id);

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
            await seeds.update(run.seed_id, { status: "open" });
            reset++;
          }
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          if (!msg.includes("not found")) {
            errors.push(`Failed to update bead ${run.seed_id}: ${msg}`);
          }
        }

        // Preserve the authoritative terminal truth in SQLite: landed work becomes
        // merged, while retryable stale work becomes reset.
        store.updateRun(run.id, {
          status: action === "close" ? "merged" : "reset",
          completed_at: new Date().toISOString(),
        });

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
  error?: string;
}

/**
 * Reset a single seed back to "open" status.
 *
 * Safety rule: a seed that is already "closed" is treated as landed work and is
 * not reopened unless `force` is explicitly true.
 *
 * - If the seed is already "open", the update is skipped (idempotent).
 * - If the seed is "closed" and `force` is not set, returns "skipped-closed".
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
  const force = opts?.force ?? false;
  try {
    const seedDetail = await seeds.show(seedId);

    if (seedDetail.status === "open") {
      return { action: "already-open", seedId, previousStatus: seedDetail.status };
    }

    if (seedDetail.status === "closed" && !force) {
      return { action: "skipped-closed", seedId, previousStatus: seedDetail.status };
    }

    if (!dryRun) {
      await seeds.update(seedId, { status: "open" });
    }
    return { action: "reset", seedId, previousStatus: seedDetail.status };
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("not found")) {
      return { action: "not-found", seedId };
    }
    return { action: "error", seedId, error: msg };
  }
}

export interface ResetActionDeps {
  resolveProjectPath?: typeof resolveRepoRootProjectPath;
  createVcs?: (
    projectPath: string,
  ) => Promise<Awaited<ReturnType<typeof VcsBackendFactory.create>>>;
  createSeeds?: (projectPath: string) => IShowUpdateClient;
  createStore?: (projectPath: string) => ForemanStore;
  createMergeQueue?: (store: ForemanStore) => MergeQueue;
  detectStuckRuns?: typeof detectStuckRuns;
  detectAndFixMismatches?: typeof detectAndFixMismatches;
  detectAndHandleStaleBranches?: typeof detectAndHandleStaleBranches;
  archiveWorktreeReports?: typeof archiveWorktreeReports;
  deleteWorkerConfigFile?: typeof deleteWorkerConfigFile;
}

export async function resetAction(
  opts: Record<string, unknown>,
  cmd: Command,
  deps: ResetActionDeps = {},
): Promise<number> {
  const dryRun = opts.dryRun as boolean | undefined;
  const all = opts.all as boolean | undefined;
  const detectStuck = opts.detectStuck as boolean | undefined;
  const beadFilter = opts.bead as string | undefined;
  const forceReopenClosed = opts.forceReopenClosed as boolean | undefined;
  const timeoutValue = opts.timeout as string;
  const timeoutMinutes = Number.parseInt(timeoutValue, 10);

  if (!Number.isInteger(timeoutMinutes) || timeoutMinutes <= 0) {
    console.error(
      chalk.red(`Error: --timeout must be a positive integer, got "${timeoutValue}"`),
    );
    return 1;
  }

  if (!detectStuck && cmd.getOptionValueSource("timeout") === "user") {
    console.error(chalk.red("Error: --timeout requires --detect-stuck."));
    return 1;
  }

  const resolveProjectPath = deps.resolveProjectPath ?? resolveRepoRootProjectPath;
  const createVcs = deps.createVcs ?? ((projectPath: string) => VcsBackendFactory.create({ backend: "auto" }, projectPath));
  const createSeeds = deps.createSeeds ?? ((projectPath: string) => new BeadsRustClient(projectPath));
  const createStore = deps.createStore ?? ((projectPath: string) => ForemanStore.forProject(projectPath));
  const createMergeQueue = deps.createMergeQueue ?? ((store: ForemanStore) => new MergeQueue(store.getDb()));
  const detectStuckRunsFn = deps.detectStuckRuns ?? detectStuckRuns;
  const detectAndFixMismatchesFn = deps.detectAndFixMismatches ?? detectAndFixMismatches;
  const detectAndHandleStaleBranchesFn = deps.detectAndHandleStaleBranches ?? detectAndHandleStaleBranches;
  const archiveReports = deps.archiveWorktreeReports ?? archiveWorktreeReports;
  const deleteWorkerConfig = deps.deleteWorkerConfigFile ?? deleteWorkerConfigFile;

  let store: ForemanStore | undefined;

  try {
    const projectPath = await resolveProjectPath(opts);
    const vcs = await createVcs(projectPath);
    let originalBranch: string | undefined;
    try {
      originalBranch = await vcs.getCurrentBranch(projectPath);
    } catch {
      // Ignore branch-detection failures; reset can still proceed.
    }

    const seeds: IShowUpdateClient = createSeeds(projectPath);
    store = createStore(projectPath);
    const project = store.getProjectByPath(projectPath);

    if (!project) {
      console.error(chalk.red("No project registered for this path. Run 'foreman init' first."));
      return 1;
    }

    const mergeQueue = createMergeQueue(store);
    const detectionErrors: string[] = [];
    let detectedStuckRuns: Run[] = [];

    if (detectStuck) {
      console.log(chalk.bold("Detecting stuck runs...\n"));
      const detectionResult = await detectStuckRunsFn(store, project.id, {
        stuckTimeoutMinutes: timeoutMinutes,
        dryRun,
      });

      detectedStuckRuns = detectionResult.stuck;

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
        detectionErrors.push(...detectionResult.errors);
        for (const err of detectionResult.errors) {
          console.error(chalk.red(`  Warning: ${err}`));
        }
        console.error();
      }
    }

    let runs: Run[];

    if (beadFilter) {
      runs = store.getRunsForSeed(beadFilter, project.id);
      const latestRun = runs[0];
      const landedStatuses: ReadonlySet<Run["status"]> = new Set(["merged", "pr-created"]);

      if (latestRun && landedStatuses.has(latestRun.status) && !forceReopenClosed) {
        console.error(
          chalk.red(
            `Bead ${beadFilter} is already landed (latest run status: ${latestRun.status}). Refusing to reopen it without --force-reopen-closed.`,
          ),
        );
        return 1;
      }

      if (runs.length === 0) {
        console.log(chalk.yellow(`No runs found for bead ${beadFilter}.`));
        console.log(chalk.dim("Nothing changed."));
        return 0;
      }

      console.log(chalk.bold(`Resetting all ${runs.length} run(s) for bead ${beadFilter}:\n`));
    } else {
      const statuses = all
        ? ["pending", "running", "failed", "stuck", "conflict", "test-failed"] as const
        : ["failed", "stuck", "conflict", "test-failed"] as const;
      const runsById = new Map<string, Run>();

      for (const run of statuses.flatMap((status) => store!.getRunsByStatus(status, project.id))) {
        runsById.set(run.id, run);
      }
      for (const run of detectedStuckRuns) {
        runsById.set(run.id, run);
      }

      runs = [...runsById.values()];
    }

    if (dryRun) {
      console.log(chalk.yellow("(dry run — no changes will be made)\n"));
    }

    if (!beadFilter && runs.length === 0) {
      console.log(chalk.yellow("No active runs to reset.\n"));
    } else if (!beadFilter) {
      console.log(chalk.bold(`Resetting ${runs.length} run(s):\n`));
    }

    const seedIds = new Set<string>();
    let killed = 0;
    let worktreesRemoved = 0;
    let branchesDeleted = 0;
    let runsMarkedReset = 0;
    let mqEntriesRemoved = 0;
    let seedsReset = 0;
    const errors: string[] = [];

    for (const run of runs) {
      const pid = extractPid(run.session_key);
      const branchName = getForemanBranchName(run.seed_id);

      console.log(`  ${chalk.cyan(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)} status=${run.status}`);

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

      if (run.worktree_path) {
        console.log(`    ${chalk.yellow("remove")} worktree ${run.worktree_path}`);
        if (!dryRun) {
          try {
            await archiveReports(projectPath, run.worktree_path, run.seed_id).catch(() => {});
            await vcs.removeWorkspace(projectPath, run.worktree_path);
            worktreesRemoved++;
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            if (!msg.includes("is not a working tree") && !msg.includes("doesn't exist")) {
              errors.push(`Failed to remove worktree for ${run.seed_id}: ${msg}`);
              console.log(`    ${chalk.red("error")} removing worktree: ${msg}`);
            } else {
              worktreesRemoved++;
            }
          }
        }
      }

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

        console.log(`    ${chalk.yellow("delete")} remote branch origin/${branchName}`);
        try {
          await promisify(execFile)("git", ["push", "origin", "--delete", branchName], { cwd: projectPath });
        } catch {
          // Remote branch may not exist; keep reset truthful by ignoring this benign case.
        }
      }

      console.log(`    ${chalk.yellow("mark")} run as reset`);
      if (!dryRun) {
        store.updateRun(run.id, {
          status: "reset",
          completed_at: new Date().toISOString(),
        });
        runsMarkedReset++;
      }

      if (!dryRun) {
        await deleteWorkerConfig(run.id);
      }

      const mqEntries = mergeQueue.list().filter((entry) => entry.seed_id === run.seed_id);
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

    for (const seedId of seedIds) {
      const result = await resetSeedToOpen(seedId, seeds, { dryRun, force: !!forceReopenClosed });
      switch (result.action) {
        case "skipped-closed":
          console.log(
            `  ${chalk.dim("skip")} bead ${chalk.cyan(seedId)} is already closed — use --force-reopen-closed to reopen landed work`,
          );
          break;
        case "already-open":
          console.log(`  ${chalk.dim("skip")} bead ${chalk.cyan(seedId)} is already open`);
          break;
        case "reset":
          console.log(`  ${chalk.yellow("reset")} bead ${chalk.cyan(seedId)} → open`);
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

    if (!dryRun) {
      const unqueuedCompleted = mergeQueue.missingFromQueue();
      for (const entry of unqueuedCompleted) {
        store.updateRun(entry.run_id, { status: "reset", completed_at: new Date().toISOString() });
        runsMarkedReset++;
      }
      if (unqueuedCompleted.length > 0) {
        console.log(`  ${chalk.yellow("reset")} ${unqueuedCompleted.length} completed run(s) with no merge queue entry`);
      }
    }

    if (!dryRun) {
      try {
        const { execFile } = await import("node:child_process");
        const { promisify } = await import("node:util");
        const { GitBackend } = await import("../../lib/vcs/git-backend.js");
        if (vcs instanceof GitBackend) {
          await promisify(execFile)("git", ["worktree", "prune"], { cwd: projectPath });
        }
        await promisify(execFile)("git", ["fetch", "--prune"], { cwd: projectPath });
      } catch {
        // Non-critical cleanup only.
      }
    }

    if (!dryRun) {
      const worktreesDir = getWorkspaceRoot(projectPath);
      if (existsSync(worktreesDir)) {
        const activeStatuses = ["pending", "running"] as const;
        const activeRuns = activeStatuses.flatMap((status) => store!.getRunsByStatus(status, project.id));
        const activeWorktreePaths = new Set(activeRuns.map((run) => run.worktree_path).filter(Boolean));

        let entries: string[] = [];
        try {
          entries = readdirSync(worktreesDir);
        } catch {
          // Directory may already be gone.
        }

        for (const entry of entries) {
          const fullPath = `${worktreesDir}/${entry}`;
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

          const orphanBranch = getForemanBranchName(entry);
          try {
            const delResult = await vcs.deleteBranch(projectPath, orphanBranch, { force: true });
            if (delResult.deleted) {
              branchesDeleted++;
              console.log(`    ${chalk.yellow("delete")} orphan branch ${orphanBranch}`);
            }
          } catch {
            // Branch may not exist.
          }
        }
      }
    }

    if (!dryRun) {
      const staleEntries = mergeQueue.list().filter(
        (entry) => entry.status === "conflict" || entry.status === "failed",
      );
      for (const entry of staleEntries) {
        mergeQueue.remove(entry.id);
        mqEntriesRemoved++;
      }
      if (staleEntries.length > 0) {
        console.log(`  ${chalk.yellow("purged")} ${staleEntries.length} stale merge queue entry(ies)`);
      }
    }

    console.log(chalk.bold("\nChecking for bead/run state mismatches..."));
    const mismatchResult = await detectAndFixMismatchesFn(store, seeds, project.id, seedIds, { dryRun });

    if (mismatchResult.mismatches.length > 0) {
      for (const mismatch of mismatchResult.mismatches) {
        const action = dryRun
          ? chalk.yellow("(would fix)")
          : chalk.green("fixed");
        console.log(
          `  ${chalk.yellow("mismatch")} ${chalk.cyan(mismatch.seedId)}: ` +
          `run=${mismatch.runStatus}, bead=${mismatch.actualSeedStatus} → ${mismatch.expectedSeedStatus} ${action}`,
        );
      }
    } else {
      console.log(chalk.dim("  No mismatches found."));
    }

    console.log(chalk.bold("\nChecking for stale / already-merged review branches..."));
    const staleResult = await detectAndHandleStaleBranchesFn(
      store,
      seeds,
      mergeQueue,
      projectPath,
      project.id,
      seedIds,
      { dryRun },
    );

    for (const result of staleResult.results) {
      if (result.action === "skip") continue;
      if (result.action === "error") {
        console.log(`  ${chalk.red("error")} ${chalk.cyan(result.seedId)}: ${result.error ?? result.reason}`);
      } else if (result.action === "close") {
        console.log(
          `  ${dryRun ? chalk.yellow("(would close)") : chalk.green("close")} ` +
          `bead ${chalk.cyan(result.seedId)} — ${result.reason}`,
        );
      } else {
        console.log(
          `  ${dryRun ? chalk.yellow("(would reset)") : chalk.yellow("reset")} ` +
          `bead ${chalk.cyan(result.seedId)} → open — ${result.reason}`,
        );
      }
    }

    if (staleResult.results.filter((result) => result.action !== "skip" && result.action !== "error").length === 0) {
      console.log(chalk.dim("  No stale review branches found."));
    }

    const meaningfulResetWork = dryRun
      ? runs.length > 0 || mismatchResult.mismatches.length > 0 || staleResult.closed > 0 || staleResult.reset > 0
      : killed > 0 ||
        worktreesRemoved > 0 ||
        branchesDeleted > 0 ||
        runsMarkedReset > 0 ||
        mqEntriesRemoved > 0 ||
        seedsReset > 0 ||
        mismatchResult.fixed > 0 ||
        staleResult.closed > 0 ||
        staleResult.reset > 0;

    console.log(chalk.bold("\nSummary:"));
    if (dryRun) {
      if (meaningfulResetWork) {
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
        console.log(chalk.dim("  No resettable runs or bead drift found."));
      }
    } else {
      console.log(`  Processes killed:      ${killed}`);
      console.log(`  Worktrees removed:     ${worktreesRemoved}`);
      console.log(`  Branches deleted:      ${branchesDeleted}`);
      console.log(`  Runs marked reset:     ${runsMarkedReset}`);
      console.log(`  MQ entries removed:    ${mqEntriesRemoved}`);
      console.log(`  Beads reset:           ${seedsReset}`);
      console.log(`  Mismatches fixed:      ${mismatchResult.fixed}`);
      console.log(`  Beads closed (merged): ${staleResult.closed}`);
      console.log(`  Beads reset (review):  ${staleResult.reset}`);
      if (!meaningfulResetWork) {
        console.log(chalk.dim("  No resettable runs or bead drift found."));
      }
    }

    let restoreBranchError: string | null = null;
    if (originalBranch) {
      try {
        const currentBranch = await vcs.getCurrentBranch(projectPath);
        if (currentBranch !== originalBranch) {
          await vcs.checkoutBranch(projectPath, originalBranch);
          console.log(chalk.dim(`Restored branch: ${originalBranch}`));
        }
      } catch {
        restoreBranchError = `Warning: could not restore branch '${originalBranch}'. Run: git checkout ${originalBranch}`;
        console.error(chalk.yellow(restoreBranchError));
      }
    }

    const allErrors = [
      ...detectionErrors,
      ...errors,
      ...mismatchResult.errors,
      ...staleResult.errors,
      ...(restoreBranchError ? [restoreBranchError] : []),
    ];

    if (allErrors.length > 0) {
      console.error(chalk.red(`\nErrors (${allErrors.length}):`));
      for (const err of allErrors) {
        console.error(chalk.red(`  ${err}`));
      }
      if (meaningfulResetWork) {
        console.error(chalk.yellow("Reset completed with errors; inspect failures before re-running foreman run."));
      }
      return 1;
    }

    if (meaningfulResetWork) {
      if (dryRun) {
        console.log(chalk.dim("\nRe-run without --dry-run to apply, then use: foreman run"));
      } else {
        console.log(chalk.dim("\nRe-run with: foreman run"));
      }
    }

    return 0;
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(chalk.red(`Error: ${message}`));
    return 1;
  } finally {
    store?.close();
  }
}

export const resetCommand = new Command("reset")
  .description("Reset failed/stuck runs: kill agents, remove worktrees, reset beads to open")
  .option("--bead <id>", "Reset a specific bead by ID (clears all runs for that bead, including stale pending ones)")
  .option("--all", "Reset ALL active runs, not just failed/stuck ones")
  .option("--detect-stuck", "Run stuck detection first, adding newly-detected stuck runs to the reset list")
  .option(
    "--timeout <minutes>",
    "Stuck detection timeout in minutes (used with --detect-stuck)",
    String(PIPELINE_LIMITS.stuckDetectionMinutes),
  )
  .option("--dry-run", "Show what would be reset without doing it")
  .option("--force-reopen-closed", "Allow reopening a bead whose latest authoritative state is already landed/closed")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (opts, cmd) => {
    const exitCode = await resetAction(opts as Record<string, unknown>, cmd);
    if (exitCode !== 0) {
      process.exit(exitCode);
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
