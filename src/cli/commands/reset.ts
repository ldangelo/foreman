import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import { rm } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { Command } from "commander";
import chalk from "chalk";

import { ElixirServerClient } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { resolveProjectContext } from "./project-context.js";
import { printDryRunNotice } from "./cli-output.js";
import { ElixirMergeQueue } from "./elixir-merge-queue.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { WorktreeManager } from "../../lib/worktree-manager.js";
import { getForemanHomePath } from "../../lib/foreman-paths.js";
import { getRunReportsDir } from "../../lib/report-paths.js";

const execFileAsync = promisify(execFile);

interface ResetOpts {
  reason?: string;
  dryRun?: boolean;
  keepWorktree?: boolean;
  project?: string;
  projectPath?: string;
}

async function createElixirResetClient(): Promise<ElixirServerClient> {
  const manager = new ElixirServerManager();
  const status = await manager.ensureRunning();
  return new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
}

async function killWorkerProcesses(runId: string, dryRun: boolean): Promise<number> {
  const { stdout } = await execFileAsync("ps", ["-axo", "pid=,command="]);
  const processList = String(stdout ?? "");
  const matches = processList
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.includes(runId) && /agent-worker|foreman run task/.test(line))
    .map((line) => Number(line.split(/\s+/, 1)[0]))
    .filter((pid) => Number.isInteger(pid) && pid > 0 && pid !== process.pid);

  for (const pid of matches) {
    if (dryRun) {
      console.log(`  would stop worker process ${chalk.dim(String(pid))}`);
      continue;
    }
    try {
      process.kill(pid, "SIGTERM");
      console.log(`  stopped worker process ${chalk.dim(String(pid))}`);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.log(chalk.yellow(`  could not stop worker process ${pid}: ${msg}`));
    }
  }

  return matches.length;
}

function runIdOf(run: Record<string, unknown>): string | null {
  const value = run.run_id ?? run.id;
  return typeof value === "string" && value.length > 0 ? value : null;
}

function runStatusOf(run: Record<string, unknown>): string {
  return typeof run.status === "string" ? run.status : "unknown";
}

const resetActiveRunStatuses: Record<string, true> = {
  in_progress: true,
  running: true,
  pending: true,
  conflict: true,
};


function prTimestampOf(run: Record<string, unknown>): number {
  for (const key of ["updated_at", "completed_at", "started_at", "created_at"]) {
    const value = run[key];
    if (typeof value !== "string") continue;
    const timestamp = Date.parse(value);
    if (Number.isFinite(timestamp)) return timestamp;
  }
  return 0;
}
function hasField(value: unknown, key: string): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && key in value;
}

function stringField(value: unknown, key: string): string | undefined {
  if (!hasField(value, key)) return undefined;
  const field = value[key];
  return typeof field === "string" ? field : undefined;
}

function isAlreadyMergedPrError(error: unknown): boolean {
  const stderr = stringField(error, "stderr");
  return typeof stderr === "string" && stderr.includes("already merged");
}


