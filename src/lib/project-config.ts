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
import { normalizeBranchLabel } from "./branch-label.js";

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
 * Directory verification guardrail configuration.
 * Prevents agents from operating in the wrong worktree directory.
 */
export interface DirectoryGuardrailConfig {
  /**
   * Guardrail enforcement mode.
   * - `auto-correct` — Prepend `cd` to bash commands; fix edit/write file paths. Log `guardrail-corrected` event.
   * - `veto`         — Abort the tool call and report via `guardrail-veto` event.
   * - `disabled`     — No checks; pass through immediately.
   * Default: `auto-correct`.
   */
  mode?: "auto-correct" | "veto" | "disabled";
  /**
   * Optional list of allowed path prefixes.
   * When set, the agent's cwd must start with one of these prefixes.
   */
  allowedPaths?: string[];
}

/**
 * Heartbeat configuration for observability events.
 */
export interface HeartbeatConfig {
  /** Enable heartbeat events. Default: true. */
  enabled?: boolean;
  /** Interval between heartbeats in seconds. Default: 60. Set to 0 to disable. */
  intervalSeconds?: number;
}

/**
 * Activity log configuration for self-documenting commits.
 */
export interface ActivityLogConfig {
  /** Enable activity log generation. Default: true. */
  enabled?: boolean;
  /** Include git diff stat output in ACTIVITY_LOG.json. Default: true. */
  includeGitDiffStat?: boolean;
}

/**
 * Observability configuration for pipeline run visibility.
 */
export interface ObservabilityConfig {
  /** Heartbeat configuration for periodic status events. */
  heartbeat?: HeartbeatConfig;
  /** Activity log configuration for self-documenting commits. */
  activityLog?: ActivityLogConfig;
}

/**
 * Stale worktree handling configuration.
 */
export interface StaleWorktreeConfig {
  /**
   * Auto-rebase stale worktrees on dispatch (before spawning agent).
   * Default: true.
   */
  autoRebase?: boolean;
  /**
   * Fail-fast if rebase would conflict.
   * Default: true.
   */
  failOnConflict?: boolean;
}

/**
 * Guardrails configuration for runtime-enforced constraints.
 */
export interface GuardrailsConfig {
  /** Directory verification guardrail settings. */
  directory?: DirectoryGuardrailConfig;
}

/**
 * Shape of `.foreman/config.yaml` (or `.foreman/config.json`).
 * Only the `vcs` section is currently defined; additional top-level keys may
 * be added in future phases without breaking this interface.
 */
export interface ProjectConfig {
  /**
   * Foreman's authoritative integration branch for this project.
   * When set, commands should prefer this value over VCS auto-detection.
   */
  defaultBranch?: string;
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
  /** Guardrails configuration for runtime-enforced constraints. */
  guardrails?: GuardrailsConfig;
  /** Observability configuration for pipeline run visibility. */
  observability?: ObservabilityConfig;
  /** Stale worktree handling configuration. */
  staleWorktree?: StaleWorktreeConfig;
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

  if ("defaultBranch" in raw) {
    if (typeof raw["defaultBranch"] !== "string") {
      throw new ProjectConfigError(filePath, "'defaultBranch' must be a string");
    }
    const normalizedDefaultBranch = normalizeBranchLabel(raw["defaultBranch"] as string);
    if (!normalizedDefaultBranch) {
      throw new ProjectConfigError(filePath, "'defaultBranch' must be a non-empty branch name");
    }
    config.defaultBranch = normalizedDefaultBranch;
  }

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

  // Optional guardrails sub-config (PRD-2026-009)
  if ("guardrails" in raw) {
    const guardrailsRaw = raw["guardrails"];
    if (!isRecord(guardrailsRaw)) {
      throw new ProjectConfigError(filePath, "'guardrails' must be an object");
    }
    const guardrailsConfig: GuardrailsConfig = {};

    if ("directory" in guardrailsRaw) {
      const dirRaw = guardrailsRaw["directory"];
      if (!isRecord(dirRaw)) {
        throw new ProjectConfigError(filePath, "'guardrails.directory' must be an object");
      }

      const dirConfig: DirectoryGuardrailConfig = {};
      if ("mode" in dirRaw) {
        const mode = dirRaw["mode"];
        if (mode !== undefined && mode !== "auto-correct" && mode !== "veto" && mode !== "disabled") {
          throw new ProjectConfigError(
            filePath,
            "'guardrails.directory.mode' must be 'auto-correct', 'veto', or 'disabled'",
          );
        }
        dirConfig.mode = mode as "auto-correct" | "veto" | "disabled" | undefined;
      }
      if ("allowedPaths" in dirRaw) {
        const ap = dirRaw["allowedPaths"];
        if (!Array.isArray(ap)) {
          throw new ProjectConfigError(filePath, "'guardrails.directory.allowedPaths' must be an array");
        }
        dirConfig.allowedPaths = ap as string[];
      }
      guardrailsConfig.directory = dirConfig;
    }

    config.guardrails = guardrailsConfig;
  }

  // Optional observability sub-config (PRD-2026-009)
  if ("observability" in raw) {
    const obsRaw = raw["observability"];
    if (!isRecord(obsRaw)) {
      throw new ProjectConfigError(filePath, "'observability' must be an object");
    }
    const obsConfig: ObservabilityConfig = {};

    if ("heartbeat" in obsRaw) {
      const hbRaw = obsRaw["heartbeat"];
      if (!isRecord(hbRaw)) {
        throw new ProjectConfigError(filePath, "'observability.heartbeat' must be an object");
      }
      const hbConfig: HeartbeatConfig = {};
      if ("enabled" in hbRaw && typeof hbRaw["enabled"] !== "boolean") {
        throw new ProjectConfigError(filePath, "'observability.heartbeat.enabled' must be a boolean");
      }
      hbConfig.enabled = (hbRaw["enabled"] as boolean | undefined) ?? true;
      if ("intervalSeconds" in hbRaw) {
        const interval = hbRaw["intervalSeconds"];
        if (typeof interval !== "number" || !Number.isFinite(interval) || interval < 0) {
          throw new ProjectConfigError(
            filePath,
            "'observability.heartbeat.intervalSeconds' must be a non-negative number (seconds)",
          );
        }
        hbConfig.intervalSeconds = interval as number;
      }
      obsConfig.heartbeat = hbConfig;
    }

    if ("activityLog" in obsRaw) {
      const alRaw = obsRaw["activityLog"];
      if (!isRecord(alRaw)) {
        throw new ProjectConfigError(filePath, "'observability.activityLog' must be an object");
      }
      const alConfig: ActivityLogConfig = {};
      if ("enabled" in alRaw && typeof alRaw["enabled"] !== "boolean") {
        throw new ProjectConfigError(filePath, "'observability.activityLog.enabled' must be a boolean");
      }
      alConfig.enabled = (alRaw["enabled"] as boolean | undefined) ?? true;
      if ("includeGitDiffStat" in alRaw && typeof alRaw["includeGitDiffStat"] !== "boolean") {
        throw new ProjectConfigError(filePath, "'observability.activityLog.includeGitDiffStat' must be a boolean");
      }
      alConfig.includeGitDiffStat = (alRaw["includeGitDiffStat"] as boolean | undefined) ?? true;
      obsConfig.activityLog = alConfig;
    }

    config.observability = obsConfig;
  }

  // Optional staleWorktree sub-config (PRD-2026-009)
  if ("staleWorktree" in raw) {
    const staleRaw = raw["staleWorktree"];
    if (!isRecord(staleRaw)) {
      throw new ProjectConfigError(filePath, "'staleWorktree' must be an object");
    }
    const staleConfig: StaleWorktreeConfig = {};
    if ("autoRebase" in staleRaw && typeof staleRaw["autoRebase"] !== "boolean") {
      throw new ProjectConfigError(filePath, "'staleWorktree.autoRebase' must be a boolean");
    }
    staleConfig.autoRebase = (staleRaw["autoRebase"] as boolean | undefined) ?? true;
    if ("failOnConflict" in staleRaw && typeof staleRaw["failOnConflict"] !== "boolean") {
      throw new ProjectConfigError(filePath, "'staleWorktree.failOnConflict' must be a boolean");
    }
    staleConfig.failOnConflict = (staleRaw["failOnConflict"] as boolean | undefined) ?? true;
    config.staleWorktree = staleConfig;
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

/**
 * Resolve the integration/default branch for a project.
 *
 * Resolution order:
 *   1. `projectConfig.defaultBranch`
 *   2. auto-detected VCS default branch
 *   3. hard fallback `"main"` when detection fails
 */
export async function resolveDefaultBranch(
  projectPath: string,
  detectDefaultBranch?: (projectPath: string) => Promise<string>,
  projectConfig?: ProjectConfig | null,
): Promise<string> {
  const config = projectConfig ?? loadProjectConfig(projectPath);
  const configured = normalizeBranchLabel(config?.defaultBranch);
  if (configured) return configured;

  if (detectDefaultBranch) {
    try {
      const detected = normalizeBranchLabel(await detectDefaultBranch(projectPath));
      if (detected) return detected;
    } catch {
      // fall through to hard default
    }
  }

  return "main";
}
