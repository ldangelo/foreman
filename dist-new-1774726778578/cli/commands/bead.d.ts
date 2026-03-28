import { Command } from "commander";
import { BeadsRustClient } from "../../lib/beads-rust.js";
interface ParsedIssue {
    title: string;
    description?: string;
    type?: string;
    priority?: string;
    labels?: string[];
    dependencies?: string[];
}
interface ParsedIssuesResponse {
    issues: ParsedIssue[];
}
/**
 * Instantiate the br task-tracking client.
 *
 * TRD-024: sd backend removed. Always returns a BeadsRustClient.
 *
 * Exported for unit testing.
 */
export declare function createBeadClient(projectPath: string): BeadsRustClient;
export declare const beadCommand: Command;
/**
 * Normalise an issue from the LLM response, filling in defaults and validating fields.
 * Exported for testing.
 */
export declare function normaliseIssue(raw: Partial<ParsedIssue>): ParsedIssue;
/**
 * Parse the raw LLM response, stripping markdown fences if present.
 * Exported for testing.
 */
export declare function parseLlmResponse(raw: string): ParsedIssuesResponse;
/** Exported for testing. */
export declare function repairTruncatedJson(json: string): string;
export {};
//# sourceMappingURL=bead.d.ts.map