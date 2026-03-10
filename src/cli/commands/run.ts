import { Command } from "commander";
import chalk from "chalk";

export const runCommand = new Command("run")
  .description("Dispatch ready tasks to agents")
  .action(async () => {
    console.log(chalk.bold("Dispatching ready tasks to agents..."));
    // TODO: Query beads for ready tasks, spin up agent workers
    console.log(chalk.yellow("(agent dispatch not yet implemented)"));
  });
