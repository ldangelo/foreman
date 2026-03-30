/**
 * Project-level VCS configuration loader.
 *
 * Loads project-wide VCS settings from `.foreman/config.yaml` (or the legacy
 * `.foreman/config.json` fallback) and resolves the final VCS configuration by
 * merging workflow-level, project-level, and auto-detection defaults.
 *
 * Resolution priority (highest wins):
 *   1. Workflow YAML `vcs.backend` (if set and not 'auto')
 *   2. Project `.foreman/config.yaml` `vcs.backend` (if set and not 'auto')
 *   3. 'auto' — auto-detect from repository contents (.jj/ → jujutsu, .git/ → git)
 *
 * @module src/lib/project-config
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { load as yamlLoad } from "js-yaml";
import type { VcsConfig } from "./vcs/index.js";

// ── Types ─────────────────────────────────────────────────────────────────────

/**
 * Dashboard configuration (REQ-010, REQ-019).
 * Controls the dashboard refresh interval when using `foreman dashboard`.
 */
export interface DashboardConfig {
  /**
   * Polling interval for the live dashboard in milliseconds.
   * Default: 5000 (5 seconds). Minimum enforced: 1000 (1 second).
   * Can be overridden by the `--refresh` CLI flag.
   */
  refreshInterval?: number;
}

/**
 * Shape of `.foreman/config.yaml` (or `.foreman/config.json`).
 * Only the `vcs` section is currently defined; additional top-level keys may
 * be added in future phases without breaking this interface.
 */
export interface ProjectConfig {
  /** VCS backend configuration for this project. */
  vcs?: {
    /**
     * Which VCS backend to use.
     * - 'git'      — always use git
     * - 'jujutsu'  — always use jujutsu
     * - 'auto'     — detect from repository (default)
     */
    backend: "git" | "jujutsu" | "auto";
    /** Git-specific options (passed through to VcsConfig). */
    git?: {
      /** If true, use git-town for branch management. Default: true. */
      useTown?: boolean;
    };
    /** Jujutsu-specific options (passed through to VcsConfig). */
    jujutsu?: {
      /** Minimum jj version required; validated by 'foreman doctor'. */
      minVersion?: string;
    };
  };
  /** Dashboard configuration (REQ-010, REQ-019). */
  dashboard?: DashboardConfig;
}

/** Error thrown when the project config file is present but malformed. */
export class ProjectConfigError extends Error {
  constructor(
    public readonly configPath: string,
    message: string,
  ) {
    super(`ProjectConfig: ${configPath}: ${message}`);
    this.name = "ProjectConfigError";
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

const VALID_BACKENDS = new Set<string>(["git", "jujutsu", "auto"]);

/**
 * Validate raw parsed config data and return a typed `ProjectConfig`.
 *
 * @throws ProjectConfigError on structural/type violations.
 */
function validateProjectConfig(raw: unknown, filePath: string): ProjectConfig {
  // Empty YAML files parse to null — treat as an empty config object (no error)
  if (raw === null || raw === undefined) {
    return {};
  }

  if (!isRecord(raw)) {
    throw new ProjectConfigError(filePath, "must be a YAML/JSON object at the top level");
  }

  const config: ProjectConfig = {};

  if ("vcs" in raw) {
    const vcsRaw = raw["vcs"];
    if (!isRecord(vcsRaw)) {
      throw new ProjectConfigError(filePath, "'vcs' must be an object");
    }

    const backend = vcsRaw["backend"];

    // Validate backend value if provided
    if (backend !== undefined) {
      if (typeof backend !== "string" || !VALID_BACKENDS.has(backend)) {
        throw new ProjectConfigError(
          filePath,
          `vcs.backend must be 'git', 'jujutsu', or 'auto' (got: ${String(backend)})`,
        );
      }
    }

    const vcsConfig: NonNullable<ProjectConfig["vcs"]> = {
      // Default to 'auto' when backend key is absent
      backend: (backend as "git" | "jujutsu" | "auto") ?? "auto",
    };

    // Optional git sub-config
    if ("git" in vcsRaw) {
      const gitRaw = vcsRaw["git"];
      if (!isRecord(gitRaw)) {
        throw new ProjectConfigError(filePath, "'vcs.git' must be an object");
      }
      vcsConfig.git = {};
      if ("useTown" in gitRaw) {
        if (typeof gitRaw["useTown"] !== "boolean") {
          throw new ProjectConfigError(filePath, "'vcs.git.useTown' must be a boolean");
        }
        vcsConfig.git.useTown = gitRaw["useTown"] as boolean;
      }
    }

    // Optional jujutsu sub-config
    if ("jujutsu" in vcsRaw) {
      const jjRaw = vcsRaw["jujutsu"];
      if (!isRecord(jjRaw)) {
        throw new ProjectConfigError(filePath, "'vcs.jujutsu' must be an object");
      }
      vcsConfig.jujutsu = {};
      if ("minVersion" in jjRaw) {
        if (typeof jjRaw["minVersion"] !== "string") {
          throw new ProjectConfigError(filePath, "'vcs.jujutsu.minVersion' must be a string");
        }
        vcsConfig.jujutsu.minVersion = jjRaw["minVersion"] as string;
      }
    }

    config.vcs = vcsConfig;
  }

  // Optional dashboard sub-config
  if ("dashboard" in raw) {
    const dashRaw = raw["dashboard"];
    if (!isRecord(dashRaw)) {
      throw new ProjectConfigError(filePath, "'dashboard' must be an object");
    }
    const dashConfig: DashboardConfig = {};
    if ("refreshInterval" in dashRaw) {
      const ri = dashRaw["refreshInterval"];
      if (typeof ri !== "number" || !Number.isFinite(ri) || ri < 0) {
        throw new ProjectConfigError(
          filePath,
          "'dashboard.refreshInterval' must be a non-negative number (milliseconds)",
        );
      }
      dashConfig.refreshInterval = ri as number;
    }
    config.dashboard = dashConfig;
  }

  return config;
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Load project-level configuration from `.foreman/config.yaml`.
 *
 * Falls back to `.foreman/config.json` if the YAML file is absent.
 * Returns `null` if neither file exists (config is optional).
 *
 * @param projectPath - Absolute path to the project root.
 * @returns Parsed `ProjectConfig`, or `null` if no config file found.
 * @throws ProjectConfigError if the config file exists but is malformed.
 */
export function loadProjectConfig(projectPath: string): ProjectConfig | null {
  const foremanDir = join(projectPath, ".foreman");

  // Prefer YAML
  const yamlPath = join(foremanDir, "config.yaml");
  if (existsSync(yamlPath)) {
    try {
      const raw = yamlLoad(readFileSync(yamlPath, "utf-8"));
      return validateProjectConfig(raw, yamlPath);
    } catch (err) {
      if (err instanceof ProjectConfigError) throw err;
      const msg = err instanceof Error ? err.message : String(err);
      throw new ProjectConfigError(yamlPath, `failed to parse YAML: ${msg}`);
    }
  }

  // Fallback: JSON
  const jsonPath = join(foremanDir, "config.json");
  if (existsSync(jsonPath)) {
    try {
      const raw: unknown = JSON.parse(readFileSync(jsonPath, "utf-8"));
      return validateProjectConfig(raw, jsonPath);
    } catch (err) {
      if (err instanceof ProjectConfigError) throw err;
      const msg = err instanceof Error ? err.message : String(err);
      throw new ProjectConfigError(jsonPath, `failed to parse JSON: ${msg}`);
    }
  }

  // No project config file — not an error
  return null;
}

/**
 * Load and return the dashboard configuration for a project.
 *
 * Reads `dashboard.refreshInterval` from `.foreman/config.yaml` and returns
 * a merged `DashboardConfig` with default values filled in.
 *
 * @param projectPath - Absolute path to the project root.
 * @returns Resolved `DashboardConfig` with defaults applied.
 */
export function loadDashboardConfig(projectPath: string): Required<DashboardConfig> {
  const defaults: Required<DashboardConfig> = { refreshInterval: 5000 };
  try {
    const config = loadProjectConfig(projectPath);
    if (!config?.dashboard) return defaults;
    const ri = config.dashboard.refreshInterval;
    return {
      refreshInterval: typeof ri === "number" && ri >= 1000 ? ri : defaults.refreshInterval,
    };
  } catch {
    return defaults;
  }
}

/**
 * Resolve the final `VcsConfig` by merging workflow-level and project-level settings.
 *
 * Resolution order (highest priority wins):
 *   1. `workflowVcs.backend` (if present and not 'auto')
 *   2. `projectVcs.backend` (if present and not 'auto')
 *   3. `'auto'` — falls through to `VcsBackendFactory.resolveBackend()` at dispatch time
 *
 * Sub-options (git.useTown, jujutsu.minVersion) are merged with workflow
 * settings taking precedence over project settings.
 *
 * @param workflowVcs - VCS config from the workflow YAML `vcs:` block (optional).
 * @param projectVcs  - VCS config from `.foreman/config.yaml` `vcs:` block (optional).
 * @returns Resolved `VcsConfig` ready for `VcsBackendFactory.create()`.
 */
export function resolveVcsConfig(
  workflowVcs?: ProjectConfig["vcs"],
  projectVcs?: ProjectConfig["vcs"],
): VcsConfig {
  // Determine backend with priority: workflow > project > auto
  let backend: "git" | "jujutsu" | "auto" = "auto";

  if (workflowVcs?.backend && workflowVcs.backend !== "auto") {
    backend = workflowVcs.backend;
  } else if (projectVcs?.backend && projectVcs.backend !== "auto") {
    backend = projectVcs.backend;
  }
  // else: backend stays 'auto'

  const resolved: VcsConfig = { backend };

  // Merge git sub-options (workflow takes precedence over project)
  const mergedGit = {
    ...(projectVcs?.git ?? {}),
    ...(workflowVcs?.git ?? {}),
  };
  if (Object.keys(mergedGit).length > 0) {
    resolved.git = mergedGit;
  }

  // Merge jujutsu sub-options (workflow takes precedence over project)
  const mergedJj = {
    ...(projectVcs?.jujutsu ?? {}),
    ...(workflowVcs?.jujutsu ?? {}),
  };
  if (Object.keys(mergedJj).length > 0) {
    resolved.jujutsu = mergedJj;
  }

  return resolved;
}
