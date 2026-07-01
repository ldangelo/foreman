import { Command } from "commander";
import chalk from "chalk";

export const resetCommand = new Command("reset")
  .description("Removed after Elixir cutover; use Elixir-backed retry/recovery workflows")
  .option("--task <id>", "Removed legacy local run-store reset")
  .option("--bead <id>", "Removed legacy alias")
  .option("--all", "Removed legacy local run-store reset")
  .option("--detect-stuck", "Removed legacy stuck detection")
  .option("--timeout <minutes>", "Removed legacy stuck detection timeout")
  .option("--dry-run", "Removed legacy dry run")
  .option("--preserve-worktree", "Removed legacy worktree preservation")
  .option("--retry-failed-phase", "Removed legacy failed-phase retry")
  .option("--project <name>", "Registered project name (unused; reset removed)")
  .option("--project-path <absolute-path>", "Absolute project path (unused; reset removed)")
  .action(async () => {
    console.error(chalk.red("Error: foreman reset was removed after the Elixir backend cutover."));
    console.error(chalk.dim("  Use Elixir-backed retry/recovery workflows instead of the legacy local run-store reset path."));
    process.exit(1);
  });
