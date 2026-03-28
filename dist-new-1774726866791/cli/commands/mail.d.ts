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
export declare const mailCommand: Command;
//# sourceMappingURL=mail.d.ts.map