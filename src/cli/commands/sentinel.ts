import { Command } from "commander";
import chalk from "chalk";

import { createTaskClient } from "../../lib/task-client-factory.js";
import { ForemanStore } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { SentinelAgent } from "../../orchestrator/sentinel.js";
import { ensureCliPostgresPool, listRegisteredProjects, resolveRepoRootProjectPath } from "./project-task-support.js";

export const sentinelCommand = new Command("sentinel")
  .description("QA sentinel: continuous testing agent for main/master branch");

export interface SentinelCommandTaskClient extends ITaskClient {
  create(
    title: string,
    opts: {
      type: string;
      priority: string;
      description?: string;
      labels?: string[];
    },
  ): Promise<Issue>;
}

export async function createSentinelTaskClient(projectPath: string): Promise<SentinelCommandTaskClient> {
  const { taskClient } = await createTaskClient(projectPath, {
    forceBeadsFallback: true,
  });
  return taskClient as SentinelCommandTaskClient;
}

function wrapLocalSentinelStore(store: ForemanStore) {
  return {
    close: () => store.close(),
    isOpen: () => store.isOpen(),
    logEvent: async (projectId: string, eventType: "sentinel-start" | "sentinel-pass" | "sentinel-fail", data: Record<string, unknown>) => store.logEvent(projectId, eventType, data),
    recordSentinelRun: async (run: Parameters<ForemanStore["recordSentinelRun"]>[0]) => store.recordSentinelRun(run),
    updateSentinelRun: async (id: string, updates: Parameters<ForemanStore["updateSentinelRun"]>[1]) => store.updateSentinelRun(id, updates),
    upsertSentinelConfig: async (projectId: string, config: Parameters<ForemanStore["upsertSentinelConfig"]>[1]) => { store.upsertSentinelConfig(projectId, config); },
    getSentinelConfig: async (projectId: string) => store.getSentinelConfig(projectId),
    getSentinelRuns: async (projectId: string, limit?: number) => store.getSentinelRuns(projectId, limit),
  };
}

export function wrapPostgresSentinelStore(store: PostgresStore, projectId: string) {
  return {
    close: () => store.close(),
    isOpen: () => store.isOpen(),
    logEvent: async (pid: string, eventType: "sentinel-start" | "sentinel-pass" | "sentinel-fail", data: Record<string, unknown>) => {
      const runId = typeof data.runId === "string" ? data.runId : undefined;
      return store.logEvent(pid, eventType, data, runId);
    },
    recordSentinelRun: async (run: Parameters<ForemanStore["recordSentinelRun"]>[0]) => store.recordSentinelRun(projectId, run),
    updateSentinelRun: async (id: string, updates: Parameters<ForemanStore["updateSentinelRun"]>[1]) => store.updateSentinelRun(id, updates),
    upsertSentinelConfig: async (_projectId: string, config: Parameters<ForemanStore["upsertSentinelConfig"]>[1]) => { await store.upsertSentinelConfig(projectId, config); },
    getSentinelConfig: async (_projectId: string) => store.getSentinelConfig(projectId),
    getSentinelRuns: async (_projectId: string, limit?: number) => store.getSentinelRuns(projectId, limit),
  };
}

async function resolveSentinelRegisteredProject(projectPath: string) {
  const projects = await listRegisteredProjects();
  return projects.find((project) => project.path === projectPath) ?? null;
}

// ── foreman sentinel run-once ──────────────────────────────────────────

