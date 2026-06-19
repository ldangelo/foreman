/**
 * Project-level VCS configuration loader.
 *
 * Loads Foreman's global VCS settings from `~/.foreman/config.yaml` (or the legacy
 * `~/.foreman/config.json` fallback) and resolves the final VCS configuration by
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
import { load as yamlLoad } from "js-yaml";
import type { VcsConfig } from "./vcs/index.js";
import { normalizeBranchLabel } from "./branch-label.js";
import { hasWorkflowConfig } from "./workflow-loader.js";
import { getForemanHomePath } from "./foreman-paths.js";
import type { WorkspaceHooks } from "../orchestrator/types.js";

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
 * Concurrency limits configuration.
 * Supports global limit and per-issue-state limits.
 *
 * @example
 * ```yaml
 * concurrency:
 *   global: 10
 *   byState:
 *     in_progress: 5
 *     review: 2
 *     qa: 3
 * ```
 */
export interface ConcurrencyConfig {
  /**
   * Global maximum number of concurrent agent runs across all states.
   * Default: unlimited (subject to `maxAgents` CLI flag).
   */
  global?: number;
  /**
   * Per-issue-state concurrency limits.
   * Keys are issue status values (e.g., "in_progress", "review", "qa").
   * Values are the maximum number of concurrent runs allowed for that state.
   * States not listed here are unlimited.
   */
  byState?: Record<string, number>;
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
 * Per-Jira-project monitoring configuration.
 * Defines which Jira project to monitor and how to map issues to workflows.
 */
export interface JiraProjectConfig {
  /** Jira project key (e.g., "PROJ"). Normalized to uppercase. */
  key: string;
  /** Status values that trigger workflow execution. */
  startStatus: string[];
  /** Status values that complete the workflow (optional tracking). */
  endStatus?: string[];
  /** Mapping of Jira issue types to Foreman workflow names. */
  issueTypeWorkflowMap: Record<string, string>;
  /** Debounce window in seconds. Default: 60. Set to 0 to disable. */
  debounceWindowSeconds?: number;
}
/**
 * Jira Cloud instance configuration.
 */
export interface JiraConfig {
  /**
   * Jira API version: "cloud" (REST API v3) or "server" (REST API v2).
   * Default: "cloud" (Atlassian Jira Cloud).
   *
   * Server/Data Center uses REST API v2 with different endpoint paths.
   */
  apiVersion?: "cloud" | "server";
  /** Jira Cloud API URL (e.g., https://your-domain.atlassian.net). */
  apiUrl: string;
  /** Jira account email for authentication (Cloud only). */
  email: string;
  /** Encrypted Jira API token (AES-256-GCM). Decrypt with FOREMAN_MASTER_KEY at runtime. */
  apiToken: string;
  /** Poll interval in seconds. Default: 60. Minimum: 30. */
  pollIntervalSeconds?: number;
  /** Enable webhook-based real-time triggers. Default: false. */
  webhookEnabled?: boolean;
  /** Environment variable name containing the webhook secret. */
  webhookSecretEnvVar?: string;
  /** Jira projects to monitor. */
  projects: JiraProjectConfig[];
}
/**
 * GitHub instance configuration for issue tracking.
 */
export interface GitHubConfig {
  /** GitHub API URL (e.g., https://api.github.com for GitHub Cloud, or https://github.myenterprise.com/api/v3 for GitHub Enterprise). */
  apiUrl: string;
  /** Encrypted GitHub personal access token (AES-256-GCM). Decrypt with FOREMAN_MASTER_KEY at runtime. */
  token: string;
  /** Repositories to monitor (owner/repo format). */
  repositories: GitHubRepositoryConfig[];
  /** Poll interval in seconds. Default: 60. Minimum: 30. */
  pollIntervalSeconds?: number;
  /** Enable webhook-based real-time triggers. Default: false. */
  webhookEnabled?: boolean;
  /** Environment variable name containing the webhook secret. */
  webhookSecretEnvVar?: string;
}

/**
 * Per-repository GitHub issue monitoring configuration.
 */
export interface GitHubRepositoryConfig {
  /** Repository owner (user or organization). */
  owner: string;
  /** Repository name. */
  repo: string;
  /** Labels that trigger workflow execution. Default: ["foreman"] */
  triggerLabels?: string[];
  /** Issue types to monitor (e.g., "issue", "pull_request"). Default: ["issue"]. */
  issueTypes?: string[];
}

/**
 * Issue tracker configuration (extensible for future backends).
 * Currently supports: jira, github.
 */
export type IssueTrackerConfig =
  | { backend: "jira"; jira: JiraConfig }
  | { backend: "github"; github: GitHubConfig };

/**
 * Container sandbox configuration for untrusted workflows.
 *
 * When configured, agent execution runs inside an isolated Docker/Podman container
 * instead of directly on the host. Useful for security-sensitive or untrusted code.
 *
 * @example
 * ```yaml
 * sandbox:
 *   backend: docker          # 'docker' | 'podman' | 'auto' (default)
 *   image: ubuntu:22.04      # Container image (default: ubuntu:22.04)
 *   limits:
 *     cpu: "1"               # CPU limit
 *     memory: "2g"           # Memory limit
 *   network: false           # Disable networking (default: false)
 *   cleanup: remove           # 'remove' | 'keep' (default: 'remove')
 * ```
 */
export interface SandboxConfig {
  /**
   * Which sandbox backend to use.
   * - 'docker'  — always use Docker
   * - 'podman'  — always use Podman
   * - 'auto'    — detect from environment (default: 'auto')
   */
  backend?: "docker" | "podman" | "auto";
  /**
   * Container image to use for sandboxes.
   * Default: 'ubuntu:22.04'.
   */
  image?: string;
  /**
   * Resource limits for sandbox containers.
   */
  limits?: {
    /** Maximum CPU units (e.g., "1" for 1 CPU, "0.5" for half). */
    cpu?: string;
    /** Memory limit (e.g., "2g" for 2GB, "512m" for 512MB). */
    memory?: string;
    /** Specific CPUs to allow (e.g., "0-1" for cores 0-1). */
    cpuset?: string;
    /** Maximum swap memory (e.g., "1g"). */
    memorySwap?: string;
  };
  /**
   * Enable networking in sandbox. Default: false (network disabled).
   */
  network?: boolean;
  /**
   * Cleanup policy when sandbox container exits.
   * - 'remove'  — remove container after destroy (default)
   * - 'keep'    — leave container stopped for debugging
   */
  cleanup?: "remove" | "keep";
}

/**
 * Workspace lifecycle hooks for pre/post-run customization.
 * Loaded from project config and/or workflow YAML.
 * @deprecated Use WorkspaceHooks from orchestrator/types instead
 */
export type ProjectHooksConfig = WorkspaceHooks;

/**
 * Shape of `~/.foreman/config.yaml` (or `~/.foreman/config.json`).
 * Only the `vcs` section is currently defined; additional top-level keys may
 * be added in future phases without breaking this interface.
 */
export interface ProjectConfig {
  /**
   * Label that triggers automatic task dispatch from GitHub issues or Jira issues.
   * 
   * When an imported issue has this label:
   * - GitHub: Task is created with status "ready" (auto-dispatched)
   * - Jira: Workflow is triggered immediately
   * 
   * If not set or empty, issues are only imported but not auto-dispatched.
   * The default label is "FOREMAN_AUTO_FIX".
   */
  foremanTag?: string;
  /** Foreman's authoritative integration branch for this project.
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
  /** Concurrency limits (global and per-state). */
  concurrency?: ConcurrencyConfig;
  /** Issue tracker configuration (e.g., Jira) for monitoring status transitions. */
  issueTracker?: IssueTrackerConfig;
  /** Container sandbox configuration for untrusted workflows (Backlog-011). */
  sandbox?: SandboxConfig;
  /** Workspace lifecycle hooks for pre/post-run customization. */
  hooks?: ProjectHooksConfig;
  /**
   * Explicit mapping from task type to workflow name.
   *
   * Resolution order (highest wins):
   *   1. workflow:<name> label override (handled by resolveWorkflowName)
   *   2. taskTypeWorkflowMap[task.type] — this config
   *   3. taskTypeWorkflowMap["default"] — fallback for unknown types
   *   4. File-existence fallback: ~/.foreman/workflows/<type>.yaml or bundled defaults
   *   5. Hard fallback to "default"
   *
   * @example
   * ```yaml
   * taskTypeWorkflowMap:
   *   bug: bug
   *   task: task
   *   feature: feature
   *   docs: task
   *   spike: feature
   *   default: default
   * ```
   */
  taskTypeWorkflowMap?: Record<string, string>;
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

