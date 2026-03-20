import { Command } from "commander";
import { spawnSync, execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";
import { homedir } from "node:os";
import chalk from "chalk";

import { BeadsRustClient } from "../../lib/beads-rust.js";
import { BvClient } from "../../lib/bv.js";
import type { ITaskClient } from "../../lib/task-client.js";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot, detectDefaultBranch } from "../../lib/git.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { DispatchedTask, ModelSelection } from "../../orchestrator/types.js";
import { watchRunsInk, type WatchResult } from "../watch-ui.js";
import { NotificationServer } from "../../orchestrator/notification-server.js";
import { notificationBus } from "../../orchestrator/notification-bus.js";
import { MergeQueue } from "../../orchestrator/merge-queue.js";
import { Refinery } from "../../orchestrator/refinery.js";
import { SentinelAgent } from "../../orchestrator/sentinel.js";
import { MergeAgent } from "../../orchestrator/merge-agent.js";
import { syncBeadStatusOnStartup } from "../../orchestrator/task-backend-ops.js";
import { mapRunStatusToSeedStatus } from "../../lib/run-status.js";
import { PIPELINE_TIMEOUTS } from "../../lib/config.js";
import { AgentMailClient, DEFAULT_AGENT_MAIL_CONFIG } from "../../orchestrator/agent-mail-client.js";

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

// ── Bead status sync after merge ─────────────────────────────────────

/** Absolute path to the br binary (mirrors task-backend-ops.ts). */
function brPath(): string {
  return join(homedir(), ".local", "bin", "br");
}

/**
 * Immediately sync a bead's status in the br backend after a merge outcome.
 *
 * Fetches the latest run status from SQLite, maps it to the expected bead
 * status via mapRunStatusToSeedStatus(), updates br, then flushes with
 * `br sync --flush-only`.
 *
 * Non-fatal — logs a warning on failure and lets the caller continue.
 */
async function syncBeadStatusAfterMerge(
  store: ForemanStore,
  taskClient: ITaskClient,
  runId: string,
  seedId: string,
  projectPath: string,
): Promise<void> {
  const run = store.getRun(runId);
  if (!run) return;

  const expectedStatus = mapRunStatusToSeedStatus(run.status);
  try {
    await taskClient.update(seedId, { status: expectedStatus });
    execFileSync(brPath(), ["sync", "--flush-only"], {
      stdio: "pipe",
      timeout: PIPELINE_TIMEOUTS.beadClosureMs,
      cwd: projectPath,
    });
  } catch (syncErr: unknown) {
    const msg = syncErr instanceof Error ? syncErr.message : String(syncErr);
    console.warn(`[merge] Warning: Failed to sync bead status for ${seedId}: ${msg}`);
  }
}

// ── Auto-Attach Logic (AT-T028/AT-T029) ──────────────────────────────

/** Options for the autoAttach function */
export interface AutoAttachOpts {
  dispatched: DispatchedTask[];
  store: ForemanStore;
  isTTY: boolean;
  forceAttach: boolean;
  noAttach: boolean;
  seedFilter: string | undefined;
  /** Override retry delay for testing (default: 500ms) */
  retryDelayMs?: number;
}

/**
 * Auto-attach to a tmux session after dispatching a single agent.
 *
 * Conditions for auto-attach (unless forceAttach overrides):
 * 1. stdout is a TTY (or forceAttach is true)
 * 2. only one agent was dispatched (single --seed mode)
 * 3. --no-attach was not set
 *
 * If forceAttach is true with multiple agents, attaches to the first agent.
 *
 * Returns true if an attach was performed, false otherwise.
 */
export async function autoAttach(opts: AutoAttachOpts): Promise<boolean> {
  const { dispatched, store, isTTY, forceAttach, noAttach, seedFilter, retryDelayMs = 500 } = opts;

  // --no-attach always wins
  if (noAttach) return false;

  // Nothing dispatched
  if (dispatched.length === 0) return false;

  // Determine if we should attach
  const shouldAttach = forceAttach || (isTTY && dispatched.length === 1 && seedFilter !== undefined);
  if (!shouldAttach) return false;

  // Pick the target: first dispatched agent
  const target = dispatched[0];

  // Look up the run's tmux_session, with retries for race conditions (AT-T029)
  const maxRetries = 3;
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    const run = store.getRun(target.runId);
    if (run?.tmux_session) {
      console.log(`Auto-attaching to ${run.tmux_session}... (Ctrl+B, D to detach)`);
      spawnSync("tmux", ["attach-session", "-t", run.tmux_session], {
        stdio: "inherit",
      });
      return true;
    }

    // Only retry if forceAttach is set (race condition handling)
    // For normal auto-attach, no tmux_session means tmux is unavailable -- skip silently
    if (!forceAttach) return false;

    // Wait before retrying
    if (attempt < maxRetries - 1) {
      await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
    }
  }

  // All retries exhausted — skip silently
  return false;
}

