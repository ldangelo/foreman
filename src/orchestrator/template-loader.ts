/**
 * Template loader utility for loading agent phase prompts from markdown files.
 *
 * Templates live in src/orchestrator/templates/ and use {{variable}} placeholder
 * syntax for dynamic content interpolation.
 */
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const TEMPLATE_DIR = join(dirname(fileURLToPath(import.meta.url)), "templates");

// Module-level cache to avoid repeated disk I/O
const templateCache = new Map<string, string>();

/**
 * Load a template file from the templates/ directory.
 * Results are cached to avoid repeated disk I/O.
 *
 * @param filename - Template filename only (e.g. "explorer-prompt.md").
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

  const filePath = join(TEMPLATE_DIR, filename);
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
 * @param filename - Template filename (e.g. "explorer-prompt.md")
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