  // Optional concurrency sub-config (Backlog-006)
  if ("concurrency" in raw) {
    const concRaw = raw["concurrency"];
    if (!isRecord(concRaw)) {
      throw new ProjectConfigError(filePath, "'concurrency' must be an object");
    }
    const concConfig: ConcurrencyConfig = {};
    if ("global" in concRaw) {
      const global = concRaw["global"];
      if (typeof global !== "number" || !Number.isFinite(global) || global <= 0) {
        throw new ProjectConfigError(
          filePath,
          "'concurrency.global' must be a positive number",
        );
      }
      concConfig.global = global as number;
    }
    if ("byState" in concRaw) {
      const byStateRaw = concRaw["byState"];
      if (!isRecord(byStateRaw)) {
        throw new ProjectConfigError(filePath, "'concurrency.byState' must be an object");
      }
      const byState: Record<string, number> = {};
      for (const [state, limit] of Object.entries(byStateRaw)) {
        if (typeof limit !== "number" || !Number.isFinite(limit) || limit <= 0) {
          throw new ProjectConfigError(
            filePath,
            `'concurrency.byState.${state}' must be a positive number`,
          );
        }
        byState[state] = limit as number;
      }
      concConfig.byState = byState;
    }
    config.concurrency = concConfig;
  }

  // Optional issueTracker sub-config (PRD-2026-013)
  if ("issueTracker" in raw) {
    const itRaw = raw["issueTracker"];
    if (!isRecord(itRaw)) {
      throw new ProjectConfigError(filePath, "'issueTracker' must be an object");
    }
    const backend = itRaw["backend"];
    if (backend === "jira") {
      const jiraRaw = itRaw["jira"];
      if (!isRecord(jiraRaw)) {
        throw new ProjectConfigError(filePath, "'issueTracker.jira' must be an object");
      }
      const jiraConfig: JiraConfig = {
        apiUrl: "",
        email: "",
        apiToken: "",
        projects: [],
      };
      if ("apiUrl" in jiraRaw) {
        if (typeof jiraRaw["apiUrl"] !== "string") {
          throw new ProjectConfigError(filePath, "'issueTracker.jira.apiUrl' must be a string");
        }
        jiraConfig.apiUrl = jiraRaw["apiUrl"] as string;
      }
      if ("email" in jiraRaw) {
        if (typeof jiraRaw["email"] !== "string") {
          throw new ProjectConfigError(filePath, "'issueTracker.jira.email' must be a string");
        }
        jiraConfig.email = jiraRaw["email"] as string;
      }
      if ("apiToken" in jiraRaw) {
        if (typeof jiraRaw["apiToken"] !== "string") {
          throw new ProjectConfigError(filePath, "'issueTracker.jira.apiToken' must be a string");
        }
        jiraConfig.apiToken = jiraRaw["apiToken"] as string;
      }
      if ("pollIntervalSeconds" in jiraRaw) {
        const interval = jiraRaw["pollIntervalSeconds"];
        if (typeof interval !== "number" || !Number.isFinite(interval) || interval < 30) {
          throw new ProjectConfigError(
            filePath,
            "'issueTracker.jira.pollIntervalSeconds' must be a number >= 30",
          );
        }
        jiraConfig.pollIntervalSeconds = interval as number;
      }
      if ("webhookEnabled" in jiraRaw && typeof jiraRaw["webhookEnabled"] !== "boolean") {
        throw new ProjectConfigError(filePath, "'issueTracker.jira.webhookEnabled' must be a boolean");
      }
      jiraConfig.webhookEnabled = (jiraRaw["webhookEnabled"] as boolean | undefined) ?? false;
      if ("webhookSecretEnvVar" in jiraRaw) {
        if (typeof jiraRaw["webhookSecretEnvVar"] !== "string") {
          throw new ProjectConfigError(filePath, "'issueTracker.jira.webhookSecretEnvVar' must be a string");
        }
        jiraConfig.webhookSecretEnvVar = jiraRaw["webhookSecretEnvVar"] as string;
      }
      // Validate projects
      if (!("projects" in jiraRaw)) {
        throw new ProjectConfigError(filePath, "'issueTracker.jira.projects' is required");
      }
      const projectsRaw = jiraRaw["projects"];
      if (!Array.isArray(projectsRaw)) {
        throw new ProjectConfigError(filePath, "'issueTracker.jira.projects' must be an array");
      }
      if (projectsRaw.length === 0) {
        throw new ProjectConfigError(filePath, "'issueTracker.jira.projects' must have at least one project");
      }
      jiraConfig.projects = [];
      for (let i = 0; i < projectsRaw.length; i++) {
        const projRaw = projectsRaw[i];
        if (!isRecord(projRaw)) {
          throw new ProjectConfigError(filePath, `'issueTracker.jira.projects[${i}]' must be an object`);
        }
        const proj: JiraProjectConfig = {
          key: "",
          startStatus: [],
          issueTypeWorkflowMap: {},
        };
        if ("key" in projRaw) {
          if (typeof projRaw["key"] !== "string") {
            throw new ProjectConfigError(filePath, `'issueTracker.jira.projects[${i}].key' must be a string`);
          }
          proj.key = (projRaw["key"] as string).toUpperCase();
        }
        if ("startStatus" in projRaw) {
          if (!Array.isArray(projRaw["startStatus"])) {
            throw new ProjectConfigError(filePath, `'issueTracker.jira.projects[${i}].startStatus' must be an array`);
          }
          proj.startStatus = projRaw["startStatus"] as string[];
        }
        if ("endStatus" in projRaw && Array.isArray(projRaw["endStatus"])) {
          proj.endStatus = projRaw["endStatus"] as string[];
        }
        if ("issueTypeWorkflowMap" in projRaw) {
          if (!isRecord(projRaw["issueTypeWorkflowMap"])) {
            throw new ProjectConfigError(
              filePath,
              `'issueTracker.jira.projects[${i}].issueTypeWorkflowMap' must be an object`,
            );
          }
          proj.issueTypeWorkflowMap = projRaw["issueTypeWorkflowMap"] as Record<string, string>;
        }
        if ("debounceWindowSeconds" in projRaw) {
          const window = projRaw["debounceWindowSeconds"];
          if (typeof window !== "number" || !Number.isFinite(window) || window < 0) {
            throw new ProjectConfigError(
              filePath,
              `'issueTracker.jira.projects[${i}].debounceWindowSeconds' must be a non-negative number`,
            );
          }
          proj.debounceWindowSeconds = window as number;
        }
        jiraConfig.projects.push(proj);
      }
      config.issueTracker = {
        backend: "jira",
        jira: jiraConfig,
      };
    } else if (backend === "github") {
      const githubRaw = itRaw["github"];
      if (!isRecord(githubRaw)) {
        throw new ProjectConfigError(filePath, "'issueTracker.github' must be an object");
      }
      const githubConfig: GitHubConfig = {
        apiUrl: "",
        token: "",
        repositories: [],
      };
      if (typeof githubRaw["apiUrl"] !== "string" || githubRaw["apiUrl"].trim().length === 0) {
        throw new ProjectConfigError(filePath, "'issueTracker.github.apiUrl' is required and must be a non-empty string");
      }
      githubConfig.apiUrl = githubRaw["apiUrl"];
      if (typeof githubRaw["token"] !== "string" || githubRaw["token"].trim().length === 0) {
        throw new ProjectConfigError(filePath, "'issueTracker.github.token' is required and must be a non-empty string");
      }
      githubConfig.token = githubRaw["token"];
      if ("pollIntervalSeconds" in githubRaw) {
        const interval = githubRaw["pollIntervalSeconds"];
        if (typeof interval !== "number" || !Number.isFinite(interval) || interval < 30) {
          throw new ProjectConfigError(
            filePath,
            "'issueTracker.github.pollIntervalSeconds' must be a number >= 30",
          );
        }
        githubConfig.pollIntervalSeconds = interval as number;
      }
      if ("webhookEnabled" in githubRaw && typeof githubRaw["webhookEnabled"] !== "boolean") {
        throw new ProjectConfigError(filePath, "'issueTracker.github.webhookEnabled' must be a boolean");
      }
      githubConfig.webhookEnabled = (githubRaw["webhookEnabled"] as boolean | undefined) ?? false;
      if ("webhookSecretEnvVar" in githubRaw) {
        if (typeof githubRaw["webhookSecretEnvVar"] !== "string") {
          throw new ProjectConfigError(filePath, "'issueTracker.github.webhookSecretEnvVar' must be a string");
        }
        githubConfig.webhookSecretEnvVar = githubRaw["webhookSecretEnvVar"] as string;
      }
      // Validate repositories
      if (!("repositories" in githubRaw)) {
        throw new ProjectConfigError(filePath, "'issueTracker.github.repositories' is required");
      }
      const reposRaw = githubRaw["repositories"];
      if (!Array.isArray(reposRaw)) {
        throw new ProjectConfigError(filePath, "'issueTracker.github.repositories' must be an array");
      }
      if (reposRaw.length === 0) {
        throw new ProjectConfigError(filePath, "'issueTracker.github.repositories' must have at least one repository");
      }
      githubConfig.repositories = [];
      for (let i = 0; i < reposRaw.length; i++) {
        const repoRaw = reposRaw[i];
        if (!isRecord(repoRaw)) {
          throw new ProjectConfigError(filePath, `'issueTracker.github.repositories[${i}]' must be an object`);
        }
        const repo: GitHubRepositoryConfig = {
          owner: "",
          repo: "",
        };
        if (typeof repoRaw["owner"] !== "string" || repoRaw["owner"].trim().length === 0) {
          throw new ProjectConfigError(filePath, `'issueTracker.github.repositories[${i}].owner' is required and must be a non-empty string`);
        }
        repo.owner = repoRaw["owner"];
        if (typeof repoRaw["repo"] !== "string" || repoRaw["repo"].trim().length === 0) {
          throw new ProjectConfigError(filePath, `'issueTracker.github.repositories[${i}].repo' is required and must be a non-empty string`);
        }
        repo.repo = repoRaw["repo"];
        if ("triggerLabels" in repoRaw && Array.isArray(repoRaw["triggerLabels"])) {
          repo.triggerLabels = repoRaw["triggerLabels"] as string[];
        }
        if ("issueTypes" in repoRaw && Array.isArray(repoRaw["issueTypes"])) {
          repo.issueTypes = repoRaw["issueTypes"] as string[];
        }
        githubConfig.repositories.push(repo);
      }
      config.issueTracker = {
        backend: "github",
        github: githubConfig,
      };
    } else {
      throw new ProjectConfigError(filePath, "'issueTracker.backend' must be 'jira' or 'github'");
    }
  }

