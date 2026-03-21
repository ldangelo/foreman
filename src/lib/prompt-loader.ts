/**
 * prompt-loader.ts — Load and render phase prompt templates.
 *
 * Checks ~/.foreman/prompts/{phase}.md for user-provided templates.
 * Falls back to a built-in string if the file is absent.
 *
 * Template syntax (Mustache-light):
 *   {{variableName}}             — replaced with value from vars; missing → empty string
 *   {{#if variableName}}...{{/if}} — block included if variable is truthy; removed otherwise
 *   Nested {{#if}} blocks        — greedy match on outermost pair
 *
 * TRD-2026-003: TRD-010 [satisfies REQ-008]
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

// ── Template rendering ─────────────────────────────────────────────────────────

/**
 * Render a Mustache-light template string with the provided variables.
 *
 * Processing order:
 *   1. Replace {{#if var}}...{{/if}} blocks (greedy match on outermost pair)
 *   2. Replace {{variableName}} placeholders (missing vars → empty string)
 *   3. Trim leading/trailing whitespace
 */
export function renderTemplate(
  template: string,
  vars: Record<string, string | undefined>,
): string {
  // Step 1: Process {{#if var}}...{{/if}} blocks.
  // The regex uses a greedy match ([\s\S]*) to capture the outermost block,
  // which handles nested {{#if}} blocks correctly by treating them as literal
  // text within the outer block.
  let result = template.replace(
    /\{\{#if (\w+)\}\}([\s\S]*?)\{\{\/if\}\}/g,
    (_match: string, varName: string, content: string): string => {
      const value = vars[varName];
      // Include block if variable is truthy (non-empty, non-undefined, non-null)
      if (value !== undefined && value !== null && value !== "") {
        return content;
      }
      return "";
    },
  );

  // Step 2: Replace {{variableName}} placeholders.
  // Missing variables become empty string (not an error).
  result = result.replace(
    /\{\{(\w+)\}\}/g,
    (_match: string, varName: string): string => {
      const value = vars[varName];
      return value !== undefined && value !== null ? value : "";
    },
  );

  // Step 3: Trim final output
  return result.trim();
}

// ── Prompt loader ──────────────────────────────────────────────────────────────

/**
 * Load a prompt template for the given phase, render it with variables, and return it.
 *
 * Resolution order:
 *   1. ~/.foreman/prompts/{phase}.md (user customization)
 *   2. fallback string (built-in prompt from roles.ts)
 *
 * The fallback is rendered with variable substitution too, so built-in prompts
 * can contain {{variable}} placeholders if desired.
 *
 * @param phase     Pipeline phase name (e.g. "explorer", "developer")
 * @param vars      Template variables for substitution
 * @param fallback  Built-in prompt string to use if external file is absent
 * @returns         Rendered prompt string
 */
export function loadPrompt(
  phase: string,
  vars: Record<string, string | undefined>,
  fallback: string,
): string {
  const promptPath = join(homedir(), ".foreman", "prompts", `${phase}.md`);

  let template: string;
  if (existsSync(promptPath)) {
    try {
      template = readFileSync(promptPath, "utf-8");
    } catch {
      // File exists but couldn't be read — fall back to built-in
      template = fallback;
    }
  } else {
    template = fallback;
  }

  return renderTemplate(template, vars);
}
