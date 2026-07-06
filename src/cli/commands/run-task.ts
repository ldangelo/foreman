/**
 * `foreman run task` — Direct workflow execution for a specific task.
 *
 * This command bypasses state-gating and executes the specified workflow
 * for a given task regardless of its current state (failed, closed,
 * in-progress, backlog, etc.).
 *
 * Usage: foreman run task <task-id> <workflow-path> [options]
 *
 * This separates scheduling/orchestration decisions from deterministic
 * workflow execution, making tasks directly runnable for debugging,
 * recovery, testing, and manual operation.
 *
 * @module src/cli/commands/run-task
 */

import { Command, Option } from "commander";
import chalk from "chalk";

import { resolveRepoRootProjectPath, listRegisteredProjects } from "./project-task-support.js";
import type { RegisteredProjectSummary } from "./project-task-support.js";
import { createTaskClient } from "../../lib/task-client-factory.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import { ForemanStore } from "../../lib/store.js";
import type { Run } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import { PostgresAdapter } from "../../lib/db/postgres-adapter.js";
import { loadProjectConfig, resolveVcsConfig } from "../../lib/project-config.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import type { VcsBackend } from "../../lib/vcs/interface.js";
import { WorktreeManager } from "../../lib/worktree-manager.js";
import { installDependencies, runSetupWithCache } from "../../lib/setup.js";
import { runWorkspaceHook } from "../../lib/setup.js";
import { loadWorkflowConfig } from "../../lib/workflow-loader.js";
import type { WorkflowConfig } from "../../lib/workflow-loader.js";
import type { ModelSelection } from "../../orchestrator/types.js";
import { buildWorkerEnv, spawnWorkerProcess } from "../../orchestrator/dispatcher.js";
import { getRunReportsDir } from "../../lib/report-paths.js";
import { normalizeBranchLabel } from "../../lib/branch-label.js";
import type { TaskInfo } from "../../orchestrator/types.js";
import { autoMerge } from "../../orchestrator/auto-merge.js";
import { watchRunsInk } from "../watch-ui.js";
import { NotificationServer } from "../../orchestrator/notification-server.js";
import { notificationBus } from "../../orchestrator/notification-bus.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { ElixirServerClient, type ElixirTask } from "../../lib/elixir-server-client.js";

// ── Types ──────────────────────────────────────────────────────────────────

// ── Helpers ────────────────────────────────────────────────────────────────

/**
 * Build the deprecation warning for the retired `--skip-explore` /
 * `--skip-review` flags.
 *
 * These flags were never consumed by the workflow YAML-driven pipeline — phase
 * shape is defined entirely by the workflow YAML. They are kept as hidden
 * no-ops for backwards compatibility.
 *
 * The suggested replacement is context-aware: `foreman run` selects workflows
 * via the `--workflow <name>` flag, while `foreman run task` takes the
 * workflow as a positional argument.
 *
 * @param context - Which command emitted the warning: "run" (default) or "task".
 * @returns The one-line warning text, or null when neither flag is set.
 */
export function skipFlagsDeprecationWarning(
  opts: {
    skipExplore?: boolean;
    skipReview?: boolean;
  },
  context: "run" | "task" = "run",
): string | null {
  const flags: string[] = [];
  if (opts.skipExplore) flags.push("--skip-explore");
  if (opts.skipReview) flags.push("--skip-review");
  if (flags.length === 0) return null;
  const suggestion = context === "task"
    ? "pass `quick` (or a custom workflow YAML) as the workflow argument instead."
    : "use --workflow quick (or a custom workflow YAML) instead.";
  return (
    `${flags.join(" and ")} ${flags.length > 1 ? "are" : "is"} deprecated and ` +
    `${flags.length > 1 ? "have" : "has"} no effect on the pipeline — ${suggestion}`
  );
}

/**
 * Convert an Issue to TaskInfo format for the worker.
 */
function issueToTaskInfo(task: Issue): TaskInfo {
  return {
    id: task.id,
    title: task.title,
    description: task.description ?? undefined,
    priority: task.priority,
    type: task.type,
    labels: task.labels,
  };
}