sentinelCommand
  .command("run-once")
  .description("Run the sentinel test suite once and exit")
  .option("--branch <branch>", "Branch to test", "main")
  .option("--test-command <cmd>", "Test command to execute", "npm test")
  .option("--failure-threshold <n>", "Consecutive failures before filing a bug", "2")
  .option("--dry-run", "Simulate without running tests")
  .action(async (opts) => {
    try {
      const projectPath = await resolveRepoRootProjectPath({});
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
      const localStore = ForemanStore.forProject(projectPath);
      const registered = await resolveSentinelRegisteredProject(projectPath);
      if (registered) {
        ensureCliPostgresPool(projectPath);
      }
      const store = registered ? wrapPostgresSentinelStore(PostgresStore.forProject(registered.id), registered.id) : wrapLocalSentinelStore(localStore);
      const seeds = await createSentinelTaskClient(projectPath);

      const project = registered ?? localStore.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("Error: project not initialized. Run `foreman init` first."));
        process.exit(1);
      }

      const agent = new SentinelAgent(store, seeds, project.id, projectPath, vcs);
      const options = {
        branch: opts.branch as string,
        testCommand: opts.testCommand as string,
        intervalMinutes: 0,
        failureThreshold: parseInt(opts.failureThreshold as string, 10),
        dryRun: Boolean(opts.dryRun),
      };

      console.log(chalk.bold(`Running sentinel on branch: ${chalk.cyan(options.branch)}`));
      if (options.dryRun) console.log(chalk.dim("  (dry-run mode)"));
      console.log();

      const result = await agent.runOnce(options);
      const icon = result.status === "passed" ? chalk.green("✓") : chalk.red("✗");
      const statusLabel =
        result.status === "passed"
          ? chalk.green("PASSED")
          : result.status === "failed"
            ? chalk.red("FAILED")
            : chalk.yellow("ERROR");

      console.log(`${icon} Tests ${statusLabel} (${(result.durationMs / 1000).toFixed(1)}s)`);
      if (result.commitHash) {
        console.log(chalk.dim(`  Commit: ${result.commitHash.slice(0, 8)}`));
      }

      if (result.status !== "passed" && result.output) {
        console.log(chalk.dim("\nOutput (last 2000 chars):"));
        console.log(result.output.slice(-2000));
      }

      localStore.close();
      if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
        (store as { close: () => void }).close();
      }
      process.exit(result.status === "passed" ? 0 : 1);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });

// ── foreman sentinel start ──────────────────────────────────────────────

sentinelCommand
  .command("start")
  .description("Start continuous sentinel monitoring loop (runs in foreground)")
  .option("--branch <branch>", "Branch to monitor", "main")
  .option("--interval <minutes>", "Check interval in minutes", "30")
  .option("--test-command <cmd>", "Test command to execute", "npm test")
  .option("--failure-threshold <n>", "Consecutive failures before filing a bug", "2")
  .option("--dry-run", "Simulate without running tests")
  .action(async (opts) => {
    try {
      const projectPath = await resolveRepoRootProjectPath({});
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
      const localStore = ForemanStore.forProject(projectPath);
      const registered = await resolveSentinelRegisteredProject(projectPath);
      if (registered) {
        ensureCliPostgresPool(projectPath);
      }
      const store = registered ? wrapPostgresSentinelStore(PostgresStore.forProject(registered.id), registered.id) : wrapLocalSentinelStore(localStore);
      const seeds = await createSentinelTaskClient(projectPath);

      const project = registered ?? localStore.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("Error: project not initialized. Run `foreman init` first."));
        process.exit(1);
      }

      const intervalMinutes = parseInt(opts.interval as string, 10);
      const failureThreshold = parseInt(opts.failureThreshold as string, 10);

      const agent = new SentinelAgent(store, seeds, project.id, projectPath, vcs);
      const options = {
        branch: opts.branch as string,
        testCommand: opts.testCommand as string,
        intervalMinutes,
        failureThreshold,
        dryRun: Boolean(opts.dryRun),
      };

      // Persist sentinel config for status queries
      await store.upsertSentinelConfig(project.id, {
        branch: options.branch,
        test_command: options.testCommand,
        interval_minutes: intervalMinutes,
        failure_threshold: failureThreshold,
        enabled: 1,
        pid: process.pid,
      });

      console.log(chalk.bold("QA Sentinel started"));
      console.log(chalk.dim(`  Branch:    ${options.branch}`));
      console.log(chalk.dim(`  Command:   ${options.testCommand}`));
      console.log(chalk.dim(`  Interval:  ${intervalMinutes}m`));
      console.log(chalk.dim(`  Threshold: ${failureThreshold} consecutive failures`));
      if (options.dryRun) console.log(chalk.yellow("  (dry-run mode)"));
      console.log(chalk.dim("\nPress Ctrl+C to stop.\n"));

      agent.start(options, (result) => {
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

      // Keep process alive; stop cleanly on SIGINT
      const cleanup = () => {
        agent.stop();
        void store.upsertSentinelConfig(project.id, { enabled: 0, pid: null });
        localStore.close();
        if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
          (store as { close: () => void }).close();
        }
        console.log(chalk.dim("\nSentinel stopped."));
        process.exit(0);
      };
      process.on("SIGINT", cleanup);
      process.on("SIGTERM", cleanup);

      // Prevent Node from exiting naturally
      await new Promise<void>(() => { /* run forever until signal */ });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });

// ── foreman sentinel status ────────────────────────────────────────────

sentinelCommand
  .command("status")
  .description("Show recent sentinel run history")
  .option("--limit <n>", "Number of recent runs to show", "10")
  .option("--json", "Output as JSON")
  .action(async (opts) => {
    try {
      const projectPath = await resolveRepoRootProjectPath({});
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
      const localStore = ForemanStore.forProject(projectPath);
      const registered = await resolveSentinelRegisteredProject(projectPath);
      if (registered) {
        ensureCliPostgresPool(projectPath);
      }
      const store = registered ? wrapPostgresSentinelStore(PostgresStore.forProject(registered.id), registered.id) : wrapLocalSentinelStore(localStore);

      const project = registered ?? localStore.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("Error: project not initialized. Run `foreman init` first."));
        process.exit(1);
      }

      const limit = parseInt(opts.limit as string, 10);
      const runs = await store.getSentinelRuns(project.id, limit);
      const config = await store.getSentinelConfig(project.id);

      if (opts.json) {
        console.log(JSON.stringify({ config, runs }, null, 2));
        localStore.close();
        if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
          (store as { close: () => void }).close();
        }
        return;
      }

      // Config summary
      if (config) {
        const isRunning = config.enabled === 1 && config.pid != null;
        const statusBadge = isRunning ? chalk.green("running") : chalk.dim("stopped");
        console.log(chalk.bold(`Sentinel status: ${statusBadge}`));
        console.log(chalk.dim(`  Branch: ${config.branch}  |  Command: ${config.test_command}  |  Interval: ${config.interval_minutes}m`));
        if (config.pid) console.log(chalk.dim(`  PID: ${config.pid}`));
        console.log();
      } else {
        console.log(chalk.dim("Sentinel not configured. Run `foreman sentinel start` to begin.\n"));
      }

      if (runs.length === 0) {
        console.log(chalk.dim("No sentinel runs recorded yet."));
        localStore.close();
        if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
          (store as { close: () => void }).close();
        }
        return;
      }

      console.log(chalk.bold(`Recent runs (${runs.length}):`));
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
            ? chalk.dim(
                ` ${((new Date(run.completed_at).getTime() - new Date(run.started_at).getTime()) / 1000).toFixed(1)}s`,
              )
            : "";
        const ts = new Date(run.started_at).toLocaleString();
        console.log(`  ${icon} ${statusLabel}${hash}${dur}  ${chalk.dim(ts)}`);
      }

      localStore.close();
      if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
        (store as { close: () => void }).close();
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });

// ── foreman sentinel stop ──────────────────────────────────────────────

sentinelCommand
  .command("stop")
  .description("Stop the continuous sentinel monitoring loop")
  .option("--force", "Force kill with SIGKILL instead of SIGTERM")
  .action(async (opts) => {
    try {
      const projectPath = await resolveRepoRootProjectPath({});
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
      const localStore = ForemanStore.forProject(projectPath);
      const registered = await resolveSentinelRegisteredProject(projectPath);
      if (registered) {
        ensureCliPostgresPool(projectPath);
      }
      const store = registered ? wrapPostgresSentinelStore(PostgresStore.forProject(registered.id), registered.id) : wrapLocalSentinelStore(localStore);

      const project = registered ?? localStore.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("Error: project not initialized. Run `foreman init` first."));
        process.exit(1);
      }

      const config = await store.getSentinelConfig(project.id);

      if (!config) {
        console.log(chalk.dim("Sentinel not configured."));
        localStore.close();
        if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
          (store as { close: () => void }).close();
        }
        return;
      }

      if (config.enabled !== 1) {
        console.log(chalk.dim("Sentinel not running."));
        localStore.close();
        if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
          (store as { close: () => void }).close();
        }
        return;
      }

      // Attempt to kill the process if a PID is stored
      if (config.pid != null) {
        try {
          process.kill(config.pid, opts.force ? "SIGKILL" : "SIGTERM");
        } catch {
          // Process may have already exited — that's fine, continue to update config
        }
      }

      // Mark sentinel as stopped in the database
      await store.upsertSentinelConfig(project.id, { enabled: 0, pid: null });
      console.log(chalk.dim("Sentinel stopped."));

      localStore.close();
      if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
        (store as { close: () => void }).close();
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });
