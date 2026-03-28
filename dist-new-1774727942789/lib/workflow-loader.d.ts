/**
 * Workflow configuration loader.
 *
 * Loads and validates workflow YAML files from:
 *   1. <projectRoot>/.foreman/workflows/{name}.yaml  (project-local override)
 *   2. Bundled defaults in src/defaults/workflows/{name}.yaml
 *
 * Workflow files define the ordered phase sequence for a pipeline run,
 * along with per-phase configuration (model, maxTurns, retryOnFail, etc.).
 *
 * @example
 * ```yaml
 * name: default
 * phases:
 *   - name: explorer
 *     prompt: explorer.md
 *     model: haiku
 *     maxTurns: 30
 *     skipIfArtifact: EXPLORER_REPORT.md
 *   - name: developer
 *     prompt: developer.md
 *     model: sonnet
 *     maxTurns: 80
 *   - name: qa
 *     prompt: qa.md
 *     model: sonnet
 *     maxTurns: 30
 *     retryOnFail: 2
 *   - name: reviewer
 *     prompt: reviewer.md
 *     model: sonnet
 *     maxTurns: 20
 *   - name: finalize
 *     builtin: true
 * ```
 */
/**
 * A single setup step from the workflow YAML `setup` block.
 * Setup steps run before the pipeline phases begin (e.g. dependency installation).
 */
export interface WorkflowSetupStep {
    /** Shell command to run (split on whitespace to form argv). */
    command: string;
    /** If true (default), a non-zero exit aborts the pipeline. */
    failFatal?: boolean;
    /** Human-readable description for logs. */
    description?: string;
}
/**
 * Stack-agnostic dependency cache configuration.
 *
 * When present in the workflow YAML `setup` block, the executor hashes the
 * `key` file(s) and symlinks `path` from a shared cache instead of running
 * the setup steps on every worktree init. Cache miss → run steps → populate cache.
 *
 * @example
 * ```yaml
 * setup:
 *   cache:
 *     key: package-lock.json     # file to hash for cache key
 *     path: node_modules         # directory to cache
 *   steps:
 *     - command: npm install --prefer-offline --no-audit
 * ```
 */
export interface WorkflowSetupCache {
    /** File path (relative to worktree root) or glob to hash for cache key. */
    key: string;
    /** Directory (relative to worktree root) to cache and symlink. */
    path: string;
}
/** Mail hooks configuration for a workflow phase. */
export interface WorkflowPhaseMail {
    /** Send phase-started mail to foreman before the phase runs. Default: true. */
    onStart?: boolean;
    /** Send phase-complete mail to foreman after the phase succeeds. Default: true. */
    onComplete?: boolean;
    /** On failure, send artifact content to this agent (e.g. "developer"). */
    onFail?: string;
    /** On success, forward the artifact content to this agent (e.g. "developer", "foreman"). */
    forwardArtifactTo?: string;
}
/** File reservation configuration for a workflow phase. */
export interface WorkflowPhaseFiles {
    /** Reserve the worktree before this phase runs. */
    reserve?: boolean;
    /** Lease duration in seconds. Default: 600. */
    leaseSecs?: number;
}
/** Per-phase configuration in a workflow YAML. */
export interface WorkflowPhaseConfig {
    /** Phase name: "explorer" | "developer" | "qa" | "reviewer" | "finalize" | custom */
    name: string;
    /**
     * Prompt file name (relative to .foreman/prompts/{workflow}/).
     * Omitted for builtin phases (e.g., finalize).
     */
    prompt?: string;
    /**
     * Model shorthand: "haiku" | "sonnet" | "opus" or full model ID.
     * Defaults to role default. @deprecated Use `models` map instead.
     */
    model?: string;
    /**
     * Priority-based model overrides. Keys are "default" or "P0"–"P4".
     * Takes precedence over the single `model` field.
     *
     * @example
     * models:
     *   default: sonnet
     *   P0: opus
     *   P1: sonnet
     */
    models?: Record<string, string>;
    /** Maximum turns. Overrides the role's default maxTurns. */
    maxTurns?: number;
    /**
     * Skip this phase if the named artifact already exists in the worktree.
     * Used for resume-from-crash semantics (e.g., "EXPLORER_REPORT.md").
     */
    skipIfArtifact?: string;
    /** Expected output artifact filename (e.g. "EXPLORER_REPORT.md"). */
    artifact?: string;
    /** Parse PASS/FAIL verdict from the artifact. */
    verdict?: boolean;
    /**
     * On verdict FAIL, loop back to this phase name for retry.
     * Used with retryOnFail to create QA⇄developer or reviewer⇄developer loops.
     */
    retryWith?: string;
    /**
     * Max retry count when this phase fails (verdict FAIL).
     * When retryWith is set, the executor loops back retryOnFail times.
     */
    retryOnFail?: number;
    /** Mail hooks for this phase. */
    mail?: WorkflowPhaseMail;
    /** File reservation config for this phase. */
    files?: WorkflowPhaseFiles;
    /**
     * When true, this phase is implemented as a built-in TypeScript function
     * rather than an SDK agent call. Currently only "finalize" uses this.
     */
    builtin?: boolean;
}
/** A loaded, validated workflow configuration. */
export interface WorkflowConfig {
    /** Workflow name (e.g. "default", "smoke"). */
    name: string;
    /**
     * Optional setup steps to run before pipeline phases begin.
     * When present, these replace the Node.js-specific installDependencies() fallback.
     */
    setup?: WorkflowSetupStep[];
    /**
     * Optional dependency cache config. When present, the executor hashes
     * `cache.key` and symlinks `cache.path` from a shared cache directory
     * (.foreman/setup-cache/<hash>/). On cache miss, setup steps run first
     * and the result is cached. Stack-agnostic — works for any ecosystem.
     */
    setupCache?: WorkflowSetupCache;
    /** Ordered list of phases to execute. */
    phases: WorkflowPhaseConfig[];
    /**
     * Optional VCS backend configuration. When present, overrides project-level
     * config and auto-detection. Use 'auto' to detect from repository contents
     * (.jj/ → jujutsu, .git/ → git).
     *
     * @example
     * ```yaml
     * vcs:
     *   backend: jujutsu
     * ```
     */
    vcs?: {
        /** VCS backend to use: 'git' | 'jujutsu' | 'auto'. Default: 'auto'. */
        backend: 'git' | 'jujutsu' | 'auto';
    };
}
/** Known workflow names with bundled defaults. */
export declare const BUNDLED_WORKFLOW_NAMES: ReadonlyArray<string>;
/**
 * Error thrown when a workflow config file is missing or invalid.
 */
