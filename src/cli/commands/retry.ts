import { Command } from "commander";
import chalk from "chalk";

import { createTaskClient, type TaskClientBackend } from "../../lib/task-client-factory.js";
import { foremanBackendMode } from "../../lib/backend-mode.js";
import { ElixirServerClient } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { resolveRepoRootProjectPath, requireProjectOrAllInMultiMode } from "./project-task-support.js";
import { findRegisteredProjectByPath } from "./project-context.js";
import { closeStoreIfPossible, wrapLocalRunStore } from "./local-store-adapter.js";
import { printDryRunNotice } from "./cli-output.js";
import { getTaskRetryTargetStatus } from "../../lib/run-status.js";
import { ForemanStore } from "../../lib/store.js";
import type { ITaskClient } from "../../lib/task-client.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { ModelSelection } from "../../orchestrator/types.js";

// ── Types ─────────────────────────────────────────────────────────────

export interface RetryOpts {
  dispatch?: boolean;
  model?: ModelSelection;
  dryRun?: boolean;
}

interface RetryStore {
  getProjectByPath(path: string): Promise<{ id: string; path: string } | null>;
  getRunsForTask(taskId: string, projectId: string): Promise<import("../../lib/store.js").Run[]>;
  updateRun(runId: string, updates: Partial<Pick<import("../../lib/store.js").Run, "status" | "completed_at">>): Promise<void>;
  logEvent(projectId: string, eventType: "restart", data: Record<string, unknown>, runId?: string): Promise<void>;
}

async function createElixirRetryClient(): Promise<ElixirServerClient> {
  const manager = new ElixirServerManager();
  const status = await manager.ensureRunning();
  return new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
}

function elixirTaskStatus(task: Record<string, unknown>): string {
  const status = task.status;
  return typeof status === "string" ? status : "backlog";
}

async function retryElixirTask(
  beadId: string,
  opts: RetryOpts,
  projectPath: string,
  projectId: string,
): Promise<number> {
  const dryRun = opts.dryRun ?? false;
  printDryRunNotice(dryRun);

  const client = await createElixirRetryClient();
  const task = await client.getTask(beadId);
  if (!task || (task.project_id && task.project_id !== projectId)) {
    console.error(chalk.red(`Bead "${beadId}" not found: Task '${beadId}' not found`));
    return 1;
  }

  const beadStatus = elixirTaskStatus(task as unknown as Record<string, unknown>);
  console.log(
    chalk.bold(`Retrying bead: ${chalk.cyan(beadId)}`) +
      (typeof task.title === "string" ? chalk.dim(` (${task.title})`) : ""),
  );
  console.log(`  Status: ${chalk.yellow(beadStatus)}`);

  const runs = (await client.listRuns({ projectId }))
    .filter((run) => run.task_id === beadId)
    .sort((a, b) => String(b.run_id ?? "").localeCompare(String(a.run_id ?? "")));
  const latestRun = runs[0] ?? null;

  if (latestRun) {
    console.log(`  Latest run: ${chalk.dim(String(latestRun.run_id ?? "(unknown)"))} status=${latestRun.status ?? "unknown"}`);
  } else {
    console.log(`  Latest run: ${chalk.dim("(none)")}`);
  }

  const beadResetTarget = getTaskRetryTargetStatus(beadStatus, { command: "retry", backendType: "native" });
  const beadNeedsReset = beadResetTarget !== null && beadResetTarget !== beadStatus;
  const beadIsAlreadyRetryable = beadResetTarget !== null && beadResetTarget === beadStatus;

  if (!dryRun) {
    if (beadNeedsReset) {
      console.log(`  ${chalk.yellow("reset")} bead status: ${beadStatus} → ${beadResetTarget}`);
      await client.sendCommand({
        command_id: `retry-task-${beadId}-${Date.now()}`,
        command_type: "task.update",
        payload: { project_id: projectId, task_id: beadId, status: beadResetTarget },
        metadata: { source: "foreman-retry" },
      }).then((response) => {
        if (!response.ok) throw new Error(response.error.message);
      });
    } else if (beadIsAlreadyRetryable) {
      console.log(`  ${chalk.dim("ok")} bead status is already "${beadStatus}"`);
    } else {
      console.log(`  ${chalk.dim("skip")} bead status is terminal: ${beadStatus}`);
    }
  } else {
    if (beadNeedsReset) {
      console.log(chalk.dim(`  Would reset bead status: ${beadStatus} → ${beadResetTarget}`));
    } else if (beadResetTarget == null) {
      console.log(chalk.dim(`  Would leave bead status unchanged: ${beadStatus} is terminal`));
    }
  }

  if (opts.dispatch) {
    console.log();
    console.log(chalk.bold("Dispatching…"));
    if (dryRun) {
      console.log(chalk.dim(`  Would request scheduler dispatch for ${beadId}`));
    } else {
      const result = await client.schedulerTick();
      console.log(`  ${chalk.green("queued")} scheduler tick accepted`);
      void result;
    }
  }

  console.log();
  if (dryRun) {
    console.log(chalk.yellow("Dry run complete — no changes were made."));
  } else {
    console.log(
      chalk.green("Done.") +
        (opts.dispatch ? "" : chalk.dim(" Use --dispatch to immediately queue a new run.")),
    );
  }

  return 0;
}