async function retireResetPr(args: {
  runs: Record<string, unknown>[];
  branchName: string;
  reason: string;
  dryRun: boolean;
  projectPath: string;
  client?: ElixirServerClient;
  projectId?: string;
  taskId?: string;
}): Promise<{ retired: boolean; prUrl?: string; alreadyMerged?: boolean }> {
  const run = [...args.runs]
    .filter((candidate) =>
      typeof candidate.pr_url === "string" &&
      (candidate.pr_state === "open" || candidate.pr_state === "draft"),
    )
    .sort((a, b) => prTimestampOf(b) - prTimestampOf(a))[0];
  if (!run) return { retired: false };

  const prUrl = String(run.pr_url);
  if (args.dryRun) {
    console.log(`  would close PR ${chalk.dim(prUrl)} as superseded by reset`);
    return { retired: true, prUrl };
  }

  try {
    await execFileAsync("gh", [
      "pr",
      "close",
      prUrl,
      "--comment",
      `Closed by foreman reset: ${args.reason}. A fresh run will create a new PR.`,
    ], { cwd: args.projectPath });
    console.log(`  closed PR ${chalk.dim(prUrl)} as superseded by reset`);
  } catch (error) {
    if (!isAlreadyMergedPrError(error)) throw error;
    console.log(`  PR ${chalk.dim(prUrl)} is already merged; completing reset without re-dispatch`);
    return { retired: false, prUrl, alreadyMerged: true };
  }

  const runId = runIdOf(run);
  if (args.client && args.projectId && args.taskId && runId) {
    const headSha = typeof run.pr_head_sha === "string" ? run.pr_head_sha : undefined;
    const baseBranch = typeof run.base_branch === "string" ? run.base_branch : undefined;
    const response = await args.client.sendCommand({
      command_id: `reset-close-pr-${runId}-${Date.now()}`,
      command_type: "run.pr.reset",
      payload: {
        project_id: args.projectId,
        task_id: args.taskId,
        run_id: runId,
        pr_url: prUrl,
        branch_name: args.branchName,
        action: "closed",
        reason: args.reason,
        ...(headSha ? { head_sha: headSha } : {}),
        ...(baseBranch ? { base_branch: baseBranch } : {}),
      },
      metadata: { source: "foreman-reset", reason: args.reason },
    });
    if (!response.ok) throw new Error(response.error.message);
  }

  return { retired: true, prUrl };
}
async function failActiveRunsForReset(
  client: ElixirServerClient,
  projectId: string,
  taskId: string,
  runIds: string[],
  reason: string,
  dryRun: boolean,
): Promise<void> {
  for (const runId of [...new Set(runIds)]) {
    if (dryRun) {
      console.log(`  would mark active run ${chalk.dim(runId)} failed`);
      continue;
    }

    const now = new Date().toISOString();
    const response = await client.sendCommand({
      command_id: `reset-fail-run-${runId}-${Date.now()}`,
      command_type: "run.fail",
      payload: {
        project_id: projectId,
        task_id: taskId,
        run_id: runId,
        reason,
        failure_reason: reason,
        completed_at: now,
        updated_at: now,
      },
      metadata: { source: "foreman-reset", reason },
    });
    if (!response.ok) throw new Error(response.error.message);
    console.log(`  marked active run ${chalk.dim(runId)} failed`);
  }
}

async function completeActiveRunsForMergedPr(
  client: ElixirServerClient,
  projectId: string,
  taskId: string,
  runIds: string[],
  reason: string,
  dryRun: boolean,
): Promise<void> {
  for (const runId of [...new Set(runIds)]) {
    if (dryRun) {
      console.log(`  would mark active run ${chalk.dim(runId)} completed`);
      continue;
    }

    const now = new Date().toISOString();
    const response = await client.sendCommand({
      command_id: `reset-complete-merged-pr-run-${runId}-${Date.now()}`,
      command_type: "run.complete",
      payload: {
        project_id: projectId,
        task_id: taskId,
        run_id: runId,
        reason,
        completed_at: now,
        updated_at: now,
      },
      metadata: { source: "foreman-reset", reason },
    });
    if (!response.ok) throw new Error(response.error.message);
    console.log(`  marked active run ${chalk.dim(runId)} completed`);
  }
}

export async function cleanupTaskRunArtifacts(
  projectId: string,
  taskId: string,
  runIds: string[],
  dryRun: boolean,
): Promise<number> {
  const uniqueRunIds = [...new Set(runIds.filter(Boolean))];
  let removed = 0;

  for (const runId of uniqueRunIds) {
    const paths = [
      join(homedir(), ".foreman", "logs", `${runId}.log`),
      join(homedir(), ".foreman", "logs", `${runId}.err`),
      join(homedir(), ".foreman", "logs", `${runId}.out`),
      getRunReportsDir(projectId, taskId, runId),
      getForemanHomePath("reports", "runs", runId, taskId),
    ];

    for (const path of paths) {
      if (!existsSync(path)) continue;
      removed++;
      if (dryRun) {
        console.log(`  would remove run artifact ${chalk.dim(path)}`);
      } else {
        await rm(path, { recursive: true, force: true });
      }
    }
  }

  return removed;
}

export async function resetAction(taskId: string, opts: ResetOpts = {}): Promise<number> {
  const dryRun = opts.dryRun ?? false;
  printDryRunNotice(dryRun);

  const { registered } = await resolveProjectContext(opts, { normalizePaths: true });
  if (!registered) {
    console.error(chalk.red("Error: foreman reset requires an Elixir-registered project. Run 'foreman init' first."));
    return 1;
  }

  const client = await createElixirResetClient();
  const task = await client.getTask(taskId);
  if (!task || (task.project_id && task.project_id !== registered.id)) {
    console.error(chalk.red(`Error: task '${taskId}' not found in project '${registered.name}'.`));
    return 1;
  }

  const runs = (await client.listRuns({ projectId: registered.id })).filter((candidate) => candidate.task_id === taskId);
  const run = runs.find((candidate) => resetActiveRunStatuses[runStatusOf(candidate)]) ??
    runs.find((candidate) => runStatusOf(candidate) === "failed") ??
    runs[0] ??
    null;
  const runId = run ? runIdOf(run) : null;
  const runIds = runs.map(runIdOf).filter((id): id is string => Boolean(id));
  const reason = opts.reason ?? "reset by operator";
  const branchName = taskId.startsWith("foreman/") ? taskId : `foreman/${taskId}`;

  console.log(chalk.bold(`${dryRun ? "Would reset" : "Resetting"} ${chalk.cyan(taskId)}`));
  console.log(`  project: ${registered.name}`);
  console.log(`  reason: ${reason}`);
  if (runId) console.log(`  active run: ${chalk.dim(runId)} status=${runStatusOf(run!)}`);
  else console.log(`  active run: ${chalk.dim("(none)")}`);

  const activeRunIds = runs
    .filter((candidate) => resetActiveRunStatuses[runStatusOf(candidate)])
    .map(runIdOf)
    .filter((id): id is string => Boolean(id));
  if (activeRunIds.length === 0) {
    console.log(chalk.dim("  no active worker process found"));
  }
  for (const activeRunId of activeRunIds) {
    const stopped = await killWorkerProcesses(activeRunId, dryRun);
    if (stopped === 0) console.log(chalk.dim(`  no worker process found for ${activeRunId}`));
  }

  const vcs = await VcsBackendFactory.create({ backend: "auto" }, registered.path);
  const defaultWorktreePath = new WorktreeManager().getWorktreePath(registered.id, taskId);
  const worktreePaths = [
    defaultWorktreePath,
    ...runs
      .map((candidate) => candidate.worktree_path)
      .filter((path): path is string => typeof path === "string" && path.length > 0),
  ];
  for (const worktreePath of [...new Set(worktreePaths)]) {
    if (opts.keepWorktree) continue;
    if (dryRun) {
      console.log(`  would remove worktree ${chalk.dim(worktreePath)}`);
    } else {
      await vcs.removeWorkspace(registered.path, worktreePath);
      console.log(`  removed worktree ${chalk.dim(worktreePath)}`);
    }
  }
  const mergeQueue = new ElixirMergeQueue(registered.id);
  const mergeQueueEntries = await Promise.resolve(mergeQueue.list());
  const queueMatches = mergeQueueEntries.filter((entry) =>
    entry.task_id === taskId || entry.branch_name === branchName || runIds.includes(entry.run_id),
  );
  if (dryRun) {
    console.log(`  would remove ${queueMatches.length} merge queue entr${queueMatches.length === 1 ? "y" : "ies"}`);
  } else {
    for (const entry of queueMatches) {
      await Promise.resolve(mergeQueue.remove(entry.id));
    }
    console.log(`  removed ${queueMatches.length} merge queue entr${queueMatches.length === 1 ? "y" : "ies"}`);
  }
  const prReset = await retireResetPr({
    runs,
    branchName,
    reason,
    dryRun,
    projectPath: registered.path,
    client,
    projectId: registered.id,
    taskId,
  });


  if (dryRun) {
    console.log(`  would delete branch ${chalk.dim(branchName)} (force)`);
    console.log(`  would delete origin branch ${chalk.dim(branchName)}`);
  } else {
    await vcs.deleteBranch(registered.path, branchName, { force: true }).catch(() => ({ deleted: false, wasFullyMerged: false }));
    await vcs.deleteRemoteBranch(registered.path, branchName).catch(() => undefined);
    console.log(`  deleted local/origin branch ${chalk.dim(branchName)} if present`);
  }

  const artifactCount = prReset.alreadyMerged
    ? 0
    : await cleanupTaskRunArtifacts(registered.id, taskId, runIds, dryRun);
  if (prReset.alreadyMerged) {
    console.log("  preserved prior run artifacts because the recorded PR is already merged");
  } else {
    console.log(`  ${dryRun ? "would remove" : "removed"} ${artifactCount} prior run artifact${artifactCount === 1 ? "" : "s"}`);
  }

  if (prReset.alreadyMerged) {
    await completeActiveRunsForMergedPr(client, registered.id, taskId, activeRunIds, reason, dryRun);

    if (dryRun) {
      console.log(chalk.dim(`  would set task ${taskId} to closed`));
      console.log(chalk.dim("  would skip scheduler dispatch because the recorded PR is already merged"));
      console.log(chalk.yellow("Dry run complete — no changes were made."));
      return 0;
    }

    const response = await client.sendCommand({
      command_id: `reset-close-merged-task-${taskId}-${Date.now()}`,
      command_type: "task.update",
      payload: {
        project_id: registered.id,
        task_id: taskId,
        status: "closed",
        run_id: null,
        phase_id: null,
        branch: null,
        failure_reason: null,
        failure_output: null,
      },
      metadata: { source: "foreman-reset", reason },
    });
    if (!response.ok) throw new Error(response.error.message);
    console.log(`  reset task ${chalk.dim(taskId)} is already merged; marked closed without dispatch`);
    console.log(chalk.green("Done."));
    return 0;
  }

  await failActiveRunsForReset(client, registered.id, taskId, activeRunIds, reason, dryRun);

  if (dryRun) {
    console.log(chalk.dim(`  would set task ${taskId} to ready`));
    console.log(chalk.dim("  would request scheduler dispatch"));
    console.log(chalk.yellow("Dry run complete — no changes were made."));
    return 0;
  }

  const response = await client.sendCommand({
    command_id: `reset-task-${taskId}-${Date.now()}`,
    command_type: "task.update",
    payload: {
      project_id: registered.id,
      task_id: taskId,
      status: "ready",
      run_id: null,
      phase_id: null,
      branch: null,
      failure_reason: null,
      failure_output: null,
    },
    metadata: { source: "foreman-reset", reason },
  });
  if (!response.ok) throw new Error(response.error.message);
  console.log(`  reset task ${chalk.dim(taskId)} to ready`);

  await client.schedulerTick();
  console.log("  queued scheduler tick accepted");
  console.log(chalk.green("Done."));
  return 0;
}

export const resetCommand = new Command("reset")
  .description("Reset a task to ready, remove its worker/worktree/branches, clean run logs, and re-dispatch")
  .argument("<task-id>", "Task ID to reset")
  .option("--reason <text>", "Reason recorded in run history")
  .option("--dry-run", "Preview changes without applying them")
  .option("--keep-worktree", "Do not remove the task worktree")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (taskId: string, opts: ResetOpts) => {
    try {
      const code = await resetAction(taskId, opts);
      if (code !== 0) process.exit(code);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${msg}`));
      process.exit(1);
    }
  });
