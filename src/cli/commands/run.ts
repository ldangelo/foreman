import { Command } from "commander";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import chalk from "chalk";

import { BeadsRustClient } from "../../lib/beads-rust.js";
import { BvClient } from "../../lib/bv.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import { ForemanStore } from "../../lib/store.js";
import { loadProjectConfig, resolveVcsConfig } from "../../lib/project-config.js";
import { resolveRepoRootProjectPath } from "./project-task-support.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import type { VcsBackend } from "../../lib/vcs/interface.js";
import { extractBranchLabel, normalizeBranchLabel } from "../../lib/branch-label.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { ModelSelection } from "../../orchestrator/types.js";
import { watchRunsInk } from "../watch-ui.js";
import { NotificationServer } from "../../orchestrator/notification-server.js";
import { notificationBus } from "../../orchestrator/notification-bus.js";
import { SentinelAgent } from "../../orchestrator/sentinel.js";
import { syncBeadStatusOnStartup } from "../../orchestrator/task-backend-ops.js";
import { PIPELINE_TIMEOUTS, PIPELINE_LIMITS } from "../../lib/config.js";
import { isPiAvailable } from "../../orchestrator/pi-rpc-spawn-strategy.js";
import { purgeOrphanedWorkerConfigs } from "../../orchestrator/dispatcher.js";
import { autoMerge } from "../../orchestrator/auto-merge.js";
export { autoMerge } from "../../orchestrator/auto-merge.js";
export type { AutoMergeOpts, AutoMergeResult } from "../../orchestrator/auto-merge.js";

// ── Backend Client Factory (TRD-007) ─────────────────────────────────

/**
 * Result returned by createTaskClients.
 * Contains the task client to pass to Dispatcher and an optional BvClient.
 */
export interface TaskClientResult {
  taskClient: ITaskClient;
  bvClient: BvClient | null;
}

/**
 * Instantiate the br task-tracking client(s).
 *
 * TRD-024: sd backend removed. Always returns a BeadsRustClient after verifying
 * the binary exists, plus a BvClient for graph-aware triage.
 *
 * Throws if the br binary cannot be found.
 */
export async function createTaskClients(projectPath: string): Promise<TaskClientResult> {
  const brClient = new BeadsRustClient(projectPath);
  // Verify binary exists before proceeding; throws with a friendly message if not
  await brClient.ensureBrInstalled();
  const bvClient = new BvClient(projectPath);
  return { taskClient: brClient, bvClient };
}

// ── Branch Mismatch Detection ────────────────────────────────────────────────

/**
 * Prompt the user for a yes/no answer via stdin.
 * Returns true for yes (empty input defaults to yes), false for no.
 */
async function promptYesNo(question: string): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise<boolean>((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      const normalised = answer.trim().toLowerCase();
      resolve(normalised === "" || normalised === "y" || normalised === "yes");
    });
  });
}

const FOREMAN_OWNED_BRANCH = "foreman";

export function isIgnorableControllerPath(path: string): boolean {
  return path === ".beads/issues.jsonl"
    || path.startsWith(".omx/")
    || path.startsWith(".foreman/")
    || path.startsWith("SessionLogs/")
    || path === "SESSION_LOG.md"
    || path === "RUN_LOG.md"
    || path.startsWith("storage.sqlite3");
}

function withCommonBinaryPath(): NodeJS.ProcessEnv {
  const home = process.env.HOME ?? "/home/nobody";
  return {
    ...process.env,
    PATH: `${home}/.local/bin:/opt/homebrew/bin:${process.env.PATH ?? ""}`,
  };
}

async function isAnonymousJujutsuRevision(
  vcs: VcsBackend,
  projectPath: string,
  branch: string | undefined,
): Promise<boolean> {
  if (!branch || vcs.name !== "jujutsu" || typeof (vcs as Partial<VcsBackend>).branchExists !== "function") {
    return false;
  }
  return !(await vcs.branchExists(projectPath, branch).catch(() => false));
}

export interface OwnedBranchResolution {
  currentBranch: string;
  defaultBranch: string;
  targetBranch?: string;
  usedOwnedBranch: boolean;
}

