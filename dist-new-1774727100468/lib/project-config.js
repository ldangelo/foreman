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
export function loadProjectConfig(projectPath) {
    const foremanDir = join(projectPath, ".foreman");
    // Prefer YAML
    const yamlPath = join(foremanDir, "config.yaml");
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
    const jsonPath = join(foremanDir, "config.json");
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
//# sourceMappingURL=project-config.js.map