import { Command } from "commander";
import chalk from "chalk";

import { ForemanStore } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import { createTaskClient } from "../../lib/task-client-factory.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { Refinery } from "../../orchestrator/refinery.js";
import { listRegisteredProjects, resolveRepoRootProjectPath } from "./project-task-support.js";

export const prCommand = new Command("pr")
  .description("Create pull requests for completed agent work")
  .option("--base-branch <branch>", "Base branch for PRs", "main")
  .option("--draft", "Create draft PRs")
  .action(async (opts) => {
    try {
      const projectPath = await resolveRepoRootProjectPath({});
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
      const registered = (await listRegisteredProjects()).find((project) => project.path === projectPath);
      const { taskClient } = await createTaskClient(projectPath, { registeredProjectId: registered?.id });
      const store = ForemanStore.forProject(projectPath);
      const runLookup = registered ? PostgresStore.forProject(registered.id) : undefined;
      const refinery = registered
        ? new Refinery(store, taskClient, projectPath, vcs, { registeredProjectId: registered.id, runLookup })
        : new Refinery(store, taskClient, projectPath, vcs);

      const project = registered ?? store.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("No project registered. Run 'foreman init' first."));
        process.exit(1);
      }

      console.log(chalk.bold("Creating PRs for completed work...\n"));

      const report = await refinery.createPRs({
        baseBranch: opts.baseBranch,
        draft: opts.draft,
        projectId: project.id,
      });

      if (report.created.length > 0) {
        console.log(chalk.green.bold(`Created ${report.created.length} PR(s):\n`));
        for (const pr of report.created) {
          console.log(`  ${chalk.cyan(pr.seedId)} ${pr.branchName}`);
          console.log(`    ${chalk.blue(pr.prUrl)}`);
          console.log();
        }
      }

      if (report.failed.length > 0) {
        console.log(chalk.red.bold(`Failed ${report.failed.length} PR(s):\n`));
        for (const f of report.failed) {
          console.log(`  ${chalk.cyan(f.seedId)} ${f.branchName}`);
          console.log(`    ${chalk.dim(f.error.split("\n")[0])}`);
        }
        console.log();
      }

      if (report.created.length === 0 && report.failed.length === 0) {
        console.log(chalk.yellow("No completed tasks to create PRs for."));
      }

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });
