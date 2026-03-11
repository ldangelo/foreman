import { Command } from "commander";
import chalk from "chalk";

import { BeadsClient } from "../../lib/beads.js";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { Refinery } from "../../orchestrator/refinery.js";

export const mergeCommand = new Command("merge")
  .description("Merge completed agent work into target branch")
  .option("--target-branch <branch>", "Branch to merge into", "main")
  .option("--no-tests", "Skip running tests after merge")
  .option("--test-command <cmd>", "Test command to run", "npm test")
  .action(async (opts) => {
    try {
      const projectPath = await getRepoRoot(process.cwd());
      const beads = new BeadsClient(projectPath);
      const store = new ForemanStore();
      const refinery = new Refinery(store, beads, projectPath);

      console.log(chalk.bold("Running refinery on completed work...\n"));

      const project = store.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("No project registered. Run 'foreman init' first."));
        process.exit(1);
      }

      const report = await refinery.mergeCompleted({
        targetBranch: opts.targetBranch,
        runTests: opts.tests, // commander inverts --no-tests to opts.tests = false
        testCommand: opts.testCommand,
        projectId: project.id,
      });

      // Merged
      if (report.merged.length > 0) {
        console.log(chalk.green.bold(`Merged ${report.merged.length} task(s):\n`));
        for (const m of report.merged) {
          console.log(`  ${chalk.cyan(m.beadId)} ${m.branchName}`);
        }
        console.log();
      }

      // Conflicts
      if (report.conflicts.length > 0) {
        console.log(chalk.yellow.bold(`Conflicts in ${report.conflicts.length} task(s):\n`));
        for (const c of report.conflicts) {
          console.log(`  ${chalk.cyan(c.beadId)} ${c.branchName}`);
          for (const f of c.conflictFiles) {
            console.log(`    ${chalk.dim(f)}`);
          }
        }
        console.log();
        console.log(
          chalk.dim("  Resolve with: foreman merge --resolve <runId> --strategy theirs|abort"),
        );
        console.log();
      }

      // Test failures
      if (report.testFailures.length > 0) {
        console.log(chalk.red.bold(`Test failures in ${report.testFailures.length} task(s):\n`));
        for (const f of report.testFailures) {
          console.log(`  ${chalk.cyan(f.beadId)} ${f.branchName}`);
          console.log(`    ${chalk.dim(f.error.split("\n")[0])}`);
        }
        console.log();
      }

      if (report.merged.length === 0 && report.conflicts.length === 0 && report.testFailures.length === 0) {
        console.log(chalk.yellow("No completed tasks to merge."));
      }

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });
