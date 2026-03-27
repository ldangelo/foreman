/**
 * Project-level configuration loader.
 *
 * Loads and validates the project-wide Foreman config from:
 *   <projectRoot>/.foreman/config.yaml
 *
 * The project config provides defaults that apply across all workflows.
 * The `vcs` key specifies which VCS backend to use:
 *
 * @example
 * ```yaml
 * # .foreman/config.yaml
 * vcs:
 *   backend: git
 *   git:
 *     useTown: true
 * ```
 *
 * Configuration precedence (highest wins):
 *   1. Workflow YAML `vcs` key (per-workflow override)
 *   2. Project `.foreman/config.yaml` `vcs` key
 *   3. Auto-detection (`.jj/` → jujutsu, `.git/` → git)
 */

import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { load as yamlLoad } from "js-yaml";
import type { VcsConfig } from "./vcs/types.js";

// ── Types ─────────────────────────────────────────────────────────────────────

/**
 * Project-level Foreman configuration loaded from `.foreman/config.yaml`.
 */
export interface ProjectConfig {
  /**
   * VCS backend configuration.
   * When set, applies as the project default for all workflows.
   * Individual workflow YAML `vcs` keys override this setting.
   * When absent, auto-detection is used.
   */
  vcs?: VcsConfig;
}

// ── Error ─────────────────────────────────────────────────────────────────────

/**
 * Error thrown when a project config file exists but is invalid.
 */
export class ProjectConfigError extends Error {
  constructor(
    public readonly projectPath: string,
    public readonly reason: string,
  ) {
    super(
      `Project config error at ${join(projectPath, ".foreman", "config.yaml")}: ${reason}. ` +
        `Check the file syntax or remove it to use defaults.`,
    );
    this.name = "ProjectConfigError";
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

// ── Validator ─────────────────────────────────────────────────────────────────

/**
 * Validate and coerce raw YAML parse output into a ProjectConfig.
 *
 * @throws ProjectConfigError if the YAML is structurally invalid.
 */
export function validateProjectConfig(raw: unknown, projectPath: string): ProjectConfig {
  if (!isRecord(raw)) {
    throw new ProjectConfigError(projectPath, "must be a YAML object");
  }

  const config: ProjectConfig = {};

  // ── Parse optional vcs block ──────────────────────────────────────────────
  if (raw["vcs"] !== undefined) {
    const rawVcs = raw["vcs"];
    if (!isRecord(rawVcs)) {
      throw new ProjectConfigError(projectPath, "'vcs' must be an object");
    }

    const backend = rawVcs["backend"];
    if (backend !== "git" && backend !== "jujutsu" && backend !== "auto") {
      throw new ProjectConfigError(
        projectPath,
        `vcs.backend must be 'git', 'jujutsu', or 'auto'; got '${String(backend)}'`,
      );
    }

    const vcs: VcsConfig = { backend };

    // Parse optional git sub-config
    if (rawVcs["git"] !== undefined) {
      if (!isRecord(rawVcs["git"])) {
        throw new ProjectConfigError(projectPath, "'vcs.git' must be an object");
      }
      const rawGit = rawVcs["git"];
      vcs.git = {};
      if (rawGit["useTown"] !== undefined) {
        if (typeof rawGit["useTown"] !== "boolean") {
          throw new ProjectConfigError(projectPath, "'vcs.git.useTown' must be a boolean");
        }
        vcs.git.useTown = rawGit["useTown"];
      }
    }

    // Parse optional jujutsu sub-config
    if (rawVcs["jujutsu"] !== undefined) {
      if (!isRecord(rawVcs["jujutsu"])) {
        throw new ProjectConfigError(projectPath, "'vcs.jujutsu' must be an object");
      }
      const rawJj = rawVcs["jujutsu"];
      vcs.jujutsu = {};
      if (rawJj["minVersion"] !== undefined) {
        if (typeof rawJj["minVersion"] !== "string" || !rawJj["minVersion"]) {
          throw new ProjectConfigError(
            projectPath,
            "'vcs.jujutsu.minVersion' must be a non-empty string",
          );
        }
        vcs.jujutsu.minVersion = rawJj["minVersion"];
      }
    }

    config.vcs = vcs;
  }

  return config;
}

// ── Loader ────────────────────────────────────────────────────────────────────

/**
 * Load and validate the project-level config from `.foreman/config.yaml`.
 *
 * Returns an empty object `{}` if the file does not exist (non-fatal).
 * Throws `ProjectConfigError` if the file exists but is invalid YAML or
 * fails schema validation.
 *
 * @param projectPath - Absolute path to the project root.
 * @throws ProjectConfigError if the file exists but is invalid.
 */
export function loadProjectConfig(projectPath: string): ProjectConfig {
  const configPath = join(projectPath, ".foreman", "config.yaml");

  if (!existsSync(configPath)) {
    return {};
  }

  let raw: unknown;
  try {
    raw = yamlLoad(readFileSync(configPath, "utf-8"));
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new ProjectConfigError(projectPath, `failed to parse YAML: ${msg}`);
  }

  // An empty file parses as null
  if (raw === null || raw === undefined) {
    return {};
  }

  return validateProjectConfig(raw, projectPath);
}

// ── Merge ─────────────────────────────────────────────────────────────────────

/**
 * Merge workflow-level and project-level VCS config with proper precedence.
 *
 * Precedence (highest to lowest):
 *   1. Workflow YAML `vcs` key
 *   2. Project `.foreman/config.yaml` `vcs` key
 *   3. Default: `{ backend: 'auto' }`
 *
 * @param workflowVcs - VCS config from the workflow YAML (highest priority).
 * @param projectVcs  - VCS config from the project config (second priority).
 * @returns Resolved VcsConfig to use for this pipeline run.
 */
export function mergeVcsConfig(
  workflowVcs: VcsConfig | undefined,
  projectVcs: VcsConfig | undefined,
): VcsConfig {
  if (workflowVcs !== undefined) return workflowVcs;
  if (projectVcs !== undefined) return projectVcs;
  return { backend: "auto" };
}