async function fetchElixirTask(taskId: string, projectPath: string): Promise<Issue | null> {
  try {
    const manager = new ElixirServerManager();
    if (!(await manager.health()).ok) return null;
    const client = new ElixirServerClient(manager.url, process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN);
    const task = await client.getTask(taskId);
    return task ? elixirTaskToIssue(task, projectPath, taskId) : null;
  } catch {
    return null;
  }
}

function elixirTaskToIssue(task: ElixirTask, projectPath: string, fallbackId: string): Issue {
  const id = task.task_id ?? task.id ?? fallbackId;
  const now = new Date().toISOString();
  return {
    id,
    title: task.title ?? id,
    status: normalizeElixirStatus(task.status ?? "backlog"),
    description: task.description ?? null,
    type: task.task_type ?? task.type ?? "task",
    priority: String(typeof task.priority === "number" ? task.priority : 2),
    assignee: null,
    parent: null,
    labels: [`project:${projectPath}`],
    created_at: task.created_at ?? now,
    updated_at: task.updated_at ?? now,
  };
}

function normalizeElixirStatus(status: string): string {
  if (status === "in_progress") return "in-progress";
  if (status === "open") return "backlog";
  if (status === "completed") return "closed";
  return status;
}

/**
 * Resolve the registered project for a given path.
 */
async function resolveRegisteredProject(projectPath: string): Promise<RegisteredProjectSummary | null> {
  const projects = await listRegisteredProjects();
  return projects.find((project) => project.path === projectPath) ?? null;
}

/**
 * Check if a worktree is already in use by an active run.
 * Returns the run ID if locked, null otherwise.
 */
async function checkWorktreeLock(
  store: ForemanStore | PostgresStore,
  taskId: string,
  projectId: string,
): Promise<string | null> {
  const runs = await store.getRunsForTask(taskId, projectId);
  const activeRun = runs.find(
    (r) => r.status === "running" || r.status === "pending",
  );
  return activeRun ? activeRun.id : null;
}

// ── Run Task Command ───────────────────────────────────────────────────────

/**
 * Execute a workflow directly for a specific task, bypassing state-gating.
 *
 * Key behaviors:
 * - Runs the specified workflow for the given task regardless of task state
 * - Uses normal task metadata, workspace/run records, logs, reports, mail
 * - Does NOT require the task to be ready/backlog/etc.
 * - Maintains worktree locking for safety
 */
