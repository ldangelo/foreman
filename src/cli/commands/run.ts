import { Command } from "commander";
import chalk from "chalk";

import { BeadsClient } from "../../lib/beads.js";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { RuntimeSelection } from "../../orchestrator/types.js";

export const runCommand = new Command("run")
  .description("Dispatch ready tasks to agents")
  .option("--max-agents <n>", "Maximum concurrent agents", "5")
  .option("--runtime <type>", "Force a specific runtime (claude-code, pi, codex)")
  .option("--dry-run", "Show what would be dispatched without doing it")
  .action(async (opts) => {
    const maxAgents = parseInt(opts.maxAgents, 10);
    const runtime = opts.runtime as RuntimeSelection | undefined;
    const dryRun = opts.dryRun as boolean | undefined;

    try {
      const projectPath = await getRepoRoot(process.cwd());
      const beads = new BeadsClient(projectPath);
      const store = new ForemanStore();
      const dispatcher = new Dispatcher(beads, store, projectPath);

      if (dryRun) {
        console.log(chalk.yellow("(dry run — no changes will be made)\n"));
      }

      const result = await dispatcher.dispatch({
        maxAgents,
        runtime,
        dryRun,
      });

      // Print dispatched tasks
      if (result.dispatched.length > 0) {
        console.log(chalk.green.bold(`Dispatched ${result.dispatched.length} task(s):\n`));
        for (const task of result.dispatched) {
          console.log(`  ${chalk.cyan(task.beadId)} ${task.title}`);
          console.log(`    Runtime:  ${chalk.magenta(task.runtime)}`);
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
          console.log(`  ${chalk.dim(task.beadId)} ${chalk.dim(task.title)} — ${task.reason}`);
        }
        console.log();
      }

      console.log(chalk.bold(`Active agents: ${result.activeAgents}/${maxAgents}`));

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });
