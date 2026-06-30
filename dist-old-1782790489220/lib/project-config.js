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
import { normalizeBranchLabel } from "./branch-label.js";
import { hasWorkflowConfig } from "./workflow-loader.js";
import { getForemanHomePath } from "./foreman-paths.js";
/** Error thrown when the project config file is present but malformed. */
export class ProjectConfigError extends Error {
    configPath;
    constructor(configPath, message) {
        super(`ProjectConfig: ${configPath}: ${message}`);
        this.configPath = configPath;
        this.name = "ProjectConfigError";
    }
}
// ── Helpers ───────────────────────────────────────────────────────────────────
function isRecord(v) {
    return typeof v === "object" && v !== null && !Array.isArray(v);
}
const VALID_BACKENDS = new Set(["git", "jujutsu", "auto"]);
/**
 * Validate raw parsed config data and return a typed `ProjectConfig`.
 *
 * @throws ProjectConfigError on structural/type violations.
 */
function validateProjectConfig(raw, filePath) {
    // Empty YAML files parse to null — treat as an empty config object (no error)
    if (raw === null || raw === undefined) {
        return {};
    }
    if (!isRecord(raw)) {
        throw new ProjectConfigError(filePath, "must be a YAML/JSON object at the top level");
    }
    const config = {};
    if ("defaultBranch" in raw) {
        if (typeof raw["defaultBranch"] !== "string") {
            throw new ProjectConfigError(filePath, "'defaultBranch' must be a string");
        }
        const normalizedDefaultBranch = normalizeBranchLabel(raw["defaultBranch"]);
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
                throw new ProjectConfigError(filePath, `vcs.backend must be 'git', 'jujutsu', or 'auto' (got: ${String(backend)})`);
            }
        }
        const vcsConfig = {
            // Default to 'auto' when backend key is absent
            backend: backend ?? "auto",
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
                vcsConfig.git.useTown = gitRaw["useTown"];
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
                vcsConfig.jujutsu.minVersion = jjRaw["minVersion"];
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
        const dashConfig = {};
        if ("refreshInterval" in dashRaw) {
            const ri = dashRaw["refreshInterval"];
            if (typeof ri !== "number" || !Number.isFinite(ri) || ri < 0) {
                throw new ProjectConfigError(filePath, "'dashboard.refreshInterval' must be a non-negative number (milliseconds)");
            }
            dashConfig.refreshInterval = ri;
        }
        config.dashboard = dashConfig;
    }
    // Optional guardrails sub-config (PRD-2026-009)
    if ("guardrails" in raw) {
        const guardrailsRaw = raw["guardrails"];
        if (!isRecord(guardrailsRaw)) {
            throw new ProjectConfigError(filePath, "'guardrails' must be an object");
        }
        const guardrailsConfig = {};
        if ("directory" in guardrailsRaw) {
            const dirRaw = guardrailsRaw["directory"];
            if (!isRecord(dirRaw)) {
                throw new ProjectConfigError(filePath, "'guardrails.directory' must be an object");
            }
            const dirConfig = {};
            if ("mode" in dirRaw) {
                const mode = dirRaw["mode"];
                if (mode !== undefined && mode !== "auto-correct" && mode !== "veto" && mode !== "disabled") {
                    throw new ProjectConfigError(filePath, "'guardrails.directory.mode' must be 'auto-correct', 'veto', or 'disabled'");
                }
                dirConfig.mode = mode;
            }
            if ("allowedPaths" in dirRaw) {
                const ap = dirRaw["allowedPaths"];
                if (!Array.isArray(ap)) {
                    throw new ProjectConfigError(filePath, "'guardrails.directory.allowedPaths' must be an array");
                }
                dirConfig.allowedPaths = ap;
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
        const obsConfig = {};
        if ("heartbeat" in obsRaw) {
            const hbRaw = obsRaw["heartbeat"];
            if (!isRecord(hbRaw)) {
                throw new ProjectConfigError(filePath, "'observability.heartbeat' must be an object");
            }
            const hbConfig = {};
            if ("enabled" in hbRaw && typeof hbRaw["enabled"] !== "boolean") {
                throw new ProjectConfigError(filePath, "'observability.heartbeat.enabled' must be a boolean");
            }
            hbConfig.enabled = hbRaw["enabled"] ?? true;
            if ("intervalSeconds" in hbRaw) {
                const interval = hbRaw["intervalSeconds"];
                if (typeof interval !== "number" || !Number.isFinite(interval) || interval < 0) {
                    throw new ProjectConfigError(filePath, "'observability.heartbeat.intervalSeconds' must be a non-negative number (seconds)");
                }
                hbConfig.intervalSeconds = interval;
            }
            obsConfig.heartbeat = hbConfig;
        }
        if ("activityLog" in obsRaw) {
            const alRaw = obsRaw["activityLog"];
            if (!isRecord(alRaw)) {
                throw new ProjectConfigError(filePath, "'observability.activityLog' must be an object");
            }
            const alConfig = {};
            if ("enabled" in alRaw && typeof alRaw["enabled"] !== "boolean") {
                throw new ProjectConfigError(filePath, "'observability.activityLog.enabled' must be a boolean");
            }
            alConfig.enabled = alRaw["enabled"] ?? true;
            if ("includeGitDiffStat" in alRaw && typeof alRaw["includeGitDiffStat"] !== "boolean") {
                throw new ProjectConfigError(filePath, "'observability.activityLog.includeGitDiffStat' must be a boolean");
            }
            alConfig.includeGitDiffStat = alRaw["includeGitDiffStat"] ?? true;
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
        const staleConfig = {};
        if ("autoRebase" in staleRaw && typeof staleRaw["autoRebase"] !== "boolean") {
            throw new ProjectConfigError(filePath, "'staleWorktree.autoRebase' must be a boolean");
        }
        staleConfig.autoRebase = staleRaw["autoRebase"] ?? true;
        if ("failOnConflict" in staleRaw && typeof staleRaw["failOnConflict"] !== "boolean") {
            throw new ProjectConfigError(filePath, "'staleWorktree.failOnConflict' must be a boolean");
        }
        staleConfig.failOnConflict = staleRaw["failOnConflict"] ?? true;
        config.staleWorktree = staleConfig;
    }
    // Optional concurrency sub-config (Backlog-006)
    if ("concurrency" in raw) {
        const concRaw = raw["concurrency"];
        if (!isRecord(concRaw)) {
            throw new ProjectConfigError(filePath, "'concurrency' must be an object");
        }
        const concConfig = {};
        if ("global" in concRaw) {
            const global = concRaw["global"];
            if (typeof global !== "number" || !Number.isFinite(global) || global <= 0) {
                throw new ProjectConfigError(filePath, "'concurrency.global' must be a positive number");
            }
            concConfig.global = global;
        }
        if ("byState" in concRaw) {
            const byStateRaw = concRaw["byState"];
            if (!isRecord(byStateRaw)) {
                throw new ProjectConfigError(filePath, "'concurrency.byState' must be an object");
            }
            const byState = {};
            for (const [state, limit] of Object.entries(byStateRaw)) {
                if (typeof limit !== "number" || !Number.isFinite(limit) || limit <= 0) {
                    throw new ProjectConfigError(filePath, `'concurrency.byState.${state}' must be a positive number`);
                }
                byState[state] = limit;
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
            const jiraConfig = {
                apiUrl: "",
                email: "",
                apiToken: "",
                projects: [],
            };
            if ("apiUrl" in jiraRaw) {
                if (typeof jiraRaw["apiUrl"] !== "string") {
                    throw new ProjectConfigError(filePath, "'issueTracker.jira.apiUrl' must be a string");
                }
                jiraConfig.apiUrl = jiraRaw["apiUrl"];
            }
            if ("email" in jiraRaw) {
                if (typeof jiraRaw["email"] !== "string") {
                    throw new ProjectConfigError(filePath, "'issueTracker.jira.email' must be a string");
                }
                jiraConfig.email = jiraRaw["email"];
            }
            if ("apiToken" in jiraRaw) {
                if (typeof jiraRaw["apiToken"] !== "string") {
                    throw new ProjectConfigError(filePath, "'issueTracker.jira.apiToken' must be a string");
                }
                jiraConfig.apiToken = jiraRaw["apiToken"];
            }
            if ("pollIntervalSeconds" in jiraRaw) {
                const interval = jiraRaw["pollIntervalSeconds"];
                if (typeof interval !== "number" || !Number.isFinite(interval) || interval < 30) {
                    throw new ProjectConfigError(filePath, "'issueTracker.jira.pollIntervalSeconds' must be a number >= 30");
                }
                jiraConfig.pollIntervalSeconds = interval;
            }
            if ("webhookEnabled" in jiraRaw && typeof jiraRaw["webhookEnabled"] !== "boolean") {
                throw new ProjectConfigError(filePath, "'issueTracker.jira.webhookEnabled' must be a boolean");
            }
            jiraConfig.webhookEnabled = jiraRaw["webhookEnabled"] ?? false;
            if ("webhookSecretEnvVar" in jiraRaw) {
                if (typeof jiraRaw["webhookSecretEnvVar"] !== "string") {
                    throw new ProjectConfigError(filePath, "'issueTracker.jira.webhookSecretEnvVar' must be a string");
                }
                jiraConfig.webhookSecretEnvVar = jiraRaw["webhookSecretEnvVar"];
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
                const proj = {
                    key: "",
                    startStatus: [],
                    issueTypeWorkflowMap: {},
                };
                if ("key" in projRaw) {
                    if (typeof projRaw["key"] !== "string") {
                        throw new ProjectConfigError(filePath, `'issueTracker.jira.projects[${i}].key' must be a string`);
                    }
                    proj.key = projRaw["key"].toUpperCase();
                }
                if ("startStatus" in projRaw) {
                    if (!Array.isArray(projRaw["startStatus"])) {
                        throw new ProjectConfigError(filePath, `'issueTracker.jira.projects[${i}].startStatus' must be an array`);
                    }
                    proj.startStatus = projRaw["startStatus"];
                }
                if ("endStatus" in projRaw && Array.isArray(projRaw["endStatus"])) {
                    proj.endStatus = projRaw["endStatus"];
                }
                if ("issueTypeWorkflowMap" in projRaw) {
                    if (!isRecord(projRaw["issueTypeWorkflowMap"])) {
                        throw new ProjectConfigError(filePath, `'issueTracker.jira.projects[${i}].issueTypeWorkflowMap' must be an object`);
                    }
                    proj.issueTypeWorkflowMap = projRaw["issueTypeWorkflowMap"];
                }
                if ("debounceWindowSeconds" in projRaw) {
                    const window = projRaw["debounceWindowSeconds"];
                    if (typeof window !== "number" || !Number.isFinite(window) || window < 0) {
                        throw new ProjectConfigError(filePath, `'issueTracker.jira.projects[${i}].debounceWindowSeconds' must be a non-negative number`);
                    }
                    proj.debounceWindowSeconds = window;
                }
                jiraConfig.projects.push(proj);
            }
            config.issueTracker = {
                backend: "jira",
                jira: jiraConfig,
            };
        }
        else if (backend === "github") {
            const githubRaw = itRaw["github"];
            if (!isRecord(githubRaw)) {
                throw new ProjectConfigError(filePath, "'issueTracker.github' must be an object");
            }
            const githubConfig = {
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
                    throw new ProjectConfigError(filePath, "'issueTracker.github.pollIntervalSeconds' must be a number >= 30");
                }
                githubConfig.pollIntervalSeconds = interval;
            }
            if ("webhookEnabled" in githubRaw && typeof githubRaw["webhookEnabled"] !== "boolean") {
                throw new ProjectConfigError(filePath, "'issueTracker.github.webhookEnabled' must be a boolean");
            }
            githubConfig.webhookEnabled = githubRaw["webhookEnabled"] ?? false;
            if ("webhookSecretEnvVar" in githubRaw) {
                if (typeof githubRaw["webhookSecretEnvVar"] !== "string") {
                    throw new ProjectConfigError(filePath, "'issueTracker.github.webhookSecretEnvVar' must be a string");
                }
                githubConfig.webhookSecretEnvVar = githubRaw["webhookSecretEnvVar"];
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
                const repo = {
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
                    repo.triggerLabels = repoRaw["triggerLabels"];
                }
                if ("issueTypes" in repoRaw && Array.isArray(repoRaw["issueTypes"])) {
                    repo.issueTypes = repoRaw["issueTypes"];
                }
                githubConfig.repositories.push(repo);
            }
            config.issueTracker = {
                backend: "github",
                github: githubConfig,
            };
        }
        else {
            throw new ProjectConfigError(filePath, "'issueTracker.backend' must be 'jira' or 'github'");
        }
    }
    // Optional hooks sub-config (workspace lifecycle hooks)
    if ("hooks" in raw) {
        const hooksRaw = raw["hooks"];
        if (!isRecord(hooksRaw)) {
            throw new ProjectConfigError(filePath, "'hooks' must be an object");
        }
        const hooksConfig = {};
        if ("afterCreate" in hooksRaw && typeof hooksRaw["afterCreate"] !== "string") {
            throw new ProjectConfigError(filePath, "'hooks.afterCreate' must be a string");
        }
        hooksConfig.afterCreate = hooksRaw["afterCreate"];
        if ("beforeRun" in hooksRaw && typeof hooksRaw["beforeRun"] !== "string") {
            throw new ProjectConfigError(filePath, "'hooks.beforeRun' must be a string");
        }
        hooksConfig.beforeRun = hooksRaw["beforeRun"];
        if ("afterRun" in hooksRaw && typeof hooksRaw["afterRun"] !== "string") {
            throw new ProjectConfigError(filePath, "'hooks.afterRun' must be a string");
        }
        hooksConfig.afterRun = hooksRaw["afterRun"];
        if ("beforeRemove" in hooksRaw && typeof hooksRaw["beforeRemove"] !== "string") {
            throw new ProjectConfigError(filePath, "'hooks.beforeRemove' must be a string");
        }
        hooksConfig.beforeRemove = hooksRaw["beforeRemove"];
        if ("timeoutMs" in hooksRaw) {
            const timeoutMs = hooksRaw["timeoutMs"];
            if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
                throw new ProjectConfigError(filePath, "'hooks.timeoutMs' must be a positive number (milliseconds)");
            }
            hooksConfig.timeoutMs = timeoutMs;
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
        const validatedMap = {};
        for (const [k, v] of Object.entries(mapRaw)) {
            if (typeof k !== "string" || typeof v !== "string") {
                throw new ProjectConfigError(filePath, "'taskTypeWorkflowMap' entries must be string->string");
            }
            if (!hasWorkflowConfig(v)) {
                throw new ProjectConfigError(filePath, `taskTypeWorkflowMap entry '${k}' references unknown workflow '${v}'`);
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
        const sandboxConfig = {};
        if ("backend" in sandboxRaw) {
            const backend = sandboxRaw["backend"];
            if (backend !== undefined && backend !== "docker" && backend !== "podman" && backend !== "auto") {
                throw new ProjectConfigError(filePath, "'sandbox.backend' must be 'docker', 'podman', or 'auto'");
            }
            sandboxConfig.backend = backend;
        }
        if ("image" in sandboxRaw) {
            if (typeof sandboxRaw["image"] !== "string" || !sandboxRaw["image"].trim()) {
                throw new ProjectConfigError(filePath, "'sandbox.image' must be a non-empty string");
            }
            sandboxConfig.image = sandboxRaw["image"];
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
            sandboxConfig.limits.cpu = limitsRaw["cpu"];
            if ("memory" in limitsRaw && (typeof limitsRaw["memory"] !== "string" || !limitsRaw["memory"].trim())) {
                throw new ProjectConfigError(filePath, "'sandbox.limits.memory' must be a non-empty string");
            }
            sandboxConfig.limits.memory = limitsRaw["memory"];
            if ("cpuset" in limitsRaw && (typeof limitsRaw["cpuset"] !== "string" || !limitsRaw["cpuset"].trim())) {
                throw new ProjectConfigError(filePath, "'sandbox.limits.cpuset' must be a non-empty string");
            }
            sandboxConfig.limits.cpuset = limitsRaw["cpuset"];
            if ("memorySwap" in limitsRaw && (typeof limitsRaw["memorySwap"] !== "string" || !limitsRaw["memorySwap"].trim())) {
                throw new ProjectConfigError(filePath, "'sandbox.limits.memorySwap' must be a non-empty string");
            }
            sandboxConfig.limits.memorySwap = limitsRaw["memorySwap"];
        }
        if ("network" in sandboxRaw && typeof sandboxRaw["network"] !== "boolean") {
            throw new ProjectConfigError(filePath, "'sandbox.network' must be a boolean");
        }
        sandboxConfig.network = sandboxRaw["network"];
        if ("cleanup" in sandboxRaw) {
            const cleanup = sandboxRaw["cleanup"];
            if (cleanup !== undefined && cleanup !== "remove" && cleanup !== "keep") {
                throw new ProjectConfigError(filePath, "'sandbox.cleanup' must be 'remove' or 'keep'");
            }
            sandboxConfig.cleanup = cleanup;
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
export function loadProjectConfig(_projectPath) {
    // Prefer YAML
    const yamlPath = getForemanHomePath("config.yaml");
    if (existsSync(yamlPath)) {
        try {
            const raw = yamlLoad(readFileSync(yamlPath, "utf-8"));
            return validateProjectConfig(raw, yamlPath);
        }
        catch (err) {
            if (err instanceof ProjectConfigError)
                throw err;
            const msg = err instanceof Error ? err.message : String(err);
            throw new ProjectConfigError(yamlPath, `failed to parse YAML: ${msg}`);
        }
    }
    // Fallback: JSON
    const jsonPath = getForemanHomePath("config.json");
    if (existsSync(jsonPath)) {
        try {
            const raw = JSON.parse(readFileSync(jsonPath, "utf-8"));
            return validateProjectConfig(raw, jsonPath);
        }
        catch (err) {
            if (err instanceof ProjectConfigError)
                throw err;
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
export function loadDashboardConfig(projectPath) {
    const defaults = { refreshInterval: 5000 };
    try {
        const config = loadProjectConfig(projectPath);
        if (!config?.dashboard)
            return defaults;
        const ri = config.dashboard.refreshInterval;
        return {
            refreshInterval: typeof ri === "number" && ri >= 1000 ? ri : defaults.refreshInterval,
        };
    }
    catch {
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
export function resolveVcsConfig(workflowVcs, projectVcs) {
    // Determine backend with priority: workflow > project > auto
    let backend = "auto";
    if (workflowVcs?.backend && workflowVcs.backend !== "auto") {
        backend = workflowVcs.backend;
    }
    else if (projectVcs?.backend && projectVcs.backend !== "auto") {
        backend = projectVcs.backend;
    }
    // else: backend stays 'auto'
    const resolved = { backend };
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
export function resolveSandboxConfig(workflowSandbox, projectSandbox) {
    // If neither has sandbox config, return undefined
    if (!workflowSandbox && !projectSandbox) {
        return undefined;
    }
    // Start with project config as base
    const resolved = {
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
export async function resolveDefaultBranch(projectPath, detectDefaultBranch, projectConfig) {
    const config = projectConfig ?? loadProjectConfig(projectPath);
    const configured = normalizeBranchLabel(config?.defaultBranch);
    if (configured)
        return configured;
    if (detectDefaultBranch) {
        try {
            const detected = normalizeBranchLabel(await detectDefaultBranch(projectPath));
            if (detected)
                return detected;
        }
        catch {
            // fall through to hard default
        }
    }
    return "main";
}
//# sourceMappingURL=project-config.js.map