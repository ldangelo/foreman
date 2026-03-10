import { Command } from "commander";
import chalk from "chalk";

export const dashboardCommand = new Command("dashboard")
  .description("Launch the web dashboard")
  .action(async () => {
    console.log(chalk.bold("Starting dashboard on :3850"));
    // TODO: Launch Hono server from ../../dashboard/server.js
    console.log(chalk.yellow("(dashboard server not yet implemented)"));
  });
