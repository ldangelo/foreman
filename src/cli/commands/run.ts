import { Command } from "commander";
import chalk from "chalk";

import { SeedsClient } from "../../lib/seeds.js";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { ModelSelection } from "../../orchestrator/types.js";
import { watchRunsInk, type WatchResult } from "../watch-ui.js";
import { NotificationServer } from "../../orchestrator/notification-server.js";
import { notificationBus } from "../../orchestrator/notification-bus.js";

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

