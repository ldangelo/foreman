/**
 * Workflow configuration loader.
 *
 * Loads and validates workflow YAML files from:
 *   1. Explicit absolute or project-relative YAML path
 *   2. .foreman/workflows/{name}.yaml                (project override)
 *   3. ~/.foreman/workflows/{name}.yaml              (global override)
 *   4. Bundled defaults in src/defaults/workflows/{name}.yaml
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
import { join, dirname, isAbsolute, resolve, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { load as yamlLoad } from "js-yaml";
import { getForemanHomePath } from "./foreman-paths.js";
import type { SandboxConfig } from "./project-config.js";

const WORKSPACE_ACTIONS = new Set(["prepare-worktree", "setup-workspace", "write-task-context"]);

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

/** Per-phase tool configuration. */
export interface WorkflowPhaseTools {
  /** SDK/Pi tool names allowed for this phase. Overrides the role default allowlist. */
  allowed?: string[];
}

export interface WorkflowPhaseContractPolicyConfig {
  requiresExplorerReport?: boolean;
  explorerCircuitBreaker?: boolean;
  developerCompletion?: boolean;
  redPhaseCompletion?: boolean;
  acceptanceCoverage?: boolean;
  allowDeferredAcceptance?: boolean;
  testEvidence?: boolean;
  captureQaTarget?: boolean;
  finalizeValidation?: boolean;
  skipDeveloperRetryOnUnrelatedFinalizeFailure?: boolean;
  structuredFailureChecklist?: boolean;
  terminalOnFailExhausted?: boolean;
}

export interface WorkflowPhaseContractConfig {
  goal?: string;
  requiredSections?: string[];
  policy?: WorkflowPhaseContractPolicyConfig;
  completion?: {
    minEditTargets?: number;
    maxEditTargets?: number;
    requireTestTargets?: boolean;
    requireFilesChanged?: boolean;
    requireValidationNotes?: boolean;
  };
  allowedScope?: {
    canRead?: boolean;
    canWriteOnly?: string[];
  };
}

export interface WorkflowPhaseOverwatchConfig {
  enabled?: boolean;
  mode?: "off" | "warn" | "enforce";
  checkEveryTurns?: number;
  forceArtifactNearMaxTurns?: boolean;
  continueIfArtifactValidOnBudgetStop?: boolean;
  maxSteersPerPhase?: number;
  forceArtifactAfterSteers?: number;
  forceArtifactAfterToolCalls?: number;
  repeatedCommandLimit?: number;
  maxToolCalls?: number;
  blockedCommands?: string[];
}

/** Per-phase configuration in a workflow YAML. */
export interface WorkflowPhaseConfig {
  /** Phase name: "explorer" | "developer" | "qa" | "reviewer" | "finalize" | custom */
  name: string;
  /** Reusable execution action type. Defaults from prompt/bash/command/builtin fields when omitted. */
  action?: string;
  /** Declared host capabilities used by project/custom actions (advisory for now). */
  capabilities?: string[];
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
  /** Stop the pipeline when verdict FAIL remains after retries are exhausted. */
  stopOnFailExhausted?: boolean;
  /**
   * When true, detects repeated QA/review failure signatures across retry attempts.
   * If the same root cause repeats on consecutive retries without meaningful diff progress,
   * the circuit breaker trips early and sets retriesExhausted: true instead of consuming
   * the remaining retry budget. Uses the failure item keys (category|file|command) from
   * the parsed QA report to detect repeated failures.
   *
   * Default: true for phases with verdict: true
   */
  sameFailureCircuitBreaker?: boolean;
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
  /** Optional deterministic completion contract used by phase overwatch. */
  contract?: WorkflowPhaseContractConfig;
  /** Optional supervisor/policy controls for runaway phase prevention. */
  overwatch?: WorkflowPhaseOverwatchConfig;
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
   * Optional task type declaration. When present, this workflow claims ownership
   * of the named task type for dispatch routing purposes.
   *
   * Example: `task_type: bug` in bug.yaml means the "bug" task type dispatches to
   * the bug workflow automatically when no explicit override is provided.
   *
   * Duplicate detection: if multiple workflows declare the same `task_type`,
   * `validateTaskTypeUniqueness()` will report the conflict.
   */
  taskType?: string;
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

// ── Constants ─────────────────────────────────────────────────────────────────

/** Bundled workflow defaults directory (relative to this source file). */
const BUNDLED_WORKFLOWS_DIR = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "defaults",
  "workflows",
);

/** Known workflow names with bundled defaults. */
export const BUNDLED_WORKFLOW_NAMES: ReadonlyArray<string> = [
  "default",
  "quick",
  "smoke",
  "epic",
  "bug",
  "task",
  "feature",
  "chore",
  "docs",
  "question",
  "tdd",
];

// ── Validation ────────────────────────────────────────────────────────────────

export function isSafeWorkflowName(workflow: string): boolean {
  return /^[A-Za-z0-9._-]+$/.test(workflow) && /[A-Za-z0-9]/.test(workflow);
}

