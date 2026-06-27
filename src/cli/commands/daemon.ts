/**
 * `foreman daemon` CLI commands — manage the legacy ForemanDaemon lifecycle.
 *
 * Sub-commands:
 *   foreman daemon start     — Start the daemon in the background
 *   foreman daemon stop      — Stop the running daemon
 *   foreman daemon status    — Show daemon status
 *   foreman daemon restart   — Stop then start
 *
 * @module src/cli/commands/daemon
 */

import { Command } from "commander";
import chalk from "chalk";
import { existsSync, readFileSync } from "node:fs";
import {
  DaemonManager,
  DaemonAlreadyRunningError,
  DaemonNotRunningError,
  type DaemonStatus,
} from "../../lib/daemon-manager.js";
import { foremanBackendMode, nodeDaemonAllowed, nodeDaemonDisabledMessage } from "../../lib/backend-mode.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";

// ── Shared helpers ────────────────────────────────────────────────────────────

/** Column widths for status output. */
const COL_LABEL = 20;
const COL_VALUE = 50;

function padLabel(str: string): string {
  return str.padEnd(COL_LABEL);
}

function formatStatus(status: DaemonStatus): void {
  const badge = status.running
    ? chalk.green("● running")
    : chalk.dim("○ stopped");
  console.log(chalk.bold(`\n  Daemon status: ${badge}\n`));
  console.log(`  ${padLabel("PID:")} ${status.pid ? chalk.cyan(String(status.pid)) : chalk.dim("—")}`);
  console.log(`  ${padLabel("Socket:")} ${chalk.dim(status.socketPath)}`);
  console.log();
}

function readDaemonLogExcerpt(path: string): string | null {
  if (!existsSync(path)) return null;
  const content = readFileSync(path, "utf-8").trim();
  if (!content) return null;
  return content.split("\n").slice(-5).join("\n");
}

function elixirManager(opts: { pidPath?: string }): ElixirServerManager {
  return new ElixirServerManager({ pidPath: opts.pidPath });
}

function formatElixirStatus(status: ReturnType<ElixirServerManager["status"]>, json?: boolean): void {
  if (json) {
    console.log(JSON.stringify({ running: status.running, pid: status.pid, url: status.url, pidPath: status.pidPath }, null, 2));
    return;
  }
  const badge = status.running ? chalk.green("● running") : chalk.dim("○ stopped");
  console.log(chalk.bold(`\n  Elixir server status: ${badge}\n`));
  console.log(`  ${padLabel("PID:")} ${status.pid ? chalk.cyan(String(status.pid)) : chalk.dim("—")}`);
  console.log(`  ${padLabel("URL:")} ${chalk.dim(status.url)}`);
  console.log(`  ${padLabel("PID file:")} ${chalk.dim(status.pidPath)}`);
  console.log(chalk.dim("\n  `foreman daemon` is an Elixir server compatibility alias; use `foreman server` directly."));
  console.log();
}

// ── foreman daemon start ─────────────────────────────────────────────────────

const startCommand = new Command("start")
  .description("Start the Elixir server by default; legacy ForemanDaemon with FOREMAN_BACKEND=node")
  .option("--socket-path <path>", "Override the Unix socket path")
  .option("--pid-path <path>", "Override the PID file path")
  .action(async (opts: { socketPath?: string; pidPath?: string }) => {
    if (foremanBackendMode() === "elixir") {
      const mgr = elixirManager(opts);
      mgr.start();
      console.log(chalk.green("✓ Elixir server started."));
      console.log(chalk.dim(`  URL: ${mgr.url}`));
      console.log(chalk.dim("  `foreman daemon start` is a compatibility alias; prefer `foreman server start`."));
      return;
    }
    if (!nodeDaemonAllowed()) {
      console.error(chalk.red(`Error: ${nodeDaemonDisabledMessage()}`));
      process.exit(1);
    }

    const mgr = new DaemonManager({
      socketPath: opts.socketPath,
      pidPath: opts.pidPath,
    });

    if (mgr.isRunning()) {
      const status = mgr.status();
      console.error(
        chalk.red("Error: daemon is already running.") +
          chalk.dim(`\n  PID:     ${status.pid ?? "?"}\n  Socket:  ${status.socketPath}\n`),
      );
      process.exit(1);
    }

    try {
      mgr.start();
      // Give the daemon a moment to open its socket before we confirm.
      await new Promise<void>((resolve) => setTimeout(resolve, 500));
      if (!mgr.isRunning()) {
        const stderrExcerpt = readDaemonLogExcerpt(mgr.stderrPath);
        console.error(
          chalk.red("Error: daemon exited before startup completed.") +
            chalk.dim("\n  Check DATABASE_URL / Postgres connectivity and retry.") +
            (stderrExcerpt
              ? chalk.dim(`\n  Daemon stderr:\n${stderrExcerpt}`)
              : "") +
            chalk.dim("\n  For full startup logs, run: node dist/daemon/index.js\n"),
        );
        process.exit(1);
      }
      console.log(chalk.green("✓ Daemon started."));
      console.log(chalk.dim(`  Socket: ${mgr.socketPath}`));
      console.log();
    } catch (err: unknown) {
      if (err instanceof DaemonAlreadyRunningError) {
        // Race: someone else started it between our check and start().
        console.error(chalk.red("Error: daemon is already running.") +
          chalk.dim(`  PID: ${err.pid}`));
      } else {
        const message = err instanceof Error ? err.message : String(err);
        console.error(chalk.red(`Error: failed to start daemon: ${message}`));
      }
      process.exit(1);
    }
  });

