import { Command } from "commander";
import chalk from "chalk";
import { ElixirServerClient } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";

/** Format seconds into a human-readable duration string (e.g., "1m 30s"). */
function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  const secs = seconds % 60;
  if (minutes < 60) return secs > 0 ? `${minutes}m ${secs}s` : `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  const mins = minutes % 60;
  return mins > 0 ? `${hours}h ${mins}m` : `${hours}h`;
}

export const metricsCommand = new Command("metrics")
  .description("Show task cost and timing metrics")
  .action(async () => {
    try {
      const manager = new ElixirServerManager();
      const status = await manager.ensureRunning();
      const client = new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);

      const metrics = await client.getMetrics();
      const totalCost = typeof metrics.total_cost === "string" ? parseFloat(metrics.total_cost) : (metrics.total_cost ?? 0);
      const costPerTurn = typeof metrics.cost_per_turn === "string" ? parseFloat(metrics.cost_per_turn) : (metrics.cost_per_turn ?? 0);
      const totalTimeSeconds = metrics.total_time_seconds ?? 0;
      const timePerTurnSeconds = typeof metrics.time_per_turn_seconds === "string" ? parseFloat(metrics.time_per_turn_seconds) : (metrics.time_per_turn_seconds ?? 0);
      const totalTurns = metrics.total_turns ?? 0;

      if (totalCost === 0 && totalTurns === 0) {
        console.log(chalk.yellow("No metrics available yet. Run some tasks first."));
        return;
      }

      console.log(chalk.bold("Metrics\n"));
      console.log(`  Total Cost:      ${chalk.yellow(`$${totalCost.toFixed(2)}`)}`);
      console.log(`  Cost per Turn:   ${chalk.yellow(`$${costPerTurn.toFixed(4)}`)}`);

      if (totalTimeSeconds > 0) {
        console.log(`  Total Time:      ${chalk.dim(formatDuration(totalTimeSeconds))}`);
        console.log(`  Time per Turn:   ${chalk.dim(formatDuration(timePerTurnSeconds))}`);
      }

      console.log(`  Total Turns:     ${chalk.dim(totalTurns.toString())}`);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });
