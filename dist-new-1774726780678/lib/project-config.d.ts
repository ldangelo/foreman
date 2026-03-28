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
import type { VcsConfig } from "./vcs/index.js";
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
}
/** Error thrown when the project config file is present but malformed. */
export declare class ProjectConfigError extends Error {
    readonly configPath: string;
    constructor(configPath: string, message: string);
}
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
export declare function loadProjectConfig(projectPath: string): ProjectConfig | null;
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
export declare function resolveVcsConfig(workflowVcs?: ProjectConfig["vcs"], projectVcs?: ProjectConfig["vcs"]): VcsConfig;
//# sourceMappingURL=project-config.d.ts.map