function staysWithinDir(parent: string, child: string): boolean {
  const rel = relative(resolve(parent), resolve(child));
  return rel === "" || (!rel.startsWith("..") && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

function isSafeActionName(action: string): boolean {
  return /^[A-Za-z0-9._-]+$/.test(action) && /[A-Za-z0-9]/.test(action);
}

function isPositiveNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0;
}

function isNonNegativeInteger(value: unknown): value is number {
  return Number.isInteger(value) && (value as number) >= 0;
}

function parseOptionalBoolean(raw: unknown, workflowName: string, path: string): boolean | undefined {
  if (raw === undefined) return undefined;
  if (typeof raw !== "boolean") throw new WorkflowConfigError(workflowName, `${path} must be a boolean`);
  return raw;
}

function parseModelsMap(raw: unknown, workflowName: string, path: string): Record<string, string> | undefined {
  if (raw === undefined) return undefined;
  if (!isRecord(raw)) {
    throw new WorkflowConfigError(workflowName, `${path} must be an object`);
  }
  const models: Record<string, string> = {};
  const validKeys = new Set(["default", "P0", "P1", "P2", "P3", "P4"]);
  for (const [key, value] of Object.entries(raw)) {
    if (!validKeys.has(key)) {
      throw new WorkflowConfigError(
        workflowName,
        `${path} key '${key}' is invalid; must be 'default' or 'P0'–'P4'`,
      );
    }
    if (typeof value !== "string" || !value.trim()) {
      throw new WorkflowConfigError(workflowName, `${path}.${key} must be a non-empty string`);
    }
    models[key] = value;
  }
  return Object.keys(models).length > 0 ? models : undefined;
}

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

  if (raw["name"] !== undefined && (typeof raw["name"] !== "string" || !raw["name"].trim())) {
    throw new WorkflowConfigError(workflowName, "name must be a non-empty string");
  }
  const name = typeof raw["name"] === "string" ? raw["name"] : workflowName;
  if (!isSafeWorkflowName(name)) {
    throw new WorkflowConfigError(workflowName, "name must be a safe workflow name");
  }

  // ── Parse optional task_type declaration ──────────────────────────────────
  let taskType: string | undefined;
  if (raw["task_type"] !== undefined) {
    if (typeof raw["task_type"] !== "string" || !raw["task_type"].trim()) {
      throw new WorkflowConfigError(workflowName, "task_type must be a non-empty string");
    }
    taskType = raw["task_type"].trim();
  }

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
      if (typeof s["command"] !== "string" || !s["command"].trim()) {
        throw new WorkflowConfigError(
          workflowName,
          `setup[${i}].command must be a non-empty string`,
        );
      }
      const step: WorkflowSetupStep = { command: s["command"] as string };
      const failFatal = parseOptionalBoolean(s["failFatal"], workflowName, `setup[${i}].failFatal`);
      if (failFatal !== undefined) step.failFatal = failFatal;
      if (s["description"] !== undefined) {
        if (typeof s["description"] !== "string" || !s["description"].trim()) {
          throw new WorkflowConfigError(workflowName, `setup[${i}].description must be a non-empty string`);
        }
        step.description = s["description"];
      }
      setup.push(step);
    }
  }

  // ── Parse optional setupCache block ──────────────────────────────────────────
  let setupCache: WorkflowSetupCache | undefined;
  if (raw["setupCache"] !== undefined && !isRecord(raw["setupCache"])) {
    throw new WorkflowConfigError(workflowName, "setupCache must be an object");
  }
  if (isRecord(raw["setupCache"])) {
    const c = raw["setupCache"];
    if (typeof c["key"] !== "string" || !c["key"].trim()) {
      throw new WorkflowConfigError(workflowName, "setupCache.key must be a non-empty string");
    }
    if (typeof c["path"] !== "string" || !c["path"].trim()) {
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
    if (!isSafeActionName(p["name"])) {
      throw new WorkflowConfigError(workflowName, `phases[${i}].name must be a safe phase name`);
    }

    const phase: WorkflowPhaseConfig = { name: p["name"] as string };

    if (p["action"] !== undefined) {
      if (typeof p["action"] !== "string" || !isSafeActionName(p["action"])) {
        throw new WorkflowConfigError(workflowName, `phases[${i}].action must be a safe non-empty action name`);
      }
      phase.action = p["action"];
    }
    if (p["capabilities"] !== undefined) {
      if (!Array.isArray(p["capabilities"])) {
        throw new WorkflowConfigError(workflowName, `phases[${i}].capabilities must be an array of strings`);
      }
      phase.capabilities = p["capabilities"].map((capability, capabilityIndex) => {
        if (typeof capability !== "string" || !capability.trim()) {
          throw new WorkflowConfigError(workflowName, `phases[${i}].capabilities[${capabilityIndex}] must be a non-empty string`);
        }
        return capability;
      });
    }
    if (p["prompt"] !== undefined) {
      if (typeof p["prompt"] !== "string" || !p["prompt"].trim()) throw new WorkflowConfigError(workflowName, `phases[${i}].prompt must be a non-empty string`);
      phase.prompt = p["prompt"];
    }
    if (p["model"] !== undefined) {
      if (typeof p["model"] !== "string" || !p["model"].trim()) throw new WorkflowConfigError(workflowName, `phases[${i}].model must be a non-empty string`);
      phase.model = p["model"];
    }

    // Parse priority-based models map (takes precedence over single model field)
    const phaseModels = parseModelsMap(p["models"], workflowName, `phases[${i}].models`);
    if (phaseModels) phase.models = phaseModels;

    if (p["maxTurns"] !== undefined) {
      if (!isPositiveNumber(p["maxTurns"])) throw new WorkflowConfigError(workflowName, `phases[${i}].maxTurns must be a positive number`);
      phase.maxTurns = p["maxTurns"];
    }
    if (p["timeoutSecs"] !== undefined) {
      if (!isPositiveNumber(p["timeoutSecs"])) throw new WorkflowConfigError(workflowName, `phases[${i}].timeoutSecs must be a positive number`);
      phase.timeoutSecs = p["timeoutSecs"];
    }
    if (p["skipIfArtifact"] !== undefined) {
      if (typeof p["skipIfArtifact"] !== "string" || !p["skipIfArtifact"].trim()) throw new WorkflowConfigError(workflowName, `phases[${i}].skipIfArtifact must be a non-empty string`);
      phase.skipIfArtifact = p["skipIfArtifact"];
    }
    const retryOnly = parseOptionalBoolean(p["retryOnly"], workflowName, `phases[${i}].retryOnly`);
    if (retryOnly !== undefined) phase.retryOnly = retryOnly;
    if (p["artifact"] !== undefined) {
      if (typeof p["artifact"] !== "string" || !p["artifact"].trim()) throw new WorkflowConfigError(workflowName, `phases[${i}].artifact must be a non-empty string`);
      phase.artifact = p["artifact"];
    }
    const verdict = parseOptionalBoolean(p["verdict"], workflowName, `phases[${i}].verdict`);
    if (verdict !== undefined) phase.verdict = verdict;
    if (p["retryWith"] !== undefined) {
      if (typeof p["retryWith"] !== "string" || !p["retryWith"].trim()) throw new WorkflowConfigError(workflowName, `phases[${i}].retryWith must be a non-empty string`);
      phase.retryWith = p["retryWith"];
    }
    if (p["retryOnFail"] !== undefined) {
      if (!isNonNegativeInteger(p["retryOnFail"])) throw new WorkflowConfigError(workflowName, `phases[${i}].retryOnFail must be a non-negative integer`);
      phase.retryOnFail = p["retryOnFail"];
    }
    const stopOnFailExhausted = parseOptionalBoolean(p["stopOnFailExhausted"], workflowName, `phases[${i}].stopOnFailExhausted`);
    if (stopOnFailExhausted !== undefined) phase.stopOnFailExhausted = stopOnFailExhausted;
    const sameFailureCircuitBreaker = parseOptionalBoolean(p["sameFailureCircuitBreaker"], workflowName, `phases[${i}].sameFailureCircuitBreaker`);
    if (sameFailureCircuitBreaker !== undefined) phase.sameFailureCircuitBreaker = sameFailureCircuitBreaker;
    const retryAfterCooldown = parseOptionalBoolean(p["retryAfterCooldown"], workflowName, `phases[${i}].retryAfterCooldown`);
    if (retryAfterCooldown !== undefined) phase.retryAfterCooldown = retryAfterCooldown;
    if (p["cooldownSeconds"] !== undefined) {
      if (!isPositiveNumber(p["cooldownSeconds"])) throw new WorkflowConfigError(workflowName, `phases[${i}].cooldownSeconds must be a positive number`);
      phase.cooldownSeconds = p["cooldownSeconds"];
    }
    const builtin = parseOptionalBoolean(p["builtin"], workflowName, `phases[${i}].builtin`);
    if (builtin !== undefined) phase.builtin = builtin;
    if (p["bash"] !== undefined) {
      if (typeof p["bash"] !== "string" || !p["bash"].trim()) throw new WorkflowConfigError(workflowName, `phases[${i}].bash must be a non-empty string`);
      phase.bash = p["bash"];
    }
    if (p["command"] !== undefined) {
      if (typeof p["command"] !== "string" || !p["command"].trim()) throw new WorkflowConfigError(workflowName, `phases[${i}].command must be a non-empty string`);
      phase.command = p["command"];
    }

    if (p["tools"] !== undefined && !isRecord(p["tools"])) {
      throw new WorkflowConfigError(workflowName, `phases[${i}].tools must be an object`);
    }
    if (isRecord(p["tools"])) {
      const toolsRaw = p["tools"];
      const allowedRaw = toolsRaw["allowed"];
      if (allowedRaw !== undefined) {
        if (!Array.isArray(allowedRaw)) {
          throw new WorkflowConfigError(workflowName, `phases[${i}].tools.allowed must be an array of strings`);
        }
        const allowed = allowedRaw.map((tool, toolIndex) => {
          if (typeof tool !== "string" || !tool.trim()) {
            throw new WorkflowConfigError(workflowName, `phases[${i}].tools.allowed[${toolIndex}] must be a non-empty string`);
          }
          return tool;
        });
        phase.tools = { allowed };
      }
    }

    if (p["contract"] !== undefined && !isRecord(p["contract"])) {
      throw new WorkflowConfigError(workflowName, `phases[${i}].contract must be an object`);
    }
    if (isRecord(p["contract"])) {
      const c = p["contract"];
      phase.contract = {};
      if (c["goal"] !== undefined) {
        if (typeof c["goal"] !== "string" || !c["goal"].trim()) {
          throw new WorkflowConfigError(workflowName, `phases[${i}].contract.goal must be a non-empty string`);
        }
        phase.contract.goal = c["goal"];
      }
      if (c["requiredSections"] !== undefined) {
        if (!Array.isArray(c["requiredSections"])) {
          throw new WorkflowConfigError(workflowName, `phases[${i}].contract.requiredSections must be an array of strings`);
        }
        phase.contract.requiredSections = c["requiredSections"].map((section, sectionIndex) => {
          if (typeof section !== "string" || !section.trim()) {
            throw new WorkflowConfigError(workflowName, `phases[${i}].contract.requiredSections[${sectionIndex}] must be a non-empty string`);
          }
          return section;
        });
      }
      if (c["policy"] !== undefined && !isRecord(c["policy"])) {
        throw new WorkflowConfigError(workflowName, `phases[${i}].contract.policy must be an object`);
      }
      if (isRecord(c["policy"])) {
        const policyRaw = c["policy"];
        const policy: WorkflowPhaseContractPolicyConfig = {};
        for (const key of [
          "requiresExplorerReport",
          "explorerCircuitBreaker",
          "developerCompletion",
          "redPhaseCompletion",
          "acceptanceCoverage",
          "allowDeferredAcceptance",
          "testEvidence",
          "captureQaTarget",
          "finalizeValidation",
          "skipDeveloperRetryOnUnrelatedFinalizeFailure",
          "structuredFailureChecklist",
          "terminalOnFailExhausted",
        ] as const) {
          const policyValue = parseOptionalBoolean(policyRaw[key], workflowName, `phases[${i}].contract.policy.${key}`);
          if (policyValue !== undefined) policy[key] = policyValue;
        }
        if (Object.keys(policy).length > 0) phase.contract.policy = policy;
      }
      if (c["completion"] !== undefined && !isRecord(c["completion"])) {
        throw new WorkflowConfigError(workflowName, `phases[${i}].contract.completion must be an object`);
      }
      if (isRecord(c["completion"])) {
        const completion = c["completion"];
        phase.contract.completion = {};
        if (completion["minEditTargets"] !== undefined) {
          if (!isNonNegativeInteger(completion["minEditTargets"])) throw new WorkflowConfigError(workflowName, `phases[${i}].contract.completion.minEditTargets must be a non-negative integer`);
          phase.contract.completion.minEditTargets = completion["minEditTargets"];
        }
        if (completion["maxEditTargets"] !== undefined) {
          if (!isNonNegativeInteger(completion["maxEditTargets"])) throw new WorkflowConfigError(workflowName, `phases[${i}].contract.completion.maxEditTargets must be a non-negative integer`);
          phase.contract.completion.maxEditTargets = completion["maxEditTargets"];
        }
        if (phase.contract.completion.minEditTargets !== undefined && phase.contract.completion.maxEditTargets !== undefined && phase.contract.completion.maxEditTargets < phase.contract.completion.minEditTargets) {
          throw new WorkflowConfigError(workflowName, `phases[${i}].contract.completion.maxEditTargets must be greater than or equal to minEditTargets`);
        }
        const requireTestTargets = parseOptionalBoolean(completion["requireTestTargets"], workflowName, `phases[${i}].contract.completion.requireTestTargets`);
        if (requireTestTargets !== undefined) phase.contract.completion.requireTestTargets = requireTestTargets;
        const requireFilesChanged = parseOptionalBoolean(completion["requireFilesChanged"], workflowName, `phases[${i}].contract.completion.requireFilesChanged`);
        if (requireFilesChanged !== undefined) phase.contract.completion.requireFilesChanged = requireFilesChanged;
        const requireValidationNotes = parseOptionalBoolean(completion["requireValidationNotes"], workflowName, `phases[${i}].contract.completion.requireValidationNotes`);
        if (requireValidationNotes !== undefined) phase.contract.completion.requireValidationNotes = requireValidationNotes;
      }
      if (c["allowedScope"] !== undefined && !isRecord(c["allowedScope"])) {
        throw new WorkflowConfigError(workflowName, `phases[${i}].contract.allowedScope must be an object`);
      }
      if (isRecord(c["allowedScope"])) {
        const allowedScope = c["allowedScope"];
        phase.contract.allowedScope = {};
        const canRead = parseOptionalBoolean(allowedScope["canRead"], workflowName, `phases[${i}].contract.allowedScope.canRead`);
        if (canRead !== undefined) phase.contract.allowedScope.canRead = canRead;
        if (allowedScope["canWriteOnly"] !== undefined) {
          if (!Array.isArray(allowedScope["canWriteOnly"])) {
            throw new WorkflowConfigError(workflowName, `phases[${i}].contract.allowedScope.canWriteOnly must be an array of strings`);
          }
          phase.contract.allowedScope.canWriteOnly = allowedScope["canWriteOnly"].map((item, itemIndex) => {
            if (typeof item !== "string" || !item.trim()) {
              throw new WorkflowConfigError(workflowName, `phases[${i}].contract.allowedScope.canWriteOnly[${itemIndex}] must be a non-empty string`);
            }
            return item;
          });
        }
      }
    }

    if (p["overwatch"] !== undefined && !isRecord(p["overwatch"])) {
      throw new WorkflowConfigError(workflowName, `phases[${i}].overwatch must be an object`);
    }
    if (isRecord(p["overwatch"])) {
      const o = p["overwatch"];
      phase.overwatch = {};
      const overwatchEnabled = parseOptionalBoolean(o["enabled"], workflowName, `phases[${i}].overwatch.enabled`);
      if (overwatchEnabled !== undefined) phase.overwatch.enabled = overwatchEnabled;
      if (o["mode"] !== undefined) {
        if (o["mode"] !== "off" && o["mode"] !== "warn" && o["mode"] !== "enforce") throw new WorkflowConfigError(workflowName, `phases[${i}].overwatch.mode must be 'off', 'warn', or 'enforce'`);
        phase.overwatch.mode = o["mode"];
      }
      if (o["checkEveryTurns"] !== undefined) {
        if (!isPositiveNumber(o["checkEveryTurns"])) throw new WorkflowConfigError(workflowName, `phases[${i}].overwatch.checkEveryTurns must be a positive number`);
        phase.overwatch.checkEveryTurns = o["checkEveryTurns"];
      }
      const forceArtifactNearMaxTurns = parseOptionalBoolean(o["forceArtifactNearMaxTurns"], workflowName, `phases[${i}].overwatch.forceArtifactNearMaxTurns`);
      if (forceArtifactNearMaxTurns !== undefined) phase.overwatch.forceArtifactNearMaxTurns = forceArtifactNearMaxTurns;
      const continueIfArtifactValidOnBudgetStop = parseOptionalBoolean(o["continueIfArtifactValidOnBudgetStop"], workflowName, `phases[${i}].overwatch.continueIfArtifactValidOnBudgetStop`);
      if (continueIfArtifactValidOnBudgetStop !== undefined) phase.overwatch.continueIfArtifactValidOnBudgetStop = continueIfArtifactValidOnBudgetStop;
      for (const key of ["maxSteersPerPhase", "forceArtifactAfterSteers", "forceArtifactAfterToolCalls", "repeatedCommandLimit", "maxToolCalls"] as const) {
        if (o[key] !== undefined) {
          if (!isNonNegativeInteger(o[key])) throw new WorkflowConfigError(workflowName, `phases[${i}].overwatch.${key} must be a non-negative integer`);
          phase.overwatch[key] = o[key];
        }
      }
      if (o["blockedCommands"] !== undefined) {
        if (!Array.isArray(o["blockedCommands"])) throw new WorkflowConfigError(workflowName, `phases[${i}].overwatch.blockedCommands must be an array of strings`);
        phase.overwatch.blockedCommands = o["blockedCommands"].map((item, itemIndex) => {
          if (typeof item !== "string" || !item.trim()) throw new WorkflowConfigError(workflowName, `phases[${i}].overwatch.blockedCommands[${itemIndex}] must be a non-empty string`);
          return item;
        });
      }
    }

    // Exactly one of bash, command, or prompt must be set (unless builtin: true)
    const hasPrompt = typeof p["prompt"] === "string";
    const hasBash = typeof p["bash"] === "string";
    const hasCommand = typeof p["command"] === "string";
    const isBuiltin = typeof p["builtin"] === "boolean" && p["builtin"];
    const hasAction = typeof p["action"] === "string" && p["action"].trim().length > 0;
    const isWorkspaceAction = hasAction && WORKSPACE_ACTIONS.has(p["action"] as string);
    if (hasBash && hasPrompt) {
      throw new WorkflowConfigError(
        workflowName,
        `phases[${i}].${p["name"]} has both 'bash:' and 'prompt:' — only one is allowed`,
      );
    }
    if (hasBash && hasCommand) {
      throw new WorkflowConfigError(
        workflowName,
        `phases[${i}].${p["name"]} has both 'bash:' and 'command:' — only one is allowed`,
      );
    }
    if (hasCommand && hasPrompt) {
      throw new WorkflowConfigError(
        workflowName,
        `phases[${i}].${p["name"]} has both 'command:' and 'prompt:' — only one is allowed`,
      );
    }
    // builtin/action phases don't need a prompt/bash/command field. Unknown actions are resolved at runtime from .foreman/actions.
    if (!hasPrompt && !hasBash && !hasCommand && !isBuiltin && !hasAction && !isWorkspaceAction) {
      throw new WorkflowConfigError(
        workflowName,
        `phases[${i}].${p["name"]} must have one of 'prompt:', 'bash:', or 'command:'`,
      );
    }

    // Parse mail hooks
    if (p["mail"] !== undefined && !isRecord(p["mail"])) {
      throw new WorkflowConfigError(workflowName, `phases[${i}].mail must be an object`);
    }
    if (isRecord(p["mail"])) {
      const m = p["mail"];
      phase.mail = {};
      const onStart = parseOptionalBoolean(m["onStart"], workflowName, `phases[${i}].mail.onStart`);
      if (onStart !== undefined) phase.mail.onStart = onStart;
      const onComplete = parseOptionalBoolean(m["onComplete"], workflowName, `phases[${i}].mail.onComplete`);
      if (onComplete !== undefined) phase.mail.onComplete = onComplete;
      if (m["onFail"] !== undefined) {
        if (typeof m["onFail"] !== "string" || !m["onFail"].trim()) throw new WorkflowConfigError(workflowName, `phases[${i}].mail.onFail must be a non-empty string`);
        phase.mail.onFail = m["onFail"];
      }
      if (m["forwardArtifactTo"] !== undefined) {
        if (typeof m["forwardArtifactTo"] !== "string" || !m["forwardArtifactTo"].trim()) throw new WorkflowConfigError(workflowName, `phases[${i}].mail.forwardArtifactTo must be a non-empty string`);
        phase.mail.forwardArtifactTo = m["forwardArtifactTo"];
      }
    }

    // Parse file reservation config
    if (p["files"] !== undefined && !isRecord(p["files"])) {
      throw new WorkflowConfigError(workflowName, `phases[${i}].files must be an object`);
    }
    if (isRecord(p["files"])) {
      const f = p["files"];
      phase.files = {};
      const reserve = parseOptionalBoolean(f["reserve"], workflowName, `phases[${i}].files.reserve`);
      if (reserve !== undefined) phase.files.reserve = reserve;
      if (f["leaseSecs"] !== undefined) {
        if (!isPositiveNumber(f["leaseSecs"])) throw new WorkflowConfigError(workflowName, `phases[${i}].files.leaseSecs must be a positive number`);
        phase.files.leaseSecs = f["leaseSecs"];
      }
    }

    phases.push(phase);
  }

  if (phases.length === 0) {
    throw new WorkflowConfigError(workflowName, "phases array must not be empty");
  }

  const phaseNames = new Set<string>();
  for (const phase of phases) {
    if (phaseNames.has(phase.name)) {
      throw new WorkflowConfigError(workflowName, `duplicate phase name '${phase.name}'`);
    }
    phaseNames.add(phase.name);
  }
  for (const phase of phases) {
    if (phase.retryWith && !phaseNames.has(phase.retryWith)) {
      throw new WorkflowConfigError(workflowName, `phase '${phase.name}' retryWith references unknown phase '${phase.retryWith}'`);
    }
    if (phase.mail?.onFail && !phaseNames.has(phase.mail.onFail)) {
      throw new WorkflowConfigError(workflowName, `phase '${phase.name}' mail.onFail references unknown phase '${phase.mail.onFail}'`);
    }
    if (phase.mail?.forwardArtifactTo && phase.mail.forwardArtifactTo !== "foreman" && !phaseNames.has(phase.mail.forwardArtifactTo)) {
      throw new WorkflowConfigError(workflowName, `phase '${phase.name}' mail.forwardArtifactTo references unknown phase '${phase.mail.forwardArtifactTo}'`);
    }
  }

  const config: WorkflowConfig = { name, phases };
  if (setup !== undefined) config.setup = setup;
  if (setupCache !== undefined) config.setupCache = setupCache;
  if (taskType !== undefined) config.taskType = taskType;

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
  if (raw["onFailure"] !== undefined && !isRecord(raw["onFailure"])) {
    throw new WorkflowConfigError(workflowName, "onFailure must be an object");
  }
  if (isRecord(raw["onFailure"])) {
    const of_ = raw["onFailure"];
    if (typeof of_["name"] !== "string" || !of_["name"].trim()) {
      throw new WorkflowConfigError(workflowName, "onFailure.name must be a non-empty string");
    }
    if (!isSafeActionName(of_["name"])) {
      throw new WorkflowConfigError(workflowName, "onFailure.name must be a safe phase name");
    }
    if (of_["prompt"] !== undefined && (typeof of_["prompt"] !== "string" || !of_["prompt"].trim())) {
      throw new WorkflowConfigError(workflowName, "onFailure.prompt must be a non-empty string");
    }
    const onFailure: OnFailureConfig = {
      name: of_["name"],
      prompt: typeof of_["prompt"] === "string" ? of_["prompt"] : `${of_["name"]}.md`,
    };
    if (of_["maxTurns"] !== undefined) {
      if (!isPositiveNumber(of_["maxTurns"])) throw new WorkflowConfigError(workflowName, "onFailure.maxTurns must be a positive number");
      onFailure.maxTurns = of_["maxTurns"];
    }
    if (of_["artifact"] !== undefined) {
      if (typeof of_["artifact"] !== "string" || !of_["artifact"].trim()) throw new WorkflowConfigError(workflowName, "onFailure.artifact must be a non-empty string");
      onFailure.artifact = of_["artifact"];
    }
    const onFailureModels = parseModelsMap(of_["models"], workflowName, "onFailure.models");
    if (onFailureModels) onFailure.models = onFailureModels;
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
      if (taskPhases.includes(pName)) {
        throw new WorkflowConfigError(workflowName, `taskPhases[${j}] duplicates phase '${pName}'`);
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
      if (finalPhases.includes(pName)) {
        throw new WorkflowConfigError(workflowName, `finalPhases[${j}] duplicates phase '${pName}'`);
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
    if (!isPositiveNumber(raw["taskTimeout"])) {
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

  // ── Parse optional merge strategy ────────────────────────────────────────
  if (raw["merge"] !== undefined) {
    const merge = raw["merge"];
    if (merge === "auto" || merge === "pr" || merge === "none") {
      config.merge = merge;
    } else {
      throw new WorkflowConfigError(
        workflowName,
        `merge must be 'auto', 'pr', or 'none' (got: ${String(merge)})`,
      );
    }
  }

  // ── Parse optional pr.timing ───────────────────────────────────────────
  if (raw["pr"] !== undefined && !isRecord(raw["pr"])) {
    throw new WorkflowConfigError(workflowName, "pr must be an object");
  }
  if (isRecord(raw["pr"])) {
    const prRaw = raw["pr"];
    config.pr = {};
    config.pr.timing = "create-at-finalize";
    if (prRaw["timing"] !== undefined) {
      if (typeof prRaw["timing"] !== "string" || !prRaw["timing"].trim()) {
        throw new WorkflowConfigError(workflowName, "pr.timing must be a non-empty string");
      }
      const timing = prRaw["timing"];
      if (timing === "draft-after-developer" || timing === "create-at-finalize" || timing === "never") {
        config.pr.timing = timing;
      } else {
        throw new WorkflowConfigError(
          workflowName,
          `pr.timing must be 'draft-after-developer', 'create-at-finalize', or 'never' (got: ${timing})`,
        );
      }
    }
  }

  // ── Parse optional sandbox block (Backlog-011: Container Sandboxing) ───
  if ("sandbox" in raw && !isRecord(raw["sandbox"])) {
    throw new WorkflowConfigError(workflowName, "'sandbox' must be an object");
  }

  if (isRecord(raw["sandbox"])) {
    const sandboxRaw = raw["sandbox"];
    const sandboxConfig: WorkflowSandboxConfig = {};

    if ("backend" in sandboxRaw) {
      const backend = sandboxRaw["backend"];
      if (backend !== undefined && backend !== "docker" && backend !== "podman" && backend !== "auto") {
        throw new WorkflowConfigError(
          workflowName,
          `'sandbox.backend' must be 'docker', 'podman', or 'auto' (got: ${String(backend)})`,
        );
      }
      sandboxConfig.backend = backend as "docker" | "podman" | "auto" | undefined;
    }

    if ("image" in sandboxRaw) {
      if (typeof sandboxRaw["image"] !== "string" || !sandboxRaw["image"].trim()) {
        throw new WorkflowConfigError(workflowName, "'sandbox.image' must be a non-empty string");
      }
      sandboxConfig.image = sandboxRaw["image"] as string;
    }

    if ("limits" in sandboxRaw && !isRecord(sandboxRaw["limits"])) {
      throw new WorkflowConfigError(workflowName, "'sandbox.limits' must be an object");
    }

    if (isRecord(sandboxRaw["limits"])) {
      const limitsRaw = sandboxRaw["limits"];
      sandboxConfig.limits = {};
      if ("cpu" in limitsRaw && (typeof limitsRaw["cpu"] !== "string" || !limitsRaw["cpu"].trim())) {
        throw new WorkflowConfigError(workflowName, "'sandbox.limits.cpu' must be a non-empty string");
      }
      sandboxConfig.limits.cpu = limitsRaw["cpu"] as string | undefined;
      if ("memory" in limitsRaw && (typeof limitsRaw["memory"] !== "string" || !limitsRaw["memory"].trim())) {
        throw new WorkflowConfigError(workflowName, "'sandbox.limits.memory' must be a non-empty string");
      }
      sandboxConfig.limits.memory = limitsRaw["memory"] as string | undefined;
      if ("cpuset" in limitsRaw && (typeof limitsRaw["cpuset"] !== "string" || !limitsRaw["cpuset"].trim())) {
        throw new WorkflowConfigError(workflowName, "'sandbox.limits.cpuset' must be a non-empty string");
      }
      sandboxConfig.limits.cpuset = limitsRaw["cpuset"] as string | undefined;
      if ("memorySwap" in limitsRaw && (typeof limitsRaw["memorySwap"] !== "string" || !limitsRaw["memorySwap"].trim())) {
        throw new WorkflowConfigError(workflowName, "'sandbox.limits.memorySwap' must be a non-empty string");
      }
      sandboxConfig.limits.memorySwap = limitsRaw["memorySwap"] as string | undefined;
    }

    if ("network" in sandboxRaw && typeof sandboxRaw["network"] !== "boolean") {
      throw new WorkflowConfigError(workflowName, "'sandbox.network' must be a boolean");
    }
    sandboxConfig.network = sandboxRaw["network"] as boolean | undefined;

    if ("cleanup" in sandboxRaw) {
      const cleanup = sandboxRaw["cleanup"];
      if (cleanup !== undefined && cleanup !== "remove" && cleanup !== "keep") {
        throw new WorkflowConfigError(
          workflowName,
          `'sandbox.cleanup' must be 'remove' or 'keep' (got: ${String(cleanup)})`,
        );
      }
      sandboxConfig.cleanup = cleanup as "remove" | "keep" | undefined;
    }

    config.sandbox = sandboxConfig;

    const hostPhases = config.phases.filter((phase) => !phase.bash).map((phase) => phase.name);
    if (hostPhases.length > 0) {
      throw new WorkflowConfigError(
        workflowName,
        `sandbox is only supported for bash phases; host-executed phases are not isolated: ${hostPhases.join(", ")}`,
      );
    }
  }

  return config;
}

// ── Loader ────────────────────────────────────────────────────────────────────

function findWorkflowFileInDir(dir: string, workflowName: string): string | null {
  if (!isSafeWorkflowName(workflowName)) return null;
  const yamlPath = join(dir, `${workflowName}.yaml`);
  if (existsSync(yamlPath)) return yamlPath;
  const ymlPath = join(dir, `${workflowName}.yml`);
  if (existsSync(ymlPath)) return ymlPath;
  return null;
}

/**
 * Load and validate a workflow config.
 *
 * Resolution order:
 *   1. Explicit absolute or project-relative YAML path
 *   2. .foreman/workflows/{name}.yaml                (project override)
 *   3. ~/.foreman/workflows/{name}.yaml              (global override)
 *   4. Bundled default: src/defaults/workflows/{name}.yaml
 *
 * @param workflowName - Workflow name (e.g. "default", "smoke").
 * @param projectRoot  - Absolute path to the project root.
 * @throws WorkflowConfigError if not found or invalid.
 */
export function loadWorkflowConfig(
  workflowName: string,
  projectRoot: string,
): WorkflowConfig {
  const directPath = workflowName.endsWith(".yaml") || workflowName.endsWith(".yml")
    ? isAbsolute(workflowName) ? workflowName : resolve(projectRoot, workflowName)
    : null;
  if (directPath && !isAbsolute(workflowName) && !staysWithinDir(projectRoot, directPath)) {
    throw new WorkflowConfigError(workflowName, "workflow path must stay within the project root");
  }
  if (!directPath && !isSafeWorkflowName(workflowName)) {
    throw new WorkflowConfigError(workflowName, "unsafe workflow name");
  }
  if (directPath && existsSync(directPath)) {
    try {
      const raw = yamlLoad(readFileSync(directPath, "utf-8"));
      return { ...validateWorkflowConfig(raw, workflowName), sourcePath: directPath };
    } catch (err) {
      if (err instanceof WorkflowConfigError) throw err;
      const msg = err instanceof Error ? err.message : String(err);
      throw new WorkflowConfigError(workflowName, `failed to parse ${directPath}: ${msg}`);
    }
  }

  // Tier 1: project override
  const projectPath = projectRoot ? findWorkflowFileInDir(join(projectRoot, ".foreman", "workflows"), workflowName) : null;
  if (projectPath) {
    try {
      const raw = yamlLoad(readFileSync(projectPath, "utf-8"));
      return { ...validateWorkflowConfig(raw, workflowName), sourcePath: projectPath };
    } catch (err) {
      if (err instanceof WorkflowConfigError) throw err;
      const msg = err instanceof Error ? err.message : String(err);
      throw new WorkflowConfigError(workflowName, `failed to parse ${projectPath}: ${msg}`);
    }
  }

  // Tier 2: global override
  const globalPath = findWorkflowFileInDir(getForemanHomePath("workflows"), workflowName) ?? getForemanHomePath("workflows", `${workflowName}.yaml`);
  if (existsSync(globalPath)) {
    try {
      const raw = yamlLoad(readFileSync(globalPath, "utf-8"));
      return { ...validateWorkflowConfig(raw, workflowName), sourcePath: globalPath };
    } catch (err) {
      if (err instanceof WorkflowConfigError) throw err;
      const msg = err instanceof Error ? err.message : String(err);
      throw new WorkflowConfigError(workflowName, `failed to parse ${globalPath}: ${msg}`);
    }
  }

  // Tier 3: bundled default
  const bundledPath = join(BUNDLED_WORKFLOWS_DIR, `${workflowName}.yaml`);
  if (existsSync(bundledPath)) {
    try {
      const raw = yamlLoad(readFileSync(bundledPath, "utf-8"));
      return { ...validateWorkflowConfig(raw, workflowName), sourcePath: bundledPath };
    } catch (err) {
      if (err instanceof WorkflowConfigError) throw err;
      const msg = err instanceof Error ? err.message : String(err);
      throw new WorkflowConfigError(workflowName, `failed to parse bundled default ${bundledPath}: ${msg}`);
    }
  }

  throw new WorkflowConfigError(
    workflowName,
    `no workflow config found at ${projectPath ?? "<no project>"}, ${globalPath}, or bundled defaults`,
  );
}

/**
 * Get the path to a bundled workflow YAML file.
 *
 * @returns Absolute path, or null if not found.
 */
export function getBundledWorkflowPath(workflowName: string): string | null {
  if (!isSafeWorkflowName(workflowName)) return null;
  const p = join(BUNDLED_WORKFLOWS_DIR, `${workflowName}.yaml`);
  return existsSync(p) ? p : null;
}

/**
 * Returns true when a workflow YAML exists in project .foreman/workflows/,
 * ~/.foreman/workflows/, or bundled defaults.
 */
export function hasWorkflowConfig(workflowName: string, projectRoot?: string): boolean {
  const projectPath = projectRoot ? findWorkflowFileInDir(join(projectRoot, ".foreman", "workflows"), workflowName) : null;
  const globalPath = findWorkflowFileInDir(getForemanHomePath("workflows"), workflowName);
  return projectPath !== null || globalPath !== null || getBundledWorkflowPath(workflowName) !== null;
}

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
export function installBundledWorkflows(
  _projectRoot: string,
  force: boolean = false,
): { installed: string[]; skipped: string[] } {
  const installed: string[] = [];
  const skipped: string[] = [];

  const destDir = getForemanHomePath("workflows");
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
 * List all workflow names available to the loader: bundled defaults plus any
 * YAML files installed in ~/.foreman/workflows/ and, when projectRoot is provided,
 * .foreman/workflows/. Sorted and deduplicated.
 */
export function listBundledWorkflowNames(): string[] {
  try {
    return readdirSync(BUNDLED_WORKFLOWS_DIR)
      .filter((file) => file.endsWith(".yaml") || file.endsWith(".yml"))
      .map((file) => file.replace(/\.ya?ml$/, ""))
      .sort();
  } catch {
    return [...BUNDLED_WORKFLOW_NAMES].sort();
  }
}

export function listAvailableWorkflows(projectRoot?: string): string[] {
  const names = new Set<string>();

  if (projectRoot) {
    try {
      for (const file of readdirSync(join(projectRoot, ".foreman", "workflows"))) {
        if (file.endsWith(".yaml") || file.endsWith(".yml")) {
          names.add(file.replace(/\.ya?ml$/, ""));
        }
      }
    } catch {
      // project .foreman/workflows/ not created yet — non-fatal
    }
  }

  try {
    for (const file of readdirSync(BUNDLED_WORKFLOWS_DIR)) {
      if (file.endsWith(".yaml") || file.endsWith(".yml")) {
        names.add(file.replace(/\.ya?ml$/, ""));
      }
    }
  } catch {
    // Bundled workflows directory missing (e.g. partial install) — non-fatal
  }

  try {
    for (const file of readdirSync(getForemanHomePath("workflows"))) {
      if (file.endsWith(".yaml") || file.endsWith(".yml")) {
        names.add(file.replace(/\.ya?ml$/, ""));
      }
    }
  } catch {
    // ~/.foreman/workflows/ not created yet — non-fatal
  }

  return [...names].sort();
}

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
export function ensureBundledWorkflowsInstalled(projectRoot: string): string[] {
  try {
    installBundledWorkflows(projectRoot, false);
  } catch {
    // Install failure (e.g. read-only home) — fall through to report missing
  }
  return findMissingWorkflows(projectRoot);
}

/**
 * Find missing workflow config files for a project.
 *
 * @param projectRoot - Absolute path to the project root.
 * @returns Array of missing workflow names (e.g. ["default", "smoke"]).
 */
export function findMissingWorkflows(_projectRoot: string): string[] {
  const missing: string[] = [];
  for (const name of BUNDLED_WORKFLOW_NAMES) {
    const p = getForemanHomePath("workflows", `${name}.yaml`);
    if (!existsSync(p)) {
      missing.push(name);
    }
  }
  return missing;
}

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
export function findStaleWorkflows(_projectRoot: string): string[] {
  const stale: string[] = [];
  for (const name of BUNDLED_WORKFLOW_NAMES) {
    const localPath = getForemanHomePath("workflows", `${name}.yaml`);
    if (!existsSync(localPath)) continue; // missing, not stale

    const bundledPath = join(BUNDLED_WORKFLOWS_DIR, `${name}.yaml`);
    if (!existsSync(bundledPath)) continue; // no bundled reference to compare against

    try {
      const localRaw = yamlLoad(readFileSync(localPath, "utf-8")) as {
        phases?: Array<{ name: string; [k: string]: unknown }>;
        [k: string]: unknown;
      };
      const bundledRaw = yamlLoad(readFileSync(bundledPath, "utf-8")) as {
        phases?: Array<{ name: string; [k: string]: unknown }>;
        [k: string]: unknown;
      };

      if (bundledRaw?.["task_type"] !== undefined && localRaw?.["task_type"] !== bundledRaw["task_type"]) {
        stale.push(name);
        continue;
      }

      if (!Array.isArray(localRaw?.phases) || !Array.isArray(bundledRaw?.phases)) continue;

      // Build a map from phase name → phase config for the local file
      const localPhaseMap = new Map<string, Record<string, unknown>>();
      for (const p of localRaw.phases) {
        if (typeof p.name === "string") {
          localPhaseMap.set(p.name, p as Record<string, unknown>);
        }
      }

      // Check each bundled verdict-phase exists locally with the required fields
      let isStale = false;
      for (const bundledPhase of bundledRaw.phases) {
        if (typeof bundledPhase.name !== "string") continue;
        if (bundledPhase["verdict"] !== true) continue; // only check verdict phases

        const localPhase = localPhaseMap.get(bundledPhase.name);
        if (!localPhase) {
          isStale = true;
          break;
        }

        // Stale if local phase is missing verdict, retryWith, or retryOnFail
        // that the bundled version defines
        if (
          (bundledPhase["verdict"] === true && localPhase["verdict"] !== true) ||
          (bundledPhase["retryWith"] !== undefined && localPhase["retryWith"] === undefined) ||
          (bundledPhase["retryOnFail"] !== undefined && localPhase["retryOnFail"] === undefined)
        ) {
          isStale = true;
          break;
        }
      }

      if (isStale) stale.push(name);
    } catch {
      // Parse error in local or bundled file — skip, let checkWorkflows handle it
    }
  }
  return stale;
}

/**
 * Result of task type uniqueness validation.
 */
export interface TaskTypeUniquenessResult {
  /** True when no duplicate task type declarations exist. */
  valid: boolean;
  /**
   * List of task types declared by multiple workflows.
   * Each entry includes the task type name and the conflicting workflow names.
   */
  duplicates: Array<{ taskType: string; workflows: string[] }>;
}

/**
 * Build a reverse map from task types to workflow names by loading all
 * available workflows and collecting their `taskType` declarations.
 *
 * Only workflows that declare a `task_type` are included in the map.
 * The map is built fresh each call — callers should cache or pass the result
 * if performance is a concern.
 *
 * @returns Map of `taskType → workflowName` for workflows that declare `task_type`.
 */
function collectTaskTypeDeclarations(projectRoot?: string): Map<string, string[]> {
  const result = new Map<string, string[]>();

  for (const workflowName of listAvailableWorkflows(projectRoot)) {
    try {
      const config = loadWorkflowConfig(workflowName, projectRoot ?? "");
      if (!config.taskType) continue;
      const workflows = result.get(config.taskType) ?? [];
      workflows.push(config.name);
      result.set(config.taskType, workflows);
    } catch {
      // Workflow not loadable (e.g. malformed YAML) — skip. Parse errors are
      // surfaced by normal workflow loading/doctor checks.
    }
  }

  return result;
}

export function buildTaskTypeWorkflowMap(projectRoot?: string): Map<string, string> {
  const result = new Map<string, string>();

  for (const [taskType, workflows] of collectTaskTypeDeclarations(projectRoot)) {
    if (workflows.length === 1) {
      result.set(taskType, workflows[0]!);
    }
  }

  return result;
}

/**
 * Validate that no two workflows declare the same `task_type`.
 *
 * On a clean install (each workflow declares a unique task type), returns
 * `{ valid: true, duplicates: [] }`.
 *
 * When duplicates exist, returns `{ valid: false, duplicates: [...] }` where
 * each entry lists all workflows that declared the conflicting task type.
 *
 * @returns Validation result describing any duplicate task type declarations.
 */
export function validateTaskTypeUniqueness(projectRoot?: string): TaskTypeUniquenessResult {
  const duplicates: Array<{ taskType: string; workflows: string[] }> = [];

  for (const [taskType, workflows] of collectTaskTypeDeclarations(projectRoot)) {
    if (workflows.length > 1) {
      duplicates.push({ taskType, workflows: [...workflows].sort() });
    }
  }

  return { valid: duplicates.length === 0, duplicates };
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
/**
 * Resolve the workflow name for a seed/bead.
 *
 * Resolution order:
 *  1. `workflowOverride` — explicit override (e.g. `foreman run --workflow <name>`)
 *  2. `workflow:<name>` label on the task
 *  3. `taskTypeWorkflowMap[seedType]` — explicit config mapping
 *  4. `taskTypeWorkflowMap["default"]` — fallback for unknown types
 *  5. `{seedType}.yaml` in project/global/bundled workflows
 *  6. "default" (hard fallback)
 *
 * When `taskTypeWorkflowMap` is not provided (undefined), steps 3–4 are skipped
 * and the resolution falls back to the file-existence check (backward compatible).
 *
 * The explicit override is trusted as-is — callers (the CLI) validate it
 * against loadable workflows before dispatch.
 */
export function resolveWorkflowName(
  seedType: string,
  labels?: string[],
  taskTypeWorkflowMap?: Record<string, string>,
  workflowOverride?: string,
  workflowDeclaredMap?: Record<string, string>,
  projectRoot?: string,
): string {
  // 0. Explicit override (e.g. `foreman run --workflow quick`) — top priority
  const override = workflowOverride?.trim();
  if (override) {
    return override;
  }

  // 1. workflow:<name> label override
  if (labels) {
    for (const label of labels) {
      if (label.startsWith("workflow:")) {
        return label.slice("workflow:".length);
      }
    }
  }

  // 2. Workflow-declared task_type mapping. An explicitly provided map is used
  // by tests/callers that already loaded workflows; otherwise build it from the
  // available workflow YAML files.
  const declaredWorkflow = workflowDeclaredMap?.[seedType] ?? buildTaskTypeWorkflowMap(projectRoot).get(seedType);
  if (declaredWorkflow && hasWorkflowConfig(declaredWorkflow, projectRoot)) {
    return declaredWorkflow;
  }

  // 3. Explicit taskTypeWorkflowMap mapping remains a compatibility fallback.
  if (taskTypeWorkflowMap) {
    const mappedWorkflow = taskTypeWorkflowMap[seedType];
    if (mappedWorkflow && hasWorkflowConfig(mappedWorkflow, projectRoot)) {
      return mappedWorkflow;
    }
    // 4. Default fallback from config mapping
    const defaultWorkflow = taskTypeWorkflowMap["default"];
    if (defaultWorkflow && hasWorkflowConfig(defaultWorkflow, projectRoot)) {
      return defaultWorkflow;
    }
  }

  // 5. File-existence fallback (backward compatible with pre-config behavior)
  if (seedType && hasWorkflowConfig(seedType, projectRoot)) {
    return seedType;
  }

  // 5. Hard fallback to default
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
  MiniMax: "minimax/MiniMax-M2.7",
  "MiniMax-highspeed": "minimax/MiniMax-M2.7-highspeed",
  gpt5: "openai/gpt-5.2-chat-latest",
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
