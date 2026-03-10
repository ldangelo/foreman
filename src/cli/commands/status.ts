import { Command } from "commander";
import chalk from "chalk";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { ForemanStore } from "../../lib/store.js";

interface Bead {
  id: string;
  title: string;
  status: string;
}

export const statusCommand = new Command("status")
  .description("Show project status from beads + sqlite")
  .action(async () => {
    console.log(chalk.bold("Project Status\n"));

    // Fetch bead list
    let beads: Bead[] = [];
    try {
      const output = execFileSync("bd", ["list", "--json"], {
        stdio: ["pipe", "pipe", "pipe"],
        encoding: "utf-8",
      });
      beads = JSON.parse(output);
    } catch {
      console.error(
        chalk.red(
          "Failed to read beads. Is this a foreman project? Run 'foreman init' first.",
        ),
      );
      process.exit(1);
    }

    const total = beads.length;
    const ready = beads.filter((b) => b.status === "ready").length;
    const inProgress = beads.filter((b) => b.status === "in-progress").length;
    const completed = beads.filter((b) => b.status === "completed").length;
    const blocked = beads.filter((b) => b.status === "blocked").length;

    console.log(chalk.bold("Tasks"));
    console.log(`  Total:       ${chalk.white(total)}`);
    console.log(`  Ready:       ${chalk.green(ready)}`);
    console.log(`  In Progress: ${chalk.yellow(inProgress)}`);
    console.log(`  Completed:   ${chalk.cyan(completed)}`);
    console.log(`  Blocked:     ${chalk.red(blocked)}`);

    // Show active agents from sqlite
    const store = new ForemanStore();
    const project = store.getProjectByPath(resolve("."));
    
    console.log();
    console.log(chalk.bold("Active Agents"));
    
    if (project) {
      const activeRuns = store.getActiveRuns(project.id);
      if (activeRuns.length === 0) {
        console.log(chalk.dim("  (no agents running)"));
      } else {
        for (const run of activeRuns) {
          const elapsed = run.started_at 
            ? Math.round((Date.now() - new Date(run.started_at).getTime()) / 60000)
            : 0;
          const badge = run.agent_type === "claude-code" 
            ? chalk.bgBlue.white(` ${run.agent_type} `)
            : run.agent_type === "pi"
            ? chalk.bgGreen.white(` ${run.agent_type} `)
            : chalk.bgMagenta.white(` ${run.agent_type} `);
          console.log(`  ${badge} ${run.bead_id} — ${run.status} (${elapsed}m)`);
        }
      }

      // Cost summary
      const metrics = store.getMetrics(project.id);
      if (metrics.totalCost > 0) {
        console.log();
        console.log(chalk.bold("Costs"));
        console.log(`  Total: ${chalk.yellow(`$${metrics.totalCost.toFixed(2)}`)}`);
        console.log(`  Tokens: ${chalk.dim(`${(metrics.totalTokens / 1000).toFixed(1)}k`)}`);
      }
    } else {
      console.log(chalk.dim("  (project not registered — run 'foreman init')"));
    }
    
    store.close();
  });
