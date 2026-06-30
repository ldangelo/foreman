import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join, dirname } from "node:path";
const __dirname = dirname(fileURLToPath(import.meta.url));
/**
 * Replace all `{{key}}` placeholders in a template string with the provided values.
 */
function renderTemplate(template, vars) {
    return template.replace(/\{\{(\w+)\}\}/g, (_, key) => {
        return Object.prototype.hasOwnProperty.call(vars, key) ? vars[key] : `{{${key}}}`;
    });
}
/**
 * Generate the TASK.md content placed in each worker worktree.
 *
 * This file provides context for all agents in the pipeline — the explorer,
 * developer, QA, and reviewer all read this to understand the task.
 *
 * Named TASK.md (not AGENTS.md) to avoid overwriting the project's AGENTS.md
 * when worktree branches are merged back to main.
 */
export function workerAgentMd(seed, worktreePath, model) {
    const templatePath = join(__dirname, "../templates/worker-agent.md");
    const template = readFileSync(templatePath, "utf8");
    const description = seed.description ?? "(no description provided)";
    const commentsSection = seed.comments
        ? `\n## Additional Context\n${seed.comments}\n`
        : "";
    return renderTemplate(template, {
        seedId: seed.id,
        title: seed.title,
        description,
        model,
        worktreePath,
        commentsSection,
    });
}
//# sourceMappingURL=templates.js.map