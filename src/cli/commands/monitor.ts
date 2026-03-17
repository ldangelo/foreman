import { Command } from "commander";
import chalk from "chalk";

import { BeadsRustClient } from "../../lib/beads-rust.js";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { Monitor } from "../../orchestrator/monitor.js";

export const monitorCommand = new Command("monitor")
  .description("Check agent progress and detect stuck runs")
  .option("--recover", "Auto-recover stuck agents")
  .option("--timeout <minutes>", "Stuck detection timeout in minutes", "15")
  .action(async (opts) => {
    const timeoutMinutes = parseInt(opts.timeout, 10);

    try {
      const projectPath = await getRepoRoot(process.cwd());
      const seeds = new BeadsRustClient(projectPath);
      const store = ForemanStore.forProject(projectPath);
      const monitor = new Monitor(store, seeds, projectPath);

      console.log(chalk.bold("Checking agent status...\n"));

      const report = await monitor.checkAll({
        stuckTimeoutMinutes: timeoutMinutes,
      });

      // Active
      if (report.active.length > 0) {
        console.log(chalk.green.bold(`Active (${report.active.length}):`));
        for (const run of report.active) {
          const elapsed = run.started_at
            ? Math.round((Date.now() - new Date(run.started_at).getTime()) / 60000)
            : 0;
          console.log(
            `  ${chalk.cyan(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)} ${elapsed}m`,
          );
        }
        console.log();
      }

      // Completed
      if (report.completed.length > 0) {
        console.log(chalk.cyan.bold(`Completed (${report.completed.length}):`));
        for (const run of report.completed) {
          console.log(`  ${chalk.cyan(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)}`);
        }
        console.log();
      }

      // Stuck
      if (report.stuck.length > 0) {
        console.log(chalk.yellow.bold(`Stuck (${report.stuck.length}):`));
        for (const run of report.stuck) {
          const elapsed = run.started_at
            ? Math.round((Date.now() - new Date(run.started_at).getTime()) / 60000)
            : 0;
          console.log(
            `  ${chalk.yellow(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)} ${elapsed}m`,
          );
        }
        console.log();

        // Auto-recover if requested
        if (opts.recover) {
          console.log(chalk.bold("Recovering stuck agents...\n"));
          for (const run of report.stuck) {
            const recovered = await monitor.recoverStuck(run);
            if (recovered) {
              console.log(`  ${chalk.green("✓")} ${run.seed_id} — re-queued as pending`);
            } else {
              console.log(`  ${chalk.red("✗")} ${run.seed_id} — max retries exceeded, marked failed`);
            }
          }
          console.log();
        } else {
          console.log(chalk.dim("  Use --recover to auto-recover stuck agents\n"));
        }
      }

      // Failed
      if (report.failed.length > 0) {
        console.log(chalk.red.bold(`Failed (${report.failed.length}):`));
        for (const run of report.failed) {
          console.log(`  ${chalk.red(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)}`);
        }
        console.log();
      }

      const total =
        report.active.length +
        report.completed.length +
        report.stuck.length +
        report.failed.length;

      if (total === 0) {
        console.log(chalk.dim("No active runs found."));
      }

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });
