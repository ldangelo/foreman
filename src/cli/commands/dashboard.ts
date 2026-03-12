import { Command } from "commander";
import chalk from "chalk";
import { resolve } from "node:path";

import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { runDashboard } from "../dashboard-ui.js";

export const dashboardCommand = new Command("dashboard")
  .description("Live TUI dashboard showing agent status and metrics")
  .option("--project <path>", "Path to the project to monitor (defaults to current directory)")
  .option("--interval <ms>", "Polling interval in milliseconds", "3000")
  .option("--no-auto-update", "Render once and exit (useful for scripting/testing)")
  .option("--all", "Show agents across all registered projects")
  .action(async (opts: {
    project?: string;
    interval: string;
    autoUpdate: boolean;
    all?: boolean;
  }) => {
    const intervalMs = parseInt(opts.interval, 10);
    if (isNaN(intervalMs) || intervalMs < 100) {
      console.error(chalk.red("Error: --interval must be a number >= 100 ms"));
      process.exit(1);
    }

    const store = new ForemanStore();

    try {
      let projectId: string | null = null;

      if (!opts.all) {
        // Determine target project path
        const projectPath = opts.project
          ? resolve(opts.project)
          : await getRepoRoot(process.cwd()).catch(() => resolve(process.cwd()));

        const project = store.getProjectByPath(projectPath);
        if (!project) {
          // Gracefully degrade — show global view with a warning
          console.warn(
            chalk.yellow(
              `Warning: No foreman project found at ${projectPath}. Showing all projects.\n` +
              `  Run 'foreman init' to register this directory, or use --all flag.\n`,
            ),
          );
        } else {
          projectId = project.id;
        }
      }

      await runDashboard(store, projectId, intervalMs, opts.autoUpdate);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    } finally {
      store.close();
    }
  });
