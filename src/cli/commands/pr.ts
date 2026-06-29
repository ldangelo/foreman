import { Command } from "commander";
import chalk from "chalk";

import { foremanBackendMode } from "../../lib/backend-mode.js";
import { ElixirServerClient, type ElixirRun } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { resolveRepoRootProjectPath } from "./project-task-support.js";
import { findRegisteredProjectByPath } from "./project-context.js";

function elixirPrCandidate(run: ElixirRun): boolean {
  return ["completed", "succeeded", "passed", "pr-created"].includes(run.status ?? "") && Boolean(run.task_id);
}

function elixirRunBranch(run: ElixirRun): string {
  if (typeof run.branch_name === "string") return run.branch_name;
  if (typeof run.branch === "string") return run.branch;
  if (typeof run.worktree_path === "string") return run.worktree_path;
  return `foreman/${run.task_id ?? run.run_id ?? run.id ?? "unknown"}`;
}

export async function renderElixirPrView(opts: { json?: boolean; baseBranch?: string; draft?: boolean; list?: boolean }): Promise<void> {
  const projectPath = await resolveRepoRootProjectPath({});
  const registered = await findRegisteredProjectByPath(projectPath, { initPool: false });
  if (!registered) {
    const message = `Project at '${projectPath}' is not registered in Elixir. Run 'foreman project add' first.`;
    if (opts.json) console.error(JSON.stringify({ error: message }));
    else console.error(chalk.red(message));
    process.exitCode = 1;
    return;
  }

  const manager = new ElixirServerManager();
  const status = await manager.ensureRunning();
  if (!status.running) {
    const message = "Elixir server is not running. Start it with 'foreman server start'.";
    if (opts.json) console.error(JSON.stringify({ error: message }));
    else console.error(chalk.red(message));
    process.exitCode = 1;
    return;
  }

  const client = new ElixirServerClient(status.url, manager.authToken);
  const candidates = (await client.listRuns(registered.id)).filter(elixirPrCandidate);
  const entries = candidates.map((run) => ({
    run_id: run.run_id ?? run.id,
    seed_id: run.task_id,
    branch_name: elixirRunBranch(run),
    status: run.status,
    base_branch: opts.baseBranch ?? "main",
    draft: Boolean(opts.draft),
  }));

  if (opts.json) {
    console.log(JSON.stringify({ entries }, null, 2));
    return;
  }

  console.log(chalk.bold(`Elixir PR candidates (${entries.length}):\n`));
  if (entries.length === 0) {
    console.log(chalk.yellow("No completed Elixir runs found as PR candidates."));
    return;
  }

  for (const entry of entries) {
    console.log(`  ${chalk.cyan(entry.seed_id ?? "unknown")} ${chalk.dim(`[${entry.run_id ?? "unknown"}] ${entry.branch_name ?? "(branch unknown)"}`)}`);
  }
}