export async function runTaskAction(
  taskId: string,
  workflowPath: string,
  opts: {
    model?: string;
    /** @deprecated No effect — phase shape is defined by the workflow YAML. */
    skipExplore?: boolean;
    /** @deprecated No effect — phase shape is defined by the workflow YAML. */
    skipReview?: boolean;
    dryRun?: boolean;
    watch?: boolean;
    targetBranch?: string;
    runId?: string;
    project?: string;
    projectPath?: string;
  },
): Promise<number> {
  const {
    model,
    dryRun = false,
    watch = true,
    targetBranch,
    runId: requestedRunId,
    project,
    projectPath: optsProjectPath,
  } = opts;

  // ── Deprecated flag warning ───────────────────────────────────────────
  const deprecationWarning = skipFlagsDeprecationWarning(opts, "task");
  if (deprecationWarning) {
    console.warn(chalk.yellow(`[foreman] ${deprecationWarning}`));
  }

  // ── Resolve project ───────────────────────────────────────────────────
  const resolvedProjectPath = await resolveRepoRootProjectPath({ project, projectPath: optsProjectPath });
  const registered = await resolveRegisteredProject(resolvedProjectPath);

  // Initialize task clients
  if (registered) {
    // ensureCliPostgresPool is called in run.ts for the main command
  }
  const clients = await createTaskClient(resolvedProjectPath, { registeredProjectId: registered?.id });
  const taskClient = clients.taskClient;

  // ── Look up task (no state gating) ───────────────────────────────────
  let task: Issue | null;
  if (requestedRunId) {
    task = await fetchElixirTask(taskId, resolvedProjectPath);
  } else {
    try {
      task = await taskClient.show(taskId) as Issue;
    } catch {
      task = null;
    }
  }
  if (!task) {
    console.error(chalk.red(`Task '${taskId}' not found`));
    return 1;
  }

  console.log(chalk.bold(`Running task: ${chalk.cyan(taskId)}`));
  console.log(`  Title:   ${chalk.green(task.title)}`);
  console.log(`  Status:  ${chalk.yellow(task.status)}`);
  console.log(`  Type:    ${chalk.cyan(task.type ?? "task")}`);

  // ── Load workflow config ─────────────────────────────────────────────
  let workflowConfig: WorkflowConfig;
  try {
    workflowConfig = loadWorkflowConfig(workflowPath, resolvedProjectPath);
    console.log(`  Workflow: ${chalk.magenta(workflowConfig.name)} (${workflowConfig.phases.length} phases)`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(chalk.red(`Failed to load workflow: ${msg}`));
    return 1;
  }

  // ── Resolve project ID ───────────────────────────────────────────────
  const store = ForemanStore.forProject(resolvedProjectPath);
  const testRuntime = process.env.FOREMAN_RUNTIME_MODE === "test";
  const daemonStore = registered && !testRuntime
    ? PostgresStore.forProject(registered.id)
    : null;
  const projectRecord = registered ?? store.getProjectByPath(resolvedProjectPath);
  if (!projectRecord) {
    console.error(chalk.red("No project registered for this path. Run 'foreman init' first."));
    return 1;
  }
  const projectId = registered?.id ?? projectRecord.id;

  // ── Check worktree lock ───────────────────────────────────────────────
  if (!testRuntime) {
    let lockRunId: string | null;
    try {
      lockRunId = await checkWorktreeLock(daemonStore ?? store, taskId, projectId);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Failed to check worktree lock: ${msg}`));
      store.close();
      return 1;
    }
    if (lockRunId) {
      console.error(chalk.red(`Worktree is locked by active run: ${lockRunId}`));
      console.error(chalk.dim("  Use 'foreman stop' to stop the active run, or 'foreman reset --bead <id>' to reset it"));
      return 1;
    }
  }

  // ── Resolve VCS backend ───────────────────────────────────────────────
  const projectCfg = loadProjectConfig(resolvedProjectPath);
  const vcsConfig = resolveVcsConfig(undefined, projectCfg?.vcs);
  let vcsBackend: VcsBackend | undefined;
  try {
    vcsBackend = await VcsBackendFactory.create(vcsConfig, resolvedProjectPath);
  } catch {
    // Non-fatal: continue without VCS backend
  }

  // ── Get task details ───────────────────────────────────────────────────
  let taskDescription: string | undefined;
  let taskLabels: string[] | undefined;
  try {
    if (requestedRunId) {
      taskDescription = task.description ?? undefined;
      taskLabels = task.labels ?? [];
    } else {
      const detail = await taskClient.show(taskId) as { description?: string | null; labels?: string[] };
      taskDescription = detail?.description ?? undefined;
      taskLabels = detail?.labels ?? [];
    }
  } catch {
    // Non-fatal: use defaults
  }

  // ── Resolve base branch ───────────────────────────────────────────────
  let baseBranch: string | undefined;
  if (vcsBackend) {
    try {
      baseBranch = normalizeBranchLabel(await vcsBackend.detectDefaultBranch(resolvedProjectPath)) ?? undefined;
    } catch {
      // Non-fatal: continue without base branch
    }
  }

  // ── Create worktree ───────────────────────────────────────────────────
  const worktreeManager = new WorktreeManager();
  let worktreePath: string;
  let branchName: string;
  let workspaceWasCreated = false;

  try {
    const worktreeInfo = await worktreeManager.createWorktree({
      projectId,
      beadId: taskId,
      repoPath: resolvedProjectPath,
      baseBranch: targetBranch ?? baseBranch,
    });
    worktreePath = worktreeInfo.path;
    branchName = worktreeInfo.branchName;
    workspaceWasCreated = worktreeInfo.created ?? !worktreeInfo.exists;
    console.log(`  Worktree: ${chalk.dim(worktreePath)}`);
    console.log(`  Branch:   ${chalk.cyan(branchName)}`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(chalk.red(`Failed to create worktree: ${msg}`));
    return 1;
  }

  // ── Run setup steps ───────────────────────────────────────────────────
  if (!dryRun && workflowConfig.setup?.length) {
    try {
      await runSetupWithCache(worktreePath, resolvedProjectPath, workflowConfig.setup, workflowConfig.setupCache);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Setup failed: ${msg}`));
      return 1;
    }
  } else if (!dryRun) {
    try {
      await installDependencies(worktreePath);
    } catch {
      // Non-fatal: dependency install failure
      console.warn(chalk.yellow("Dependency installation failed (non-fatal)"));
    }
  }

  // ── Run afterCreate hook ──────────────────────────────────────────────
  if (!dryRun && workspaceWasCreated && projectCfg?.hooks?.afterCreate) {
    const hookEnv: Record<string, string> = {
      FOREMAN_WORKSPACE_PATH: worktreePath,
      FOREMAN_ISSUE_ID: taskId,
      FOREMAN_ISSUE_IDENTIFIER: taskId,
      FOREMAN_ATTEMPT: "1",
    };
    try {
      await runWorkspaceHook(projectCfg.hooks, "afterCreate", worktreePath, hookEnv);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`afterCreate hook failed: ${msg}`));
      return 1;
    }
  }

  if (dryRun) {
    console.log(chalk.yellow("\n(dry run — no run record created, no worker spawned)\n"));
    console.log(chalk.bold("Would execute workflow:"));
    console.log(`  Task ID:     ${taskId}`);
    console.log(`  Workflow:    ${workflowConfig.name}`);
    console.log(`  Worktree:    ${worktreePath}`);
    console.log(`  Branch:      ${branchName}`);
    console.log(`  Model:       ${model ?? "default (from workflow)"}`);
    store.close();
    return 0;
  }

  // ── Create run record ────────────────────────────────────────────────
  let runId = requestedRunId ?? `run-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
  const attemptNumber = 1;

  try {
    if (requestedRunId) {
      // Elixir scheduler already appended RunStarted and claimed the task.
    } else if (daemonStore && registered) {
      const pg = new PostgresAdapter();
      const existingRuns = await daemonStore.getRunsForTask(taskId, projectId);
      const runNumber = existingRuns.length + 1;

      await pg.createPipelineRun({
        id: runId,
        projectId,
        beadId: taskId,
        runNumber,
        branch: branchName,
        trigger: "manual",
        agentType: "developer",
        worktreePath,
        baseBranch: baseBranch ?? undefined,
        mergeStrategy: workflowConfig.merge ?? "auto",
      });
    } else {
      const localRun = store.createRun(projectId, taskId, "developer", worktreePath, {
        baseBranch: baseBranch ?? undefined,
        mergeStrategy: (workflowConfig.merge ?? "auto") as Run["merge_strategy"],
      });
      runId = localRun.id;
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(chalk.red(`Failed to create run record: ${msg}`));
    store.close();
    return 1;
  }

  // ── Update task status to in_progress ────────────────────────────────
  try {
    if (requestedRunId) {
      // Elixir scheduler already owns task status for this run.
    } else if (daemonStore && registered) {
      const pg = new PostgresAdapter();
      await pg.updateTask(projectId, taskId, { status: "in-progress" });
    } else if (typeof taskClient.update === "function") {
      await taskClient.update(taskId, { status: "in-progress" });
    }
  } catch {
    // Non-fatal: status update failure
  }

  // ── Start notification server ─────────────────────────────────────────
  const notifyServer = new NotificationServer(notificationBus);
  let notifyUrl: string | undefined;
  try {
    await notifyServer.start();
    notifyUrl = notifyServer.url;
  } catch {
    notifyUrl = undefined;
  }

  // ── Spawn worker ──────────────────────────────────────────────────────
  const selectedModel: ModelSelection = (model as ModelSelection) ?? "anthropic/claude-sonnet-4-6";
  const taskInfo: TaskInfo = issueToTaskInfo(task);

  const env = buildWorkerEnv(false, taskId, runId, selectedModel, notifyUrl, vcsBackend);

  try {
    const { pid } = await spawnWorkerProcess({
      runId,
      projectId,
      taskId: taskId,
      taskTitle: task.title,
      taskDescription: taskDescription,
      taskComments: undefined,
      model: selectedModel,
      worktreePath,
      projectPath: resolvedProjectPath,
      prompt: `Execute workflow '${workflowConfig.name}' for task ${taskId}.`,
      env,
      pipeline: true,
      workflowName: workflowConfig.name,
      workflowPath,
      taskType: task.type ?? "task",
      taskLabels: taskLabels,
      taskPriority: task.priority,
      targetBranch: targetBranch ?? baseBranch,
      attemptNumber,
      nativeTaskId: taskId,
      taskMeta: {
        id: taskId,
        title: task.title,
        description: taskDescription ?? '',
        type: task.type ?? '',
        priority: typeof task.priority === 'number' ? task.priority : 2,
        projectReportsDir: getRunReportsDir(projectId, taskId, runId),
      },
      githubIssueNumber: (task as { githubIssueNumber?: number }).githubIssueNumber,
      guardrailConfig: {
        expectedCwd: worktreePath,
        mode: "auto-correct",
      },
      hooks: projectCfg?.hooks,
    });

    console.log(chalk.green(`\nWorker spawned (pid=${pid}) for run ${runId}`));
    console.log(chalk.dim(`  Logs: ~/.foreman/logs/${runId}.log`));
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(chalk.red(`Failed to spawn worker: ${msg}`));
    await notifyServer.stop();
    store.close();
    return 1;
  }

  // ── Watch mode ─────────────────────────────────────────────────────────
  if (watch) {
    console.log(chalk.dim("\nWatching run... (Ctrl+C to detach)\n"));
    const { detached } = await watchRunsInk(daemonStore ?? store, [runId], { notificationBus });

    if (detached) {
      console.log(chalk.yellow("\nDetached — worker continues in background"));
      console.log(chalk.dim(`  Monitor with: foreman status`));
      console.log(chalk.dim(`  View logs: ~/.foreman/logs/${runId}.log`));
    } else {
      // Run completed — check status
      const finalRun = await (daemonStore ?? store).getRun(runId);
      if (finalRun) {
        console.log(chalk.bold(`\nRun completed: ${finalRun.status}`));
        if (finalRun.status === "completed") {
          // Trigger merge
          // For registered projects, the daemon handles merge via RefineryAgent
          // For non-registered projects, use autoMerge with ForemanStore
          if (!registered) {
            try {
              const mergeResult = await autoMerge({
                store,
                taskClient,
                projectPath: resolvedProjectPath,
              });
              if (mergeResult.merged > 0) {
                console.log(chalk.green(`Merged ${mergeResult.merged} branch(es)`));
              }
            } catch {
              // Non-fatal: merge failure
            }
          } else {
            console.log(chalk.dim("  Merge will be handled by the Foreman daemon"));
          }
        }
      }
    }
  }

  await notifyServer.stop();
  store.close();
  return 0;
}

// ── CLI Command Definition ────────────────────────────────────────────────

export const runTaskCommand = new Command("task")
  .description("Run a workflow directly for a specific task (bypasses state-gating)")
  .argument("<task-id>", "Task ID to run the workflow for")
  .argument("<workflow-path>", "Workflow name or path to a workflow YAML file")
  .option("--model <model>", "Model to use (overrides workflow default)")
  .addOption(new Option("--skip-explore", "(deprecated) No effect — use a workflow without an explorer phase").hideHelp())
  .addOption(new Option("--skip-review", "(deprecated) No effect — use a workflow without a reviewer phase").hideHelp())
  .option("--dry-run", "Show what would be done without executing")
  .option("--no-watch", "Exit immediately after spawning worker (don't monitor)")
  .option("--target-branch <branch>", "Override target branch for finalize/merge")
  .addOption(new Option("--run-id <id>", "Use an existing orchestration run id (internal Elixir scheduler bridge)").hideHelp())
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (taskId, workflowPath, opts) => {
    if (process.env.FOREMAN_RUNTIME_MODE !== "test" && process.env.VITEST !== "true" && !opts.runId) {
      console.error(
        chalk.red(
          "Error: foreman run task operator use was removed after the Elixir backend cutover. Elixir scheduler worker launches use the internal --run-id bridge.",
        ),
      );
      process.exit(1);
    }
    const exitCode = await runTaskAction(taskId, workflowPath, {
      model: opts.model as string | undefined,
      skipExplore: opts.skipExplore as boolean | undefined,
      skipReview: opts.skipReview as boolean | undefined,
      dryRun: opts.dryRun as boolean | undefined,
      watch: opts.watch as boolean,
      targetBranch: opts.targetBranch as string | undefined,
      runId: opts.runId as string | undefined,
      project: opts.project as string | undefined,
      projectPath: opts.projectPath as string | undefined,
    });
    process.exit(exitCode);
  });