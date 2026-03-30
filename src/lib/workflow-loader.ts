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

import {
  readFileSync,
  existsSync,
  mkdirSync,
  copyFileSync,
  readdirSync,
} from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { load as yamlLoad } from "js-yaml";

// ── Types ─────────────────────────────────────────────────────────────────────

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
}

// ── Constants ─────────────────────────────────────────────────────────────────

/** Bundled workflow defaults directory (relative to this source file). */
const BUNDLED_WORKFLOWS_DIR = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "defaults",
  "workflows",
);

/** Known workflow names with bundled defaults. */
export const BUNDLED_WORKFLOW_NAMES: ReadonlyArray<string> = ["default", "smoke", "epic"];

// ── Validation ────────────────────────────────────────────────────────────────

/**
 * Error thrown when a workflow config file is missing or invalid.
 */
export class WorkflowConfigError extends Error {
  constructor(
    public readonly workflowName: string,
    public readonly reason: string,
  ) {
    super(
      `Workflow config error for '${workflowName}': ${reason}. ` +
        `Run 'foreman init' or 'foreman doctor --fix' to reinstall.`,
    );
    this.name = "WorkflowConfigError";
  }
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/**
 * Validate and coerce raw YAML parse output into a WorkflowConfig.
 *
 * @throws WorkflowConfigError if the YAML is structurally invalid.
 */
export function validateWorkflowConfig(raw: unknown, workflowName: string): WorkflowConfig {
  if (!isRecord(raw)) {
    throw new WorkflowConfigError(workflowName, "must be a YAML object");
  }

  const name = typeof raw["name"] === "string" ? raw["name"] : workflowName;

  // ── Parse optional setup block ─────────────────────────────────────────────
  let setup: WorkflowSetupStep[] | undefined;
  if (raw["setup"] !== undefined) {
    if (!Array.isArray(raw["setup"])) {
      throw new WorkflowConfigError(workflowName, "'setup' must be an array");
    }
    setup = [];
    for (let i = 0; i < raw["setup"].length; i++) {
      const s = raw["setup"][i];
      if (!isRecord(s)) {
        throw new WorkflowConfigError(workflowName, `setup[${i}] must be an object`);
      }
      if (typeof s["command"] !== "string" || !s["command"]) {
        throw new WorkflowConfigError(
          workflowName,
          `setup[${i}].command must be a non-empty string`,
        );
      }
      const step: WorkflowSetupStep = { command: s["command"] as string };
      if (typeof s["failFatal"] === "boolean") step.failFatal = s["failFatal"];
      if (typeof s["description"] === "string") step.description = s["description"];
      setup.push(step);
    }
  }

  // ── Parse optional setupCache block ──────────────────────────────────────────
  let setupCache: WorkflowSetupCache | undefined;
  if (isRecord(raw["setupCache"])) {
    const c = raw["setupCache"];
    if (typeof c["key"] !== "string" || !c["key"]) {
      throw new WorkflowConfigError(workflowName, "setupCache.key must be a non-empty string");
    }
    if (typeof c["path"] !== "string" || !c["path"]) {
      throw new WorkflowConfigError(workflowName, "setupCache.path must be a non-empty string");
    }
    setupCache = { key: c["key"], path: c["path"] };
  }

  if (!Array.isArray(raw["phases"])) {
    throw new WorkflowConfigError(workflowName, "missing required 'phases' array");
  }

  const phases: WorkflowPhaseConfig[] = [];
  for (let i = 0; i < raw["phases"].length; i++) {
    const p = raw["phases"][i];
    if (!isRecord(p)) {
      throw new WorkflowConfigError(workflowName, `phases[${i}] must be an object`);
    }
    if (typeof p["name"] !== "string" || !p["name"]) {
      throw new WorkflowConfigError(workflowName, `phases[${i}].name must be a non-empty string`);
    }

    const phase: WorkflowPhaseConfig = { name: p["name"] as string };

    if (typeof p["prompt"] === "string") phase.prompt = p["prompt"];
    if (typeof p["model"] === "string") phase.model = p["model"];

    // Parse priority-based models map (takes precedence over single model field)
    if (isRecord(p["models"])) {
      const modelsRaw = p["models"];
      const models: Record<string, string> = {};
      const validKeys = new Set(["default", "P0", "P1", "P2", "P3", "P4"]);
      for (const [key, value] of Object.entries(modelsRaw)) {
        if (!validKeys.has(key)) {
          throw new WorkflowConfigError(
            workflowName,
            `phases[${i}].models key '${key}' is invalid; must be 'default' or 'P0'–'P4'`,
          );
        }
        if (typeof value !== "string" || !value) {
          throw new WorkflowConfigError(
            workflowName,
            `phases[${i}].models.${key} must be a non-empty string`,
          );
        }
        models[key] = value;
      }
      if (Object.keys(models).length > 0) {
        phase.models = models;
      }
    }

    if (typeof p["maxTurns"] === "number") phase.maxTurns = p["maxTurns"];
    if (typeof p["skipIfArtifact"] === "string") phase.skipIfArtifact = p["skipIfArtifact"];
    if (typeof p["artifact"] === "string") phase.artifact = p["artifact"];
    if (typeof p["verdict"] === "boolean") phase.verdict = p["verdict"];
    if (typeof p["retryWith"] === "string") phase.retryWith = p["retryWith"];
    if (typeof p["retryOnFail"] === "number") phase.retryOnFail = p["retryOnFail"];
    if (typeof p["builtin"] === "boolean") phase.builtin = p["builtin"];

    // Parse mail hooks
    if (isRecord(p["mail"])) {
      const m = p["mail"];
      phase.mail = {};
      if (typeof m["onStart"] === "boolean") phase.mail.onStart = m["onStart"];
      if (typeof m["onComplete"] === "boolean") phase.mail.onComplete = m["onComplete"];
      if (typeof m["onFail"] === "string") phase.mail.onFail = m["onFail"];
      if (typeof m["forwardArtifactTo"] === "string") phase.mail.forwardArtifactTo = m["forwardArtifactTo"];
    }

    // Parse file reservation config
    if (isRecord(p["files"])) {
      const f = p["files"];
      phase.files = {};
      if (typeof f["reserve"] === "boolean") phase.files.reserve = f["reserve"];
      if (typeof f["leaseSecs"] === "number") phase.files.leaseSecs = f["leaseSecs"];
    }

    phases.push(phase);
  }

  if (phases.length === 0) {
    throw new WorkflowConfigError(workflowName, "phases array must not be empty");
  }

  const config: WorkflowConfig = { name, phases };
  if (setup !== undefined) config.setup = setup;
  if (setupCache !== undefined) config.setupCache = setupCache;

  // ── Parse optional vcs block ───────────────────────────────────────────────
  if (isRecord(raw["vcs"])) {
    const vcsRaw = raw["vcs"];
    const backend = vcsRaw["backend"];
    if (backend === "git" || backend === "jujutsu" || backend === "auto") {
      config.vcs = { backend };
    } else if (backend !== undefined) {
      throw new WorkflowConfigError(
        workflowName,
        `vcs.backend must be 'git', 'jujutsu', or 'auto' (got: ${String(backend)})`,
      );
    }
  }

  // ── Parse optional onFailure block ────────────────────────────────────────
  if (isRecord(raw["onFailure"])) {
    const of_ = raw["onFailure"];
    if (typeof of_["name"] !== "string" || !of_["name"]) {
      throw new WorkflowConfigError(workflowName, "onFailure.name must be a non-empty string");
    }
    const onFailure: OnFailureConfig = {
      name: of_["name"] as string,
      prompt: typeof of_["prompt"] === "string" ? of_["prompt"] : `${of_["name"] as string}.md`,
    };
    if (typeof of_["maxTurns"] === "number") onFailure.maxTurns = of_["maxTurns"];
    if (typeof of_["artifact"] === "string") onFailure.artifact = of_["artifact"];
    if (isRecord(of_["models"])) {
      const models: Record<string, string> = {};
      for (const [k, v] of Object.entries(of_["models"])) {
        if (typeof v === "string") models[k] = v;
      }
      onFailure.models = models;
    }
    config.onFailure = onFailure;
  }

  // ── Parse optional epic mode fields (taskPhases, finalPhases) ──────────
  if (raw["taskPhases"] !== undefined) {
    if (!Array.isArray(raw["taskPhases"])) {
      throw new WorkflowConfigError(workflowName, "'taskPhases' must be an array of phase names");
    }
    const taskPhases: string[] = [];
    for (let j = 0; j < raw["taskPhases"].length; j++) {
      const pName = raw["taskPhases"][j];
      if (typeof pName !== "string" || !pName) {
        throw new WorkflowConfigError(workflowName, `taskPhases[${j}] must be a non-empty string`);
      }
      // Validate that referenced phase exists in the phases array
      if (!phases.some((p) => p.name === pName)) {
        throw new WorkflowConfigError(
          workflowName,
          `taskPhases[${j}] references phase '${pName}' which is not defined in phases`,
        );
      }
      taskPhases.push(pName);
    }
    if (taskPhases.length > 0) {
      config.taskPhases = taskPhases;
    }
  }
  if (raw["finalPhases"] !== undefined) {
    if (!Array.isArray(raw["finalPhases"])) {
      throw new WorkflowConfigError(workflowName, "'finalPhases' must be an array of phase names");
    }
    const finalPhases: string[] = [];
    for (let j = 0; j < raw["finalPhases"].length; j++) {
      const pName = raw["finalPhases"][j];
      if (typeof pName !== "string" || !pName) {
        throw new WorkflowConfigError(workflowName, `finalPhases[${j}] must be a non-empty string`);
      }
      if (!phases.some((p) => p.name === pName)) {
        throw new WorkflowConfigError(
          workflowName,
          `finalPhases[${j}] references phase '${pName}' which is not defined in phases`,
        );
      }
      finalPhases.push(pName);
    }
    if (finalPhases.length > 0) {
      config.finalPhases = finalPhases;
    }
  }

  // ── Parse optional taskTimeout ─────────────────────────────────────────
  if (raw["taskTimeout"] !== undefined) {
    if (typeof raw["taskTimeout"] !== "number" || raw["taskTimeout"] <= 0) {
      throw new WorkflowConfigError(workflowName, "taskTimeout must be a positive number (seconds)");
    }
    config.taskTimeout = raw["taskTimeout"];
  }


  // ── Parse optional onError strategy ─────────────────────────────────────
  if (raw["onError"] !== undefined) {
    const onError = raw["onError"];
    if (onError === "stop" || onError === "continue") {
      config.onError = onError;
    } else {
      throw new WorkflowConfigError(
        workflowName,
        `onError must be 'stop' or 'continue' (got: ${String(onError)})`,
      );
    }
  }

  return config;
}

// ── Loader ────────────────────────────────────────────────────────────────────

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
export function loadWorkflowConfig(
  workflowName: string,
  projectRoot: string,
): WorkflowConfig {
  // Tier 1: project-local override
  const localPath = join(projectRoot, ".foreman", "workflows", `${workflowName}.yaml`);
  if (existsSync(localPath)) {
    try {
      const raw = yamlLoad(readFileSync(localPath, "utf-8"));
      return validateWorkflowConfig(raw, workflowName);
    } catch (err) {
      if (err instanceof WorkflowConfigError) throw err;
      const msg = err instanceof Error ? err.message : String(err);
      throw new WorkflowConfigError(workflowName, `failed to parse ${localPath}: ${msg}`);
    }
  }

  // Tier 2: bundled default
  const bundledPath = join(BUNDLED_WORKFLOWS_DIR, `${workflowName}.yaml`);
  if (existsSync(bundledPath)) {
    try {
      const raw = yamlLoad(readFileSync(bundledPath, "utf-8"));
      return validateWorkflowConfig(raw, workflowName);
    } catch (err) {
      if (err instanceof WorkflowConfigError) throw err;
      const msg = err instanceof Error ? err.message : String(err);
      throw new WorkflowConfigError(workflowName, `failed to parse bundled default ${bundledPath}: ${msg}`);
    }
  }

  throw new WorkflowConfigError(
    workflowName,
    `no workflow config found at ${localPath} or bundled defaults`,
  );
}

/**
 * Get the path to a bundled workflow YAML file.
 *
 * @returns Absolute path, or null if not found.
 */
export function getBundledWorkflowPath(workflowName: string): string | null {
  const p = join(BUNDLED_WORKFLOWS_DIR, `${workflowName}.yaml`);
  return existsSync(p) ? p : null;
}

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
export function installBundledWorkflows(
  projectRoot: string,
  force: boolean = false,
): { installed: string[]; skipped: string[] } {
  const installed: string[] = [];
  const skipped: string[] = [];

  const destDir = join(projectRoot, ".foreman", "workflows");
  mkdirSync(destDir, { recursive: true });

  let files: string[];
  try {
    files = readdirSync(BUNDLED_WORKFLOWS_DIR).filter((f) => f.endsWith(".yaml"));
  } catch {
    // Bundled workflows directory doesn't exist (e.g. non-dist environment)
    return { installed, skipped };
  }

  for (const file of files) {
    const destPath = join(destDir, file);
    if (existsSync(destPath) && !force) {
      skipped.push(file);
    } else {
      copyFileSync(join(BUNDLED_WORKFLOWS_DIR, file), destPath);
      installed.push(file);
    }
  }

  return { installed, skipped };
}

/**
 * Find missing workflow config files for a project.
 *
 * @param projectRoot - Absolute path to the project root.
 * @returns Array of missing workflow names (e.g. ["default", "smoke"]).
 */
export function findMissingWorkflows(projectRoot: string): string[] {
  const missing: string[] = [];
  for (const name of BUNDLED_WORKFLOW_NAMES) {
    const p = join(projectRoot, ".foreman", "workflows", `${name}.yaml`);
    if (!existsSync(p)) {
      missing.push(name);
    }
  }
  return missing;
}

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
export function resolveWorkflowName(seedType: string, labels?: string[]): string {
  if (labels) {
    for (const label of labels) {
      if (label.startsWith("workflow:")) {
        return label.slice("workflow:".length);
      }
    }
  }
  if (seedType === "smoke") return "smoke";
  if (seedType === "epic") return "epic";
  return "default";
}

// ── Compatibility exports ─────────────────────────────────────────────────────

/**
 * Alias for BUNDLED_WORKFLOW_NAMES — required workflow names.
 * @deprecated Use BUNDLED_WORKFLOW_NAMES instead.
 */
export const REQUIRED_WORKFLOWS: ReadonlyArray<string> = BUNDLED_WORKFLOW_NAMES;

/**
 * Find a phase by name in a workflow config.
 *
 * @param workflow   - Loaded workflow config.
 * @param phaseName  - Phase name to look up.
 * @returns The matching phase config, or undefined if not found.
 */
export function getWorkflowPhase(
  workflow: WorkflowConfig,
  phaseName: string,
): WorkflowPhaseConfig | undefined {
  return workflow.phases.find((p) => p.name === phaseName);
}

/**
 * Model shorthand to full model ID mapping.
 * Allows YAML to use readable aliases instead of full model strings.
 */
const MODEL_SHORTHANDS: Record<string, string> = {
  haiku: "anthropic/claude-haiku-4-5",
  sonnet: "anthropic/claude-sonnet-4-6",
  opus: "anthropic/claude-opus-4-6",
};

/**
 * Resolve a model string from workflow YAML to a full model ID.
 * Accepts shorthands ("haiku", "sonnet", "opus") or full model IDs.
 *
 * @param model - Model string from YAML, or undefined.
 * @returns Full model ID, or undefined if input is undefined.
 */
export function resolveWorkflowModel(model: string | undefined): string | undefined {
  if (!model) return undefined;
  return MODEL_SHORTHANDS[model] ?? model;
}

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
export function resolvePhaseModel(
  phase: WorkflowPhaseConfig,
  priorityStr: string | undefined,
  fallbackModel: string,
): string {
  if (phase.models) {
    // Normalise priority to "P0"–"P4" format
    const priorityKey = normalisePriorityKey(priorityStr);
    const priorityOverride = priorityKey ? phase.models[priorityKey] : undefined;
    const resolved = priorityOverride ?? phase.models["default"];
    if (resolved) return resolveWorkflowModel(resolved) ?? resolved;
  }
  // Legacy single-model field
  if (phase.model) {
    const resolved = resolveWorkflowModel(phase.model);
    if (resolved) return resolved;
  }
  return fallbackModel;
}

/**
 * Convert a priority string in any format ("P0"–"P4" or "0"–"4") to the
 * canonical "P0"–"P4" format used as YAML models map keys.
 *
 * Returns undefined for unrecognised inputs.
 */
function normalisePriorityKey(p: string | undefined): string | undefined {
  if (!p) return undefined;
  const upper = p.trim().toUpperCase();
  // Already in "P0"–"P4" format
  if (/^P[0-4]$/.test(upper)) return upper;
  // Numeric string "0"–"4"
  if (/^[0-4]$/.test(upper)) return `P${upper}`;
  return undefined;
}
