/**
 * `foreman mail` — Agent Mail subcommands.
 *
 * Subcommands:
 *   send  Send an Agent Mail message from one agent to another within a pipeline run.
 *
 * Usage:
 *   foreman mail send --run-id <id> --from <agent> --to <agent> --subject <subject> [--body <json>]
 *
 * The --run-id flag falls back to the FOREMAN_RUN_ID environment variable when not provided.
 */

import { Command } from "commander";
import { ForemanStore } from "../../lib/store.js";
import { getMainRepoRoot } from "../../lib/git.js";

// ── send subcommand ───────────────────────────────────────────────────────────

const sendCommand = new Command("send")
  .description("Send an Agent Mail message within a pipeline run")
  .option("--run-id <id>", "Run ID (falls back to FOREMAN_RUN_ID env var)")
  .requiredOption("--from <agent>", "Sender agent role (e.g. explorer, developer)")
  .requiredOption("--to <agent>", "Recipient agent role (e.g. foreman, developer)")
  .requiredOption("--subject <subject>", "Message subject (e.g. phase-started, phase-complete, agent-error)")
  .option("--body <json>", "Message body as JSON string (defaults to '{}')", "{}")
  .action(async (options: {
    runId?: string;
    from: string;
    to: string;
    subject: string;
    body: string;
  }) => {
    // Resolve run ID: flag takes priority, then env var
    const runId = options.runId ?? process.env["FOREMAN_RUN_ID"];
    if (!runId) {
      process.stderr.write(
        "mail send error: --run-id is required (or set FOREMAN_RUN_ID)\n",
      );
      process.exit(1);
    }

    // Validate body is valid JSON
    let parsedBody: string;
    try {
      // Parse and re-stringify to normalise whitespace; also validates JSON
      parsedBody = JSON.stringify(JSON.parse(options.body));
    } catch {
      process.stderr.write(
        `mail send error: --body must be valid JSON (got: ${options.body})\n`,
      );
      process.exit(1);
    }

    // Resolve the project root so we can open the correct store
    let projectPath: string;
    try {
      projectPath = await getMainRepoRoot(process.cwd());
    } catch {
      projectPath = process.cwd();
    }

    const store = ForemanStore.forProject(projectPath);
    try {
      store.sendMessage(runId, options.from, options.to, options.subject, parsedBody);
      store.close();
      process.exit(0);
    } catch (err: unknown) {
      store.close();
      const msg = err instanceof Error ? err.message : String(err);
      process.stderr.write(`mail send error: ${msg}\n`);
      process.exit(1);
    }
  });

// ── mail command (parent) ─────────────────────────────────────────────────────

export const mailCommand = new Command("mail")
  .description("Agent Mail subcommands (send, etc.)")
  .addCommand(sendCommand);
