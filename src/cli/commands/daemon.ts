/**
 * `foreman daemon` CLI commands — inspect/stop stray legacy daemon processes.
 *
 * Sub-commands:
 *   foreman daemon start     — Removed after Elixir cutover
 *   foreman daemon stop      — Stop a running stray legacy daemon
 *   foreman daemon status    — Show legacy daemon status
 *   foreman daemon restart   — Removed after Elixir cutover
 *
 * @module src/cli/commands/daemon
 */

import { Command } from "commander";
import chalk from "chalk";
import {
  DaemonManager,
  DaemonNotRunningError,
  type DaemonStatus,
} from "../../lib/daemon-manager.js";

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

function rejectRemovedDaemonStart(): never {
  console.error(chalk.red("Error: foreman daemon start/restart was removed after the Elixir backend cutover."));
  console.error(chalk.dim("  Use 'foreman server start' to run the Elixir backend scheduler."));
  process.exit(1);
}

// ── foreman daemon start ─────────────────────────────────────────────────────

const startCommand = new Command("start")
  .description("Removed after Elixir cutover; use foreman server start")
  .option("--socket-path <path>", "Ignored legacy daemon socket path")
  .option("--pid-path <path>", "Ignored legacy daemon PID path")
  .action(async (_opts: { socketPath?: string; pidPath?: string }) => {
    rejectRemovedDaemonStart();
  });

// ── foreman daemon stop ──────────────────────────────────────────────────────

const stopCommand = new Command("stop")
  .description("Stop a running stray legacy ForemanDaemon")
  .option("--socket-path <path>", "Override the Unix socket path")
  .option("--pid-path <path>", "Override the PID file path")
  .action(async (opts: { socketPath?: string; pidPath?: string }) => {
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
  .description("Show daemon status (running/stopped, PID, socket path)")
  .option("--socket-path <path>", "Override the Unix socket path")
  .option("--pid-path <path>", "Override the PID file path")
  .option("--json", "Output status as JSON")
  .action(async (opts: { socketPath?: string; pidPath?: string; json?: boolean }) => {
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
  .description("Removed after Elixir cutover; use foreman server start")
  .option("--socket-path <path>", "Ignored legacy daemon socket path")
  .option("--pid-path <path>", "Ignored legacy daemon PID path")
  .action(async (_opts: { socketPath?: string; pidPath?: string }) => {
    rejectRemovedDaemonStart();
  });

// ── Parent command ───────────────────────────────────────────────────────────

export const daemonCommand = new Command("daemon")
  .description(
    "Inspect or stop a legacy ForemanDaemon; start/restart are removed after Elixir cutover",
  )
  .addCommand(startCommand)
  .addCommand(stopCommand)
  .addCommand(statusCommand)
  .addCommand(restartCommand);
