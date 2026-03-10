import { Command } from "commander";
import chalk from "chalk";
import { execFileSync } from "node:child_process";

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

    // TODO: Show active agents from sqlite
    console.log();
    console.log(chalk.bold("Active Agents"));
    console.log(chalk.dim("  (no agents running)"));
  });
