import { Command } from "commander";
import { spawnSync } from "node:child_process";
import chalk from "chalk";

import { SeedsClient } from "../../lib/seeds.js";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { DispatchedTask, ModelSelection } from "../../orchestrator/types.js";
import { watchRunsInk, type WatchResult } from "../watch-ui.js";
import { NotificationServer } from "../../orchestrator/notification-server.js";
import { notificationBus } from "../../orchestrator/notification-bus.js";

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
      const seeds = new SeedsClient(projectPath);
      const store = new ForemanStore();
      const dispatcher = new Dispatcher(seeds, store, projectPath);

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
          const { detached } = await watchRunsInk(store, runIds, { notificationBus });
          if (detached) {
            store.close();
            return;
          }
        }

        store.close();
        return;
      }

      if (dryRun) {
        console.log(chalk.yellow("(dry run — no changes will be made)\n"));
      }

      // Dispatch loop: dispatch a batch, watch until done, then check for more work.
      // Exits when no new tasks are dispatched (all work complete or all remaining blocked).
      let iteration = 0;
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

        // Nothing dispatched — all work is done (or blocked/dry-run)
        if (result.dispatched.length === 0 || dryRun) {
          break;
        }

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
          const runIds = result.dispatched.map((t) => t.runId);
          const { detached } = await watchRunsInk(store, runIds, { notificationBus });
          if (detached) {
            break; // User hit Ctrl+C — exit dispatch loop, agents continue in background
          }
          // After batch completes, loop back to dispatch the next batch
          continue;
        }

        // No-watch mode: dispatch once and exit
        break;
      }

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
