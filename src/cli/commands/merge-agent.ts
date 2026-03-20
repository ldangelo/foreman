// foreman merge-agent start|stop|status

import { Command } from "commander";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import chalk from "chalk";

export function createMergeAgentCommand(store: ForemanStore, projectId: string): Command {
  const cmd = new Command("merge-agent")
    .description("Manage the merge agent daemon");

  cmd
    .command("start")
    .description("Start the merge agent daemon")
    .option("--interval <seconds>", "Polling interval in seconds", "30")
    .action((opts) => {
      const config = store.upsertMergeAgentConfig(projectId, {
        enabled: 1,
        interval_seconds: Number(opts.interval),
      });
      console.log(chalk.green(`Merge agent configured (interval=${config.interval_seconds}s)`));
      console.log(chalk.dim("Run `foreman run` to start the daemon"));
    });

  cmd
    .command("stop")
    .description("Stop the merge agent daemon")
    .action(() => {
      store.upsertMergeAgentConfig(projectId, { enabled: 0, pid: null });
      console.log(chalk.yellow("Merge agent disabled"));
    });

  cmd
    .command("status")
    .description("Show merge agent status")
    .action(() => {
      const config = store.getMergeAgentConfig(projectId);
      if (!config) {
        console.log(chalk.dim("Merge agent not configured. Run `foreman merge-agent start`."));
        return;
      }
      const status = config.enabled ? chalk.green("enabled") : chalk.red("disabled");
      const pidInfo = config.pid ? chalk.dim(`pid=${config.pid}`) : chalk.dim("not running");
      console.log(`Merge agent: ${status} | ${pidInfo} | interval=${config.interval_seconds}s`);
    });

  return cmd;
}

/**
 * Pre-built merge-agent command that self-resolves store and projectId.
 * Registered directly in the CLI program.
 */
export const mergeAgentCommand = new Command("merge-agent")
  .description("Manage the merge agent daemon");

mergeAgentCommand
  .command("start")
  .description("Start the merge agent daemon")
  .option("--interval <seconds>", "Polling interval in seconds", "30")
  .action(async (opts) => {
    try {
      const projectPath = await getRepoRoot(process.cwd());
      const store = ForemanStore.forProject(projectPath);
      const project = store.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("No project registered. Run `foreman init` first."));
        store.close();
        process.exit(1);
      }
      const config = store.upsertMergeAgentConfig(project.id, {
        enabled: 1,
        interval_seconds: Number(opts.interval),
      });
      console.log(chalk.green(`Merge agent configured (interval=${config.interval_seconds}s)`));
      console.log(chalk.dim("Run `foreman run` to start the daemon"));
      store.close();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${msg}`));
      process.exit(1);
    }
  });

mergeAgentCommand
  .command("stop")
  .description("Stop the merge agent daemon")
  .action(async () => {
    try {
      const projectPath = await getRepoRoot(process.cwd());
      const store = ForemanStore.forProject(projectPath);
      const project = store.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("No project registered. Run `foreman init` first."));
        store.close();
        process.exit(1);
      }
      store.upsertMergeAgentConfig(project.id, { enabled: 0, pid: null });
      console.log(chalk.yellow("Merge agent disabled"));
      store.close();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${msg}`));
      process.exit(1);
    }
  });

mergeAgentCommand
  .command("status")
  .description("Show merge agent status")
  .action(async () => {
    try {
      const projectPath = await getRepoRoot(process.cwd());
      const store = ForemanStore.forProject(projectPath);
      const project = store.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("No project registered. Run `foreman init` first."));
        store.close();
        process.exit(1);
      }
      const config = store.getMergeAgentConfig(project.id);
      if (!config) {
        console.log(chalk.dim("Merge agent not configured. Run `foreman merge-agent start`."));
        store.close();
        return;
      }
      const status = config.enabled ? chalk.green("enabled") : chalk.red("disabled");
      const pidInfo = config.pid ? chalk.dim(`pid=${config.pid}`) : chalk.dim("not running");
      console.log(`Merge agent: ${status} | ${pidInfo} | interval=${config.interval_seconds}s`);
      store.close();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${msg}`));
      process.exit(1);
    }
  });
