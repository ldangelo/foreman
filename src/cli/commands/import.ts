import { Command } from "commander";
import chalk from "chalk";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { ElixirServerClient } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";

export const importCommand = new Command("import")
  .description("Import legacy Foreman data into the Elixir event store")
  .option("--dry-run", "Preview mode for supported import sources")
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

      throw new Error("No default import source is available. Use --to-elixir with --file or --from-node.");
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

async function runElixirMigrationImport(opts: { file?: string; fromNode?: boolean; project?: string; projectPath?: string; commandId?: string; autoStart?: boolean }): Promise<void> {
  if (!opts.file && !opts.fromNode) {
    throw new Error("--to-elixir requires --file <migration.json> or --from-node");
  }

  if (opts.fromNode) {
    throw new Error("--from-node no longer reads Postgres from the CLI. Export a migration JSON and use --to-elixir --file <migration.json>.");
  }

  const payload = JSON.parse(readFileSync(resolve(opts.file!), "utf8")) as Record<string, unknown>;
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

