import { Command } from "commander";
import chalk from "chalk";

import { foremanBackendMode } from "../../lib/backend-mode.js";
import { ElixirServerClient, type ElixirRun } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { ForemanStore } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import { createTaskClient } from "../../lib/task-client-factory.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { Refinery } from "../../orchestrator/refinery.js";
import { resolveRepoRootProjectPath } from "./project-task-support.js";
import { findRegisteredProjectByPath } from "./project-context.js";

function elixirPrCandidate(run: ElixirRun): boolean {
  return ["completed", "succeeded", "passed", "pr-created"].includes(run.status ?? "") && Boolean(run.task_id);
}

export async function renderElixirPrView(opts: { json?: boolean; baseBranch?: string; draft?: boolean }): Promise<void> {
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
    branch_name: typeof run.branch_name === "string" ? run.branch_name : typeof run.branch === "string" ? run.branch : null,
    status: run.status,
    base_branch: opts.baseBranch ?? "main",
    draft: Boolean(opts.draft),
  }));

  if (opts.json) {
    console.log(JSON.stringify({ entries, note: "PR creation is owned by Elixir scheduler/finalize workflow; legacy Refinery PR creation requires FOREMAN_BACKEND=node." }, null, 2));
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
  console.log(chalk.dim("\nPR creation remains workflow-owned in Elixir mode. Use FOREMAN_BACKEND=node only for legacy Refinery PR creation."));
}

export const prCommand = new Command("pr")
  .description("Show Elixir PR candidates by default; legacy Refinery PR creation with FOREMAN_BACKEND=node")
  .option("--base-branch <branch>", "Base branch for PRs", "main")
  .option("--draft", "Create draft PRs")
  .option("--json", "Output Elixir PR candidate view as JSON")
  .action(async (opts) => {
    try {
      if (foremanBackendMode() === "elixir") {
        await renderElixirPrView(opts);
        return;
      }

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
