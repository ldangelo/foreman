/**
 * `foreman bead` — DEPRECATED spelling for natural-language task creation.
 *
 * Natural-language task generation was removed after the Elixir backend
 * cutover. This hidden command remains only to return an explicit removal
 * message for old scripts.
 */
import { Command } from "commander";
import chalk from "chalk";
import type { CreateFromTextOptions } from "./create-from-text.js";

// Re-export the shared helpers under their historical module path so existing
// importers/tests of bead.js keep working.
export {
  createBeadClient,
  createTasksFromText,
  normaliseIssue,
  parseLlmResponse,
  repairTruncatedJson,
  type BeadCommandClient,
  type CreateFromTextOptions,
} from "./create-from-text.js";

// ── Command ──────────────────────────────────────────────────────────────

export const beadCommand = new Command("bead")
  .description("Create tasks from natural-language description (deprecated: use 'foreman task create --from-text')")
  .argument("<description>", "Natural language description (or path to a file)")
  .option("--type <type>", "Force issue type (task|bug|feature|epic|chore|decision)")
  .option("--priority <priority>", "Force priority (P0-P4)")
  .option("--parent <id>", "Parent task ID")
  .option("--dry-run", "Show what would be created without creating tasks")
  .option("--no-llm", "Skip LLM parsing — create a single task with the text as title")
  .option("--model <model>", "Claude model to use for parsing")
  .action(
    async (
      description: string,
      opts: CreateFromTextOptions,
    ) => {
      void description;
      void opts;
      console.error(chalk.red("Error: foreman bead was removed after the Elixir backend cutover."));
      console.error(chalk.dim("  Use structured task creation: foreman task create --title <text> [--description <text>]"));
      process.exit(1);
    },
  );