export async function requestElixirPr(opts: { json?: boolean; baseBranch?: string; draft?: boolean }): Promise<void> {
  const projectPath = await resolveRepoRootProjectPath({});
  const registered = await findRegisteredProjectByPath(projectPath, { initPool: false });
  if (!registered) {
    const message = `Project at '${projectPath}' is not registered in Elixir. Run 'foreman project add' first.`;
    if (opts.json) console.error(JSON.stringify({ error: message }));
    else console.error(chalk.red(message));
    process.exitCode = 1;
    return;
  }

  const manager = new ElixirServerManager();
  const status = await manager.ensureRunning();
  if (!status.running) {
    const message = "Elixir server is not running. Start it with 'foreman server start'.";
    if (opts.json) console.error(JSON.stringify({ error: message }));
    else console.error(chalk.red(message));
    process.exitCode = 1;
    return;
  }

  const client = new ElixirServerClient(status.url, manager.authToken);
  const candidates = (await client.listRuns(registered.id)).filter(elixirPrCandidate);
  const baseBranch = opts.baseBranch ?? "main";
  const requested = [] as Array<{ run_id: string; seed_id: string | undefined; branch_name: string; base_branch: string; draft: boolean }>;

  for (const run of candidates) {
    const runId = String(run.run_id ?? run.id ?? "");
    if (!runId) continue;
    const branch = elixirRunBranch(run);
    const response = await client.requestPr({ runId, taskId: run.task_id, branch, baseBranch, draft: Boolean(opts.draft) });
    if (!response.ok) throw new Error(response.error.message);
    requested.push({ run_id: runId, seed_id: run.task_id, branch_name: branch, base_branch: baseBranch, draft: Boolean(opts.draft) });
  }

  if (opts.json) {
    console.log(JSON.stringify({ requested }, null, 2));
    return;
  }

  if (requested.length === 0) {
    console.log(chalk.yellow("No completed Elixir runs found as PR candidates."));
    return;
  }

  console.log(chalk.green.bold(`Requested ${requested.length} Elixir PR operation(s):\n`));
  for (const request of requested) {
    console.log(`  ${chalk.cyan(request.seed_id ?? request.run_id)} ${chalk.dim(`${request.branch_name} -> ${request.base_branch}${request.draft ? " (draft)" : ""}`)}`);
  }
}

export const prCommand = new Command("pr")
  .description("Request Elixir PR operations by default; legacy Refinery PR creation with FOREMAN_BACKEND=node")
  .option("--base-branch <branch>", "Base branch for PRs", "main")
  .option("--draft", "Create draft PRs")
  .option("--list", "Show Elixir PR candidates without requesting PRs")
  .option("--json", "Output PR operations as JSON")
  .action(async (opts) => {
    try {
      if (foremanBackendMode() === "elixir") {
        if (opts.list) await renderElixirPrView(opts);
        else await requestElixirPr(opts);
        return;
      }

      const [{ ForemanStore }, { PostgresStore }, { createTaskClient }, { VcsBackendFactory }, { Refinery }] = await Promise.all([
        import("../../lib/store.js"),
        import("../../lib/postgres-store.js"),
        import("../../lib/task-client-factory.js"),
        import("../../lib/vcs/index.js"),
        import("../../orchestrator/refinery.js"),
      ]);
      const projectPath = await resolveRepoRootProjectPath({});
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
      const registered = await findRegisteredProjectByPath(projectPath);
      const { taskClient } = await createTaskClient(projectPath, { registeredProjectId: registered?.id });
      const store = ForemanStore.forProject(projectPath);
      const runLookup = registered ? PostgresStore.forProject(registered.id) : undefined;
      const refinery = registered
        ? new Refinery(store, taskClient, projectPath, vcs, { registeredProjectId: registered.id, runLookup })
        : new Refinery(store, taskClient, projectPath, vcs);

      const project = registered ?? store.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("No project registered. Run 'foreman init' first."));
        process.exit(1);
      }

      console.log(chalk.bold("Creating PRs for completed work...\n"));

      const report = await refinery.createPRs({
        baseBranch: opts.baseBranch,
        draft: opts.draft,
        projectId: project.id,
      });

      if (report.created.length > 0) {
        console.log(chalk.green.bold(`Created ${report.created.length} PR(s):\n`));
        for (const pr of report.created) {
          console.log(`  ${chalk.cyan(pr.seedId)} ${pr.branchName}`);
          console.log(`    ${chalk.blue(pr.prUrl)}`);
          console.log();
        }
      }

      if (report.failed.length > 0) {
        console.log(chalk.red.bold(`Failed ${report.failed.length} PR(s):\n`));
        for (const f of report.failed) {
          console.log(`  ${chalk.cyan(f.seedId)} ${f.branchName}`);
          console.log(`    ${chalk.dim(f.error.split("\n")[0])}`);
        }
        console.log();
      }

      if (report.created.length === 0 && report.failed.length === 0) {
        console.log(chalk.yellow("No completed tasks to create PRs for."));
      }

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });
