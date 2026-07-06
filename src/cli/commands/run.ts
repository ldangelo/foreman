import { Command, Option } from "commander";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import chalk from "chalk";

import type { ITaskClient, Issue } from "../../lib/task-client.js";
import { createTaskClient } from "../../lib/task-client-factory.js";
import { ForemanStore } from "../../lib/store.js";
import type { Run } from "../../lib/store.js";
import { ElixirCliStore } from "./elixir-cli-store.js";
import { loadProjectConfig, resolveDefaultBranch, resolveVcsConfig } from "../../lib/project-config.js";
import { isIgnorableControllerPath } from "../../lib/controller-paths.js";
import { syncRegisteredProjectCheckout } from "../../lib/registered-project-checkout.js";
import type { ProjectConfig } from "../../lib/project-config.js";
import { elixirClient, listRegisteredProjects, resolveRepoRootProjectPath, requireProjectOrAllInMultiMode } from "./project-task-support.js";
import type { RegisteredProjectSummary } from "./project-task-support.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import type { VcsBackend } from "../../lib/vcs/interface.js";
import { extractBranchLabel, normalizeBranchLabel } from "../../lib/branch-label.js";
import { findMissingPrompts, findStalePrompts } from "../../lib/prompt-loader.js";
import {
  ensureBundledWorkflowsInstalled,
  findStaleWorkflows,
  listAvailableWorkflows,
  loadWorkflowConfig,
} from "../../lib/workflow-loader.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { DispatcherOverrides } from "../../orchestrator/dispatcher.js";
import type { ModelSelection } from "../../orchestrator/types.js";
import { watchRunsInk } from "../watch-ui.js";
import { NotificationServer } from "../../orchestrator/notification-server.js";
import { notificationBus } from "../../orchestrator/notification-bus.js";
import { SentinelAgent } from "../../orchestrator/sentinel.js";
import { syncTaskStatusOnStartup } from "../../orchestrator/task-backend-ops.js";
import { PIPELINE_TIMEOUTS, PIPELINE_LIMITS } from "../../lib/config.js";
import { isPiAvailable } from "../../orchestrator/pi-rpc-spawn-strategy.js";
import { purgeOrphanedWorkerConfigs } from "../../orchestrator/dispatcher.js";
import { autoMerge } from "../../orchestrator/auto-merge.js";
export { autoMerge } from "../../orchestrator/auto-merge.js";
export type { AutoMergeOpts, AutoMergeResult } from "../../orchestrator/auto-merge.js";
import { runTaskCommand, skipFlagsDeprecationWarning } from "./run-task.js";
import { RefineryAgent, wrapLocalRefineryQueue, type RunLookup } from "../../orchestrator/refinery-agent.js";
import { ElixirMergeQueue } from "./elixir-merge-queue.js";
import { MergeQueue } from "../../orchestrator/merge-queue.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { ElixirServerClient } from "../../lib/elixir-server-client.js";

// ── Backend Client Factory (TRD-007) ─────────────────────────────────

/**
 * Result returned by createTaskClients.
 * Contains the task client to pass to Dispatcher.
 * The Elixir backend task store is the supported registered-project backend.
 */
export interface TaskClientResult {
  taskClient: ITaskClient;
  bvClient: null;
  backendType: "native";
}

