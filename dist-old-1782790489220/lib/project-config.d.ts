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
import type { VcsConfig } from "./vcs/index.js";
import type { WorkspaceHooks } from "../orchestrator/types.js";
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
export type IssueTrackerConfig = {
    backend: "jira";
    jira: JiraConfig;
} | {
    backend: "github";
    github: GitHubConfig;
};
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
export declare class ProjectConfigError extends Error {
    readonly configPath: string;
    constructor(configPath: string, message: string);
}
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
export declare function loadProjectConfig(_projectPath: string): ProjectConfig | null;
/**
 * Load and return the dashboard configuration for a project.
 *
 * Reads `dashboard.refreshInterval` from `~/.foreman/config.yaml` and returns
 * a merged `DashboardConfig` with default values filled in.
 *
 * @param projectPath - Absolute path to the project root.
 * @returns Resolved `DashboardConfig` with defaults applied.
 */
export declare function loadDashboardConfig(projectPath: string): Required<DashboardConfig>;
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
export declare function resolveVcsConfig(workflowVcs?: ProjectConfig["vcs"], projectVcs?: ProjectConfig["vcs"]): VcsConfig;
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
export declare function resolveSandboxConfig(workflowSandbox?: SandboxConfig, projectSandbox?: SandboxConfig): SandboxConfig | undefined;
/**
 * Resolve the integration/default branch for a project.
 *
 * Resolution order:
 *   1. `projectConfig.defaultBranch`
 *   2. auto-detected VCS default branch
 *   3. hard fallback `"main"` when detection fails
 */
export declare function resolveDefaultBranch(projectPath: string, detectDefaultBranch?: (projectPath: string) => Promise<string>, projectConfig?: ProjectConfig | null): Promise<string>;
//# sourceMappingURL=project-config.d.ts.map