// ── Core action (exported for testing) ───────────────────────────────

/**
 * Core retry logic extracted for testability.
 * Returns the exit code (0 = success, 1 = error).
 */
export async function retryAction(
  beadId: string,
  opts: RetryOpts,
  beadsClient: ITaskClient,
  store: RetryStore,
  projectPath: string,
  dispatcher?: Dispatcher,
  backendType: TaskClientBackend = "native",
): Promise<number> {
  const dryRun = opts.dryRun ?? false;

  printDryRunNotice(dryRun);

  // 1. Validate project exists
  const project = await store.getProjectByPath(projectPath);
  if (!project) {
    console.error(
      chalk.red("No project registered for this path. Run 'foreman init' first."),
    );
    return 1;
  }

  // 2. Look up bead via the active task client
  let bead: Awaited<ReturnType<ITaskClient["show"]>>;
  try {
    bead = await beadsClient.show(beadId);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(chalk.red(`Bead "${beadId}" not found: ${msg}`));
    return 1;
  }

  const beadTitle =
    typeof bead === "object" && bead !== null && "title" in bead && typeof bead.title === "string"
      ? bead.title
      : undefined;

  console.log(
    chalk.bold(`Retrying bead: ${chalk.cyan(beadId)}`) +
      (beadTitle ? chalk.dim(` (${beadTitle})`) : ""),
  );
  console.log(`  Status: ${chalk.yellow(bead.status)}`);

  // 3. Look up run history
  const runs = await store.getRunsForTask(beadId, project.id);
  const latestRun = runs.length > 0 ? runs[0] : null;

  if (latestRun) {
    console.log(
      `  Latest run: ${chalk.dim(latestRun.id)} status=${latestRun.status}`,
    );
  } else {
    console.log(`  Latest run: ${chalk.dim("(none)")}`);
  }

  // 4. Determine what needs to be reset
  const beadResetTarget = getTaskRetryTargetStatus(bead.status, { command: "retry", backendType });
  const beadNeedsReset = beadResetTarget !== null && beadResetTarget !== bead.status;
  const beadIsAlreadyRetryable = beadResetTarget !== null && beadResetTarget === bead.status;

  const runNeedsReset =
    latestRun !== null &&
    (latestRun.status === "stuck" ||
      latestRun.status === "running" ||
      latestRun.status === "pending" ||
      latestRun.status === "failed");

  const runNeedsExplicitReset =
    latestRun !== null &&
    (latestRun.status === "completed" ||
      latestRun.status === "merged" ||
      latestRun.status === "pr-created" ||
      latestRun.status === "conflict" ||
      latestRun.status === "test-failed");

  // 5. Apply resets
  if (!dryRun) {
    // Reset bead status to a retryable state when appropriate.
    if (beadNeedsReset) {
      console.log(
        `  ${chalk.yellow("reset")} bead status: ${bead.status} → ${beadResetTarget}`,
      );
      if (beadResetTarget === "ready" && typeof beadsClient.resetToReady === "function") {
        await beadsClient.resetToReady(beadId);
      } else {
        await beadsClient.update(beadId, { status: beadResetTarget! });
      }
    } else if (beadIsAlreadyRetryable) {
      console.log(`  ${chalk.dim("ok")} bead status is already "${bead.status}"`);
    } else {
      console.log(
        `  ${chalk.dim("skip")} bead status is terminal: ${bead.status}`,
      );
    }

    // Mark latest run as failed so it won't block a new dispatch
    if (runNeedsReset && latestRun) {
      console.log(
        `  ${chalk.yellow("reset")} run ${latestRun.id}: ${latestRun.status} → failed`,
      );
        await store.updateRun(latestRun.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        await store.logEvent(
          project.id,
          "restart",
          { reason: "foreman retry", beadId, previousRunId: latestRun.id },
          latestRun.id,
        );
    } else if (runNeedsExplicitReset && latestRun) {
      console.log(
        `  ${chalk.yellow("reset")} run ${latestRun.id}: ${latestRun.status} → reset`,
      );
        await store.updateRun(latestRun.id, {
          status: "reset",
          completed_at: new Date().toISOString(),
        });
        await store.logEvent(
          project.id,
          "restart",
          { reason: "foreman retry", beadId, previousRunId: latestRun.id },
          latestRun.id,
      );
    } else if (latestRun) {
      // Run exists but doesn't need resetting (already completed/merged/etc.)
      console.log(
        `  ${chalk.dim("skip")} run status "${latestRun.status}" does not need reset`,
      );
    }
  } else {
    // Dry-run: just describe what would happen
    if (beadNeedsReset) {
      console.log(
        chalk.dim(
          `  Would reset bead status: ${bead.status} → ${beadResetTarget}`,
        ),
      );
    } else if (beadResetTarget == null) {
      console.log(
        chalk.dim(
          `  Would leave bead status unchanged: ${bead.status} is terminal`,
        ),
      );
    }
    if (runNeedsReset && latestRun) {
      console.log(
        chalk.dim(
          `  Would reset run ${latestRun.id}: ${latestRun.status} → failed`,
        ),
      );
    }
    if (runNeedsExplicitReset && latestRun) {
      console.log(
        chalk.dim(
          `  Would reset run ${latestRun.id}: ${latestRun.status} → reset`,
        ),
      );
    }
  }

  // 6. Optionally dispatch
  if (opts.dispatch) {
    console.log();
    console.log(chalk.bold("Dispatching…"));
    const disp = dispatcher
      ?? (store instanceof ForemanStore
        ? new Dispatcher(beadsClient, store, projectPath)
        : null);
    if (!disp) {
      throw new Error("Dispatcher unavailable for daemon-backed retry path.");
    }
    const result = await disp.dispatch({
      maxAgents: 1,
      model: opts.model,
      taskId: beadId,
      dryRun,
    });

    if (result.dispatched.length > 0) {
      for (const t of result.dispatched) {
        console.log(
          `  ${chalk.green("dispatched")} ${t.taskId} → worktree ${t.worktreePath}`,
        );
      }
    } else if (result.skipped.length > 0) {
      for (const s of result.skipped) {
        console.log(
          `  ${chalk.yellow("skipped")} ${s.taskId}: ${s.reason}`,
        );
      }
    } else {
      console.log(
        `  ${chalk.yellow("warn")} no tasks dispatched`,
      );
    }
  }

  console.log();
  if (dryRun) {
    console.log(chalk.yellow("Dry run complete — no changes were made."));
  } else {
    console.log(
      chalk.green("Done.") +
        (opts.dispatch
          ? ""
          : chalk.dim(" Use --dispatch to immediately queue a new run.")),
    );
  }

  return 0;
}

// ── CLI Command ─────────────────────────────────────────────────────────

export const retryCommand = new Command("retry")
  .description(
    "Reset a task and optionally re-dispatch it for execution",
  )
  .argument("<task-id>", "Task ID to retry (alias: bead-id for backward compatibility)")
  .option("--dispatch", "Dispatch the task immediately after resetting")
  .option("--model <model>", "Override agent model for dispatch")
  .option("--dry-run", "Show what would happen without making changes")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (beadId: string, opts: RetryOpts & { project?: string; projectPath?: string }) => {
    // Require --project in multi-project mode
    await requireProjectOrAllInMultiMode(opts.project, false);

    let projectPath: string;
    try {
      projectPath = await resolveRepoRootProjectPath({
        project: opts.project,
        projectPath: opts.projectPath,
      });
    } catch {
      console.error(
        chalk.red(
          "Not in a git repository. Run from within a foreman project.",
        ),
      );
      process.exit(1);
      return;
    }

    const localStore = ForemanStore.forProject(projectPath);
    const registered = await findRegisteredProjectByPath(projectPath, { normalizePaths: true });

    if (foremanBackendMode() === "elixir") {
      if (!registered) {
        console.error(
          chalk.red(
            `Project at '${projectPath}' is not registered in Elixir projections. Run 'foreman project register ${projectPath}'.`,
          ),
        );
        localStore.close();
        process.exit(1);
        return;
      }

      try {
        const exitCode = await retryElixirTask(beadId, opts, projectPath, registered.id);
        localStore.close();
        process.exit(exitCode);
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(chalk.red(`Unexpected error: ${msg}`));
        localStore.close();
        process.exit(1);
      }
      return;
    }

    if (registered) {
      try {
        const exitCode = await retryElixirTask(beadId, opts, projectPath, registered.id);
        localStore.close();
        process.exit(exitCode);
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(chalk.red(`Unexpected error: ${msg}`));
        localStore.close();
        process.exit(1);
      }
      return;
    }

    const store: RetryStore = wrapLocalRunStore(localStore);
    const { taskClient, backendType } = await createTaskClient(projectPath);
    const dispatcher = undefined;

    try {
      const exitCode = await retryAction(
        beadId,
        opts,
        taskClient,
        store,
        projectPath,
        dispatcher,
        backendType,
      );
      localStore.close();
      closeStoreIfPossible(store);
      process.exit(exitCode);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Unexpected error: ${msg}`));
      localStore.close();
      closeStoreIfPossible(store);
      process.exit(1);
    }
  });
