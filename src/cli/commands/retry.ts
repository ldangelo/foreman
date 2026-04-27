import { Command } from "commander";
import chalk from "chalk";

import { createTaskClient, type TaskClientBackend } from "../../lib/task-client-factory.js";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { PostgresAdapter } from "../../lib/db/postgres-adapter.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import { resolveRepoRootProjectPath, requireProjectOrAllInMultiMode, listRegisteredProjects, ensureCliPostgresPool } from "./project-task-support.js";
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
  getRunsForSeed(seedId: string, projectId: string): Promise<import("../../lib/store.js").Run[]>;
  updateRun(runId: string, updates: Partial<Pick<import("../../lib/store.js").Run, "status" | "completed_at">>): Promise<void>;
  logEvent(projectId: string, eventType: "restart", data: Record<string, unknown>, runId?: string): Promise<void>;
}

function wrapLocalRetryStore(store: ForemanStore): RetryStore {
  return {
    getProjectByPath: async (path) => store.getProjectByPath(path),
    getRunsForSeed: async (seedId, projectId) => store.getRunsForSeed(seedId, projectId),
    updateRun: async (runId, updates) => store.updateRun(runId, updates),
    logEvent: async (projectId, eventType, data, runId) => store.logEvent(projectId, eventType, data, runId),
  };
}

function createDaemonTaskClient(client: ReturnType<typeof createTrpcClient>, projectId: string): ITaskClient {
  return {
    async show(id: string) {
      const task = await client.tasks.get({ projectId, taskId: id }) as { status: string; description?: string | null; title?: string } | null;
      if (!task) throw new Error(`Task '${id}' not found`);
      return { status: task.status, description: task.description ?? null, title: task.title };
    },
    async update(id: string, opts) {
      await client.tasks.update({
        projectId,
        taskId: id,
        updates: {
          status: opts.status,
          title: opts.title,
          description: opts.description ?? undefined,
        },
      });
    },
    async resetToReady(id: string) {
      await client.tasks.retry({ projectId, taskId: id });
    },
    async ready() { return []; },
    async list() { return []; },
    async close() { throw new Error("not implemented"); },
  } as ITaskClient;
}

const RETRYABLE_NATIVE_STATUSES = new Set([
  "backlog",
  "ready",
  "in-progress",
  "blocked",
  "conflict",
  "failed",
  "stuck",
  "explorer",
  "developer",
  "qa",
  "reviewer",
  "finalize",
]);

