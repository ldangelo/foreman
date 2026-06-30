/**
 * `foreman bead` — DEPRECATED spelling for natural-language task creation.
 *
 * The implementation lives in create-from-text.ts and is shared with the
 * canonical spelling: `foreman task create --from-text "<description>"`.
 * This command is registered hidden and prints a one-line deprecation notice
 * before delegating; all of its original flags keep working.
 */
import { Command } from "commander";
export { createBeadClient, createTasksFromText, normaliseIssue, parseLlmResponse, repairTruncatedJson, type BeadCommandClient, type CreateFromTextOptions, } from "./create-from-text.js";
export declare const beadCommand: Command;
//# sourceMappingURL=bead.d.ts.map