export async function resolveOwnedControllerBranch(
  vcs: VcsBackend,
  projectPath: string,
): Promise<OwnedBranchResolution> {
  const maybeVcs = vcs as Partial<VcsBackend>;
  if (
    typeof maybeVcs.getCurrentBranch !== "function" ||
    typeof maybeVcs.detectDefaultBranch !== "function" ||
    typeof maybeVcs.branchExists !== "function" ||
    typeof maybeVcs.getModifiedFiles !== "function" ||
    typeof maybeVcs.getUntrackedFiles !== "function"
  ) {
    return {
      currentBranch: "",
      defaultBranch: "",
      usedOwnedBranch: false,
    };
  }

  const currentBranch = normalizeBranchLabel(await vcs.getCurrentBranch(projectPath)) ?? "";
  const defaultBranch = normalizeBranchLabel(await vcs.detectDefaultBranch(projectPath)) ?? "";
  const currentIsAnonymousRevision = await isAnonymousJujutsuRevision(vcs, projectPath, currentBranch);

  const shouldUseOwnedBranch =
    vcs.name === "jujutsu" &&
    (currentIsAnonymousRevision || currentBranch === defaultBranch);

  if (!shouldUseOwnedBranch) {
    return {
      currentBranch,
      defaultBranch,
      usedOwnedBranch: false,
    };
  }

  const dirtyTracked = (await vcs.getModifiedFiles(projectPath))
    .filter((path) => !isIgnorableControllerPath(path));
  const dirtyUntracked = (await vcs.getUntrackedFiles(projectPath))
    .filter((path) => !isIgnorableControllerPath(path));
  const dirtyPaths = [...dirtyTracked, ...dirtyUntracked];
  if (dirtyPaths.length > 0) {
    throw new Error(
      `Foreman-owned branch requires a clean controller checkout. Dirty paths: ${dirtyPaths.slice(0, 8).join(", ")}`,
    );
  }

  const branchExists = await vcs.branchExists(projectPath, FOREMAN_OWNED_BRANCH).catch(() => false);
  if (!branchExists) {
    execFileSync("jj", ["bookmark", "create", FOREMAN_OWNED_BRANCH, "-r", defaultBranch], {
      cwd: projectPath,
      stdio: "pipe",
      env: withCommonBinaryPath(),
    });
  }

  if (currentBranch !== FOREMAN_OWNED_BRANCH) {
    execFileSync("jj", ["new", FOREMAN_OWNED_BRANCH], {
      cwd: projectPath,
      stdio: "pipe",
      env: withCommonBinaryPath(),
    });
  }

  return {
    currentBranch: FOREMAN_OWNED_BRANCH,
    defaultBranch,
    targetBranch: defaultBranch,
    usedOwnedBranch: true,
  };
}

/**
 * Check whether any in-progress beads have a `branch:` label that differs
 * from the current git branch.
 *
 * Edge cases handled:
 * - No in-progress beads: no prompt, return false (continue normally)
 * - Label matches current branch: no prompt, return false (continue normally)
 * - No branch: label on bead: no prompt, return false (backward compat)
 * - Label differs: show prompt, switch branch (return false) or exit (return true)
 *
 * Returns true if the caller should abort (user declined to switch).
 */
async function createRunVcsBackend(projectPath: string): Promise<VcsBackend> {
  const projectCfg = loadProjectConfig(projectPath);
  const vcsConfig = resolveVcsConfig(undefined, projectCfg?.vcs);
  return VcsBackendFactory.create(vcsConfig, projectPath);
}

