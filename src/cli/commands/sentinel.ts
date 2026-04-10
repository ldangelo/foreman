import { Command } from "commander";
import chalk from "chalk";

import { BeadsRustClient } from "../../lib/beads-rust.js";
import { ForemanStore } from "../../lib/store.js";
import { ProjectRegistry } from "../../lib/project-registry.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { IntegrationValidator } from "../../orchestrator/integration-validator.js";
import { inspectFleetHealth } from "../../orchestrator/fleet-monitor.js";

function emitSentinelStatusError(jsonOutput: boolean, message: string): never {
  if (jsonOutput) {
    console.error(JSON.stringify({ error: message }));
  } else {
    console.error(chalk.red(`Error: ${message}`));
  }
  process.exit(1);
}


export const sentinelCommand = new Command("sentinel")
  .description("Integration validation and fleet monitoring");

sentinelCommand
  .command("run-once")
  .description("Run integration validation once and exit")
  .option("--branch <branch>", "Integration branch to validate", "main")
  .option("--test-command <cmd>", "Validation command to execute", "npm test")
  .option("--failure-threshold <n>", "Consecutive failures before filing a bug", "2")
  .option("--dry-run", "Simulate without running validation")
  .action(async (opts) => {
    try {
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, process.cwd());
      const projectPath = await vcs.getRepoRoot(process.cwd());
      const store = ForemanStore.forProject(projectPath);
      const seeds = new BeadsRustClient(projectPath);

      const project = store.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("Error: project not initialized. Run `foreman init` first."));
        process.exit(1);
      }

      const validator = new IntegrationValidator(store, seeds, project.id, projectPath);
      const options = {
        branch: opts.branch as string,
        testCommand: opts.testCommand as string,
        intervalMinutes: 0,
        failureThreshold: parseInt(opts.failureThreshold as string, 10),
        dryRun: Boolean(opts.dryRun),
      };

      console.log(chalk.bold(`Running integration validation on branch: ${chalk.cyan(options.branch)}`));
      if (options.dryRun) console.log(chalk.dim("  (dry-run mode)"));
      console.log();

      const result = await validator.runOnce(options);
      const icon = result.status === "passed" ? chalk.green("✓") : chalk.red("✗");
      const statusLabel =
        result.status === "passed"
          ? chalk.green("PASSED")
          : result.status === "failed"
            ? chalk.red("FAILED")
            : chalk.yellow("ERROR");

      console.log(`${icon} Integration validation ${statusLabel} (${(result.durationMs / 1000).toFixed(1)}s)`);
      if (result.commitHash) {
        console.log(chalk.dim(`  Commit: ${result.commitHash.slice(0, 8)}`));
      }
      if (result.status !== "passed" && result.output) {
        console.log(chalk.dim("\nOutput (last 2000 chars):"));
        console.log(result.output.slice(-2000));
      }

      store.close();
      process.exit(result.status === "passed" ? 0 : 1);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });

sentinelCommand
  .command("start")
  .description("Start continuous integration validation (foreground)")
  .option("--branch <branch>", "Integration branch to validate", "main")
  .option("--interval <minutes>", "Validation interval in minutes", "30")
  .option("--test-command <cmd>", "Validation command to execute", "npm test")
  .option("--failure-threshold <n>", "Consecutive failures before filing a bug", "2")
  .option("--dry-run", "Simulate without running validation")
  .action(async (opts) => {
    try {
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, process.cwd());
      const projectPath = await vcs.getRepoRoot(process.cwd());
      const store = ForemanStore.forProject(projectPath);
      const seeds = new BeadsRustClient(projectPath);

      const project = store.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("Error: project not initialized. Run `foreman init` first."));
        process.exit(1);
      }

      const intervalMinutes = parseInt(opts.interval as string, 10);
      const failureThreshold = parseInt(opts.failureThreshold as string, 10);
      const validator = new IntegrationValidator(store, seeds, project.id, projectPath);
      const options = {
        branch: opts.branch as string,
        testCommand: opts.testCommand as string,
        intervalMinutes,
        failureThreshold,
        dryRun: Boolean(opts.dryRun),
      };

      store.upsertSentinelConfig(project.id, {
        branch: options.branch,
        test_command: options.testCommand,
        interval_minutes: intervalMinutes,
        failure_threshold: failureThreshold,
        enabled: 1,
        pid: process.pid,
      });

      console.log(chalk.bold("Integration validator started"));
      console.log(chalk.dim(`  Branch:    ${options.branch}`));
      console.log(chalk.dim(`  Command:   ${options.testCommand}`));
      console.log(chalk.dim(`  Interval:  ${intervalMinutes}m`));
      console.log(chalk.dim(`  Threshold: ${failureThreshold} consecutive failures`));
      if (options.dryRun) console.log(chalk.yellow("  (dry-run mode)"));
      console.log(chalk.dim("\nPress Ctrl+C to stop.\n"));

      validator.start(options, (result) => {
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
        console.log(`[${now}] ${icon} ${statusLabel} ${dur}${hash}`);
      });

      const cleanup = () => {
        validator.stop();
        store.upsertSentinelConfig(project.id, { enabled: 0, pid: null });
        store.close();
        console.log(chalk.dim("\nIntegration validator stopped."));
        process.exit(0);
      };
      process.on("SIGINT", cleanup);
      process.on("SIGTERM", cleanup);

      await new Promise<void>(() => { /* run forever until signal */ });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });

