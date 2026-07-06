import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { Command } from "commander";
import chalk from "chalk";

import { ElixirServerClient } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { resolveProjectContext } from "./project-context.js";
import { abandonAction } from "./abandon.js";
import { printDryRunNotice } from "./cli-output.js";

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
  const matches = stdout
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

async function activeRunForTask(client: ElixirServerClient, projectId: string, taskId: string): Promise<Record<string, unknown> | null> {
  const runs = (await client.listRuns({ projectId })).filter((run) => run.task_id === taskId);
  return runs.find((run) => ["in_progress", "running", "pending", "conflict", "failed"].includes(runStatusOf(run))) ?? runs[0] ?? null;
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

  const run = await activeRunForTask(client, registered.id, taskId);
  const runId = run ? runIdOf(run) : null;
  const reason = opts.reason ?? "reset by operator";

  console.log(chalk.bold(`${dryRun ? "Would reset" : "Resetting"} ${chalk.cyan(taskId)}`));
  console.log(`  project: ${registered.name}`);
  console.log(`  reason: ${reason}`);
  if (runId) console.log(`  active run: ${chalk.dim(runId)} status=${runStatusOf(run!)}`);
  else console.log(`  active run: ${chalk.dim("(none)")}`);

  if (runId) {
    const stopped = await killWorkerProcesses(runId, dryRun);
    if (stopped === 0) console.log(chalk.dim("  no worker process found"));

    const code = await abandonAction(taskId, {
      project: opts.project,
      projectPath: opts.projectPath,
      reason,
      dryRun,
      keepTask: true,
      keepWorktree: opts.keepWorktree,
    });
    if (code !== 0) return code;
  }

  if (dryRun) {
    console.log(chalk.dim(`  would set task ${taskId} to ready`));
    console.log(chalk.dim("  would request scheduler dispatch"));
    if (!runId) console.log(chalk.yellow("Dry run complete — no changes were made."));
    return 0;
  }

  const response = await client.sendCommand({
    command_id: `reset-task-${taskId}-${Date.now()}`,
    command_type: "task.update",
    payload: { project_id: registered.id, task_id: taskId, status: "ready" },
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
  .description("Reset an active task by stopping its worker, abandoning the current run, and re-dispatching")
  .argument("<task-id>", "Task ID to reset")
  .option("--reason <text>", "Reason recorded in run history")
  .option("--dry-run", "Preview changes without applying them")
  .option("--keep-worktree", "Do not remove the current run worktree")
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
