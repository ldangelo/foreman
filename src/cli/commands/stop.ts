import { Command } from "commander";
import chalk from "chalk";

export interface StopOpts {
  list?: boolean;
  force?: boolean;
  dryRun?: boolean;
}

export const stopCommand = new Command("stop")
  .description("Removed after Elixir cutover; use Elixir run controls")
  .argument("[id]", "Run ID or task ID (removed operator surface)")
  .option("--list", "Removed legacy run-store listing")
  .option("--force", "Removed legacy force stop")
  .option("--dry-run", "Removed legacy dry run")
  .action(async (_id: string | undefined, _opts: StopOpts) => {
    console.error(chalk.red("Error: foreman stop was removed after the Elixir backend cutover."));
    console.error(chalk.dim("  Use Elixir run/recovery controls via foreman server/attach/retry workflows."));
    process.exit(1);
  });
