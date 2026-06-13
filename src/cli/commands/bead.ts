/**
 * `foreman bead` — DEPRECATED spelling for natural-language task creation.
 *
 * The implementation lives in create-from-text.ts and is shared with the
 * canonical spelling: `foreman task create --from-text "<description>"`.
 * This command is registered hidden and prints a one-line deprecation notice
 * before delegating; all of its original flags keep working.
 */
import { Command } from "commander";
import { createTasksFromText, type CreateFromTextOptions } from "./create-from-text.js";
import { printDeprecationNotice } from "./cli-output.js";

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
      printDeprecationNotice("foreman bead", "foreman task create --from-text");
      await createTasksFromText(description, opts);
    },
  );
