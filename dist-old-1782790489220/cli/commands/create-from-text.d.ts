import type { Issue } from "../../lib/task-client.js";
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
/** Options accepted by the natural-language creation path (bead's flags). */
export interface CreateFromTextOptions {
    type?: string;
    priority?: string;
    parent?: string;
    dryRun?: boolean;
    llm: boolean;
    model?: string;
}
/**
 * Instantiate the br task-tracking client for natural-language task creation.
 *
 * Note: Foreman's task management uses the native Postgres store exclusively.
 * The natural-language creation path provides direct access to the beads_rust
 * CLI for operators who wish to manage beads outside of Foreman's workflow.
 *
 * Exported for unit testing.
 */
export interface BeadCommandClient {
    ensureBrInstalled(): Promise<void>;
    isInitialized(): Promise<boolean>;
    create(title: string, opts?: {
        type?: string;
        priority?: string;
        parent?: string;
        description?: string;
        labels?: string[];
    }): Promise<Issue>;
    addDependency(fromId: string, toId: string): Promise<void>;
}
export declare function createBeadClient(projectPath: string): BeadCommandClient;
/**
 * Create one or more tasks from a natural-language description.
 *
 * This is the full action body of the legacy `foreman bead` command. Failures
 * set `process.exitCode = 1` (rather than exiting) so callers can clean up.
 *
 * @param description - Natural-language description, or a path to a file.
 * @param opts        - Bead's flags (--type, --priority, --parent, --dry-run, --no-llm, --model).
 * @param projectPathArg - Project directory; defaults to the current working directory.
 */
export declare function createTasksFromText(description: string, opts: CreateFromTextOptions, projectPathArg?: string): Promise<void>;
/**
 * Derive a bead title (and optional description remainder) from free-form
 * text for the --no-llm path.
 *
 * Keeps the historical 200-code-unit title cap, but prefers cutting at the
 * last word boundary within the cap and never splits a surrogate pair (which
 * would leave a lone surrogate at the end of the title).
 *
 * Exported for testing.
 */
export declare function splitTitleFromText(text: string, maxLength?: number): {
    title: string;
    description?: string;
};
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
//# sourceMappingURL=create-from-text.d.ts.map