  // Optional hooks sub-config (workspace lifecycle hooks)
  if ("hooks" in raw) {
    const hooksRaw = raw["hooks"];
    if (!isRecord(hooksRaw)) {
      throw new ProjectConfigError(filePath, "'hooks' must be an object");
    }
    const hooksConfig: ProjectHooksConfig = {};
    if ("afterCreate" in hooksRaw && typeof hooksRaw["afterCreate"] !== "string") {
      throw new ProjectConfigError(filePath, "'hooks.afterCreate' must be a string");
    }
    hooksConfig.afterCreate = hooksRaw["afterCreate"] as string | undefined;
    if ("beforeRun" in hooksRaw && typeof hooksRaw["beforeRun"] !== "string") {
      throw new ProjectConfigError(filePath, "'hooks.beforeRun' must be a string");
    }
    hooksConfig.beforeRun = hooksRaw["beforeRun"] as string | undefined;
    if ("afterRun" in hooksRaw && typeof hooksRaw["afterRun"] !== "string") {
      throw new ProjectConfigError(filePath, "'hooks.afterRun' must be a string");
    }
    hooksConfig.afterRun = hooksRaw["afterRun"] as string | undefined;
    if ("beforeRemove" in hooksRaw && typeof hooksRaw["beforeRemove"] !== "string") {
      throw new ProjectConfigError(filePath, "'hooks.beforeRemove' must be a string");
    }
    hooksConfig.beforeRemove = hooksRaw["beforeRemove"] as string | undefined;
    if ("timeoutMs" in hooksRaw) {
      const timeoutMs = hooksRaw["timeoutMs"];
      if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
        throw new ProjectConfigError(
          filePath,
          "'hooks.timeoutMs' must be a positive number (milliseconds)",
        );
      }
      hooksConfig.timeoutMs = timeoutMs as number;
    }
    config.hooks = hooksConfig;
  }

