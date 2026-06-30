import { Command } from "commander";
import chalk from "chalk";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
export const serverCommand = new Command("server").description("Manage the Elixir orchestration server");
serverCommand
    .command("start")
    .description("Start the local Elixir orchestration server")
    .option("--port <port>", "HTTP port", Number)
    .action(async (opts) => {
    const manager = new ElixirServerManager({ port: opts.port });
    try {
        const status = await manager.ensureRunning();
        console.log(chalk.green("✓ Elixir server running"));
        console.log(chalk.dim(`  URL: ${status.url}`));
        if (status.pid)
            console.log(chalk.dim(`  PID: ${status.pid}`));
    }
    catch (error) {
        console.error(chalk.red(`Error: failed to start Elixir server: ${error instanceof Error ? error.message : String(error)}`));
        process.exit(1);
    }
});
serverCommand
    .command("status")
    .description("Show local Elixir orchestration server status")
    .option("--port <port>", "HTTP port", Number)
    .action(async (opts) => {
    const manager = new ElixirServerManager({ port: opts.port });
    const status = manager.status();
    const health = await manager.health();
    console.log(status.running && health.ok ? chalk.green("● running") : chalk.dim("○ stopped"));
    console.log(chalk.dim(`URL: ${status.url}`));
    if (status.pid)
        console.log(chalk.dim(`PID: ${status.pid}`));
});
serverCommand
    .command("doctor")
    .description("Check Elixir orchestration server readiness")
    .option("--port <port>", "HTTP port", Number)
    .option("--no-auto-start", "Do not start the server if it is not already healthy")
    .action(async (opts) => {
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
//# sourceMappingURL=server.js.map