sentinelCommand
  .command("status")
  .description("Show integration validation state and fleet monitoring health")
  .option("--limit <n>", "Number of recent validation runs to show", "10")
  .option("--all", "Show fleet-wide monitoring across registered projects")
  .option("--json", "Output as JSON")
  .action(async (opts) => {
    try {
      if (opts.all) {
        const fleet = inspectFleetHealth(new ProjectRegistry());
        if (opts.json) {
          console.log(JSON.stringify({ projects: fleet }, null, 2));
          return;
        }
        console.log(chalk.bold("Fleet monitoring"));
        for (const item of fleet) {
          const badge = item.validationReady ? chalk.green("ready") : chalk.yellow("attention");
          console.log(`\n${chalk.bold(item.project.name)} ${badge}`);
          console.log(chalk.dim(`  Path: ${item.project.path}`));
          console.log(chalk.dim(`  ${item.healthSummary}`));
        }
        return;
      }

      const vcs = await VcsBackendFactory.create({ backend: "auto" }, process.cwd());
      const projectPath = await vcs.getRepoRoot(process.cwd());
      const store = ForemanStore.forProject(projectPath);

      const project = store.getProjectByPath(projectPath);
      if (!project) {
        emitSentinelStatusError(Boolean(opts.json), "project not initialized. Run `foreman init` first.");
      }

      const limit = parseInt(opts.limit as string, 10);
      const runs = store.getSentinelRuns(project.id, limit);
      const config = store.getSentinelConfig(project.id);

      if (opts.json) {
        console.log(JSON.stringify({ config, runs }, null, 2));
        store.close();
        return;
      }

      if (config) {
        const isRunning = config.enabled === 1 && config.pid != null;
        const statusBadge = isRunning ? chalk.green("running") : chalk.dim("stopped");
        console.log(chalk.bold(`Integration validator: ${statusBadge}`));
        console.log(chalk.dim(`  Branch: ${config.branch}  |  Command: ${config.test_command}  |  Interval: ${config.interval_minutes}m`));
        if (config.pid) console.log(chalk.dim(`  PID: ${config.pid}`));
        console.log();
      } else {
        console.log(chalk.dim("Integration validation not configured. Run `foreman sentinel start` to begin.\n"));
      }

      if (runs.length === 0) {
        console.log(chalk.dim("No validation runs recorded yet."));
        store.close();
        return;
      }

      console.log(chalk.bold(`Recent validation runs (${runs.length}):`));
      for (const run of runs) {
        const icon =
          run.status === "passed"
            ? chalk.green("✓")
            : run.status === "running"
              ? chalk.cyan("⟳")
              : chalk.red("✗");
        const statusLabel =
          run.status === "passed"
            ? chalk.green(run.status)
            : run.status === "running"
              ? chalk.cyan(run.status)
              : chalk.red(run.status);
        const hash = run.commit_hash ? chalk.dim(` [${run.commit_hash.slice(0, 8)}]`) : "";
        const dur =
          run.completed_at
            ? chalk.dim(` ${((new Date(run.completed_at).getTime() - new Date(run.started_at).getTime()) / 1000).toFixed(1)}s`)
            : "";
        const ts = new Date(run.started_at).toLocaleString();
        console.log(`  ${icon} ${statusLabel}${hash}${dur}  ${chalk.dim(ts)}`);
      }

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      emitSentinelStatusError(Boolean(opts.json), message);
    }
  });

sentinelCommand
  .command("stop")
  .description("Stop continuous integration validation")
  .option("--force", "Force kill with SIGKILL instead of SIGTERM")
  .action(async (opts) => {
    try {
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, process.cwd());
      const projectPath = await vcs.getRepoRoot(process.cwd());
      const store = ForemanStore.forProject(projectPath);

      const project = store.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("Error: project not initialized. Run `foreman init` first."));
        process.exit(1);
      }

      const config = store.getSentinelConfig(project.id);
      if (!config) {
        console.log(chalk.dim("Integration validation not configured."));
        store.close();
        return;
      }
      if (config.enabled !== 1) {
        console.log(chalk.dim("Integration validator not running."));
        store.close();
        return;
      }

      if (config.pid != null) {
        try {
          process.kill(config.pid, opts.force ? "SIGKILL" : "SIGTERM");
        } catch {
          // Process may already have exited.
        }
      }

      store.upsertSentinelConfig(project.id, { enabled: 0, pid: null });
      console.log(chalk.dim("Integration validator stopped."));
      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });
