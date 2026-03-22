/**
 * Unified prompt loader.
 *
 * Single resolution chain for agent phase prompts:
 *   1. <projectRoot>/.foreman/prompts/{workflow}/{phase}.md  (project-local override)
 *   2. ~/.foreman/prompts/{phase}.md                         (user global override)
 *   3. Error — no silent fallback to bundled defaults at runtime
 *
 * Bundled defaults live in src/defaults/prompts/{workflow}/{phase}.md and are
 * installed into a project by `foreman init` (or `foreman doctor --fix`).
 *
 * Use installBundledPrompts() to populate .foreman/prompts/ from bundled defaults.
 */
import {
  readFileSync,
  existsSync,
  mkdirSync,
  copyFileSync,
  readdirSync,
} from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

// ── Constants ────────────────────────────────────────────────────────────────

/**
 * Required prompt phase files per workflow.
 * Foreman init and doctor use these to validate / install prompts.
 */
export const REQUIRED_PHASES: Readonly<Record<string, ReadonlyArray<string>>> =
  {
    default: [
      "explorer",
      "developer",
      "qa",
      "reviewer",
      "sentinel",
      "lead",
      "lead-explorer",
      "lead-reviewer",
    ],
    smoke: ["explorer", "developer", "qa", "reviewer"],
  };

/** Bundled defaults directory (relative to this source file). */
const BUNDLED_DEFAULTS_DIR = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "defaults",
  "prompts",
);

// ── Template rendering ────────────────────────────────────────────────────────

/**
 * Replace {{variable}} placeholders in a template string with provided values.
 * Unknown placeholders are left as-is.
 */
export function renderTemplate(
  template: string,
  vars: Record<string, string | undefined>,
): string {
  return template.replace(/\{\{(\w+)\}\}/g, (_match, key: string) => {
    const val = vars[key];
    return val !== undefined ? val : `{{${key}}}`;
  });
}

// ── Loader ───────────────────────────────────────────────────────────────────

/**
 * Load and interpolate a phase prompt using the unified resolution chain.
 *
 * Resolution order:
 *   1. <projectRoot>/.foreman/prompts/{workflow}/{phase}.md
 *   2. ~/.foreman/prompts/{phase}.md
 *   3. Throws PromptNotFoundError
 *
 * @param phase       - Phase name: "explorer" | "developer" | "qa" | "reviewer" | ...
 * @param vars        - Template variables for {{placeholder}} substitution.
 * @param workflow    - Workflow name (e.g. "default", "smoke").
 * @param projectRoot - Absolute path to the project root (contains .foreman/).
 * @throws PromptNotFoundError if no prompt file is found in any tier.
 */
export function loadPrompt(
  phase: string,
  vars: Record<string, string | undefined>,
  workflow: string,
  projectRoot: string,
): string {
  // Tier 1: project-local prompt
  const projectPromptPath = join(
    projectRoot,
    ".foreman",
    "prompts",
    workflow,
    `${phase}.md`,
  );
  if (existsSync(projectPromptPath)) {
    try {
      return renderTemplate(readFileSync(projectPromptPath, "utf-8"), vars);
    } catch {
      // Fall through to next tier
    }
  }

  // Tier 2: user global prompt
  const userPromptPath = join(homedir(), ".foreman", "prompts", `${phase}.md`);
  if (existsSync(userPromptPath)) {
    try {
      return renderTemplate(readFileSync(userPromptPath, "utf-8"), vars);
    } catch {
      // Fall through to error
    }
  }

  // Tier 3: error
  throw new PromptNotFoundError(phase, workflow, projectRoot);
}

/**
 * Error thrown when a required prompt file is not found.
 * The message is designed to be shown directly to the user.
 */
export class PromptNotFoundError extends Error {
  constructor(
    public readonly phase: string,
    public readonly workflow: string,
    public readonly projectRoot: string,
  ) {
    super(
      `Missing prompt for phase '${phase}' (workflow '${workflow}'). ` +
        `Run 'foreman init' or 'foreman doctor --fix' to reinstall.`,
    );
    this.name = "PromptNotFoundError";
  }
}

// ── Installation helpers ─────────────────────────────────────────────────────

/**
 * Get the path to a bundled default prompt file.
 *
 * @param workflow - Workflow name (e.g. "default", "smoke")
 * @param phase    - Phase name (e.g. "explorer", "developer")
 * @returns Absolute path to the bundled file, or null if not found
 */
export function getBundledPromptPath(
  workflow: string,
  phase: string,
): string | null {
  const p = join(BUNDLED_DEFAULTS_DIR, workflow, `${phase}.md`);
  return existsSync(p) ? p : null;
}

/**
 * Read bundled default prompt content.
 *
 * @param workflow - Workflow name
 * @param phase    - Phase name
 * @returns File content, or null if not found
 */
export function getBundledPromptContent(
  workflow: string,
  phase: string,
): string | null {
  const p = getBundledPromptPath(workflow, phase);
  if (!p) return null;
  try {
    return readFileSync(p, "utf-8");
  } catch {
    return null;
  }
}

/**
 * Install bundled prompt templates to <projectRoot>/.foreman/prompts/.
 *
 * Copies all bundled workflows (default, smoke) to the project's .foreman/prompts/
 * directory. Existing files are skipped unless force=true.
 *
 * @param projectRoot - Absolute path to the project root
 * @param force       - Overwrite existing prompt files (default: false)
 * @returns Summary of installed/skipped files
 */
export function installBundledPrompts(
  projectRoot: string,
  force: boolean = false,
): { installed: string[]; skipped: string[] } {
  const installed: string[] = [];
  const skipped: string[] = [];

  // Install each bundled workflow
  const workflows = readdirSync(BUNDLED_DEFAULTS_DIR, {
    withFileTypes: true,
  })
    .filter((e) => e.isDirectory())
    .map((e) => e.name);

  for (const workflow of workflows) {
    const srcDir = join(BUNDLED_DEFAULTS_DIR, workflow);
    const destDir = join(projectRoot, ".foreman", "prompts", workflow);
    mkdirSync(destDir, { recursive: true });

    const files = readdirSync(srcDir).filter((f) => f.endsWith(".md"));
    for (const file of files) {
      const destPath = join(destDir, file);
      if (existsSync(destPath) && !force) {
        skipped.push(`${workflow}/${file}`);
      } else {
        copyFileSync(join(srcDir, file), destPath);
        installed.push(`${workflow}/${file}`);
      }
    }
  }

  return { installed, skipped };
}

/**
 * Validate that all required prompt files are present for a project.
 *
 * @param projectRoot - Absolute path to the project root
 * @returns Array of missing prompt file paths (relative to .foreman/prompts/)
 */
export function findMissingPrompts(projectRoot: string): string[] {
  const missing: string[] = [];

  for (const [workflow, phases] of Object.entries(REQUIRED_PHASES)) {
    for (const phase of phases) {
      const p = join(
        projectRoot,
        ".foreman",
        "prompts",
        workflow,
        `${phase}.md`,
      );
      if (!existsSync(p)) {
        missing.push(`${workflow}/${phase}.md`);
      }
    }
  }

  return missing;
}
