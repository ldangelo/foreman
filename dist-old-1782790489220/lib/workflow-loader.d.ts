/**
 * Workflow configuration loader.
 *
 * Loads and validates workflow YAML files from:
 *   1. Explicit absolute or project-relative YAML path
 *   2. ~/.foreman/workflows/{name}.yaml              (global override)
 *   3. Bundled defaults in src/defaults/workflows/{name}.yaml
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
import type { SandboxConfig } from "./project-config.js";
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
/** Per-phase tool configuration. */
export interface WorkflowPhaseTools {
    /** SDK/Pi tool names allowed for this phase. Overrides the role default allowlist. */
    allowed?: string[];
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
    /** Optional timeout override in seconds for bash phases. */
    timeoutSecs?: number;
    /**
     * Skip this phase if the named artifact already exists in the worktree.
     * Used for resume-from-crash semantics (e.g., "EXPLORER_REPORT.md").
     */
    skipIfArtifact?: string;
    /**
     * Skip this phase during normal sequential execution; run it only when a
     * failing verdict phase jumps to it via retryWith.
     */
    retryOnly?: boolean;
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
    /**
     * When true and this phase fails with a retryable/transient error (e.g. rate limit),
     * the task is placed in cooldown state instead of being marked failed/stuck.
     * The dispatcher will not re-dispatch the task until the cooldown period expires.
     * Use for phases that frequently hit transient limits (e.g. cli-review with CodeRabbit).
     *
     * @default false
     */
    retryAfterCooldown?: boolean;
    /**
     * Cooldown duration in seconds when retryAfterCooldown is enabled.
     * If only retryAfterCooldown is set (no cooldownSeconds), uses the default (300s).
     *
     * @default 300
     */
    cooldownSeconds?: number;
    /** Mail hooks for this phase. */
    mail?: WorkflowPhaseMail;
    /** File reservation config for this phase. */
    files?: WorkflowPhaseFiles;
    /** Tool allowlist override for this phase. */
    tools?: WorkflowPhaseTools;
    /**
     * When true, this phase is implemented as a built-in TypeScript function
     * rather than an SDK agent call. Currently only "finalize" uses this.
     */
    builtin?: boolean;
    /**
     * Bash command string executed via `/bin/sh -c` in the worktree directory.
     * Supports multi-arg commands, shell operators (`&&`, `||`, `|`), and redirects.
     * Mutually exclusive with `command` and `prompt`. Exactly one of the three
     * must be set per phase.
     *
     * @example bash: "npm run test"
     */
    bash?: string;
    /**
     * Inline command string sent to the Pi SDK session as a prompt.
     * Supports `{task.*}` placeholder interpolation.
     * Mutually exclusive with `bash` and `prompt`. Exactly one of the three
     * must be set per phase.
     *
     * @example command: "/ensemble:fix-issue {task.title}"
     */
    command?: string;
}
/** Configuration for the onFailure troubleshooter phase. */
export interface OnFailureConfig {
    /** Phase name (e.g. "troubleshooter"). */
    name: string;
    /** Prompt file name (e.g. "troubleshooter.md"). */
    prompt: string;
    /** Priority-based model selection map. */
    models?: Record<string, string>;
    /** Maximum conversation turns for the troubleshooter. */
    maxTurns?: number;
    /** Report artifact filename (e.g. "TROUBLESHOOT_REPORT.md"). */
    artifact?: string;
}
/** Valid onError strategies for workflow-level error handling. */
export type OnErrorStrategy = "stop" | "continue";
/** Workflow-level sandbox configuration for container isolation. */
export type WorkflowSandboxConfig = SandboxConfig;
/** A loaded, validated workflow configuration. */
export interface WorkflowConfig {
    /** Workflow name (e.g. "default", "smoke"). */
    name: string;
    /** Absolute path of the workflow YAML file that was actually loaded. */
    sourcePath?: string;
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
    /**
     * Optional troubleshooter phase config. When present, the troubleshooter
     * is invoked after a pipeline failure to attempt automatic recovery.
     */
    onFailure?: OnFailureConfig;
    /**
     * Dispatcher error strategy. Controls whether the dispatcher stops or
     * continues when any bead ends in a non-merged terminal failure state
     * (test-failed, failed, stuck, conflict).
     *
     * - "stop": refuse to dispatch new agents until failures are resolved
     * - "continue": keep dispatching regardless of failures (default)
     *
     * @default "continue"
     */
    onError?: OnErrorStrategy;
    /**
     * Epic mode: ordered list of phase names to execute per-task.
     * When present, the pipeline executor runs these phases for each child task
     * instead of using the top-level `phases` array.
     *
     * Example: `taskPhases: [developer, qa]` — each task runs developer→QA with retry.
     * When absent (undefined), the pipeline runs in single-task mode using `phases`.
     */
    taskPhases?: string[];
    /**
     * Epic mode: ordered list of phase names to execute once after all tasks complete.
     * Only used when `taskPhases` is also set (epic mode).
     *
     * Example: `finalPhases: [finalize]` — run finalize once after all tasks pass.
     * When absent in epic mode, defaults to no final phases.
     */
    finalPhases?: string[];
    /**
     * Epic mode: maximum seconds allowed per task's phase execution.
     * When a task's developer phase exceeds this timeout, the phase is terminated
     * and the task is marked failed. Only used when `taskPhases` is set.
     *
     * @example `taskTimeout: 300` — 5 minute timeout per task
     */
    taskTimeout?: number;
    /**
     * Per-workflow merge strategy. Controls how completed branches are merged:
     *
     * - `'auto'`: refinery merges completed branches automatically (default)
     * - `'pr'`: creates a GitHub PR via `gh pr create`
     * - `'none'`: no merge or PR; run ends in `completed` status
     *
     * @default 'auto'
     */
    merge?: "auto" | "pr" | "none";
    /**
     * Per-workflow PR timing policy. Controls when and whether GitHub PRs are created.
     *
     * - `'draft-after-developer'`: PR is created in draft state after the developer phase
     *   completes, then promoted to open (or merged) at finalize (default)
     * - `'create-at-finalize'`: PR is created (open, not draft) only at finalize phase completion
     * - `'never'`: no PR is created; merge:auto merges the branch directly via refinery
     *
     * @default 'draft-after-developer'
     */
    pr?: {
        /** When to create the PR. */
        timing?: "draft-after-developer" | "create-at-finalize" | "never";
    };
    /**
     * Optional sandbox configuration for container isolation.
     * When present, overrides project-level sandbox config.
     * Useful for workflow-specific sandbox settings (e.g., untrusted code).
     *
     * @example
     * ```yaml
     * sandbox:
     *   backend: docker
     *   image: ubuntu:22.04
     *   limits:
     *     cpu: "1"
     *     memory: "2g"
     * ```
     */
    sandbox?: WorkflowSandboxConfig;
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
 *   1. ~/.foreman/workflows/{name}.yaml              (global override)
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
 * Returns true when a workflow YAML exists either in ~/.foreman/workflows/
 * or in the bundled defaults directory.
 */
export declare function hasWorkflowConfig(workflowName: string): boolean;
/**
 * Install bundled workflow configs to ~/.foreman/workflows/.
 *
 * Copies all bundled workflow YAML files. Existing files are skipped unless
 * force=true.
 *
 * @param projectRoot - Absolute path to the project root.
 * @param force       - Overwrite existing workflow files (default: false).
 * @returns Summary of installed/skipped files.
 */
export declare function installBundledWorkflows(_projectRoot: string, force?: boolean): {
    installed: string[];
    skipped: string[];
};
/**
 * List all workflow names available to the loader: bundled defaults plus any
 * YAML files installed in ~/.foreman/workflows/. Sorted and deduplicated.
 */
export declare function listAvailableWorkflows(): string[];
/**
 * Ensure all bundled workflows are installed in ~/.foreman/workflows/.
 *
 * Installs any missing bundled workflow YAML (never overwrites existing
 * files), then returns the names that are still missing (e.g. when the
 * bundled defaults directory is unavailable). Used by the `foreman run`
 * preflight so that newly added bundled workflows (e.g. quick.yaml) are
 * installed on the fly instead of blocking dispatch for existing installs.
 *
 * @param projectRoot - Absolute path to the project root.
 * @returns Array of workflow names still missing after the install attempt.
 */
export declare function ensureBundledWorkflowsInstalled(projectRoot: string): string[];
/**
 * Find missing workflow config files for a project.
 *
 * @param projectRoot - Absolute path to the project root.
 * @returns Array of missing workflow names (e.g. ["default", "smoke"]).
 */
export declare function findMissingWorkflows(_projectRoot: string): string[];
/**
 * Find locally installed workflow configs that are stale (missing critical
 * verdict/retry fields that exist in the bundled default).
 *
 * A workflow is considered stale when any phase in the bundled version has
 * `verdict: true` but the corresponding local phase is missing `verdict`,
 * `retryWith`, or `retryOnFail`.
 *
 * This catches the class of bugs where `foreman init` installs an older copy
 * of a workflow YAML and subsequent updates to the bundled default (adding
 * verdict/retry config) are never propagated to the project-local copy.
 *
 * @param projectRoot - Absolute path to the project root.
 * @returns Array of stale workflow names (present but outdated).
 */
export declare function findStaleWorkflows(_projectRoot: string): string[];
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
/**
 * Resolve the workflow name for a seed/bead.
 *
 * Resolution order:
 *  1. `workflowOverride` — explicit override (e.g. `foreman run --workflow <name>`)
 *  2. `workflow:<name>` label on the task
 *  3. `taskTypeWorkflowMap[seedType]` — explicit config mapping
 *  4. `taskTypeWorkflowMap["default"]` — fallback for unknown types
 *  5. `{seedType}.yaml` in global (~/.foreman/workflows/) or bundled workflows
 *  6. "default" (hard fallback)
 *
 * When `taskTypeWorkflowMap` is not provided (undefined), steps 3–4 are skipped
 * and the resolution falls back to the file-existence check (backward compatible).
 *
 * The explicit override is trusted as-is — callers (the CLI) validate it
 * against loadable workflows before dispatch.
 */
export declare function resolveWorkflowName(seedType: string, labels?: string[], taskTypeWorkflowMap?: Record<string, string>, workflowOverride?: string): string;
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