/**
 * Template loader utility for loading agent phase prompts from markdown files.
 *
 * Templates live in src/defaults/prompts/default/ and use {{variable}} placeholder
 * syntax for dynamic content interpolation.
 *
 * @deprecated Use loadPrompt() from src/lib/prompt-loader.ts for new code.
 *   This module is retained for backward compatibility with existing callers.
 *   Templates have moved from src/orchestrator/templates/ to
 *   src/defaults/prompts/default/ with shorter names (no "-prompt" suffix).
 */
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const TEMPLATE_DIR = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "defaults",
  "prompts",
  "default",
);

/**
 * Map legacy filenames (e.g. "explorer-prompt.md") to new names ("explorer.md").
 * Allows existing callers that pass old-style filenames to keep working.
 */
const LEGACY_FILENAME_MAP: Readonly<Record<string, string>> = {
  "explorer-prompt.md": "explorer.md",
  "developer-prompt.md": "developer.md",
  "qa-prompt.md": "qa.md",
  "reviewer-prompt.md": "reviewer.md",
  "sentinel-prompt.md": "sentinel.md",
  "lead-prompt.md": "lead.md",
  "lead-prompt-explorer.md": "lead-explorer.md",
  "lead-prompt-reviewer.md": "lead-reviewer.md",
};

// Module-level cache to avoid repeated disk I/O
const templateCache = new Map<string, string>();

/**
 * Load a template file from the defaults/prompts/default/ directory.
 * Results are cached to avoid repeated disk I/O.
 *
 * @param filename - Template filename (e.g. "explorer.md" or legacy "explorer-prompt.md").
 *   Must not contain path separators — only bare filenames are accepted.
 *   All callers pass hardcoded filenames; this function is not intended
 *   to be used with user-controlled input.
 * @throws Error if the filename contains a path separator or if the file cannot be read
 */
export function loadTemplate(filename: string): string {
  // Reject paths containing directory separators to keep lookups confined to TEMPLATE_DIR.
  if (filename.includes("/") || filename.includes("\\")) {
    throw new Error(
      `loadTemplate expects a bare filename, not a path (got "${filename}")`,
    );
  }

  const cached = templateCache.get(filename);
  if (cached !== undefined) return cached;

  // Resolve legacy filename → new filename
  const resolvedFilename = LEGACY_FILENAME_MAP[filename] ?? filename;

  const filePath = join(TEMPLATE_DIR, resolvedFilename);
  let content: string;
  try {
    content = readFileSync(filePath, "utf-8");
  } catch (err) {
    throw new Error(
      `Failed to load template "${filename}" from ${filePath}: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
  }
  templateCache.set(filename, content);
  return content;
}

/**
 * Replace {{variable}} placeholders in a template string with provided values.
 * Unrecognised placeholders are left as-is.
 *
 * @param template - Template string containing {{variable}} placeholders
 * @param variables - Key/value pairs to substitute
 */
export function interpolateTemplate(
  template: string,
  variables: Record<string, string>,
): string {
  return template.replace(/\{\{(\w+)\}\}/g, (_match, key: string) => {
    return key in variables ? variables[key] : `{{${key}}}`;
  });
}

/**
 * Load a template file and interpolate variables in a single call.
 *
 * @param filename - Template filename (e.g. "explorer.md" or legacy "explorer-prompt.md")
 * @param variables - Key/value pairs to substitute
 */
export function loadAndInterpolate(
  filename: string,
  variables: Record<string, string>,
): string {
  return interpolateTemplate(loadTemplate(filename), variables);
}

/**
 * Clear the template cache.
 * Intended for use in tests where template files may be mocked.
 */
export function clearTemplateCache(): void {
  templateCache.clear();
}