// ── foreman daemon stop ──────────────────────────────────────────────────────

const stopCommand = new Command("stop")
  .description("Stop the Elixir server by default; legacy ForemanDaemon with FOREMAN_BACKEND=node")
  .option("--socket-path <path>", "Override the Unix socket path")
  .option("--pid-path <path>", "Override the PID file path")
  .action(async (opts: { socketPath?: string; pidPath?: string }) => {
    if (foremanBackendMode() === "elixir") {
      const mgr = elixirManager(opts);
      mgr.stop();
      console.log(chalk.green("✓ Elixir server stopped."));
      console.log(chalk.dim("  `foreman daemon stop` is a compatibility alias; prefer `foreman server stop`."));
      return;
    }
    if (!nodeDaemonAllowed()) {
      console.error(chalk.red(`Error: ${nodeDaemonDisabledMessage()}`));
      process.exit(1);
    }

    const mgr = new DaemonManager({
      socketPath: opts.socketPath,
      pidPath: opts.pidPath,
    });

    if (!mgr.isRunning()) {
      console.error(chalk.red("Error: daemon is not running."));
      process.exit(1);
    }

    try {
      mgr.stop();
      console.log(chalk.green("✓ Daemon stopped."));
      console.log(chalk.dim(`  Socket: ${mgr.socketPath}`));
      console.log();
    } catch (err: unknown) {
      if (err instanceof DaemonNotRunningError) {
        console.error(chalk.red("Error: daemon is not running."));
      } else {
        const message = err instanceof Error ? err.message : String(err);
        console.error(chalk.red(`Error: failed to stop daemon: ${message}`));
      }
      process.exit(1);
    }
  });

// ── foreman daemon status ────────────────────────────────────────────────────

const statusCommand = new Command("status")
  .description("Show Elixir server status by default; legacy daemon status with FOREMAN_BACKEND=node")
  .option("--socket-path <path>", "Override the Unix socket path")
  .option("--pid-path <path>", "Override the PID file path")
  .option("--json", "Output status as JSON")
  .action(async (opts: { socketPath?: string; pidPath?: string; json?: boolean }) => {
    if (foremanBackendMode() === "elixir") {
      formatElixirStatus(elixirManager(opts).status(), opts.json);
      return;
    }
    if (!nodeDaemonAllowed()) {
      const message = nodeDaemonDisabledMessage();
      if (opts.json) {
        console.log(JSON.stringify({ error: message }, null, 2));
      } else {
        console.error(chalk.red(`Error: ${message}`));
      }
      process.exit(1);
    }

    const mgr = new DaemonManager({
      socketPath: opts.socketPath,
      pidPath: opts.pidPath,
    });

    const status = mgr.status();

    if (opts.json) {
      console.log(
        JSON.stringify(
          {
            running: status.running,
            pid: status.pid,
            socketPath: status.socketPath,
          },
          null,
          2,
        ),
      );
      return;
    }

    formatStatus(status);
  });

// ── foreman daemon restart ────────────────────────────────────────────────────

const restartCommand = new Command("restart")
  .description("Restart the Elixir server by default; legacy daemon with FOREMAN_BACKEND=node")
  .option("--socket-path <path>", "Override the Unix socket path")
  .option("--pid-path <path>", "Override the PID file path")
  .action(async (opts: { socketPath?: string; pidPath?: string }) => {
    if (foremanBackendMode() === "elixir") {
      const mgr = elixirManager(opts);
      mgr.stop();
      mgr.start();
      console.log(chalk.green("✓ Elixir server restarted."));
      console.log(chalk.dim(`  URL: ${mgr.url}`));
      console.log(chalk.dim("  `foreman daemon restart` is a compatibility alias; prefer `foreman server restart`."));
      return;
    }
    if (!nodeDaemonAllowed()) {
      console.error(chalk.red(`Error: ${nodeDaemonDisabledMessage()}`));
      process.exit(1);
    }

    const mgr = new DaemonManager({
      socketPath: opts.socketPath,
      pidPath: opts.pidPath,
    });

    // Stop if running.
    if (mgr.isRunning()) {
      try {
        mgr.stop();
        console.log(chalk.green("✓ Daemon stopped."));
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        console.error(chalk.red(`Warning: stop failed: ${message}`));
        // Continue to start anyway.
      }
    }

    // Start.
    try {
      mgr.start();
      await new Promise<void>((resolve) => setTimeout(resolve, 500));
      console.log(chalk.green("✓ Daemon started."));
      console.log(chalk.dim(`  Socket: ${mgr.socketPath}`));
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: failed to start daemon: ${message}`));
      process.exit(1);
    }
  });

// ── Parent command ───────────────────────────────────────────────────────────

export const daemonCommand = new Command("daemon")
  .description(
    "Compatibility alias for Elixir server lifecycle; legacy ForemanDaemon with FOREMAN_BACKEND=node",
  )
  .addCommand(startCommand)
  .addCommand(stopCommand)
  .addCommand(statusCommand)
  .addCommand(restartCommand);
