import { Command } from "commander";
import chalk from "chalk";

import { BeadsRustClient } from "../../lib/beads-rust.js";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { Monitor } from "../../orchestrator/monitor.js";
import { AgentMailClient } from "../../orchestrator/agent-mail-client.js";

// ── Agent Mail health helpers ─────────────────────────────────────────────────

/** Result returned by fetchAgentMailHealth. */
export interface AgentMailHealth {
  online: boolean;
}

/**
 * Check Agent Mail service health.
 * Never throws — returns { online: false } on any failure.
 */
export async function fetchAgentMailHealth(): Promise<AgentMailHealth> {
  const client = new AgentMailClient();
  try {
    const online = await client.healthCheck();
    return { online };
  } catch {
    return { online: false };
  }
}

/**
 * Render a single Agent Mail health line for the monitor command.
 * Exported for testing.
 */
export function renderAgentMailMonitorLine(
  health: AgentMailHealth,
  output: (line: string) => void = console.log,
): void {
  if (health.online) {
    output(`  ${chalk.green("✓")} Agent Mail server: ${chalk.green("online")}`);
  } else {
    output(
      `  ${chalk.red("✗")} Agent Mail server: ${chalk.red("offline")}` +
        chalk.dim("  (run: python -m mcp_agent_mail &)"),
    );
  }
}

export const monitorCommand = new Command("monitor")
  .description("[deprecated] Check agent progress and detect stuck runs. Use 'foreman reset --detect-stuck' instead.")
  .option("--recover", "Auto-recover stuck agents (ignored when --json is used)")
  .option("--timeout <minutes>", "Stuck detection timeout in minutes", "15")
  .option("--json", "Output monitor report as JSON (note: --recover is ignored in this mode)")
  .action(async (opts) => {
    const timeoutMinutes = parseInt(opts.timeout, 10);

    // Warn when --json and --recover are combined — recovery is silently skipped in JSON mode
    if (opts.json && opts.recover) {
      console.warn("Warning: --recover is ignored when --json is used; recovery actions will not be performed.");
    }

    // Deprecation warning (skip when --json is used for clean automation output)
    if (!opts.json) {
      console.warn(
        chalk.yellow(
          "⚠  'foreman monitor' is deprecated. Use 'foreman reset --detect-stuck' instead.\n" +
          "   Recovery: foreman reset --detect-stuck\n" +
          "   Preview:  foreman reset --detect-stuck --dry-run\n",
        ),
      );
    }

    try {
      const projectPath = await getRepoRoot(process.cwd());
      const seeds = new BeadsRustClient(projectPath);
      const store = ForemanStore.forProject(projectPath);
      const monitor = new Monitor(store, seeds, projectPath);

      if (!opts.json) {
        console.log(chalk.bold("Checking agent status...\n"));
      }

      const report = await monitor.checkAll({
        stuckTimeoutMinutes: timeoutMinutes,
      });

      // JSON output path — serialize MonitorReport directly
      if (opts.json) {
        console.log(JSON.stringify(report, null, 2));
        store.close();
        return;
      }

      // Active
      if (report.active.length > 0) {
        console.log(chalk.green.bold(`Active (${report.active.length}):`));
        for (const run of report.active) {
          const elapsed = run.started_at
            ? Math.round((Date.now() - new Date(run.started_at).getTime()) / 60000)
            : 0;
          console.log(
            `  ${chalk.cyan(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)} ${elapsed}m`,
          );
        }
        console.log();
      }

      // Completed
      if (report.completed.length > 0) {
        console.log(chalk.cyan.bold(`Completed (${report.completed.length}):`));
        for (const run of report.completed) {
          console.log(`  ${chalk.cyan(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)}`);
        }
        console.log();
      }

      // Stuck
      if (report.stuck.length > 0) {
        console.log(chalk.yellow.bold(`Stuck (${report.stuck.length}):`));
        for (const run of report.stuck) {
          const elapsed = run.started_at
            ? Math.round((Date.now() - new Date(run.started_at).getTime()) / 60000)
            : 0;
          console.log(
            `  ${chalk.yellow(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)} ${elapsed}m`,
          );
        }
        console.log();

        // Auto-recover if requested
        if (opts.recover) {
          console.log(chalk.bold("Recovering stuck agents...\n"));
          for (const run of report.stuck) {
            const recovered = await monitor.recoverStuck(run);
            if (recovered) {
              console.log(`  ${chalk.green("✓")} ${run.seed_id} — re-queued as pending`);
            } else {
              console.log(`  ${chalk.red("✗")} ${run.seed_id} — max retries exceeded, marked failed`);
            }
          }
          console.log();
        } else {
          console.log(chalk.dim("  Use --recover to auto-recover stuck agents\n"));
        }
      }

      // Failed
      if (report.failed.length > 0) {
        console.log(chalk.red.bold(`Failed (${report.failed.length}):`));
        for (const run of report.failed) {
          console.log(`  ${chalk.red(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)}`);
        }
        console.log();
      }

      const total =
        report.active.length +
        report.completed.length +
        report.stuck.length +
        report.failed.length;

      if (total === 0) {
        console.log(chalk.dim("No active runs found."));
      }

      // Agent Mail health check (informational — never fails the command)
      console.log();
      console.log(chalk.bold("Service Health"));
      const agentMailHealth = await fetchAgentMailHealth();
      renderAgentMailMonitorLine(agentMailHealth);

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (opts.json) {
        console.error(JSON.stringify({ error: message }));
      } else {
        console.error(chalk.red(`Error: ${message}`));
      }
      process.exit(1);
    }
  });
