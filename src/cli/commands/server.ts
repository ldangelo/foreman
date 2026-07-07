import { Command } from "commander";
import chalk from "chalk";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";

export const serverCommand = new Command("server").description("Manage the Elixir orchestration server");

serverCommand
  .command("start")
  .description("Start the local Elixir orchestration server")
  .option("--port <port>", "HTTP port", Number)
  .action(async (opts: { port?: number }) => {
    const manager = new ElixirServerManager({ port: opts.port });
    try {
      const status = await manager.ensureRunning();
      console.log(chalk.green("✓ Elixir server running"));
      console.log(chalk.dim(`  URL: ${status.url}`));
      if (status.pid) console.log(chalk.dim(`  PID: ${status.pid}`));
    } catch (error) {
      console.error(chalk.red(`Error: failed to start Elixir server: ${error instanceof Error ? error.message : String(error)}`));
      process.exit(1);
    }
  });

serverCommand
  .command("status")
  .description("Show local Elixir orchestration server status")
  .option("--port <port>", "HTTP port", Number)
  .action(async (opts: { port?: number }) => {
    const manager = new ElixirServerManager({ port: opts.port });
    const status = manager.status();
    const health = await manager.health();
    console.log(status.running && health.ok ? chalk.green("● running") : chalk.dim("○ stopped"));
    console.log(chalk.dim(`URL: ${status.url}`));
    if (status.pid) console.log(chalk.dim(`PID: ${status.pid}`));
    if (isRecord(health.body) && isRecord(health.body.runtime)) {
      const runtime = health.body.runtime;
      console.log(chalk.dim(`MIX_ENV: ${stringValue(runtime.mix_env)}`));
      if (isRecord(runtime.event_store)) {
        const eventStore = `${stringValue(runtime.event_store.adapter)} ${stringValue(runtime.event_store.path ?? runtime.event_store.table)}`;
        console.log(chalk.dim(`Event store: ${eventStore}`));
      }
      if (isRecord(runtime.projection_store)) {
        const tables = Array.isArray(runtime.projection_store.tables) ? runtime.projection_store.tables.join(",") : "memory";
        console.log(chalk.dim(`Projection store: ${stringValue(runtime.projection_store.adapter)} ${tables}`));
      }
      if (isRecord(runtime.project_config_store)) {
        const projectConfigStore = `${stringValue(runtime.project_config_store.adapter)} ${stringValue(runtime.project_config_store.path)}`;
        console.log(chalk.dim(`Project config store: ${projectConfigStore}`));
      } else if (isRecord(runtime.project_store)) {
        const projectStore = `${stringValue(runtime.project_store.adapter)} ${stringValue(runtime.project_store.path)}`;
        console.log(chalk.dim(`Project config store: ${projectStore}`));
      }
    }
  });

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function stringValue(value: unknown): string {
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  return "unknown";
}

serverCommand
  .command("doctor")
  .description("Check Elixir orchestration server readiness")
  .option("--port <port>", "HTTP port", Number)
  .option("--no-auto-start", "Do not start the server if it is not already healthy")
  .action(async (opts: { port?: number; autoStart?: boolean }) => {
    const manager = new ElixirServerManager({ port: opts.port });

    if (opts.autoStart) {
      await manager.ensureRunning();
    }

    const doctor = await manager.doctor();
    if (!doctor.ok) {
      console.error(chalk.red("Elixir server doctor: FAIL"));
      console.error(chalk.dim(doctor.error ?? JSON.stringify(doctor.body)));
      process.exit(1);
    }

    console.log(chalk.green("Elixir server doctor: PASS"));
    console.log(JSON.stringify(doctor.body, null, 2));
  });

serverCommand
  .command("stop")
  .description("Stop the local Elixir orchestration server")
  .action(() => {
    const manager = new ElixirServerManager();
    manager.stop();
    console.log(chalk.green("✓ Elixir server stopped"));
  });