  // Optional taskTypeWorkflowMap — maps task types to workflow names
  if ("taskTypeWorkflowMap" in raw) {
    const mapRaw = raw["taskTypeWorkflowMap"];
    if (!isRecord(mapRaw)) {
      throw new ProjectConfigError(filePath, "'taskTypeWorkflowMap' must be an object");
    }
    // Validate every entry is string -> string and points to a real workflow.
    const validatedMap: Record<string, string> = {};
    for (const [k, v] of Object.entries(mapRaw)) {
      if (typeof k !== "string" || typeof v !== "string") {
        throw new ProjectConfigError(filePath, "'taskTypeWorkflowMap' entries must be string->string");
      }
      if (!hasWorkflowConfig(v)) {
        throw new ProjectConfigError(
          filePath,
          `taskTypeWorkflowMap entry '${k}' references unknown workflow '${v}'`,
        );
      }
      validatedMap[k] = v;
    }
    config.taskTypeWorkflowMap = validatedMap;
  }

  // Optional sandbox sub-config (Backlog-011: Container Sandboxing)
  if ("sandbox" in raw) {
    const sandboxRaw = raw["sandbox"];
    if (!isRecord(sandboxRaw)) {
      throw new ProjectConfigError(filePath, "'sandbox' must be an object");
    }
    const sandboxConfig: SandboxConfig = {};

    if ("backend" in sandboxRaw) {
      const backend = sandboxRaw["backend"];
      if (backend !== undefined && backend !== "docker" && backend !== "podman" && backend !== "auto") {
        throw new ProjectConfigError(
          filePath,
          "'sandbox.backend' must be 'docker', 'podman', or 'auto'",
        );
      }
      sandboxConfig.backend = backend as "docker" | "podman" | "auto" | undefined;
    }

    if ("image" in sandboxRaw) {
      if (typeof sandboxRaw["image"] !== "string" || !sandboxRaw["image"].trim()) {
        throw new ProjectConfigError(filePath, "'sandbox.image' must be a non-empty string");
      }
      sandboxConfig.image = sandboxRaw["image"] as string;
    }

    if ("limits" in sandboxRaw) {
      const limitsRaw = sandboxRaw["limits"];
      if (!isRecord(limitsRaw)) {
        throw new ProjectConfigError(filePath, "'sandbox.limits' must be an object");
      }
      sandboxConfig.limits = {};
      if ("cpu" in limitsRaw && (typeof limitsRaw["cpu"] !== "string" || !limitsRaw["cpu"].trim())) {
        throw new ProjectConfigError(filePath, "'sandbox.limits.cpu' must be a non-empty string");
      }
      sandboxConfig.limits.cpu = limitsRaw["cpu"] as string | undefined;
      if ("memory" in limitsRaw && (typeof limitsRaw["memory"] !== "string" || !limitsRaw["memory"].trim())) {
        throw new ProjectConfigError(filePath, "'sandbox.limits.memory' must be a non-empty string");
      }
      sandboxConfig.limits.memory = limitsRaw["memory"] as string | undefined;
      if ("cpuset" in limitsRaw && (typeof limitsRaw["cpuset"] !== "string" || !limitsRaw["cpuset"].trim())) {
        throw new ProjectConfigError(filePath, "'sandbox.limits.cpuset' must be a non-empty string");
      }
      sandboxConfig.limits.cpuset = limitsRaw["cpuset"] as string | undefined;
      if ("memorySwap" in limitsRaw && (typeof limitsRaw["memorySwap"] !== "string" || !limitsRaw["memorySwap"].trim())) {
        throw new ProjectConfigError(filePath, "'sandbox.limits.memorySwap' must be a non-empty string");
      }
      sandboxConfig.limits.memorySwap = limitsRaw["memorySwap"] as string | undefined;
    }

    if ("network" in sandboxRaw && typeof sandboxRaw["network"] !== "boolean") {
      throw new ProjectConfigError(filePath, "'sandbox.network' must be a boolean");
    }
    sandboxConfig.network = sandboxRaw["network"] as boolean | undefined;

    if ("cleanup" in sandboxRaw) {
      const cleanup = sandboxRaw["cleanup"];
      if (cleanup !== undefined && cleanup !== "remove" && cleanup !== "keep") {
        throw new ProjectConfigError(
          filePath,
          "'sandbox.cleanup' must be 'remove' or 'keep'",
        );
      }
      sandboxConfig.cleanup = cleanup as "remove" | "keep" | undefined;
    }

    config.sandbox = sandboxConfig;
  }

  return config;
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Load Foreman's global configuration from `~/.foreman/config.yaml`.
 *
 * Falls back to `.foreman/config.json` if the YAML file is absent.
 * Returns `null` if neither file exists (config is optional).
 *
 * @param projectPath - Absolute path to the project root.
 * @returns Parsed `ProjectConfig`, or `null` if no config file found.
 * @throws ProjectConfigError if the config file exists but is malformed.
 */
export function loadProjectConfig(_projectPath: string): ProjectConfig | null {
  // Prefer YAML
  const yamlPath = getForemanHomePath("config.yaml");
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
  const jsonPath = getForemanHomePath("config.json");
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
 * Reads `dashboard.refreshInterval` from `~/.foreman/config.yaml` and returns
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
 * @param projectVcs  - VCS config from `~/.foreman/config.yaml` `vcs:` block (optional).
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
 * Resolve the final `SandboxConfig` by merging workflow-level and project-level settings.
 *
 * Resolution order (highest priority wins):
 *   1. `workflowSandbox` (if present)
 *   2. `projectSandbox` (if present)
 *   3. undefined (no sandbox — host execution)
 *
 * Sub-options (image, limits, network, cleanup) are merged with workflow
 * settings taking precedence over project settings.
 *
 * @param workflowSandbox - Sandbox config from the workflow YAML `sandbox:` block (optional).
 * @param projectSandbox  - Sandbox config from `~/.foreman/config.yaml` `sandbox:` block (optional).
 * @returns Resolved `SandboxConfig` ready for `SandboxProviderFactory.create()`.
 */
export function resolveSandboxConfig(
  workflowSandbox?: SandboxConfig,
  projectSandbox?: SandboxConfig,
): SandboxConfig | undefined {
  // If neither has sandbox config, return undefined
  if (!workflowSandbox && !projectSandbox) {
    return undefined;
  }

  // Start with project config as base
  const resolved: SandboxConfig = {
    backend: projectSandbox?.backend,
    image: projectSandbox?.image,
    limits: projectSandbox?.limits ? { ...projectSandbox.limits } : undefined,
    network: projectSandbox?.network,
    cleanup: projectSandbox?.cleanup,
  };

  // Override with workflow config (workflow takes precedence)
  if (workflowSandbox) {
    if (workflowSandbox.backend !== undefined) {
      resolved.backend = workflowSandbox.backend;
    }
    if (workflowSandbox.image !== undefined) {
      resolved.image = workflowSandbox.image;
    }
    if (workflowSandbox.limits !== undefined) {
      resolved.limits = {
        ...(resolved.limits ?? {}),
        ...workflowSandbox.limits,
      };
    }
    if (workflowSandbox.network !== undefined) {
      resolved.network = workflowSandbox.network;
    }
    if (workflowSandbox.cleanup !== undefined) {
      resolved.cleanup = workflowSandbox.cleanup;
    }
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
