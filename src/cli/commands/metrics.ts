import { Command } from "commander";
import chalk from "chalk";
import { ElixirServerClient } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { formatDuration } from "../watch-ui.js";

/**
 * Fetch and display task metrics including cost and time statistics.
 */
export async function displayMetrics(): Promise<void> {
  const manager = new ElixirServerManager();
  const status = await manager.ensureRunning();
  const client = new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
  const metrics = await client.getMetrics();

  console.log(chalk.bold("Task Metrics\n"));

  // Total cost
  const totalCost = typeof metrics.total_cost === "string" ? parseFloat(metrics.total_cost) : (metrics.total_cost ?? 0);
  console.log(`  Total Cost: ${chalk.yellow(`$${totalCost.toFixed(2)}`)}`);

  // Total turns
  const totalTurns = metrics.total_turns ?? 0;
  console.log(`  Total Turns: ${chalk.white(totalTurns.toLocaleString())}`);

  // Cost per turn
  const costPerTurn = typeof metrics.cost_per_turn === "string" ? parseFloat(metrics.cost_per_turn) : (metrics.cost_per_turn ?? 0);
  if (totalTurns > 0) {
    console.log(`  Cost per Turn: ${chalk.yellow(`$${costPerTurn.toFixed(4)}`)}`);
  } else {
    console.log(`  Cost per Turn: ${chalk.dim("—")}`);
  }

  // Total time
  const totalTimeSeconds = metrics.total_time_seconds ?? 0;
  console.log(`  Total Time: ${chalk.dim(totalTimeSeconds > 0 ? formatDuration(totalTimeSeconds) : "—")}`);

  // Time per turn
  const timePerTurnSeconds = typeof metrics.time_per_turn_seconds === "string" ? parseFloat(metrics.time_per_turn_seconds) : (metrics.time_per_turn_seconds ?? 0);
  if (totalTurns > 0 && timePerTurnSeconds > 0) {
    console.log(`  Time per Turn: ${chalk.dim(formatDuration(timePerTurnSeconds))}`);
  } else {
    console.log(`  Time per Turn: ${chalk.dim("—")}`);
  }
}

export const metricsCommand = new Command("metrics")
  .description("Show task metrics including total cost, cost per turn, total time, and time per turn")
  .action(async () => {
    try {
      await displayMetrics();
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });
