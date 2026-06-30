/**
 * Required prompt phase files per workflow.
 * Foreman init and doctor use these to validate / install prompts.
 */
export declare const REQUIRED_PHASES: Readonly<Record<string, ReadonlyArray<string>>>;
/** Required Pi skill names bundled with foreman. */
export declare const REQUIRED_SKILLS: ReadonlyArray<string>;
/**
 * Replace {{variable}} placeholders in a template string with provided values.
 * Unknown placeholders are left as-is.
 */
export declare function renderTemplate(template: string, vars: Record<string, string | undefined>): string;
/**
 * Error thrown when a shell command fails during prompt expansion.
 */
export declare class CommandExpansionError extends Error {
    readonly command: string;
    readonly exitCode: number | null;
    readonly stderr: string;
    constructor(command: string, exitCode: number | null, stderr: string);
}
/**
 * Expand !`command` placeholders in a template by executing each command
 * and replacing the placeholder with its stdout output.
 *
 * Commands are executed in the provided working directory (cwd).
 * If a command fails (non-zero exit), a CommandExpansionError is thrown.
 *
 * @param template - Template string potentially containing !`command` patterns
 * @param cwd      - Working directory for command execution
 * @returns Template with all !`command` patterns replaced by command output
 * @throws CommandExpansionError if any command fails
 */
export declare function expandCommandPlaceholders(template: string, cwd: string): string;
/**
 * Load and interpolate a phase prompt using the unified resolution chain.
 *
 * Resolution order:
 *   1. {projectRoot}/.foreman/prompts/{workflow}/{phase}.md
 *   2. {projectRoot}/.foreman/prompts/default/{phase}.md
 *   3. {projectRoot}/.foreman/prompts/{phase}.md
 *   4. ~/.foreman/prompts/{workflow}/{phase}.md
 *   5. ~/.foreman/prompts/default/{phase}.md
 *   6. ~/.foreman/prompts/{phase}.md
 *   7. Throws PromptNotFoundError
 *
 * @param phase       - Phase name: "explorer" | "developer" | "qa" | "reviewer" | ...
 * @param vars        - Template variables for {{placeholder}} substitution.
 * @param workflow    - Workflow name (e.g. "default", "smoke").
 * @param projectRoot - Absolute path to the project root (contains .foreman/).
 * @throws PromptNotFoundError if no prompt file is found in any tier.
 */
export declare function loadPrompt(phase: string, vars: Record<string, string | undefined>, workflow: string, projectRoot: string): string;
/**
 * Error thrown when a required prompt file is not found.
 * The message is designed to be shown directly to the user.
 */
export declare class PromptNotFoundError extends Error {
    readonly phase: string;
    readonly workflow: string;
    readonly projectRoot: string;
    constructor(phase: string, workflow: string, projectRoot: string);
}
/**
 * Get the path to a bundled default prompt file.
 *
 * @param workflow - Workflow name (e.g. "default", "smoke")
 * @param phase    - Phase name (e.g. "explorer", "developer")
 * @returns Absolute path to the bundled file, or null if not found
 */
export declare function getBundledPromptPath(workflow: string, phase: string): string | null;
/**
 * Read bundled default prompt content.
 *
 * @param workflow - Workflow name
 * @param phase    - Phase name
 * @returns File content, or null if not found
 */
export declare function getBundledPromptContent(workflow: string, phase: string): string | null;
/**
 * Install bundled prompt templates to ~/.foreman/prompts/.
 *
 * Copies all bundled workflows (default, smoke) to the global ~/.foreman/prompts/
 * directory. Existing files are skipped unless force=true.
 *
 * @param projectRoot - Absolute path to the project root
 * @param force       - Overwrite existing prompt files (default: false)
 * @returns Summary of installed/skipped files
 */
export declare function installBundledPrompts(_projectRoot: string, force?: boolean): {
    installed: string[];
    skipped: string[];
};
/**
 * Validate that all required prompt files are present for a project.
 *
 * @param projectRoot - Absolute path to the project root
 * @returns Array of missing prompt file paths (relative to ~/.foreman/prompts/)
 */
export declare function findMissingPrompts(_projectRoot: string): string[];
/**
 * Find project-local prompt overrides that are present but stale relative to
 * current runtime expectations (e.g. missing critical placeholder markers that
 * newer pipeline code depends on).
 */
export declare function findStalePrompts(_projectRoot: string): string[];
/**
 * Install bundled Pi skills to ~/.pi/agent/skills/.
 * Each skill is a directory containing SKILL.md. Always overwrites to keep up to date.
 */
export declare function installBundledSkills(): {
    installed: string[];
    skipped: string[];
};
/**
 * Check which required Pi skills are missing from ~/.pi/agent/skills/.
 */
export declare function findMissingSkills(): string[];
//# sourceMappingURL=prompt-loader.d.ts.map