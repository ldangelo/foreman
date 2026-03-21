/**
 * Workflow-aware prompt loader.
 *
 * Three-tier resolution chain for agent phase prompts:
 *   1. ~/.foreman/prompts/{workflow}/{phase}.md   (workflow-scoped user override)
 *   2. ~/.foreman/prompts/{phase}.md              (global user override)
 *   3. Built-in fallback string                   (always works)
 *
 * The `workflow` parameter enables smoke/custom workflow types to use their own
 * prompt files without touching the built-in templates.
 */
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

/**
 * Replace {{variable}} placeholders in a template string with provided values.
 * Unknown placeholders are left as-is.
 */
function renderTemplate(
  template: string,
  vars: Record<string, string | undefined>,
): string {
  return template.replace(/\{\{(\w+)\}\}/g, (_match, key: string) => {
    const val = vars[key];
    return val !== undefined ? val : `{{${key}}}`;
  });
}

/**
 * Load a phase prompt with optional workflow scoping.
 *
 * @param phase      - Phase name: "explorer" | "developer" | "qa" | "reviewer" | etc.
 * @param vars       - Template variables for {{placeholder}} substitution.
 * @param fallback   - Built-in prompt string used when no user file is found.
 * @param workflow   - Optional workflow name (e.g. "smoke", "feature", "bug").
 *                     When provided, checks the workflow-scoped directory first.
 * @returns The resolved and interpolated prompt string.
 */
export function loadPrompt(
  phase: string,
  vars: Record<string, string | undefined>,
  fallback: string,
  workflow?: string,
): string {
  const foremanPromptsDir = join(homedir(), ".foreman", "prompts");

  // Step 1: Workflow-scoped user prompt (~/.foreman/prompts/{workflow}/{phase}.md)
  if (workflow) {
    const workflowPromptPath = join(foremanPromptsDir, workflow, `${phase}.md`);
    if (existsSync(workflowPromptPath)) {
      try {
        return renderTemplate(readFileSync(workflowPromptPath, "utf-8"), vars);
      } catch {
        // Fall through to next tier
      }
    }
  }

  // Step 2: Global user prompt (~/.foreman/prompts/{phase}.md)
  const promptPath = join(foremanPromptsDir, `${phase}.md`);
  if (existsSync(promptPath)) {
    try {
      return renderTemplate(readFileSync(promptPath, "utf-8"), vars);
    } catch {
      // Fall through to built-in
    }
  }

  // Step 3: Built-in fallback
  return renderTemplate(fallback, vars);
}