export declare class WorkflowConfigError extends Error {
    readonly workflowName: string;
    readonly reason: string;
    constructor(workflowName: string, reason: string);
}
/**
 * Validate and coerce raw YAML parse output into a WorkflowConfig.
 *
 * @throws WorkflowConfigError if the YAML is structurally invalid.
 */
export declare function validateWorkflowConfig(raw: unknown, workflowName: string): WorkflowConfig;
/**
 * Load and validate a workflow config.
 *
 * Resolution order:
 *   1. <projectRoot>/.foreman/workflows/{name}.yaml  (project-local override)
 *   2. Bundled default: src/defaults/workflows/{name}.yaml
 *
 * @param workflowName - Workflow name (e.g. "default", "smoke").
 * @param projectRoot  - Absolute path to the project root.
 * @throws WorkflowConfigError if not found or invalid.
 */
export declare function loadWorkflowConfig(workflowName: string, projectRoot: string): WorkflowConfig;
/**
 * Get the path to a bundled workflow YAML file.
 *
 * @returns Absolute path, or null if not found.
 */
export declare function getBundledWorkflowPath(workflowName: string): string | null;
/**
 * Install bundled workflow configs to <projectRoot>/.foreman/workflows/.
 *
 * Copies all bundled workflow YAML files. Existing files are skipped unless
 * force=true.
 *
 * @param projectRoot - Absolute path to the project root.
 * @param force       - Overwrite existing workflow files (default: false).
 * @returns Summary of installed/skipped files.
 */
export declare function installBundledWorkflows(projectRoot: string, force?: boolean): {
    installed: string[];
    skipped: string[];
};
/**
 * Find missing workflow config files for a project.
 *
 * @param projectRoot - Absolute path to the project root.
 * @returns Array of missing workflow names (e.g. ["default", "smoke"]).
 */
export declare function findMissingWorkflows(projectRoot: string): string[];
/**
 * Resolve the effective workflow name for a seed.
 *
 * Resolution order:
 *   1. First `workflow:<name>` label on the bead
 *   2. Bead type field mapped: "smoke" → "smoke", everything else → "default"
 *
 * @param seedType - The bead's type field (e.g. "feature", "smoke").
 * @param labels   - Optional list of labels on the bead.
 * @returns The resolved workflow name to use.
 */
export declare function resolveWorkflowName(seedType: string, labels?: string[]): string;
/**
 * Alias for BUNDLED_WORKFLOW_NAMES — required workflow names.
 * @deprecated Use BUNDLED_WORKFLOW_NAMES instead.
 */
export declare const REQUIRED_WORKFLOWS: ReadonlyArray<string>;
/**
 * Find a phase by name in a workflow config.
 *
 * @param workflow   - Loaded workflow config.
 * @param phaseName  - Phase name to look up.
 * @returns The matching phase config, or undefined if not found.
 */
export declare function getWorkflowPhase(workflow: WorkflowConfig, phaseName: string): WorkflowPhaseConfig | undefined;
/**
 * Resolve a model string from workflow YAML to a full model ID.
 * Accepts shorthands ("haiku", "sonnet", "opus") or full model IDs.
 *
 * @param model - Model string from YAML, or undefined.
 * @returns Full model ID, or undefined if input is undefined.
 */
export declare function resolveWorkflowModel(model: string | undefined): string | undefined;
/**
 * Resolve the effective model for a pipeline phase at runtime.
 *
 * Resolution order (first defined wins):
 *   1. `phase.models[priorityKey]`  — per-priority YAML override (e.g. "P0: opus")
 *   2. `phase.models.default`       — per-phase YAML default
 *   3. `phase.model`                — legacy single-model YAML field (backward compat)
 *   4. `fallbackModel`              — caller-supplied fallback (typically ROLE_CONFIGS value)
 *
 * @param phase         - Loaded workflow phase config.
 * @param priorityStr   - Bead priority string ("P0"–"P4", "0"–"4", or undefined).
 * @param fallbackModel - Model to use when no YAML config is present (e.g. ROLE_CONFIGS[role].model).
 * @returns Full model ID string.
 */
export declare function resolvePhaseModel(phase: WorkflowPhaseConfig, priorityStr: string | undefined, fallbackModel: string): string;
//# sourceMappingURL=workflow-loader.d.ts.map