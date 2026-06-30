/**
 * Task metadata used for placeholder interpolation in workflow templates.
 */
export interface TaskMeta {
    id: string;
    title: string;
    description: string;
    type: string;
    priority: number;
    /**
     * Stable directory for phase artifacts/reports.
     * Defaults to Foreman's private report store under ~/.foreman/reports.
     * Runtime artifacts are not written to the agent worktree by default.
     */
    projectReportsDir?: string;
}
/**
 * Interpolate `{task.*}` placeholders in a template string with values from task metadata.
 *
 * Supported placeholders:
 * - `{task.id}`         → task.id
 * - `{task.title}`      → task.title
 * - `{task.description}`→ task.description
 * - `{task.type}`       → task.type
 * - `{task.priority}`  → task.priority (converted to string)
 *
 * Behavior:
 * - Unknown placeholders (e.g. `{task.unknown}`) are left as-is and a warning is logged.
 * - Escaped braces `\{task.title\}` emit literal `{task.title}` (no substitution).
 * - Empty / null task fields substitute as empty string.
 * - Backslash before a non-placeholder does not escape — only `\{` is treated as escape.
 *
 * @param template - String containing `{task.*}` placeholders
 * @param task    - Task metadata values to substitute
 * @returns Template with all recognized placeholders replaced
 */
export declare function interpolateTaskPlaceholders(template: string, task: TaskMeta): string;
//# sourceMappingURL=interpolate.d.ts.map