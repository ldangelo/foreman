import { Command } from "commander";
import chalk from "chalk";

export const mergeCommand = new Command("merge")
  .description("Trigger refinery for completed work")
  .action(async () => {
    console.log(chalk.bold("Running refinery on completed beads..."));
    // TODO: Collect completed bead outputs, run merge/refinery logic
    console.log(chalk.yellow("(refinery not yet implemented)"));
  });