// ── Auto-Merge Logic ─────────────────────────────────────────────────

/** Options for the autoMerge function. */
export interface AutoMergeOpts {
  store: ForemanStore;
  taskClient: ITaskClient;
  projectPath: string;
  /** Merge target branch. When omitted, auto-detected via detectDefaultBranch(). */
  targetBranch?: string;
}

/**
 * Process the merge queue after a batch of agents completes.
 *
 * Reconciles completed runs into the queue, then drains the pending entries
 * via the Refinery. Non-fatal — errors are logged and the caller continues.
 *
 * Returns a summary of what happened (for logging / testing).
 */
export async function autoMerge(opts: AutoMergeOpts): Promise<{
  merged: number;
  conflicts: number;
  failed: number;
}> {
  const { store, taskClient, projectPath } = opts;
  const targetBranch = opts.targetBranch ?? await detectDefaultBranch(projectPath);

  const project = store.getProjectByPath(projectPath);
  if (!project) {
    // No project registered — skip silently (init not run yet)
    return { merged: 0, conflicts: 0, failed: 0 };
  }

  const execFileAsync = promisify(execFile);
  const mq = new MergeQueue(store.getDb());
  const refinery = new Refinery(store, taskClient, projectPath);

  // Reconcile completed runs into the queue
  await mq.reconcile(store.getDb(), projectPath, execFileAsync);

  let mergedCount = 0;
  let conflictCount = 0;
  let failedCount = 0;

  let entry = mq.dequeue();
  while (entry) {
    const currentEntry = entry;
    try {
      const report = await refinery.mergeCompleted({
        targetBranch,
        runTests: true,
        testCommand: "npm test",
        projectId: project.id,
        seedId: currentEntry.seed_id,
      });

      if (report.merged.length > 0) {
        mq.updateStatus(currentEntry.id, "merged", { completedAt: new Date().toISOString() });
        mergedCount += report.merged.length;
      } else if (report.conflicts.length > 0 || report.prsCreated.length > 0) {
        mq.updateStatus(currentEntry.id, "conflict", { error: "Code conflicts" });
        conflictCount += report.conflicts.length + report.prsCreated.length;
      } else if (report.testFailures.length > 0) {
        mq.updateStatus(currentEntry.id, "failed", { error: "Test failures" });
        failedCount += report.testFailures.length;
      } else {
        mq.updateStatus(currentEntry.id, "failed", { error: "No completed run found" });
        failedCount++;
      }

      // Immediately sync bead status in br so it reflects the merge outcome
      // without waiting for the next foreman startup reconciliation.
      await syncBeadStatusAfterMerge(store, taskClient, currentEntry.run_id, currentEntry.seed_id, projectPath);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      mq.updateStatus(currentEntry.id, "failed", { error: message });
      failedCount++;
      // Sync bead status even when refinery throws (run may have been updated before exception)
      await syncBeadStatusAfterMerge(store, taskClient, currentEntry.run_id, currentEntry.seed_id, projectPath);
    }

    entry = mq.dequeue();
  }

  return { merged: mergedCount, conflicts: conflictCount, failed: failedCount };
}

// ── Run Command ──────────────────────────────────────────────────────

export const runCommand = new Command("run")
  .description("Dispatch ready tasks to agents")
  .option("--max-agents <n>", "Maximum concurrent agents", "5")
  .option("--model <model>", "Force a specific model (claude-opus-4-6, claude-sonnet-4-6, claude-haiku-4-5-20251001)")
  .option("--dry-run", "Show what would be dispatched without doing it")
  .option("--no-watch", "Exit immediately after dispatching (don't monitor agents)")
  .option("--telemetry", "Enable OpenTelemetry tracing on spawned agents (requires OTEL_* env vars)")
  .option("--resume", "Resume stuck/rate-limited runs from a previous dispatch")
  .option("--resume-failed", "Also resume failed runs (not just stuck/rate-limited)")
  .option("--no-pipeline", "Skip the explorer/qa/reviewer pipeline — run as single worker agent")
  .option("--skip-explore", "Skip the explorer phase in the pipeline")
  .option("--skip-review", "Skip the reviewer phase in the pipeline")
  .option("--seed <id>", "Dispatch only this specific seed (must be ready)")
  .option("--attach", "Force auto-attach to tmux session after dispatch")
  .option("--no-attach", "Disable auto-attach to tmux session after dispatch")
  .option("--no-auto-merge", "Disable automatic merge queue processing after each batch")
  .option("--no-auto-dispatch", "Disable automatic dispatch when an agent completes and capacity is available")
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
    const seedFilter = opts.seed as string | undefined;
    const forceAttach = opts.attach === true;
    const noAttach = opts.attach === false;
    const enableAutoMerge = opts.autoMerge !== false;  // --no-auto-merge sets autoMerge to false
    const enableAutoDispatch = opts.autoDispatch !== false; // --no-auto-dispatch sets to false

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
      const projectPath = await getRepoRoot(process.cwd());

      // ── Agent Mail health check ──────────────────────────────────────────────
      // Verify mcp_agent_mail is reachable before dispatching agents.
      // Skipped in dry-run mode since no real work will happen.
      if (!dryRun) {
        const agentMailClient = new AgentMailClient();
        const agentMailRunning = await agentMailClient.healthCheck();
        if (!agentMailRunning) {
          const url = process.env.AGENT_MAIL_URL ?? DEFAULT_AGENT_MAIL_CONFIG.baseUrl;
          const port = url.split(":").pop() ?? "8766";
          console.error(chalk.red("\nError: Agent Mail service is not running.\n"));
          console.error(`  Start it with:  ${chalk.cyan(`mcp_agent_mail serve --port ${port}`)}`);
          console.error(`  Then re-run:    ${chalk.cyan("foreman run")}\n`);
          console.error(chalk.dim(`  Expected URL: ${url}`));
          console.error(chalk.dim(`  Configure via: .foreman/agent-mail.json or AGENT_MAIL_URL env var\n`));
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

      // ── Merge Agent Auto-Start ───────────────────────────────────────────
      // If merge_agent_config.enabled=1 in the DB config, start the merge agent
      // daemon automatically alongside foreman run. The merge agent polls Agent
      // Mail for "branch-ready" messages and triggers Refinery automatically.
      // Non-fatal — if anything fails, log a warning and continue without it.
      let mergeAgentInstance: MergeAgent | null = null;
      if (!dryRun) {
        try {
          const mergeAgentConfig = store.getMergeAgentConfig();
          if (mergeAgentConfig && mergeAgentConfig.enabled === 1) {
            mergeAgentInstance = new MergeAgent(
              projectPath,
              store,
              taskClient,
              mergeAgentConfig.poll_interval_ms,
            );
            mergeAgentInstance.start();
            console.log(
              chalk.dim(
                `[merge-agent] Auto-started (polling every ${mergeAgentConfig.poll_interval_ms / 1000}s)`
              )
            );
          }
        } catch (mergeAgentErr: unknown) {
          const msg = mergeAgentErr instanceof Error ? mergeAgentErr.message : String(mergeAgentErr);
          console.warn(chalk.yellow(`[merge-agent] Failed to auto-start (non-fatal): ${msg}`));
        }
      }

      /** Stop the merge agent daemon if it is running. Non-fatal cleanup helper. */
      const stopMergeAgent = (): void => {
        if (mergeAgentInstance?.isRunning()) {
          mergeAgentInstance.stop();
          console.log(chalk.dim("[merge-agent] Stopped."));
        }
      };

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
              seedId: seedFilter,
              notifyUrl,
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
            stopMergeAgent();
            store.close();
            return;
          }
        }

        stopSentinel();
        stopMergeAgent();
        store.close();
        return;
      }

      if (dryRun) {
        console.log(chalk.yellow("(dry run — no changes will be made)\n"));
      }

      // Dispatch loop: dispatch a batch, watch until done, then check for more work.
      // Exits when no new tasks are dispatched (all work complete or all remaining blocked).
      let iteration = 0;
      // Track whether the user explicitly detached (Ctrl+C). When detached, agents
      // continue running in the background so we skip the final merge drain.
      let userDetached = false;
      // Suppress repeated "No ready beads" log messages — only print once per wait period.
      let waitingForTasksLogged = false;
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
          seedId: seedFilter,
          notifyUrl,
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
            if (enableAutoMerge) {
              console.log(chalk.dim("Auto-merging completed branches..."));
              try {
                const mergeResult = await autoMerge({ store, taskClient, projectPath });
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

        // Tasks were dispatched — reset flag so the "waiting" message reappears
        // if we later enter another no-tasks polling period.
        waitingForTasksLogged = false;

        // AT-T028: Auto-attach to tmux session after dispatch
        await autoAttach({
          dispatched: result.dispatched,
          store,
          isTTY: !!process.stdout.isTTY,
          forceAttach,
          noAttach,
          seedFilter,
        });

        // Watch mode: wait for this batch to finish, then loop to check for more
        if (watch) {
          // Auto-merge completed branches BEFORE blocking on watch
          if (enableAutoMerge) {
            console.log(chalk.dim("Auto-merging completed branches..."));
            try {
              const mergeResult = await autoMerge({ store, taskClient, projectPath });
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
      if (enableAutoMerge && !dryRun && !userDetached) {
        console.log(chalk.dim("Processing remaining merge queue entries..."));
        try {
          const mergeResult = await autoMerge({ store, taskClient, projectPath });
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
      stopMergeAgent();
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
