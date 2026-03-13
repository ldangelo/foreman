import { Command } from "commander";
import chalk from "chalk";

import { SeedsClient } from "../../lib/seeds.js";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { Refinery } from "../../orchestrator/refinery.js";

export const mergeCommand = new Command("merge")
  .description("Merge completed agent work into target branch")
  .option("--target-branch <branch>", "Branch to merge into", "main")
  .option("--no-tests", "Skip running tests after merge")
  .option("--test-command <cmd>", "Test command to run", "npm test")
  .option("--seed <id>", "Merge a single seed by ID")
  .option("--list", "List seeds ready to merge (no merge performed)")
  .option("--resolve <runId>", "Resolve a conflicting run by ID")
  .option("--strategy <strategy>", "Conflict resolution strategy: theirs|abort")
  .action(async (opts) => {
    try {
      const projectPath = await getRepoRoot(process.cwd());
      const seeds = new SeedsClient(projectPath);
      const store = new ForemanStore();
      const refinery = new Refinery(store, seeds, projectPath);

      const project = store.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("No project registered. Run 'foreman init' first."));
        process.exit(1);
      }

      // --resolve mode: resolve a conflicting run
      if (opts.resolve) {
        if (!opts.strategy) {
          console.error(chalk.red("Error: --strategy <theirs|abort> is required when using --resolve"));
          store.close();
          process.exit(1);
        }

        const strategy = opts.strategy as string;
        if (strategy !== "theirs" && strategy !== "abort") {
          console.error(chalk.red(`Error: Invalid strategy '${strategy}'. Must be 'theirs' or 'abort'.`));
          store.close();
          process.exit(1);
        }

        const runId = opts.resolve as string;
        const run = store.getRun(runId);
        if (!run) {
          console.error(chalk.red(`Error: Run '${runId}' not found.`));
          store.close();
          process.exit(1);
        }

        if (run.status !== "conflict") {
          console.error(
            chalk.red(
              `Error: Run '${runId}' is not in conflict state (current status: '${run.status}'). Only runs with status 'conflict' can be resolved.`,
            ),
          );
          store.close();
          process.exit(1);
        }

        const branchName = `foreman/${run.seed_id}`;
        console.log(chalk.bold(`Resolving conflict for ${chalk.cyan(run.seed_id)} (${branchName}) with strategy: ${chalk.yellow(strategy)}\n`));

        const success = await refinery.resolveConflict(runId, strategy as "theirs" | "abort", {
          targetBranch: opts.targetBranch,
          runTests: opts.tests, // commander inverts --no-tests to opts.tests = false
          testCommand: opts.testCommand,
        });

        if (success) {
          console.log(chalk.green.bold(`✓ Conflict resolved — ${run.seed_id} merged successfully.`));
        } else if (strategy === "abort") {
          console.log(chalk.yellow(`Merge aborted — ${run.seed_id} marked as failed.`));
        } else {
          console.log(chalk.red(`✗ Failed to resolve conflict for ${run.seed_id} — marked as failed.`));
        }

        store.close();
        return;
      }

      // --list: show completed runs and exit
      if (opts.list) {
        const completedRuns = await refinery.orderByDependencies(
          refinery.getCompletedRuns(project.id),
        );

        if (completedRuns.length === 0) {
          console.log(chalk.yellow("No completed seeds ready to merge."));
          store.close();
          return;
        }

        console.log(chalk.bold(`Seeds ready to merge (${completedRuns.length}):\n`));
        console.log(chalk.dim("  (listed in dependency order — dependencies first)\n"));

        for (let i = 0; i < completedRuns.length; i++) {
          const run = completedRuns[i];
          const branch = `foreman/${run.seed_id}`;
          const elapsed = run.completed_at
            ? Math.round((Date.now() - new Date(run.completed_at).getTime()) / 60000)
            : 0;
          const num = `${i + 1}`.padStart(2);
          console.log(
            `  ${chalk.dim(num + ".")} ${chalk.cyan(run.seed_id)} ${chalk.dim(branch)} ${chalk.dim(`(${elapsed}m ago)`)}`,
          );
        }

        console.log(chalk.dim("\nMerge all:    foreman merge"));
        console.log(chalk.dim("Merge one:    foreman merge --seed <id>"));

        store.close();
        return;
      }

      console.log(chalk.bold("Running refinery on completed work...\n"));

      const report = await refinery.mergeCompleted({
        targetBranch: opts.targetBranch,
        runTests: opts.tests, // commander inverts --no-tests to opts.tests = false
        testCommand: opts.testCommand,
        projectId: project.id,
        seedId: opts.seed,
      });

      // Merged
      if (report.merged.length > 0) {
        console.log(chalk.green.bold(`Merged ${report.merged.length} task(s):\n`));
        for (const m of report.merged) {
          console.log(`  ${chalk.cyan(m.seedId)} ${m.branchName}`);
        }
        console.log();
      }

      // Conflicts
      if (report.conflicts.length > 0) {
        console.log(chalk.yellow.bold(`Conflicts in ${report.conflicts.length} task(s):\n`));
        for (const c of report.conflicts) {
          console.log(`  ${chalk.cyan(c.seedId)} ${c.branchName}`);
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

      // PRs created for conflicts
      if (report.prsCreated.length > 0) {
        console.log(chalk.blue.bold(`PRs created for ${report.prsCreated.length} conflicting task(s):\n`));
        for (const pr of report.prsCreated) {
          console.log(`  ${chalk.cyan(pr.seedId)} ${chalk.dim(pr.branchName)}`);
          console.log(`    ${chalk.underline(pr.prUrl)}`);
        }
        console.log();
      }

      // Test failures
      if (report.testFailures.length > 0) {
        console.log(chalk.red.bold(`Test failures in ${report.testFailures.length} task(s):\n`));
        for (const f of report.testFailures) {
          console.log(`  ${chalk.cyan(f.seedId)} ${f.branchName}`);
          console.log(`    ${chalk.dim(f.error.split("\n")[0])}`);
        }
        console.log();
      }

      if (report.merged.length === 0 && report.conflicts.length === 0 && report.testFailures.length === 0 && report.prsCreated.length === 0) {
        if (opts.seed) {
          console.log(chalk.yellow(`No completed run found for seed ${opts.seed}.`));
          console.log(chalk.dim("Use 'foreman merge --list' to see seeds ready to merge."));
        } else {
          console.log(chalk.yellow("No completed tasks to merge."));
        }
      }

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });
