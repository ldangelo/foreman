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
import { VcsBackendFactory } from "../../lib/vcs/index.js";

export type MailSendActionOptions = {
  runId?: string;
  from: string;
  to: string;
  subject: string;
  body: string;
};

function writeMailSendError(message: string): number {
  process.stderr.write(`mail send error: ${message}\n`);
  return 1;
}

async function resolveMailProjectPath(cwd: string): Promise<string> {
  const vcs = await VcsBackendFactory.create({ backend: "auto" }, cwd);
  return await vcs.getMainRepoRoot(cwd);
}

export async function mailSendAction(options: MailSendActionOptions): Promise<number> {
  const runId = options.runId?.trim() || process.env["FOREMAN_RUN_ID"]?.trim();
  if (!runId) {
    return writeMailSendError("--run-id is required (or set FOREMAN_RUN_ID)");
  }

  let parsedBody: string;
  try {
    parsedBody = JSON.stringify(JSON.parse(options.body));
  } catch {
    return writeMailSendError(`--body must be valid JSON (got: ${options.body})`);
  }

  let projectPath: string;
  try {
    projectPath = await resolveMailProjectPath(process.cwd());
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    return writeMailSendError(`unable to resolve project path: ${msg}`);
  }

  const store = ForemanStore.forProject(projectPath);
  try {
    store.sendMessage(runId, options.from, options.to, options.subject, parsedBody);
    return 0;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    return writeMailSendError(msg);
  } finally {
    store.close();
  }
}

// ── send subcommand ───────────────────────────────────────────────────────────

const sendCommand = new Command("send")
  .description("Send an Agent Mail message within a pipeline run")
  .option("--run-id <id>", "Run ID (falls back to FOREMAN_RUN_ID env var)")
  .requiredOption("--from <agent>", "Sender agent role (e.g. explorer, developer)")
  .requiredOption("--to <agent>", "Recipient agent role (e.g. foreman, developer)")
  .requiredOption("--subject <subject>", "Message subject (e.g. phase-started, phase-complete, agent-error)")
  .option("--body <json>", "Message body as JSON string (defaults to '{}')", "{}")
  .action(async (options: MailSendActionOptions) => {
    process.exitCode = await mailSendAction(options);
  });

// ── mail command (parent) ─────────────────────────────────────────────────────

export const mailCommand = new Command("mail")
  .description("Agent Mail subcommands (send, etc.)")
  .addCommand(sendCommand);
