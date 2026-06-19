import { Command } from "commander";
import chalk from "chalk";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { performBeadsImport } from "./task.js";
import { ensureCliPostgresPool, listRegisteredProjects, resolveProjectPathFromOptions } from "./project-task-support.js";
import { PostgresAdapter } from "../../lib/db/postgres-adapter.js";
import { ElixirServerClient } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";

export const importCommand = new Command("import")
  .description("Import legacy Foreman data")
  .option("--from-beads", "Import tasks from .beads/issues.jsonl or .beads/beads.jsonl", true)
  .option("--dry-run", "Preview the first 5 mappings without writing to the database")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .option("--to-elixir", "Import a legacy migration JSON payload into the Elixir event store")
  .option("--file <path>", "Legacy migration JSON payload for --to-elixir")
  .option("--from-node", "Build a migration payload from the current Node/Postgres project")
  .option("--command-id <id>", "Explicit server command id for idempotent migration retries")
  .option("--no-auto-start", "Require an already-running Elixir server for --to-elixir")
  .action(async (opts: { dryRun?: boolean; project?: string; projectPath?: string; toElixir?: boolean; file?: string; fromNode?: boolean; commandId?: string; autoStart?: boolean }) => {
    try {
      if (opts.toElixir) {
        await runElixirMigrationImport(opts);
        return;
      }

      const projectPath = await resolveProjectPathFromOptions(opts);
      const result = await performBeadsImport(projectPath, { dryRun: opts.dryRun });
      if (opts.dryRun) {
        console.log(chalk.bold("\n  Dry-run preview (first 5 tasks)\n"));
        for (const record of result.preview.slice(0, 5)) {
          console.log(
            `  ${chalk.dim(record.bead.id)} → ${record.nativeId.slice(0, 8)} ` +
              `${chalk.cyan(record.status)} ${record.bead.title}`,
          );
        }
        console.log();
        console.log(
          chalk.green(
            `Would import ${result.imported} tasks (${result.duplicateSkips} skipped: already exist by external_id${result.unsupportedStatusSkips > 0 ? `, ${result.unsupportedStatusSkips} skipped: unsupported status` : ""}).`,
          ),
        );
        return;
      }

      console.log(
        chalk.green(
            `Imported ${result.imported} tasks (${result.duplicateSkips} skipped: already exist by external_id${result.unsupportedStatusSkips > 0 ? `, ${result.unsupportedStatusSkips} skipped: unsupported status` : ""}).`,
        ),
      );
      console.log(chalk.dim(`  Source: ${result.jsonlPath}`));
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

async function runElixirMigrationImport(opts: { file?: string; fromNode?: boolean; project?: string; projectPath?: string; commandId?: string; autoStart?: boolean }): Promise<void> {
  if (!opts.file && !opts.fromNode) {
    throw new Error("--to-elixir requires --file <migration.json> or --from-node");
  }

  const payload = opts.fromNode
    ? await buildNodeMigrationPayload(opts)
    : JSON.parse(readFileSync(resolve(opts.file!), "utf8")) as Record<string, unknown>;
  const migrationId = typeof payload.migration_id === "string" ? payload.migration_id : undefined;
  const commandId = opts.commandId ?? migrationId ?? `migration-import-${Date.now()}`;
  const manager = new ElixirServerManager();
  const status = opts.autoStart === false ? manager.status() : await manager.ensureRunning();

  if (!status.running) {
    throw new Error("Elixir server is not running. Start it with 'foreman server start' or omit --no-auto-start.");
  }

  const client = new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
  const response = await client.sendCommand({
    command_id: commandId,
    command_type: "migration.import",
    payload,
    metadata: { correlation_id: commandId, source: "foreman-cli-import" },
  });

  if (!response.ok) {
    throw new Error(`Migration import failed: ${response.error.message}`);
  }

  console.log(chalk.green("✓ Migration import command accepted"));
  console.log(chalk.dim(`Command: ${commandId}`));
  console.log(chalk.dim(`Events: ${response.events.join(", ")}`));
}

async function buildNodeMigrationPayload(opts: { project?: string; projectPath?: string }): Promise<Record<string, unknown>> {
  const projectPath = await resolveProjectPathFromOptions(opts);
  const projects = await listRegisteredProjects();
  const project = projects.find((record) => resolve(record.path) === resolve(projectPath));
  if (!project) {
    throw new Error(`Project at '${projectPath}' is not registered; run 'foreman init' or pass --file`);
  }

  ensureCliPostgresPool(project.path);
  const adapter = new PostgresAdapter();
  const tasks = await adapter.listTasks(project.id, { limit: 10_000 });

  return {
    migration_id: `node-project-${project.id}`,
    source: "node-postgres",
    projects: [{
      id: project.id,
      project_id: project.id,
      name: project.name,
      path: project.path,
      default_branch: project.defaultBranch ?? "main",
      status: "active",
    }],
    tasks: tasks.map((task) => ({
      id: task.id,
      task_id: task.id,
      project_id: project.id,
      title: task.title,
      description: task.description,
      status: task.status,
      task_type: task.type,
      priority: task.priority,
      external_id: task.external_id,
      dependencies: [],
      source: "node-postgres",
    })),
    runs: [],
    workflows: [],
    inbox_messages: [],
    config: {},
  };
}