interface SentinelStartupTaskClient extends ITaskClient {
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

export type RuntimeMode = "normal" | "test";

export function resolveRuntimeMode(value?: string): RuntimeMode {
  const raw = (value ?? process.env.FOREMAN_RUNTIME_MODE ?? "normal").trim().toLowerCase();
  return raw === "test" ? "test" : "normal";
}

function createElixirTestDispatcherOverrides(projectId: string): DispatcherOverrides {
  const client = new ElixirServerClient(
    process.env.FOREMAN_SERVER_URL ?? "http://127.0.0.1:4766",
    process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN,
  );
  const sequences = new Map<string, number>();
  const nextSequence = (runId: string) => {
    const next = (sequences.get(runId) ?? 0) + 1;
    sequences.set(runId, next);
    return next;
  };

  return {
    externalProjectId: projectId,
    runOps: {
      createRun: async (args) => {
        await client.sendWorkerEvent({
          run_id: args.runId,
          project_id: args.projectId,
          phase_id: args.agentType,
          worker_id: `dispatcher-${args.runId}`,
          type: "run_started",
          sequence: nextSequence(args.runId),
          details: { task_id: args.taskId, branch_name: args.branchName, worktree_path: args.worktreePath },
        });
        const startedAt = new Date().toISOString();
        return {
          id: args.runId,
          project_id: args.projectId,
          task_id: args.taskId,
          agent_type: args.agentType,
          session_key: null,
          worktree_path: args.worktreePath,
          status: "running",
          started_at: startedAt,
          completed_at: null,
          created_at: startedAt,
          progress: null,
          tmux_session: null,
          base_branch: args.baseBranch ?? null,
          merge_strategy: args.mergeStrategy ?? "auto",
        };
      },
      updateRun: async (runId, updates) => {
        if (updates.status === "completed" || updates.status === "failed") {
          await client.sendWorkerEvent({
            run_id: runId,
            project_id: projectId,
            phase_id: updates.status,
            worker_id: `dispatcher-${runId}`,
            type: updates.status === "completed" ? "run_completed" : "run_failed",
            status: updates.status,
            sequence: nextSequence(runId),
          });
        }
      },
      sendMessage: async (runId, senderAgentType, recipientAgentType, subject, body) => {
        await client.sendCommand({
          command_id: `inbox-send-${runId}-${Date.now()}`,
          command_type: "inbox.send",
          payload: { project_id: projectId, run_id: runId, sender: senderAgentType, recipient: recipientAgentType, subject, body },
          metadata: { correlation_id: runId },
        });
      },
      logEvent: async (runId, eventProjectId, eventType, payload) => {
        await client.sendWorkerEvent({
          run_id: runId,
          project_id: eventProjectId,
          phase_id: eventType,
          worker_id: `dispatcher-${runId}`,
          type: eventType,
          sequence: nextSequence(runId),
          details: payload,
        });
      },
    },
  };
}

function createRegisteredDispatcherOverrides(projectId: string, daemonStore: ElixirCliStore): DispatcherOverrides {
  const mapTask = (task: Record<string, unknown>) => ({
    id: String(task.task_id ?? task.id ?? ""),
    title: String(task.title ?? task.task_id ?? task.id ?? ""),
    description: (task.description as string | null | undefined) ?? null,
    type: String(task.task_type ?? task.type ?? "task"),
    priority: Number(task.priority ?? 2),
    status: String(task.status ?? "open"),
    run_id: (task.run_id as string | null | undefined) ?? null,
    created_at: String(task.created_at ?? new Date(0).toISOString()),
    updated_at: String(task.updated_at ?? new Date(0).toISOString()),
    external_id: (task.external_id as string | null | undefined) ?? null,
    labels: Array.isArray(task.labels) ? task.labels : [],
  }) as never;

  return {
    externalProjectId: projectId,
    getRecentFailureCount: async (_projectId: string, since: string) => {
      const runs = await daemonStore.getRunsByStatuses(["failed", "stuck", "conflict", "test-failed"] as Run["status"][]);
      return runs.filter((run) => run.created_at >= since).length;
    },
    getActiveTaskIds: async () => {
      const activeRuns = await daemonStore.getActiveRuns(projectId);
      return activeRuns.map((run) => run.task_id);
    },
    getActiveAgentCount: async () => {
      const activeRuns = await daemonStore.getActiveRuns(projectId);
      return activeRuns.length;
    },
    hasActiveOrPendingRun: async (taskId: string) => {
      const runs = await daemonStore.getRunsForTask(taskId);
      return runs.some((run) => ["pending", "running"].includes(run.status));
    },
    getRunsByStatus: async (status, overrideProjectId) => await daemonStore.getRunsByStatus(status, overrideProjectId),
    getRunsForTask: async (taskId, _overrideProjectId) => await daemonStore.getRunsForTask(taskId),
    getRun: async (runId) => await daemonStore.getRun(runId),
    getActiveRuns: async (overrideProjectId) => await daemonStore.getActiveRuns(overrideProjectId),
    nativeTaskOps: {
      hasNativeTasks: async () => {
        const client = await elixirClient();
        return (await client.listTasks()).some((task) => task.project_id === projectId);
      },
      getReadyTasks: async () => {
        const client = await elixirClient();
        return (await client.listTasks())
          .filter((task) => task.project_id === projectId && task.status === "ready")
          .map((task) => mapTask(task as Record<string, unknown>));
      },
      getTaskByExternalId: async (externalId: string) => {
        const client = await elixirClient();
        const task = (await client.listTasks()).find((candidate) => candidate.project_id === projectId && candidate.external_id === externalId);
        return task ? mapTask(task as Record<string, unknown>) : null;
      },
      getTaskById: async (taskId: string) => {
        const client = await elixirClient();
        const task = await client.getTask(taskId);
        return task ? mapTask(task as Record<string, unknown>) : null;
      },
      claimTask: async (taskId: string, runId: string) => {
        const client = await elixirClient();
        const response = await client.sendCommand({
          command_id: `task-claim-${taskId}-${runId}`,
          command_type: "task.update",
          payload: { project_id: projectId, task_id: taskId, status: "in_progress", run_id: runId },
        });
        return response.ok;
      },
    },
    runOps: {
      createRun: async ({ runId, taskId, branchName, worktreePath, baseBranch, mergeStrategy, agentType }) => {
        const createdAt = new Date().toISOString();
        const client = await elixirClient();
        const response = await client.sendCommand({
          command_id: `run-start-${runId}`,
          command_type: "run.start",
          payload: {
            run_id: runId,
            project_id: projectId,
            task_id: taskId,
            agent_type: agentType,
            branch_name: branchName,
            worktree_path: worktreePath,
            base_branch: baseBranch ?? null,
            merge_strategy: mergeStrategy ?? "auto",
            status: "pending",
            created_at: createdAt,
          },
        });
        if (!response.ok) throw new Error(response.error.message);
        const run: Run = {
          id: runId,
          project_id: projectId,
          task_id: taskId,
          agent_type: agentType,
          session_key: null,
          worktree_path: worktreePath,
          status: "pending",
          started_at: null,
          completed_at: null,
          created_at: createdAt,
          progress: null,
          tmux_session: null,
          base_branch: baseBranch ?? null,
          merge_strategy: mergeStrategy ?? "auto",
        };
        return run;
      },
      updateRun: async (runId, updates) => {
        await daemonStore.updateRun(runId, updates as Partial<Run>);
      },
      sendMessage: async (runId, senderAgentType, recipientAgentType, subject, body) => {
        const client = await elixirClient();
        const response = await client.sendCommand({
          command_id: `inbox-send-${runId}-${Date.now()}`,
          command_type: "inbox.send",
          payload: { project_id: projectId, run_id: runId, sender_agent_type: senderAgentType, recipient_agent_type: recipientAgentType, subject, body },
        });
        if (!response.ok) throw new Error(response.error.message);
      },
      logEvent: async (runId, eventProjectId, eventType, payload) => {
        await daemonStore.logEvent(eventProjectId, eventType, payload, runId);
      },
    },
  };
}

/**
 * Instantiate the native task client.
 */
export async function createTaskClients(
  projectPath: string,
  _runtimeMode: RuntimeMode = resolveRuntimeMode(),
  registeredProjectId?: string,
): Promise<TaskClientResult> {
  // Always use native task store
  const { taskClient, backendType } = await createTaskClient(projectPath, {
    registeredProjectId,
  });

  return {
    taskClient,
    bvClient: null,
    backendType,
  };
}

/**
 * Run the Refinery Agent to process the merge queue.
 * Replaces the legacy autoMerge() with an agentic approach.
 */
async function runRefineryMerge(
  store: ForemanStore,
  projectPath: string,
  taskClient: ITaskClient,
  runLookup: RunLookup,
  registeredProject?: RegisteredProjectSummary | null,
): Promise<{ merged: number; conflicts: number; failed: number }> {
  const registered = registeredProject ?? null;

  try {
    const mergeQueue = registered
      ? new ElixirMergeQueue(registered.id)
      : wrapLocalRefineryQueue(new MergeQueue(store.getDb()));
    const vcsBackend = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
    const agent = new RefineryAgent(mergeQueue, vcsBackend, projectPath, {}, runLookup);
    const results = await agent.processOnce();

    return {
      merged: results.filter((r) => r.action === "merged").length,
      conflicts: results.filter((r) => r.action === "escalated").length,
      failed: results.filter((r) => r.action === "error" || r.action === "skipped").length,
    };
  } catch (err) {
    if (registered) {
      throw err;
    }

    // Fallback to legacy autoMerge only for local/unregistered projects.
    return autoMerge({ store, taskClient, projectPath });
  }
}

// ── Branch Mismatch Detection ────────────────────────────────────────────────

/**
 * Prompt the user for a yes/no answer via stdin.
 * Returns true for yes (empty input defaults to yes), false for no.
 */
async function promptYesNo(question: string): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise<boolean>((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      const normalised = answer.trim().toLowerCase();
      resolve(normalised === "" || normalised === "y" || normalised === "yes");
    });
  });
}

const FOREMAN_OWNED_BRANCH = "foreman-controller";

export { isIgnorableControllerPath } from "../../lib/controller-paths.js";

function withCommonBinaryPath(): NodeJS.ProcessEnv {
  const home = process.env.HOME ?? "/home/nobody";
  return {
    ...process.env,
    PATH: `${home}/.local/bin:/opt/homebrew/bin:${process.env.PATH ?? ""}`,
  };
}

async function isAnonymousJujutsuRevision(
  vcs: VcsBackend,
  projectPath: string,
  branch: string | undefined,
): Promise<boolean> {
  if (!branch || vcs.name !== "jujutsu" || typeof (vcs as Partial<VcsBackend>).branchExists !== "function") {
    return false;
  }
  return !(await vcs.branchExists(projectPath, branch).catch(() => false));
}

export interface OwnedBranchResolution {
  currentBranch: string;
  defaultBranch: string;
  targetBranch?: string;
  usedOwnedBranch: boolean;
}

export async function resolveOwnedControllerBranch(
  vcs: VcsBackend,
  projectPath: string,
  preferredDefaultBranch?: string,
): Promise<OwnedBranchResolution> {
  const maybeVcs = vcs as Partial<VcsBackend>;
  if (
    typeof maybeVcs.getCurrentBranch !== "function" ||
    typeof maybeVcs.detectDefaultBranch !== "function" ||
    typeof maybeVcs.branchExists !== "function" ||
    typeof maybeVcs.getModifiedFiles !== "function" ||
    typeof maybeVcs.getUntrackedFiles !== "function"
  ) {
    return {
      currentBranch: "",
      defaultBranch: "",
      usedOwnedBranch: false,
    };
  }

  const currentBranch = normalizeBranchLabel(await vcs.getCurrentBranch(projectPath)) ?? "";
  const defaultBranch = normalizeBranchLabel(
    preferredDefaultBranch ?? await vcs.detectDefaultBranch(projectPath),
  ) ?? "";
  const currentIsAnonymousRevision = await isAnonymousJujutsuRevision(vcs, projectPath, currentBranch);

  const shouldUseOwnedBranch =
    vcs.name === "jujutsu" &&
    (currentIsAnonymousRevision || currentBranch === defaultBranch);

  if (!shouldUseOwnedBranch) {
    return {
      currentBranch,
      defaultBranch,
      usedOwnedBranch: false,
    };
  }

  const dirtyTracked = (await vcs.getModifiedFiles(projectPath))
    .filter((path) => !isIgnorableControllerPath(path));
  const dirtyUntracked = (await vcs.getUntrackedFiles(projectPath))
    .filter((path) => !isIgnorableControllerPath(path));
  const dirtyPaths = [...dirtyTracked, ...dirtyUntracked];
  if (dirtyPaths.length > 0) {
    throw new Error(
      `Foreman-owned branch requires a clean controller checkout. Dirty paths: ${dirtyPaths.slice(0, 8).join(", ")}`,
    );
  }

  const branchExists = await vcs.branchExists(projectPath, FOREMAN_OWNED_BRANCH).catch(() => false);
  if (!branchExists) {
    execFileSync("jj", ["bookmark", "create", FOREMAN_OWNED_BRANCH, "-r", defaultBranch], {
      cwd: projectPath,
      stdio: "pipe",
      env: withCommonBinaryPath(),
    });
  }

  if (currentBranch !== FOREMAN_OWNED_BRANCH) {
    execFileSync("jj", ["new", FOREMAN_OWNED_BRANCH], {
      cwd: projectPath,
      stdio: "pipe",
      env: withCommonBinaryPath(),
    });
  }

  return {
    currentBranch: FOREMAN_OWNED_BRANCH,
    defaultBranch,
    targetBranch: defaultBranch,
    usedOwnedBranch: true,
  };
}

/**
 * Check whether any in-progress tasks have a `branch:` label that differs
 * from the current git branch.
 *
 * Edge cases handled:
 * - No in-progress tasks: no prompt, return false (continue normally)
 * - Label matches current branch: no prompt, return false (continue normally)
 * - No branch: label on task: no prompt, return false
 * - Label differs: show prompt, switch branch (return false) or exit (return true)
 *
 * Returns true if the caller should abort (user declined to switch).
 */
async function createRunVcsBackend(projectPath: string): Promise<VcsBackend> {
  const projectCfg = loadProjectConfig(projectPath);
  const vcsConfig = resolveVcsConfig(undefined, projectCfg?.vcs);
  return VcsBackendFactory.create(vcsConfig, projectPath);
}

async function resolveRunRegisteredProject(projectPath: string) {
  const projects = await listRegisteredProjects();
  return projects.find((project) => project.path === projectPath) ?? null;
}

export function collectRuntimeAssetIssues(
  projectPath: string,
  projectCfg?: ProjectConfig | null,
): string[] {
  const issues: string[] = [];

  try {
    if (projectCfg === undefined) {
      loadProjectConfig(projectPath);
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    issues.push(`project config invalid: ${msg}`);
    return issues;
  }

  const missingPrompts = findMissingPrompts(projectPath);
  const stalePrompts = findStalePrompts(projectPath);
  // Auto-install any missing bundled workflows (e.g. newly added bundled
  // workflows like quick.yaml on existing installs) instead of blocking
  // dispatch. Only workflows still missing after the install attempt are
  // reported as preflight issues.
  const missingWorkflows = ensureBundledWorkflowsInstalled(projectPath);
  const staleWorkflows = findStaleWorkflows(projectPath);

  if (missingPrompts.length > 0) {
    issues.push(`missing prompts: ${missingPrompts.join(", ")}`);
  }
  if (stalePrompts.length > 0) {
    issues.push(`stale prompts: ${stalePrompts.join(", ")}`);
  }
  if (missingWorkflows.length > 0) {
    issues.push(`missing workflows: ${missingWorkflows.map((name) => `${name}.yaml`).join(", ")}`);
  }
  if (staleWorkflows.length > 0) {
    issues.push(`stale workflows: ${staleWorkflows.map((name) => `${name}.yaml`).join(", ")}`);
  }

  return issues;
}

export async function checkBranchMismatch(
  taskClient: ITaskClient,
  projectPath: string,
): Promise<boolean> {
  let vcs: VcsBackend;
  try {
    vcs = await createRunVcsBackend(projectPath);
  } catch {
    // Cannot determine VCS backend — skip mismatch check
    return false;
  }

  let currentBranch: string;
  try {
    currentBranch = normalizeBranchLabel(await vcs.getCurrentBranch(projectPath)) ?? "";
  } catch {
    // Cannot determine current branch — skip mismatch check
    return false;
  }

  let inProgressTasks: Issue[];
  try {
    inProgressTasks = await taskClient.list({ status: "in_progress" });
  } catch {
    // Cannot list in-progress tasks — skip mismatch check
    return false;
  }

  if (inProgressTasks.length === 0) return false;

  // Group mismatched tasks by target branch
  const mismatchByBranch = new Map<string, string[]>();
  for (const task of inProgressTasks) {
    try {
      const detail = await taskClient.show(task.id) as unknown as { labels?: string[] };
      const targetBranch = normalizeBranchLabel(extractBranchLabel(detail.labels));
      if (targetBranch && targetBranch !== currentBranch) {
        const ids = mismatchByBranch.get(targetBranch) ?? [];
        ids.push(task.id);
        mismatchByBranch.set(targetBranch, ids);
      }
    } catch {
      // Non-fatal: skip this task if detail fetch fails
    }
  }

  if (mismatchByBranch.size === 0) return false;

  // For each unique target branch, prompt the user to switch
  for (const [targetBranch, taskIds] of mismatchByBranch) {
    const taskList = taskIds.join(", ");
    const question = chalk.yellow(
      `\nTasks ${chalk.cyan(taskList)} target branch ${chalk.green(targetBranch)} ` +
      `but you are on ${chalk.red(currentBranch)}.\n` +
      `Switch to ${chalk.green(targetBranch)} to continue? [Y/n] `,
    );

    const shouldSwitch = await promptYesNo(question);
    if (shouldSwitch) {
      try {
        await vcs.checkoutBranch(projectPath, targetBranch);
        console.log(chalk.green(`Switched to branch ${targetBranch}.`));
        currentBranch = targetBranch;
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(chalk.red(`Failed to switch to branch ${targetBranch}: ${msg}`));
        console.error(chalk.dim(`Run 'git checkout ${targetBranch}' manually and re-run foreman.`));
        return true; // abort
      }
    } else {
      console.log(
        chalk.yellow(`Skipping tasks ${taskList} — they target ${targetBranch}.`) +
        chalk.dim(` Run 'git checkout ${targetBranch}' and re-run foreman to continue those tasks.`),
      );
      return true; // abort — user said no
    }
  }

  return false;
}

// ── Workflow Override Validation ─────────────────────────────────────

/**
 * Validate a `--workflow <name>` override before dispatch.
 *
 * Fails fast when the named workflow cannot be loaded (not bundled, not in
 * ~/.foreman/workflows/, not a valid YAML path), returning an error message
 * that lists the available workflow names.
 */
export function validateWorkflowOverride(
  workflowName: string,
  projectPath: string,
): { ok: true } | { ok: false; message: string } {
  try {
    loadWorkflowConfig(workflowName, projectPath);
    return { ok: true };
  } catch (err: unknown) {
    const reason = err instanceof Error ? err.message : String(err);
    const available = listAvailableWorkflows();
    return {
      ok: false,
      message:
        `Cannot load workflow '${workflowName}': ${reason}\n` +
        `Available workflows: ${available.join(", ")}`,
    };
  }
}

// ── Run Command ──────────────────────────────────────────────────────

export const runCommand = new Command("run")
  .description("Dispatch ready tasks to agents")
  .option("--max-agents <n>", "Maximum concurrent agents")
  .option("--model <model>", "Force a specific model (overrides FOREMAN_DEFAULT_MODEL)")
  .option("--dry-run", "Show what would be dispatched without doing it")
  .option("--no-watch", "Exit immediately after dispatching (don't monitor agents)")
  .option("--telemetry", "Enable OpenTelemetry tracing on spawned agents (requires OTEL_* env vars)")
  .option("--resume", "Resume stuck/rate-limited runs from a previous dispatch")
  .option("--resume-failed", "Also resume failed runs (not just stuck/rate-limited)")
  .option("--no-pipeline", "Skip the explorer/qa/reviewer pipeline — run as single worker agent")
  .option("--workflow <name>", "Run all dispatched tasks with this workflow (overrides workflow:<name> labels and task-type mapping)")
  .addOption(new Option("--skip-explore", "(deprecated) No effect — use --workflow quick or a custom workflow").hideHelp())
  .addOption(new Option("--skip-review", "(deprecated) No effect — use --workflow quick or a custom workflow").hideHelp())
  .option("--task <id>", "Dispatch only this specific task by ID (must be ready)")
  .option("--no-auto-dispatch", "Disable automatic dispatch when an agent completes and capacity is available")
  .option("--stagger <duration>", "Stagger delay between dispatches to prevent thundering herd (e.g. '30s', '1m')")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .option("--runtime-mode <mode>", "Runtime mode: normal|test (test uses deterministic phase-runner seams)")
  .option("--yes", "Answer yes to run confirmation prompts (for non-interactive dispatch)")
  .action(async (opts) => {
    const maxAgents = parseInt(opts.maxAgents ?? "5", 10);
    const model = opts.model as ModelSelection | undefined;
    const dryRun = opts.dryRun as boolean | undefined;
    const resume = opts.resume as boolean | undefined;
    const resumeFailed = opts.resumeFailed as boolean | undefined;
    const watch = opts.watch as boolean;
    const telemetry = opts.telemetry as boolean | undefined;
    const pipeline = opts.pipeline as boolean;  // --no-pipeline sets to false
    const workflowOverride = (opts.workflow as string | undefined)?.trim() || undefined;
    const taskFilter = opts.task as string | undefined;

    // Deprecated no-op flags retained for backwards compatibility
    const deprecationWarning = skipFlagsDeprecationWarning({
      skipExplore: opts.skipExplore as boolean | undefined,
      skipReview: opts.skipReview as boolean | undefined,
    });
    if (deprecationWarning) {
      console.warn(chalk.yellow(`[foreman] ${deprecationWarning}`));
    }
    const enableAutoDispatch = opts.autoDispatch !== false; // --no-auto-dispatch sets to false
    const runtimeMode = resolveRuntimeMode(opts.runtimeMode as string | undefined);
    const assumeYes = opts.yes === true;

    // P1: Parse stagger delay for preventing thundering herd on Haiku quotas
    // Accept formats like "30s", "1m", "2m30s"
    let staggerMs: number | undefined;
    if (opts.stagger) {
      const match = opts.stagger.match(/^(\d+)([smh])/);
      if (match) {
        const value = parseInt(match[1], 10);
        const unit = match[2];
        staggerMs = unit === "s" ? value * 1000 : unit === "m" ? value * 60 * 1000 : value * 60 * 60 * 1000;
      } else {
        console.warn(chalk.yellow(`[foreman] Warning: invalid --stagger value "${opts.stagger}", ignoring (use formats like "30s", "1m")`));
      }
    }

    if (runtimeMode !== "test" && process.env.VITEST !== "true") {
      if (taskFilter) {
        console.error(chalk.red("Error: foreman run --task was removed after the Elixir backend cutover. Use normal 'foreman run' to tick the scheduler, or 'foreman retry <task-id>' for retry flows."));
        process.exit(1);
      }
      if (resume || resumeFailed) {
        console.error(chalk.red("Error: foreman run --resume/--resume-failed was removed after the Elixir backend cutover. Use 'foreman retry' for Elixir-backed retry operations."));
        process.exit(1);
      }
      if (pipeline === false || workflowOverride || staggerMs !== undefined || telemetry || opts.autoDispatch === false || model || opts.maxAgents !== undefined) {
        console.error(chalk.red("Error: these foreman run dispatch-shaping options were removed after the Elixir backend cutover. The Elixir scheduler owns default dispatch policy."));
        process.exit(1);
      }
      const manager = new ElixirServerManager();
      const status = await manager.ensureRunning();
      const client = new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
      if (dryRun) {
        console.log(chalk.dim("Elixir scheduler dry run: server is available; no scheduler tick sent."));
      } else {
        await client.schedulerTick();
        console.log(chalk.green("✓ Elixir scheduler tick dispatched"));
      }
      if (watch) {
        console.log(chalk.dim("Use 'foreman watch' or 'foreman status --watch' to monitor Elixir-backed runs."));
      }
      return;
    }

    // Start notification server so workers can POST status updates immediately
    // instead of waiting for the next poll cycle. Stopped in the finally block.
    //
    // NOTE: The `monitor` command (src/orchestrator/monitor.ts) is NOT wired to
    // notificationBus yet — it still uses its own polling-only loop. Wiring it
    // would speed up stuck detection but requires refactoring monitor's external
    // API. Deferred to a follow-up task.
    const notifyServer = new NotificationServer(notificationBus);
    let notifyUrl: string | undefined;
    try {
      await notifyServer.start();
      notifyUrl = notifyServer.url;
    } catch {
      // Non-fatal — notification server is an enhancement; polling still works
      notifyUrl = undefined;
    }

    try {
      // Require --project in multi-project mode
      await requireProjectOrAllInMultiMode(opts.project, false);
      const projectPath = await resolveRepoRootProjectPath(opts);
      const registered = await resolveRunRegisteredProject(projectPath);
      if (registered) {
        try {
          syncRegisteredProjectCheckout({
            projectId: registered.id,
            projectPath,
            defaultBranch: registered.defaultBranch,
          });
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          console.warn(chalk.yellow(`[Foreman] Registered checkout sync warning: ${msg}`));
        }
      }
      const projectCfg = loadProjectConfig(projectPath);

      // ── Workflow override validation ────────────────────────────────────
      // Fail fast when --workflow names a workflow that cannot be loaded.
      if (workflowOverride) {
        const validation = validateWorkflowOverride(workflowOverride, projectPath);
        if (!validation.ok) {
          console.error(chalk.red(`\nError: ${validation.message}\n`));
          process.exit(1);
        }
        console.log(chalk.dim(`[foreman] Workflow override: ${workflowOverride}`));
      }

      if (!dryRun && !resume && !resumeFailed) {
        const assetIssues = collectRuntimeAssetIssues(projectPath, projectCfg);
        if (assetIssues.length > 0) {
          console.error(chalk.red("\nRun preflight failed: Foreman runtime assets are out of date.\n"));
          for (const issue of assetIssues) {
            console.error(chalk.yellow(`  - ${issue}`));
          }
          console.error(
            chalk.dim(
              "\nRun 'foreman doctor --fix' (or reinstall prompts/workflows) before dispatching agents.\n",
            ),
          );
          process.exit(1);
        }
      }
      const startupVcs = await createRunVcsBackend(projectPath);

      // ── Pi Extensions check ──────────────────────────────────────────────────
      // If Pi is available, the extensions package must be built before dispatch.
      // Skipped in dry-run mode since no real agent work will happen.
      if (!dryRun && runtimeMode !== "test" && isPiAvailable()) {
        const extDist = join(projectPath, "packages/foreman-pi-extensions/dist/index.js");
        if (!existsSync(extDist)) {
          console.error(chalk.red("\nError: Pi extensions package has not been built.\n"));
          console.error(`  Build it with:  ${chalk.cyan("npm run build")}`);
          console.error(`  Expected:       ${chalk.dim(extDist)}\n`);
          process.exit(1);
        }
      }

      let taskClient: ITaskClient;
      let backendType: "native" = "native";
      const useElixirTestBackend = Boolean(registered && runtimeMode === "test" && process.env.FOREMAN_SERVER_URL);
      try {
        const clients = await createTaskClients(projectPath, runtimeMode, registered?.id);
        taskClient = clients.taskClient;
        backendType = clients.backendType;
      } catch (clientErr: unknown) {
        const message = clientErr instanceof Error ? clientErr.message : String(clientErr);
        console.error(chalk.red(`Error initialising task backend: ${message}`));
        process.exit(1);
      }
      const store = ForemanStore.forProject(projectPath);
      const daemonStore = registered && !useElixirTestBackend
        ? ElixirCliStore.forProject(registered)
        : null;
      const project = registered ?? store.getProjectByPath(projectPath);
      const dispatcher = new Dispatcher(
        taskClient,
        store,
        projectPath,
        null,
        registered && daemonStore && !useElixirTestBackend
          ? createRegisteredDispatcherOverrides(registered.id, daemonStore)
          : useElixirTestBackend && registered
            ? createElixirTestDispatcherOverrides(registered.id)
            : undefined,
      );

      // ── Sentinel Auto-Start ──────────────────────────────────────────────
      // If sentinel.enabled=1 in the DB config, start the sentinel agent
      // automatically alongside foreman run. Non-fatal — if anything fails,
      // log a warning and continue without sentinel.
      let sentinelAgent: SentinelAgent | null = null;
      if (!dryRun) {
        try {
          if (project && !useElixirTestBackend && !registered) {
            const sentinelStore = store;
            const sentinelConfig = await sentinelStore.getSentinelConfig(project.id);
            if (sentinelConfig && sentinelConfig.enabled === 1) {
              const sentinelTaskClient = taskClient as SentinelStartupTaskClient;
              sentinelAgent = new SentinelAgent(sentinelStore, sentinelTaskClient, project.id, projectPath, startupVcs);
              sentinelAgent.start(
                {
                  branch: sentinelConfig.branch,
                  testCommand: sentinelConfig.test_command,
                  intervalMinutes: sentinelConfig.interval_minutes,
                  failureThreshold: sentinelConfig.failure_threshold,
                },
                (result) => {
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
                  console.log(`[sentinel ${now}] ${icon} ${statusLabel} ${dur}${hash}`);
                },
              );
              console.log(
                chalk.dim(
                  `[sentinel] Auto-started on branch ${sentinelConfig.branch} (every ${sentinelConfig.interval_minutes}m)`
                )
              );
            }
          }
        } catch (sentinelErr: unknown) {
          const msg = sentinelErr instanceof Error ? sentinelErr.message : String(sentinelErr);
          sentinelAgent = null;
          console.warn(chalk.yellow(`[sentinel] Failed to auto-start (non-fatal): ${msg}`));
        }
      }

      /** Stop the sentinel agent and wait for in-flight work to quiesce. */
      const stopSentinel = async (): Promise<void> => {
        if (!sentinelAgent) return;
        await sentinelAgent.stop();
        sentinelAgent = null;
        console.log(chalk.dim("[sentinel] Stopped."));
      };

      // ── Startup worker config file cleanup ──────────────────────────────────
      // Delete orphaned worker-{runId}.json files in ~/.foreman/tmp/ that were
      // never consumed by a worker (e.g. because the run was killed externally).
      // Non-fatal — stale files waste disk space but do not affect correctness.
      if (!dryRun) {
        try {
          const purged = await purgeOrphanedWorkerConfigs(daemonStore ?? store);
          if (purged > 0) {
            console.log(chalk.dim(`[startup] Purged ${purged} orphaned worker config file(s).`));
          }
        } catch {
          // Non-fatal — ignore cleanup errors
        }
      }

      // ── Startup Task Sync ────────────────────────────────────────────────
      // Reconcile native task statuses against run state before dispatching.
      // Fixes drift caused by interrupted foreman sessions. Non-fatal.
      // Native task status sync runs before dispatch.
      if (!dryRun && project) {
        try {
          const taskSyncResult = await syncTaskStatusOnStartup(daemonStore ?? store, project.id);
          if (taskSyncResult.synced > 0 || taskSyncResult.mismatches.length > 0) {
            console.log(
              chalk.dim(
                `[startup] Reconciled ${taskSyncResult.synced} task(s), ` +
                `${taskSyncResult.mismatches.length} mismatch(es) detected`
              )
            );
          }
          for (const err of taskSyncResult.errors) {
            console.warn(chalk.yellow(`[startup] Task sync warning: ${err}`));
          }
        } catch (syncErr: unknown) {
          const msg = syncErr instanceof Error ? syncErr.message : String(syncErr);
          console.warn(chalk.yellow(`[startup] Task sync failed (non-fatal): ${msg}`));
        }
      }

      // ── Branch mismatch check ───────────────────────────────────────────────
      // Before dispatching, check if any in-progress tasks target a different
      // branch than the current one. If so, prompt the user to switch branches.
      // Skip in dry-run mode since no actual dispatch happens.
      if (!dryRun && !resume && !resumeFailed) {
        const shouldAbort = await checkBranchMismatch(taskClient, projectPath);
        if (shouldAbort) {
          await stopSentinel();
          store.close();
          await notifyServer.stop().catch(() => { /* ignore */ });
          process.exit(1);
        }
      }

      // ── Target branch confirmation ──────────────────────────────────────────
      // When the current branch differs from the detected default branch (e.g.
      // working on a feature branch instead of dev/main), confirm with the user
      // that agent worktrees and merges should target the current branch.
      // The confirmed targetBranch is threaded through to autoMerge and workers.
      let targetBranch: string | undefined;
      if (!dryRun) {
        try {
          const configuredDefaultBranch = await resolveDefaultBranch(
            projectPath,
            (path) => startupVcs.detectDefaultBranch(path),
            projectCfg,
          );
          const controller = await resolveOwnedControllerBranch(
            startupVcs,
            projectPath,
            configuredDefaultBranch,
          );
          if (controller.usedOwnedBranch) {
            targetBranch = controller.targetBranch;
            console.log(
              chalk.dim(
                `[startup] Using Foreman-owned branch ${FOREMAN_OWNED_BRANCH} (target: ${controller.defaultBranch})`,
              ),
            );
          }
          const cb = targetBranch ? undefined : normalizeBranchLabel(await startupVcs.getCurrentBranch(projectPath));
          const db = targetBranch
            ? undefined
            : normalizeBranchLabel(
                await resolveDefaultBranch(
                  projectPath,
                  (path) => startupVcs.detectDefaultBranch(path),
                  projectCfg,
                ),
              );
          if (cb && db && cb !== db) {
            const question = chalk.yellow(
              `\nYou are on branch ${chalk.green(cb)}, ` +
              `which differs from the default branch ${chalk.cyan(db)}.\n` +
              `Agent work will be branched from and merged into ${chalk.green(cb)}.\n` +
              `Continue? [Y/n] `,
            );
            const confirmed = assumeYes ? true : await promptYesNo(question);
            if (!confirmed) {
              console.log(
                chalk.dim(`Aborted. Switch to ${db} or the desired target branch and re-run.`),
              );
              await stopSentinel();
              store.close();
              await notifyServer.stop().catch(() => { /* ignore */ });
              process.exit(1);
            }
            targetBranch = cb;
            console.log(chalk.green(`Target branch: ${cb}`));
          }
        } catch {
          // Non-fatal: if branch detection fails, fall back to default behavior
        }
      }

      /**
       * Build the auto-dispatch callback passed to watchRunsInk.
       * Called when an agent completes mid-watch and capacity may be available.
       * Returns IDs of newly dispatched runs to add to the watch list.
       */
      const makeAutoDispatchFn = (!dryRun && watch && enableAutoDispatch)
        ? async (): Promise<string[]> => {
            const newResult = await dispatcher.dispatch({
              maxAgents,
              model,
              dryRun,
              telemetry,
              pipeline,
              runtimeMode,
              workflow: workflowOverride,
              taskId: taskFilter,
              notifyUrl,
              targetBranch,
              staggerMs,
            });
            return newResult.dispatched.map((t) => t.runId);
          }
        : undefined;

      // Resume mode: pick up stuck/failed runs from a previous dispatch
      if (resume || resumeFailed) {
        const statuses: Array<"stuck" | "failed"> = resumeFailed
          ? ["stuck", "failed"]
          : ["stuck"];

        const result = await dispatcher.resumeRuns({
          maxAgents,
          model,
          telemetry,
          statuses,
          notifyUrl,
          runtimeMode,
        });

        if (result.resumed.length > 0) {
          console.log(chalk.green.bold(`Resumed ${result.resumed.length} agent(s):\n`));
          for (const task of result.resumed) {
            console.log(`  ${chalk.cyan(task.taskId)} (was ${chalk.yellow(task.previousStatus)})`);
            console.log(`    Model:    ${chalk.magenta(task.model)}`);
            console.log(`    Session:  ${chalk.dim(task.sessionId)}`);
            console.log(`    Run ID:   ${task.runId}`);
            console.log();
          }
        } else {
          console.log(chalk.yellow("No runs to resume."));
        }

        if (result.skipped.length > 0) {
          console.log(chalk.dim(`Skipped ${result.skipped.length} run(s):`));
          for (const task of result.skipped) {
            console.log(`  ${chalk.dim(task.taskId)} — ${task.reason}`);
          }
          console.log();
        }

        console.log(chalk.bold(`Active agents: ${result.activeAgents}/${maxAgents}`));

        if (watch && result.resumed.length > 0) {
          const runIds = result.resumed.map((t) => t.runId);
          // Resume mode is a one-shot recovery action — no continuous auto-dispatch needed.
            const { detached } = await watchRunsInk(daemonStore ?? store, runIds, { notificationBus });
          if (detached) {
            await stopSentinel();
            store.close();
            return;
          }
        }

        await stopSentinel();
        store.close();
        return;
      }

      if (dryRun) {
        console.log(chalk.yellow("(dry run — no changes will be made)\n"));
      }

      // ── Startup merge drain ─────────────────────────────────────────────────
      // Drain any completed-but-unmerged runs from previous interrupted sessions
      // BEFORE dispatching new work. Finalize now owns merge queue production,
      // so foreman run only performs this startup recovery pass rather than
      // re-processing merge work after every batch.
      if (!dryRun && project) {
        try {
          const runLookup: RunLookup = registered && daemonStore ? daemonStore : store;
          const startupMerge = await runRefineryMerge(store, projectPath, taskClient, runLookup, registered);
          if (startupMerge.merged > 0) {
            console.log(chalk.green(`[startup] Merged ${startupMerge.merged} previously completed branch(es).`));
          }
        } catch (startupMergeErr: unknown) {
          const msg = startupMergeErr instanceof Error ? startupMergeErr.message : String(startupMergeErr);
          console.warn(chalk.yellow(`[startup] Merge drain error (non-fatal): ${msg}`));
        }
      }

      // Dispatch loop: dispatch a batch, watch until done, then check for more work.
      // Exits when no new tasks are dispatched (all work complete or all remaining blocked).
      let iteration = 0;
      // Track whether the user explicitly detached (Ctrl+C). When detached, agents
      // continue running in the background so we skip the final merge drain.
      let userDetached = false;
      // Suppress repeated "No ready tasks" log messages — only print once per wait period.
      let waitingForTasksLogged = false;
      // Count consecutive poll cycles with nothing dispatched and no active agents.
      // When this reaches PIPELINE_LIMITS.emptyPollCycles the loop exits gracefully.
      let emptyPollCount = 0;
      while (true) {
        iteration++;
        if (iteration > 1) {
          console.log(chalk.bold(`\n── Batch ${iteration} ──────────────────────────────────\n`));
        }

        const result = await dispatcher.dispatch({
          maxAgents,
          model,
          dryRun,
          telemetry,
          pipeline,
          runtimeMode,
          workflow: workflowOverride,
          taskId: taskFilter,
          notifyUrl,
          targetBranch,
          staggerMs,
        });

        // Print dispatched tasks
        if (result.dispatched.length > 0) {
          console.log(chalk.green.bold(`Dispatched ${result.dispatched.length} task(s):\n`));
          for (const task of result.dispatched) {
            console.log(`  ${chalk.cyan(task.taskId)} ${task.title}`);
            console.log(`    Model:    ${chalk.magenta(task.model)}`);
            console.log(`    Branch:   ${task.branchName}`);
            console.log(`    Worktree: ${task.worktreePath}`);
            console.log(`    Run ID:   ${task.runId}`);
            console.log();
          }
        } else {
          console.log(chalk.yellow("No tasks dispatched."));
        }

        // Print skipped tasks
        if (result.skipped.length > 0) {
          console.log(chalk.dim(`Skipped ${result.skipped.length} task(s):`));
          for (const task of result.skipped) {
            console.log(`  ${chalk.dim(task.taskId)} ${chalk.dim(task.title)} — ${task.reason}`);
          }
          console.log();
        }

        console.log(chalk.bold(`Active agents: ${result.activeAgents}/${maxAgents}`));

        // dry-run: always exit immediately
        if (dryRun) {
          break;
        }

        // Nothing new dispatched in this iteration
        if (result.dispatched.length === 0) {
          // If agents are still running AND watch mode is on, wait for them to
          // finish — they may unblock previously-blocked tasks when they complete.
          if (watch && result.activeAgents > 0) {
            waitingForTasksLogged = false; // Reset: leaving "no tasks" wait state
            console.log(
              chalk.dim(
                `No new tasks dispatched — waiting for ${result.activeAgents} active agent(s) to finish…`
              )
            );
            const activeRuns = await (daemonStore ?? store).getActiveRuns();
            const runIds = activeRuns.map((r) => r.id);
            if (runIds.length > 0) {
              const { detached } = await watchRunsInk(daemonStore ?? store, runIds, { notificationBus, ...(makeAutoDispatchFn ? { autoDispatch: makeAutoDispatchFn } : {}) });
              if (detached) {
                userDetached = true;
                break; // User hit Ctrl+C — exit dispatch loop, agents continue in background
              }
            }
            // Agents finished — loop back and check for newly-unblocked tasks
            continue;
          }
          // Watch mode with no active agents: poll for new tasks to become ready
          if (watch) {
            emptyPollCount++;
            // Check cycle limit (0 = disabled / legacy infinite-poll behaviour)
            if (
              PIPELINE_LIMITS.emptyPollCycles > 0 &&
              emptyPollCount >= PIPELINE_LIMITS.emptyPollCycles
            ) {
              const elapsedSec = Math.round(
                (emptyPollCount * PIPELINE_TIMEOUTS.monitorPollMs) / 1000
              );
              console.log(
                chalk.yellow(
                  `\nNo ready tasks after ${emptyPollCount} poll cycle(s) (~${elapsedSec}s). Exiting dispatch loop.`
                )
              );
              console.log(
                chalk.dim(
                  "  • Re-run 'foreman run' once tasks become unblocked\n" +
                  "  • Use 'foreman tasks' to see which tasks are ready\n" +
                  "  • Use 'foreman status' to check for stuck agents\n" +
                  "  • Set FOREMAN_EMPTY_POLL_CYCLES=0 to disable this limit"
                )
              );
              break;
            }
            if (!waitingForTasksLogged) {
              console.log(
                chalk.dim(
                  `No ready tasks — waiting for tasks to become available…`
                )
              );
              waitingForTasksLogged = true;
            }
            await new Promise<void>((resolve) =>
              setTimeout(resolve, PIPELINE_TIMEOUTS.monitorPollMs)
            );
            continue;
          }
          // No active agents and --no-watch: nothing left to do
          break;
        }

        // Tasks were dispatched — reset counters so the "waiting" message and
        // the empty-poll limit restart from zero when we next enter a dry spell.
        waitingForTasksLogged = false;
        emptyPollCount = 0;

        // Watch mode: wait for this batch to finish, then loop to check for more
        if (watch) {
          const runIds = result.dispatched.map((t) => t.runId);
          const { detached } = await watchRunsInk(daemonStore ?? store, runIds, { notificationBus, ...(makeAutoDispatchFn ? { autoDispatch: makeAutoDispatchFn } : {}) });
          if (detached) {
            userDetached = true;
            break; // User hit Ctrl+C — exit dispatch loop, agents continue in background
          }
          // After batch completes, loop back to dispatch the next batch
          continue;
        }

        // No-watch mode: dispatch once and exit
        break;
      }

      await stopSentinel();
      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    } finally {
      // Stop the notification server regardless of how the command exits
      await notifyServer.stop().catch(() => { /* ignore cleanup errors */ });
    }
  });

// Add task subcommand for direct workflow execution
runCommand.addCommand(runTaskCommand);