export async function checkBranchMismatch(
  taskClient: ITaskClient,
  projectPath: string,
): Promise<boolean> {
  let vcs: VcsBackend;
  try {
    vcs = await createRunVcsBackend(projectPath);
  } catch {
    // Cannot determine VCS backend — skip mismatch check
    return false;
  }

  let currentBranch: string;
  try {
    currentBranch = normalizeBranchLabel(await vcs.getCurrentBranch(projectPath)) ?? "";
  } catch {
    // Cannot determine current branch — skip mismatch check
    return false;
  }

  let inProgressBeads: Issue[];
  try {
    inProgressBeads = await taskClient.list({ status: "in_progress" });
  } catch {
    // Cannot list in-progress beads — skip mismatch check
    return false;
  }

  if (inProgressBeads.length === 0) return false;

  // Group mismatched beads by target branch
  const mismatchByBranch = new Map<string, string[]>();
  for (const bead of inProgressBeads) {
    try {
      const detail = await taskClient.show(bead.id) as unknown as { labels?: string[] };
      const targetBranch = normalizeBranchLabel(extractBranchLabel(detail.labels));
      if (targetBranch && targetBranch !== currentBranch) {
        const ids = mismatchByBranch.get(targetBranch) ?? [];
        ids.push(bead.id);
        mismatchByBranch.set(targetBranch, ids);
      }
    } catch {
      // Non-fatal: skip this bead if detail fetch fails
    }
  }

  if (mismatchByBranch.size === 0) return false;

  // For each unique target branch, prompt the user to switch
  for (const [targetBranch, beadIds] of mismatchByBranch) {
    const beadList = beadIds.join(", ");
    const question = chalk.yellow(
      `\nBeads ${chalk.cyan(beadList)} target branch ${chalk.green(targetBranch)} ` +
      `but you are on ${chalk.red(currentBranch)}.\n` +
      `Switch to ${chalk.green(targetBranch)} to continue? [Y/n] `,
    );

    const shouldSwitch = await promptYesNo(question);
    if (shouldSwitch) {
      try {
        await vcs.checkoutBranch(projectPath, targetBranch);
        console.log(chalk.green(`Switched to branch ${targetBranch}.`));
        currentBranch = targetBranch;
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(chalk.red(`Failed to switch to branch ${targetBranch}: ${msg}`));
        console.error(chalk.dim(`Run 'git checkout ${targetBranch}' manually and re-run foreman.`));
        return true; // abort
      }
    } else {
      console.log(
        chalk.yellow(`Skipping beads ${beadList} — they target ${targetBranch}.`) +
        chalk.dim(` Run 'git checkout ${targetBranch}' and re-run foreman to continue those beads.`),
      );
      return true; // abort — user said no
    }
  }

  return false;
}

// ── Run Command ──────────────────────────────────────────────────────

