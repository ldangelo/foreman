import { Command } from "commander";
import chalk from "chalk";

import { createTaskClient } from "../../lib/task-client-factory.js";
import { ForemanStore } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { Monitor } from "../../orchestrator/monitor.js";
import { ensureCliPostgresPool, listRegisteredProjects, resolveRepoRootProjectPath } from "./project-task-support.js";

export const monitorCommand = new Command("monitor")
  .description("[deprecated] Check agent progress and detect stuck runs. Use 'foreman reset --detect-stuck' instead.")
  .option("--recover", "Auto-recover stuck agents (ignored when --json is used)")
  .option("--timeout <minutes>", "Stuck detection timeout in minutes", "15")
  .option("--json", "Output monitor report as JSON (note: --recover is ignored in this mode)")
  .action(async (opts) => {
    const timeoutMinutes = parseInt(opts.timeout, 10);

    // Warn when --json and --recover are combined — recovery is silently skipped in JSON mode
    if (opts.json && opts.recover) {
      console.warn("Warning: --recover is ignored when --json is used; recovery actions will not be performed.");
    }

    // Deprecation warning (skip when --json is used for clean automation output)
    if (!opts.json) {
      console.warn(
        chalk.yellow(
          "⚠  'foreman monitor' is deprecated. Use 'foreman reset --detect-stuck' instead.\n" +
          "   Recovery: foreman reset --detect-stuck\n" +
          "   Preview:  foreman reset --detect-stuck --dry-run\n",
        ),
      );
    }

    try {
      const projectPath = await resolveRepoRootProjectPath({});
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
      const { taskClient } = await createTaskClient(projectPath, { ensureBrInstalled: true });
      const registered = (await listRegisteredProjects()).find((project) => project.path === projectPath);
      if (registered) {
        ensureCliPostgresPool(projectPath);
      }
      const store = registered
        ? PostgresStore.forProject(registered.id)
        : (() => {
            const local = ForemanStore.forProject(projectPath);
            return {
              getActiveRuns: async (projectId?: string) => local.getActiveRuns(projectId),
              updateRun: async (runId: string, updates: Parameters<typeof local.updateRun>[1]) => local.updateRun(runId, updates),
              logEvent: async (projectId: string, eventType: Parameters<typeof local.logEvent>[1], data: Record<string, unknown>, runId?: string) => local.logEvent(projectId, eventType, data, runId),
              getRunProgress: async (runId: string) => local.getRunProgress(runId),
              getRunEvents: async (runId: string, eventType?: "recover") =>
                local.getRunEvents(runId, eventType).map((event) => ({
                  id: event.id,
                  event_type: event.event_type,
                  data: event.details ?? "{}",
                  created_at: event.created_at,
                })),
              close: () => local.close(),
            };
          })();
      const monitor = new Monitor(store, taskClient, projectPath, vcs);

      if (!opts.json) {
        console.log(chalk.bold("Checking agent status...\n"));
      }

      const report = await monitor.checkAll({
        stuckTimeoutMinutes: timeoutMinutes,
      });

      // JSON output path — serialize MonitorReport directly
      if (opts.json) {
        console.log(JSON.stringify(report, null, 2));
        if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
          (store as { close: () => void }).close();
        }
        return;
      }

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

      if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
        (store as { close: () => void }).close();
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (opts.json) {
        console.error(JSON.stringify({ error: message }));
      } else {
        console.error(chalk.red(`Error: ${message}`));
      }
      process.exit(1);
    }
  });