function getRetryTargetStatus(
  currentStatus: string,
  backendType: TaskClientBackend,
): "open" | "ready" | null {
  if (backendType === "native") {
    if (currentStatus === "closed" || currentStatus === "completed" || currentStatus === "merged") {
      return null;
    }

    if (currentStatus === "ready") {
      return "ready";
    }

    if (RETRYABLE_NATIVE_STATUSES.has(currentStatus)) {
      return "ready";
    }

    return null;
  }

  if (currentStatus === "open") {
    return "open";
  }

  if (currentStatus === "closed" || currentStatus === "completed" || currentStatus === "merged") {
    return null;
  }

  if (currentStatus === "in_progress" || currentStatus === "blocked") {
    return "open";
  }

  return null;
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
  backendType: TaskClientBackend = "beads",
): Promise<number> {
  const dryRun = opts.dryRun ?? false;

  if (dryRun) {
    console.log(chalk.yellow("(dry run — no changes will be made)\n"));
  }

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
  const runs = await store.getRunsForSeed(beadId, project.id);
  const latestRun = runs.length > 0 ? runs[0] : null;

  if (latestRun) {
    console.log(
      `  Latest run: ${chalk.dim(latestRun.id)} status=${latestRun.status}`,
    );
  } else {
    console.log(`  Latest run: ${chalk.dim("(none)")}`);
  }

  // 4. Determine what needs to be reset
  const beadResetTarget = getRetryTargetStatus(bead.status, backendType);
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
      seedId: beadId,
      dryRun,
    });

    if (result.dispatched.length > 0) {
      for (const t of result.dispatched) {
        console.log(
          `  ${chalk.green("dispatched")} ${t.seedId} → worktree ${t.worktreePath}`,
        );
      }
    } else if (result.skipped.length > 0) {
      for (const s of result.skipped) {
        console.log(
          `  ${chalk.yellow("skipped")} ${s.seedId}: ${s.reason}`,
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
    "Reset a bead and optionally re-dispatch it for execution",
  )
  .argument("<bead-id>", "Bead ID (seed ID) to retry, e.g. bd-ps1")
  .option("--dispatch", "Dispatch the bead immediately after resetting")
  .option("--model <model>", "Override agent model for dispatch")
  .option("--dry-run", "Show what would happen without making changes")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (beadId: string, opts: RetryOpts & { project?: string; projectPath?: string }) => {
    // Require --project in multi-project mode
    await requireProjectOrAllInMultiMode(opts.project, false);

    let projectPath: string;
    try {
      projectPath = await resolveRepoRootProjectPath(opts);
    } catch {
      console.error(
        chalk.red(
          "Not in a git repository. Run from within a foreman project.",
        ),
      );
      process.exit(1);
    }

    const localStore = ForemanStore.forProject(projectPath);
    const registered = (await listRegisteredProjects()).find((project) => project.path === projectPath);
    if (registered) {
      ensureCliPostgresPool(projectPath);
    }
    const store: RetryStore = registered ? PostgresStore.forProject(registered.id) : wrapLocalRetryStore(localStore);
    const { taskClient, backendType } = registered
      ? { taskClient: createDaemonTaskClient(createTrpcClient(), registered.id), backendType: "native" as const }
      : await createTaskClient(projectPath);
    const dispatcher = registered
      ? (() => {
          const pg = new PostgresAdapter();
          return new Dispatcher(taskClient, localStore, projectPath, null, {
            externalProjectId: registered.id,
            getRecentFailureCount: async (_projectId, since) => {
              const failures = await pg.listTasks(registered.id, { status: ["failed", "stuck", "conflict"], limit: 1000 });
              return failures.filter((t) => t.updated_at >= since).length;
            },
            getActiveSeedIds: async () => {
              const active = await pg.listPipelineRuns(registered.id, { status: "running", limit: 1000 });
              const pending = await pg.listPipelineRuns(registered.id, { status: "pending", limit: 1000 });
              return [...active, ...pending].map((r) => r.bead_id);
            },
            getActiveAgentCount: async () => {
              const active = await pg.listPipelineRuns(registered.id, { status: "running", limit: 1000 });
              const pending = await pg.listPipelineRuns(registered.id, { status: "pending", limit: 1000 });
              return active.length + pending.length;
            },
            hasActiveOrPendingRun: async (seedId) => {
              const runs = await pg.listPipelineRuns(registered.id, { beadId: seedId, limit: 20 });
              return runs.some((r) => ["pending", "running", "success"].includes(r.status));
            },
            nativeTaskOps: {
              hasNativeTasks: async () => pg.hasNativeTasks(registered.id),
              getReadyTasks: async () => await pg.listTasks(registered.id, { status: ["ready"], limit: 1000 }) as never,
              getTaskByExternalId: async (externalId) => await pg.getTaskByExternalId(registered.id, externalId) as never,
              getTaskById: async (taskId) => await pg.getTask(registered.id, taskId) as never,
              claimTask: async (taskId, runId) => await pg.claimTask(registered.id, taskId, runId),
            },
          });
        })()
      : undefined;

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
      if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
        (store as { close: () => void }).close();
      }
      process.exit(exitCode);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Unexpected error: ${msg}`));
      localStore.close();
      if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
        (store as { close: () => void }).close();
      }
      process.exit(1);
    }
  });