export const runCommand = new Command("run")
  .description("Dispatch ready tasks to agents")
  .option("--max-agents <n>", "Maximum concurrent agents", "5")
  .option("--model <model>", "Force a specific model (overrides FOREMAN_DEFAULT_MODEL)")
  .option("--dry-run", "Show what would be dispatched without doing it")
  .option("--no-watch", "Exit immediately after dispatching (don't monitor agents)")
  .option("--telemetry", "Enable OpenTelemetry tracing on spawned agents (requires OTEL_* env vars)")
  .option("--resume", "Resume stuck/rate-limited runs from a previous dispatch")
  .option("--resume-failed", "Also resume failed runs (not just stuck/rate-limited)")
  .option("--no-pipeline", "Skip the explorer/qa/reviewer pipeline — run as single worker agent")
  .option("--skip-explore", "Skip the explorer phase in the pipeline")
  .option("--skip-review", "Skip the reviewer phase in the pipeline")
  .option("--bead <id>", "Dispatch only this specific bead (must be ready)")
  .option("--no-auto-dispatch", "Disable automatic dispatch when an agent completes and capacity is available")
  .option("--stagger <duration>", "Stagger delay between dispatches to prevent thundering herd (e.g. '30s', '1m')")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (opts) => {
    const maxAgents = parseInt(opts.maxAgents, 10);
    const model = opts.model as ModelSelection | undefined;
    const dryRun = opts.dryRun as boolean | undefined;
    const resume = opts.resume as boolean | undefined;
    const resumeFailed = opts.resumeFailed as boolean | undefined;
    const watch = opts.watch as boolean;
    const telemetry = opts.telemetry as boolean | undefined;
    const pipeline = opts.pipeline as boolean;  // --no-pipeline sets to false
    const skipExplore = opts.skipExplore as boolean | undefined;
    const skipReview = opts.skipReview as boolean | undefined;
    const beadFilter = opts.bead as string | undefined;
    const enableAutoDispatch = opts.autoDispatch !== false; // --no-auto-dispatch sets to false

    // P1: Parse stagger delay for preventing thundering herd on Haiku quotas
    // Accept formats like "30s", "1m", "2m30s"
    let staggerMs: number | undefined;
    if (opts.stagger) {
      const match = opts.stagger.match(/^(\d+)([smh])/);
      if (match) {
        const value = parseInt(match[1], 10);
        const unit = match[2];
        staggerMs = unit === "s" ? value * 1000 : unit === "m" ? value * 60 * 1000 : value * 60 * 60 * 1000;
      } else {
        console.warn(chalk.yellow(`[foreman] Warning: invalid --stagger value "${opts.stagger}", ignoring (use formats like "30s", "1m")`));
      }
    }

    // Start notification server so workers can POST status updates immediately
    // instead of waiting for the next poll cycle. Stopped in the finally block.
    //
    // NOTE: The `monitor` command (src/orchestrator/monitor.ts) is NOT wired to
    // notificationBus yet — it still uses its own polling-only loop. Wiring it
    // would speed up stuck detection but requires refactoring monitor's external
    // API. Deferred to a follow-up task.
    const notifyServer = new NotificationServer(notificationBus);
    let notifyUrl: string | undefined;
    try {
      await notifyServer.start();
      notifyUrl = notifyServer.url;
    } catch {
      // Non-fatal — notification server is an enhancement; polling still works
      notifyUrl = undefined;
    }

    try {
      const projectPath = await resolveRepoRootProjectPath(opts);
      const startupVcs = await createRunVcsBackend(projectPath);

      // ── Pi Extensions check ──────────────────────────────────────────────────
      // If Pi is available, the extensions package must be built before dispatch.
      // Skipped in dry-run mode since no real agent work will happen.
      if (!dryRun && isPiAvailable()) {
        const extDist = join(projectPath, "packages/foreman-pi-extensions/dist/index.js");
        if (!existsSync(extDist)) {
          console.error(chalk.red("\nError: Pi extensions package has not been built.\n"));
          console.error(`  Build it with:  ${chalk.cyan("npm run build")}`);
          console.error(`  Expected:       ${chalk.dim(extDist)}\n`);
          process.exit(1);
        }
      }

      let taskClient: ITaskClient;
      let bvClient: BvClient | null = null;
      try {
        const clients = await createTaskClients(projectPath);
        taskClient = clients.taskClient;
        bvClient = clients.bvClient;
      } catch (clientErr: unknown) {
        const message = clientErr instanceof Error ? clientErr.message : String(clientErr);
        console.error(chalk.red(`Error initialising task backend: ${message}`));
        process.exit(1);
      }
      const store = ForemanStore.forProject(projectPath);
      const project = store.getProjectByPath(projectPath);
      const dispatcher = new Dispatcher(taskClient, store, projectPath, bvClient);

      // ── Sentinel Auto-Start ──────────────────────────────────────────────
      // If sentinel.enabled=1 in the DB config, start the sentinel agent
      // automatically alongside foreman run. Non-fatal — if anything fails,
      // log a warning and continue without sentinel.
      let sentinelAgent: SentinelAgent | null = null;
      if (!dryRun) {
        try {
          if (project) {
            const sentinelConfig = store.getSentinelConfig(project.id);
            if (sentinelConfig && sentinelConfig.enabled === 1) {
              const brClient = new BeadsRustClient(projectPath);
              sentinelAgent = new SentinelAgent(store, brClient, project.id, projectPath);
              sentinelAgent.start(
                {
                  branch: sentinelConfig.branch,
                  testCommand: sentinelConfig.test_command,
                  intervalMinutes: sentinelConfig.interval_minutes,
                  failureThreshold: sentinelConfig.failure_threshold,
                },
                (result) => {
                  const now = new Date().toLocaleTimeString();
                  const icon = result.status === "passed" ? chalk.green("✓") : chalk.red("✗");
                  const statusLabel =
                    result.status === "passed"
                      ? chalk.green("PASS")
                      : result.status === "failed"
                        ? chalk.red("FAIL")
                        : chalk.yellow("ERR");
                  const dur = `${(result.durationMs / 1000).toFixed(1)}s`;
                  const hash = result.commitHash ? chalk.dim(` [${result.commitHash.slice(0, 8)}]`) : "";
                  console.log(`[sentinel ${now}] ${icon} ${statusLabel} ${dur}${hash}`);
                },
              );
              console.log(
                chalk.dim(
                  `[sentinel] Auto-started on branch ${sentinelConfig.branch} (every ${sentinelConfig.interval_minutes}m)`
                )
              );
            }
          }
        } catch (sentinelErr: unknown) {
          const msg = sentinelErr instanceof Error ? sentinelErr.message : String(sentinelErr);
          console.warn(chalk.yellow(`[sentinel] Failed to auto-start (non-fatal): ${msg}`));
        }
      }

      /** Stop the sentinel agent if it is running. Non-fatal cleanup helper. */
      const stopSentinel = (): void => {
        if (sentinelAgent?.isRunning()) {
          sentinelAgent.stop();
          console.log(chalk.dim("[sentinel] Stopped."));
        }
      };

      // ── Startup worker config file cleanup ──────────────────────────────────
      // Delete orphaned worker-{runId}.json files in ~/.foreman/tmp/ that were
      // never consumed by a worker (e.g. because the run was killed externally).
      // Non-fatal — stale files waste disk space but do not affect correctness.
      if (!dryRun) {
        try {
          const purged = await purgeOrphanedWorkerConfigs(store);
          if (purged > 0) {
            console.log(chalk.dim(`[startup] Purged ${purged} orphaned worker config file(s).`));
          }
        } catch {
          // Non-fatal — ignore cleanup errors
        }
      }

      // ── Startup Bead Sync ────────────────────────────────────────────────
      // Reconcile br seed statuses against SQLite run statuses before dispatching.
      // Fixes drift caused by interrupted foreman sessions. Non-fatal.
      if (!dryRun && project) {
        try {
          const syncResult = await syncBeadStatusOnStartup(store, taskClient, project.id, { projectPath });
          if (syncResult.synced > 0 || syncResult.mismatches.length > 0) {
            console.log(
              chalk.dim(
                `[startup] Reconciled ${syncResult.synced} bead(s), ` +
                `${syncResult.mismatches.length} mismatch(es) detected`
              )
            );
          }
          for (const err of syncResult.errors) {
            console.warn(chalk.yellow(`[startup] Sync warning: ${err}`));
          }
        } catch (syncErr: unknown) {
          const msg = syncErr instanceof Error ? syncErr.message : String(syncErr);
          console.warn(chalk.yellow(`[startup] Bead sync failed (non-fatal): ${msg}`));
        }
      }

      // ── Branch mismatch check ───────────────────────────────────────────────
      // Before dispatching, check if any in-progress beads target a different
      // branch than the current one. If so, prompt the user to switch branches.
      // Skip in dry-run mode since no actual dispatch happens.
      if (!dryRun && !resume && !resumeFailed) {
        const shouldAbort = await checkBranchMismatch(taskClient, projectPath);
        if (shouldAbort) {
          stopSentinel();
          store.close();
          await notifyServer.stop().catch(() => { /* ignore */ });
          process.exit(1);
        }
      }

      // ── Target branch confirmation ──────────────────────────────────────────
      // When the current branch differs from the detected default branch (e.g.
      // working on a feature branch instead of dev/main), confirm with the user
      // that agent worktrees and merges should target the current branch.
      // The confirmed targetBranch is threaded through to autoMerge and workers.
      let targetBranch: string | undefined;
      if (!dryRun) {
        try {
          const controller = await resolveOwnedControllerBranch(startupVcs, projectPath);
          if (controller.usedOwnedBranch) {
            targetBranch = controller.targetBranch;
            console.log(
              chalk.dim(
                `[startup] Using Foreman-owned branch ${FOREMAN_OWNED_BRANCH} (target: ${controller.defaultBranch})`,
              ),
            );
          }
          const cb = targetBranch ? undefined : normalizeBranchLabel(await startupVcs.getCurrentBranch(projectPath));
          const db = targetBranch ? undefined : normalizeBranchLabel(await startupVcs.detectDefaultBranch(projectPath));
          if (cb && db && cb !== db) {
            const question = chalk.yellow(
              `\nYou are on branch ${chalk.green(cb)}, ` +
              `which differs from the default branch ${chalk.cyan(db)}.\n` +
              `Agent work will be branched from and merged into ${chalk.green(cb)}.\n` +
              `Continue? [Y/n] `,
            );
            const confirmed = await promptYesNo(question);
            if (!confirmed) {
              console.log(
                chalk.dim(`Aborted. Switch to ${db} or the desired target branch and re-run.`),
              );
              stopSentinel();
              store.close();
              await notifyServer.stop().catch(() => { /* ignore */ });
              process.exit(1);
            }
            targetBranch = cb;
            console.log(chalk.green(`Target branch: ${cb}`));
          }
        } catch {
          // Non-fatal: if branch detection fails, fall back to default behavior
        }
      }

      /**
       * Build the auto-dispatch callback passed to watchRunsInk.
       * Called when an agent completes mid-watch and capacity may be available.
       * Returns IDs of newly dispatched runs to add to the watch list.
       */
      const makeAutoDispatchFn = (!dryRun && watch && enableAutoDispatch)
        ? async (): Promise<string[]> => {
            const newResult = await dispatcher.dispatch({
              maxAgents,
              model,
              dryRun,
              telemetry,
              pipeline,
              skipExplore,
              skipReview,
              seedId: beadFilter,
              notifyUrl,
              targetBranch,
              staggerMs,
            });
            return newResult.dispatched.map((t) => t.runId);
          }
        : undefined;

      // Resume mode: pick up stuck/failed runs from a previous dispatch
      if (resume || resumeFailed) {
        const statuses: Array<"stuck" | "failed"> = resumeFailed
          ? ["stuck", "failed"]
          : ["stuck"];

        const result = await dispatcher.resumeRuns({
          maxAgents,
          model,
          telemetry,
          statuses,
          notifyUrl,
        });

        if (result.resumed.length > 0) {
          console.log(chalk.green.bold(`Resumed ${result.resumed.length} agent(s):\n`));
          for (const task of result.resumed) {
            console.log(`  ${chalk.cyan(task.seedId)} (was ${chalk.yellow(task.previousStatus)})`);
            console.log(`    Model:    ${chalk.magenta(task.model)}`);
            console.log(`    Session:  ${chalk.dim(task.sessionId)}`);
            console.log(`    Run ID:   ${task.runId}`);
            console.log();
          }
        } else {
          console.log(chalk.yellow("No runs to resume."));
        }

        if (result.skipped.length > 0) {
          console.log(chalk.dim(`Skipped ${result.skipped.length} run(s):`));
          for (const task of result.skipped) {
            console.log(`  ${chalk.dim(task.seedId)} — ${task.reason}`);
          }
          console.log();
        }

        console.log(chalk.bold(`Active agents: ${result.activeAgents}/${maxAgents}`));

        if (watch && result.resumed.length > 0) {
          const runIds = result.resumed.map((t) => t.runId);
          // Resume mode is a one-shot recovery action — no continuous auto-dispatch needed.
          const { detached } = await watchRunsInk(store, runIds, { notificationBus });
          if (detached) {
            stopSentinel();
            store.close();
            return;
          }
        }

        stopSentinel();
        store.close();
        return;
      }

      if (dryRun) {
        console.log(chalk.yellow("(dry run — no changes will be made)\n"));
      }

      // ── Startup merge drain ─────────────────────────────────────────────────
      // Drain any completed-but-unmerged runs from previous interrupted sessions
      // BEFORE dispatching new work. Non-fatal. Merge is always-on — the
      // MergeAgentDaemon runs continuously alongside sentinel, and per-dispatch
      // drains here provide an additional safety net.
      if (!dryRun && project) {
        try {
          const startupMerge = await autoMerge({ store, taskClient, projectPath, targetBranch });
          if (startupMerge.merged > 0) {
            console.log(chalk.green(`[startup] Merged ${startupMerge.merged} previously completed branch(es).`));
          }
        } catch (startupMergeErr: unknown) {
          const msg = startupMergeErr instanceof Error ? startupMergeErr.message : String(startupMergeErr);
          console.warn(chalk.yellow(`[startup] Merge drain error (non-fatal): ${msg}`));
        }
      }

      // Dispatch loop: dispatch a batch, watch until done, then check for more work.
      // Exits when no new tasks are dispatched (all work complete or all remaining blocked).
      let iteration = 0;
      // Track whether the user explicitly detached (Ctrl+C). When detached, agents
      // continue running in the background so we skip the final merge drain.
      let userDetached = false;
      // Suppress repeated "No ready beads" log messages — only print once per wait period.
      let waitingForTasksLogged = false;
      // Count consecutive poll cycles with nothing dispatched and no active agents.
      // When this reaches PIPELINE_LIMITS.emptyPollCycles the loop exits gracefully.
      let emptyPollCount = 0;
      while (true) {
        iteration++;
        if (iteration > 1) {
          console.log(chalk.bold(`\n── Batch ${iteration} ──────────────────────────────────\n`));
        }

        const result = await dispatcher.dispatch({
          maxAgents,
          model,
          dryRun,
          telemetry,
          pipeline,
          skipExplore,
          skipReview,
          seedId: beadFilter,
          notifyUrl,
          targetBranch,
          staggerMs,
        });

        // Print dispatched tasks
        if (result.dispatched.length > 0) {
          console.log(chalk.green.bold(`Dispatched ${result.dispatched.length} task(s):\n`));
          for (const task of result.dispatched) {
            console.log(`  ${chalk.cyan(task.seedId)} ${task.title}`);
            console.log(`    Model:    ${chalk.magenta(task.model)}`);
            console.log(`    Branch:   ${task.branchName}`);
            console.log(`    Worktree: ${task.worktreePath}`);
            console.log(`    Run ID:   ${task.runId}`);
            console.log();
          }
        } else {
          console.log(chalk.yellow("No tasks dispatched."));
        }

        // Print skipped tasks
        if (result.skipped.length > 0) {
          console.log(chalk.dim(`Skipped ${result.skipped.length} task(s):`));
          for (const task of result.skipped) {
            console.log(`  ${chalk.dim(task.seedId)} ${chalk.dim(task.title)} — ${task.reason}`);
          }
          console.log();
        }

        console.log(chalk.bold(`Active agents: ${result.activeAgents}/${maxAgents}`));

        // dry-run: always exit immediately
        if (dryRun) {
          break;
        }

        // Nothing new dispatched in this iteration
        if (result.dispatched.length === 0) {
          // If agents are still running AND watch mode is on, wait for them to
          // finish — they may unblock previously-blocked tasks when they complete.
          if (watch && result.activeAgents > 0) {
            waitingForTasksLogged = false; // Reset: leaving "no tasks" wait state
            console.log(
              chalk.dim(
                `No new tasks dispatched — waiting for ${result.activeAgents} active agent(s) to finish…`
              )
            );
            const activeRuns = store.getActiveRuns();
            const runIds = activeRuns.map((r) => r.id);
            // Auto-merge completed branches BEFORE blocking on watch
            {
              console.log(chalk.dim("Auto-merging completed branches..."));
              try {
                const mergeResult = await autoMerge({ store, taskClient, projectPath, targetBranch });
                if (mergeResult.merged > 0) {
                  console.log(chalk.green(`  Auto-merged ${mergeResult.merged} branch(es).`));
                }
                if (mergeResult.conflicts > 0) {
                  console.log(chalk.yellow(`  ${mergeResult.conflicts} conflict(s) — run 'foreman merge' to resolve.`));
                }
                if (mergeResult.failed > 0) {
                  console.log(chalk.dim(`  ${mergeResult.failed} merge(s) failed — run 'foreman merge' for details.`));
                }
              } catch (mergeErr: unknown) {
                const msg = mergeErr instanceof Error ? mergeErr.message : String(mergeErr);
                console.error(chalk.yellow(`  Auto-merge error (non-fatal): ${msg}`));
              }
            }
            if (runIds.length > 0) {
              const { detached } = await watchRunsInk(store, runIds, { notificationBus, ...(makeAutoDispatchFn ? { autoDispatch: makeAutoDispatchFn } : {}) });
              if (detached) {
                userDetached = true;
                break; // User hit Ctrl+C — exit dispatch loop, agents continue in background
              }
            }
            // Agents finished — loop back and check for newly-unblocked tasks
            continue;
          }
          // Watch mode with no active agents: poll for new tasks to become ready
          if (watch) {
            emptyPollCount++;
            // Check cycle limit (0 = disabled / legacy infinite-poll behaviour)
            if (
              PIPELINE_LIMITS.emptyPollCycles > 0 &&
              emptyPollCount >= PIPELINE_LIMITS.emptyPollCycles
            ) {
              const elapsedSec = Math.round(
                (emptyPollCount * PIPELINE_TIMEOUTS.monitorPollMs) / 1000
              );
              console.log(
                chalk.yellow(
                  `\nNo ready beads after ${emptyPollCount} poll cycle(s) (~${elapsedSec}s). Exiting dispatch loop.`
                )
              );
              console.log(
                chalk.dim(
                  "  • Re-run 'foreman run' once tasks become unblocked\n" +
                  "  • Use 'br ready' to see which tasks are ready\n" +
                  "  • Use 'foreman status' to check for stuck agents\n" +
                  "  • Set FOREMAN_EMPTY_POLL_CYCLES=0 to disable this limit"
                )
              );
              break;
            }
            if (!waitingForTasksLogged) {
              console.log(
                chalk.dim(
                  `No ready beads — waiting for tasks to become available…`
                )
              );
              waitingForTasksLogged = true;
            }
            await new Promise<void>((resolve) =>
              setTimeout(resolve, PIPELINE_TIMEOUTS.monitorPollMs)
            );
            continue;
          }
          // No active agents and --no-watch: nothing left to do
          break;
        }

        // Tasks were dispatched — reset counters so the "waiting" message and
        // the empty-poll limit restart from zero when we next enter a dry spell.
        waitingForTasksLogged = false;
        emptyPollCount = 0;

        // Watch mode: wait for this batch to finish, then loop to check for more
        if (watch) {
          // Auto-merge completed branches BEFORE blocking on watch
          {
            console.log(chalk.dim("Auto-merging completed branches..."));
            try {
              const mergeResult = await autoMerge({ store, taskClient, projectPath, targetBranch });
              if (mergeResult.merged > 0) {
                console.log(chalk.green(`  Auto-merged ${mergeResult.merged} branch(es).`));
              }
              if (mergeResult.conflicts > 0) {
                console.log(chalk.yellow(`  ${mergeResult.conflicts} conflict(s) — run 'foreman merge' to resolve.`));
              }
              if (mergeResult.failed > 0) {
                console.log(chalk.dim(`  ${mergeResult.failed} merge(s) failed — run 'foreman merge' for details.`));
              }
            } catch (mergeErr: unknown) {
              const msg = mergeErr instanceof Error ? mergeErr.message : String(mergeErr);
              console.error(chalk.yellow(`  Auto-merge error (non-fatal): ${msg}`));
            }
          }
          const runIds = result.dispatched.map((t) => t.runId);
          const { detached } = await watchRunsInk(store, runIds, { notificationBus, ...(makeAutoDispatchFn ? { autoDispatch: makeAutoDispatchFn } : {}) });
          if (detached) {
            userDetached = true;
            break; // User hit Ctrl+C — exit dispatch loop, agents continue in background
          }
          // After batch completes, loop back to dispatch the next batch
          continue;
        }

        // No-watch mode: dispatch once and exit
        break;
      }

      // ── Final merge drain ───────────────────────────────────────────────────
      // After the dispatch loop exits, process any merge queue entries that
      // accumulated while agents were running. This covers two scenarios:
      //   1. Race window: an agent completed after the last in-loop autoMerge call
      //      but before the loop exit, leaving an entry in the queue.
      //   2. No-watch mode: autoMerge was never called during the loop, but
      //      previously-completed agents may have pending queue entries.
      //
      // Skipped when the user detached (Ctrl+C) — agents are still running in
      // the background and the user did not intend to block on merging.
      if (!dryRun && !userDetached) {
        console.log(chalk.dim("Processing remaining merge queue entries..."));
        try {
          const mergeResult = await autoMerge({ store, taskClient, projectPath, targetBranch });
          if (mergeResult.merged > 0 || mergeResult.conflicts > 0 || mergeResult.failed > 0) {
            if (mergeResult.merged > 0) {
              console.log(chalk.green(`  Auto-merged ${mergeResult.merged} branch(es).`));
            }
            if (mergeResult.conflicts > 0) {
              console.log(chalk.yellow(`  ${mergeResult.conflicts} conflict(s) — run 'foreman merge' to resolve.`));
            }
            if (mergeResult.failed > 0) {
              console.log(chalk.dim(`  ${mergeResult.failed} merge(s) failed — run 'foreman merge' for details.`));
            }
          }
        } catch (mergeErr: unknown) {
          const msg = mergeErr instanceof Error ? mergeErr.message : String(mergeErr);
          console.error(chalk.yellow(`  Auto-merge error (non-fatal): ${msg}`));
        }
      }

      stopSentinel();
      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    } finally {
      // Stop the notification server regardless of how the command exits
      await notifyServer.stop().catch(() => { /* ignore cleanup errors */ });
    }
  });
