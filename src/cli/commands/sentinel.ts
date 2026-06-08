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
  const { taskClient } = await createTaskClient(projectPath);
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

// ─────────────────────────────────────────────────────────────────────────────
// Project Resolution
// ─────────────────────────────────────────────────────────────────────────────

async function resolveProject(
  opts: { project?: string },
): Promise<{ id: string; name: string; path: string } | null> {
  if (opts.project) {
    const projects = await listRegisteredProjects();
    const match = projects.find(
      (p) => p.id === opts.project || p.name === opts.project,
    );
    return match ?? null;
  }
  // Fall back to current directory
  const projectPath = await resolveRepoRootProjectPath({});
  const projects = await listRegisteredProjects();
  return projects.find((p) => p.path === projectPath) ?? null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Lockfile Management
// ─────────────────────────────────────────────────────────────────────────────

function getSentinelLockPath(projectId: string): string {
  const { join } = require("node:path");
  const { homedir } = require("node:os");
  return join(homedir(), ".foreman", "sentinels", `${projectId}.lock`);
}

interface SentinelLock {
  pid: number;
  startedAt: string;
  branch: string;
  intervalMinutes: number;
  testCommand: string;
}

function readSentinelLock(projectId: string): SentinelLock | null {
  const { readFileSync, existsSync } = require("node:fs");
  const lockPath = getSentinelLockPath(projectId);
  if (!existsSync(lockPath)) return null;
  try {
    return JSON.parse(readFileSync(lockPath, "utf-8"));
  } catch {
    return null;
  }
}

function writeSentinelLock(projectId: string, lock: SentinelLock): void {
  const { writeFileSync, mkdirSync, existsSync } = require("node:fs");
  const { dirname } = require("node:path");
  const lockPath = getSentinelLockPath(projectId);
  const dir = dirname(lockPath);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  writeFileSync(lockPath, JSON.stringify(lock, null, 2));
}

function removeSentinelLock(projectId: string): void {
  const { unlinkSync, existsSync } = require("node:fs");
  const lockPath = getSentinelLockPath(projectId);
  if (existsSync(lockPath)) {
    try {
      unlinkSync(lockPath);
    } catch {
      // Ignore errors on cleanup
    }
  }
}

async function stopProjectSentinel(
  projectId: string,
  force: boolean,
): Promise<{ stopped: boolean; message: string }> {
  // Try lockfile first
  const lock = readSentinelLock(projectId);
  if (lock) {
    try {
      process.kill(lock.pid, 0); // Check if process exists
      process.kill(lock.pid, force ? "SIGKILL" : "SIGTERM");
      removeSentinelLock(projectId);
      return {
        stopped: true,
        message: `Sent SIG${force ? "KILL" : "TERM"} to sentinel (PID: ${lock.pid})`,
      };
    } catch {
      removeSentinelLock(projectId);
      return {
        stopped: false,
        message: `Process ${lock.pid} not running, cleaned up lockfile`,
      };
    }
  }
  return { stopped: false, message: "No sentinel running (no lockfile found)" };
}

// ─────────────────────────────────────────────────────────────────────────────
// foreman sentinel run-once
// ─────────────────────────────────────────────────────────────────────────────

sentinelCommand
  .command("run-once")
  .description("Run the sentinel test suite once and exit")
  .option("--project <name-or-id>", "Project name or ID (defaults to current directory)")
  .option("--branch <branch>", "Branch to test", "main")
  .option("--test-command <cmd>", "Test command to execute", "npm test")
  .option("--failure-threshold <n>", "Consecutive failures before filing a bug", "2")
  .option("--dry-run", "Simulate without running tests")
  .action(async (opts) => {
    try {
      const registered = await resolveProject({ project: opts.project });
      if (!registered) {
        const projectHint = opts.project
          ? `No project found matching '${opts.project}'`
          : "Not in a foreman project directory. Run `foreman init` or use --project.";
        console.error(chalk.red(`Error: ${projectHint}`));
        process.exit(1);
      }

      const projectPath = registered.path;
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
      const localStore = ForemanStore.forProject(projectPath);

      if (opts.project) {
        ensureCliPostgresPool(projectPath);
      }
      const store = registered
        ? wrapPostgresSentinelStore(PostgresStore.forProject(registered.id), registered.id)
        : wrapLocalSentinelStore(localStore);
      const seeds = await createSentinelTaskClient(projectPath);

      const agent = new SentinelAgent(store, seeds, registered.id, projectPath, vcs);
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

// ─────────────────────────────────────────────────────────────────────────────
// foreman sentinel start
// ─────────────────────────────────────────────────────────────────────────────

sentinelCommand
  .command("start")
  .description("Start continuous sentinel monitoring loop (runs in foreground)")
  .option("--project <name-or-id>", "Project name or ID (defaults to current directory)")
  .option("--branch <branch>", "Branch to monitor", "main")
  .option("--interval <minutes>", "Check interval in minutes", "30")
  .option("--test-command <cmd>", "Test command to execute", "npm test")
  .option("--failure-threshold <n>", "Consecutive failures before filing a bug", "2")
  .option("--dry-run", "Simulate without running tests")
  .action(async (opts) => {
    try {
      const registered = await resolveProject({ project: opts.project });
      if (!registered) {
        const projectHint = opts.project
          ? `No project found matching '${opts.project}'`
          : "Not in a foreman project directory. Run `foreman init` or use --project.";
        console.error(chalk.red(`Error: ${projectHint}`));
        process.exit(1);
      }

      // Check if sentinel already running for this project
      const existingLock = readSentinelLock(registered.id);
      if (existingLock) {
        try {
          process.kill(existingLock.pid, 0);
          console.error(chalk.red(`Error: Sentinel already running for project '${registered.name}' (PID: ${existingLock.pid}).`));
          console.error(chalk.dim(`Run \`foreman sentinel stop --project ${registered.name}\` first.`));
          process.exit(1);
        } catch {
          // Process no longer exists, stale lockfile
          removeSentinelLock(registered.id);
        }
      }

      const projectPath = registered.path;
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
      const localStore = ForemanStore.forProject(projectPath);
      ensureCliPostgresPool(projectPath);
      const store = wrapPostgresSentinelStore(PostgresStore.forProject(registered.id), registered.id);
      // Check if Jira is configured for this project
      let seeds = await createSentinelTaskClient(projectPath);
      const { loadProjectConfig } = await import("../../lib/project-config.js");
      const projectConfig = loadProjectConfig(projectPath);
      if (projectConfig?.issueTracker?.jira) {
        const jiraConfig = projectConfig.issueTracker.jira;
        const { createJiraTaskClientFromConfig, JiraTaskClient } = await import("../../daemon/jira-task-client.js");
        const jiraClient = await createJiraTaskClientFromConfig({
          apiUrl: jiraConfig.apiUrl,
          email: jiraConfig.email,
          apiToken: jiraConfig.apiToken,
          projects: jiraConfig.projects?.map((p) => ({ key: p.key })),
        });
        if (jiraClient) {
          console.log(chalk.dim("  Issue tracker: Jira (bugs will be filed in Jira)"));
          seeds = jiraClient as unknown as typeof seeds;
        } else {
          console.log(chalk.yellow("  Warning: Jira configured but could not connect. Falling back to task backend."));
        }
      } else {
        console.log(chalk.dim("  Issue tracker: task backend (beads/github)"));
      }
      const intervalMinutes = parseInt(opts.interval as string, 10);
      const failureThreshold = parseInt(opts.failureThreshold as string, 10);
      const options = {
        branch: opts.branch as string,
        testCommand: opts.testCommand as string,
        intervalMinutes,
        failureThreshold,
        dryRun: Boolean(opts.dryRun),
      };
      const agent = new SentinelAgent(store, seeds, registered.id, projectPath, vcs);
      // Write lockfile
      writeSentinelLock(registered.id, {
        pid: process.pid,
        startedAt: new Date().toISOString(),
        branch: options.branch,
        intervalMinutes,
        testCommand: options.testCommand,
      });

      // Persist sentinel config to DB
      await store.upsertSentinelConfig(registered.id, {
        branch: options.branch,
        test_command: options.testCommand,
        interval_minutes: intervalMinutes,
        failure_threshold: failureThreshold,
        enabled: 1,
        pid: process.pid,
      });

      console.log(chalk.bold("QA Sentinel started"));
      console.log(chalk.dim(`  Project:   ${registered.name}`));
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
        removeSentinelLock(registered.id);
        void store.upsertSentinelConfig(registered.id, { enabled: 0, pid: null });
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

// ─────────────────────────────────────────────────────────────────────────────
// foreman sentinel status
// ─────────────────────────────────────────────────────────────────────────────

sentinelCommand
  .command("status")
  .description("Show recent sentinel run history")
  .option("--project <name-or-id>", "Project name or ID (defaults to current directory)")
  .option("--limit <n>", "Number of recent runs to show", "10")
  .option("--json", "Output as JSON")
  .action(async (opts) => {
    try {
      const registered = await resolveProject({ project: opts.project });
      if (!registered) {
        const projectHint = opts.project
          ? `No project found matching '${opts.project}'`
          : "Not in a foreman project directory. Run `foreman init` or use --project.";
        console.error(chalk.red(`Error: ${projectHint}`));
        process.exit(1);
      }

      const projectPath = registered.path;
      const localStore = ForemanStore.forProject(projectPath);
      ensureCliPostgresPool(projectPath);
      const store = wrapPostgresSentinelStore(PostgresStore.forProject(registered.id), registered.id);

      const limit = parseInt(opts.limit as string, 10);
      const runs = await store.getSentinelRuns(registered.id, limit);
      const config = await store.getSentinelConfig(registered.id);
      const lock = readSentinelLock(registered.id);

      if (opts.json) {
        console.log(JSON.stringify({ config, lock, runs }, null, 2));
        localStore.close();
        if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
          (store as { close: () => void }).close();
        }
        return;
      }

      // Check if actually running (via lockfile PID)
      let isRunning = false;
      if (lock) {
        try {
          process.kill(lock.pid, 0);
          isRunning = true;
        } catch {
          // Process dead, clean up stale lock
          removeSentinelLock(registered.id);
        }
      }

      const statusBadge = isRunning ? chalk.green("running") : chalk.dim("stopped");
      console.log(chalk.bold(`Sentinel status: ${statusBadge}`));
      console.log(chalk.dim(`  Project:  ${registered.name} (${registered.id})`));
      if (config) {
        console.log(chalk.dim(`  Branch:   ${config.branch}  |  Command: ${config.test_command}  |  Interval: ${config.interval_minutes}m`));
      }
      if (lock) {
        console.log(chalk.dim(`  Started:  ${new Date(lock.startedAt).toLocaleString()}`));
        console.log(chalk.dim(`  PID:      ${lock.pid}`));
      }
      console.log();

      if (runs.length === 0) {
        console.log(chalk.dim("No sentinel runs recorded yet."));
      } else {
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
      }
      console.log();

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

// ─────────────────────────────────────────────────────────────────────────────
// foreman sentinel stop
// ─────────────────────────────────────────────────────────────────────────────

sentinelCommand
  .command("stop")
  .description("Stop the continuous sentinel monitoring loop")
  .option("--project <name-or-id>", "Project name or ID (defaults to current directory)")
  .option("--force", "Force kill with SIGKILL instead of SIGTERM")
  .action(async (opts) => {
    try {
      const registered = await resolveProject({ project: opts.project });
      if (!registered) {
        const projectHint = opts.project
          ? `No project found matching '${opts.project}'`
          : "Not in a foreman project directory. Run `foreman init` or use --project.";
        console.error(chalk.red(`Error: ${projectHint}`));
        process.exit(1);
      }

      const projectPath = registered.path;
      ensureCliPostgresPool(projectPath);
      const store = wrapPostgresSentinelStore(PostgresStore.forProject(registered.id), registered.id);

      const result = await stopProjectSentinel(registered.id, Boolean(opts.force));

      if (result.stopped) {
        console.log(chalk.green(`✓ ${result.message}`));
      } else {
        console.log(chalk.dim(result.message));
      }

      // Also update DB config
      await store.upsertSentinelConfig(registered.id, { enabled: 0, pid: null });

      if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
        (store as { close: () => void }).close();
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });

// ─────────────────────────────────────────────────────────────────────────────
// foreman sentinel list
// ─────────────────────────────────────────────────────────────────────────────

sentinelCommand
  .command("list")
  .description("List all registered projects with sentinel status")
  .option("--json", "Output as JSON")
  .action(async (opts) => {
    try {
      const projects = await listRegisteredProjects();

      if (projects.length === 0) {
        console.log(chalk.dim("No projects registered. Run `foreman init` first."));
        return;
      }

      interface ProjectSentinelStatus {
        id: string;
        name: string;
        path: string;
        sentinelRunning: boolean;
        lock: SentinelLock | null;
        config: unknown;
      }

      const statuses: ProjectSentinelStatus[] = [];

      for (const project of projects) {
        ensureCliPostgresPool(project.path);
        const store = wrapPostgresSentinelStore(PostgresStore.forProject(project.id), project.id);
        const lock = readSentinelLock(project.id);
        const config = await store.getSentinelConfig(project.id);

        let sentinelRunning = false;
        if (lock) {
          try {
            process.kill(lock.pid, 0);
            sentinelRunning = true;
          } catch {
            // Process dead, clean up stale lock
            removeSentinelLock(project.id);
          }
        }

        statuses.push({
          id: project.id,
          name: project.name,
          path: project.path,
          sentinelRunning,
          lock: sentinelRunning ? lock : null,
          config,
        });

        if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
          (store as { close: () => void }).close();
        }
      }

      if (opts.json) {
        console.log(JSON.stringify(statuses, null, 2));
        return;
      }

      console.log(chalk.bold(`\n  Projects with Sentinel Status (${statuses.length})\n`));

      for (const status of statuses) {
        const badge = status.sentinelRunning
          ? chalk.green("● running")
          : chalk.dim("○ stopped");
        console.log(`  ${chalk.bold(status.name)}  ${badge}`);
        console.log(chalk.dim(`    ${status.id}  ·  ${status.path}`));
        if (status.lock) {
          console.log(chalk.dim(`    PID: ${status.lock.pid}  ·  Started: ${new Date(status.lock.startedAt).toLocaleString()}`));
        }
        console.log();
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });
