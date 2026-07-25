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

import {
  readFileSync,
  existsSync,
  mkdirSync,
  copyFileSync,
  readdirSync,
} from "node:fs";
import { join, dirname, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";
import { load as yamlLoad } from "js-yaml";
import { getForemanHomePath } from "./foreman-paths.js";
import type { SandboxConfig } from "./project-config.js";

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
   * Optional failure-reason routing map. Keys are reason prefixes or `/regex/`
   * strings; values are retry phase names. Falls back to retryWith.
   */
  retryWithByReason?: Record<string, string>;
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
  /** When true, successful dirty phases checkpoint work to a draft PR. */
  checkpointPr?: boolean;
  /**
   * When set, the pipeline executor runs `vcs.rebase(onto)` against the
   * worktree after this phase completes successfully and before the next
   * phase dispatches. The value is passed directly as the `onto` argument
   * to `VcsBackend.rebase()`.
   *
   * @example rebaseAfterPhase: "origin/dev"
   */
  rebaseAfterPhase?: string;
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
   * continues when any task ends in a non-merged terminal failure state
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

const BUNDLED_WORKFLOW_ORDER: Record<string, number> = {
  default: 0,
  smoke: 1,
  epic: 2,
  bug: 3,
  task: 4,
  feature: 5,
};

function listBundledWorkflowNames(): string[] {
  try {
    const names = readdirSync(BUNDLED_WORKFLOWS_DIR)
      .filter((file) => file.endsWith(".yaml") || file.endsWith(".yml"))
      .map((file) => file.replace(/\.ya?ml$/, ""));
    return names.sort(
      (a, b) =>
        (BUNDLED_WORKFLOW_ORDER[a] ?? Number.MAX_SAFE_INTEGER) -
          (BUNDLED_WORKFLOW_ORDER[b] ?? Number.MAX_SAFE_INTEGER) || a.localeCompare(b),
    );
  } catch {
    return [];
  }
}

/** Workflow names currently present in src/defaults/workflows. */
export const BUNDLED_WORKFLOW_NAMES: ReadonlyArray<string> = listBundledWorkflowNames();

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

export type DerivedMergeStrategy = "auto" | "none";

export function deriveMergeStrategyFromPhases(config: Pick<WorkflowConfig, "phases">): DerivedMergeStrategy {
  return config.phases.some((phase) => phase.name === "merge") ? "auto" : "none";
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

  // ── Parse optional task_type declaration ──────────────────────────────────
  const taskType = typeof raw["task_type"] === "string" && raw["task_type"].trim()
    ? raw["task_type"].trim()
    : undefined;

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
    if (typeof p["timeoutSecs"] === "number") phase.timeoutSecs = p["timeoutSecs"];
    if (typeof p["skipIfArtifact"] === "string") phase.skipIfArtifact = p["skipIfArtifact"];
    if (typeof p["retryOnly"] === "boolean") phase.retryOnly = p["retryOnly"];
    if (typeof p["artifact"] === "string") phase.artifact = p["artifact"];
    if (typeof p["verdict"] === "boolean") phase.verdict = p["verdict"];
    if (typeof p["retryWith"] === "string") phase.retryWith = p["retryWith"];
    if (isRecord(p["retryWithByReason"])) {
      const routing: Record<string, string> = {};
      for (const [key, value] of Object.entries(p["retryWithByReason"])) {
        if (typeof value === "string") routing[key] = value;
      }
      if (Object.keys(routing).length > 0) phase.retryWithByReason = routing;
    }
    if (typeof p["retryOnFail"] === "number") phase.retryOnFail = p["retryOnFail"];
    if (typeof p["retryAfterCooldown"] === "boolean") phase.retryAfterCooldown = p["retryAfterCooldown"];
    if (typeof p["cooldownSeconds"] === "number") phase.cooldownSeconds = p["cooldownSeconds"];
    if (typeof p["builtin"] === "boolean") phase.builtin = p["builtin"];
    if (p["checkpointPr"] === true) phase.checkpointPr = true;
    if (typeof p["rebaseAfterPhase"] === "string") phase.rebaseAfterPhase = p["rebaseAfterPhase"];
    if (typeof p["bash"] === "string") phase.bash = p["bash"];
    if (typeof p["command"] === "string") phase.command = p["command"];

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

    // Exactly one of bash, command, or prompt must be set (unless builtin: true)
    const hasPrompt = typeof p["prompt"] === "string";
    const hasBash = typeof p["bash"] === "string";
    const hasCommand = typeof p["command"] === "string";
    const isBuiltin = typeof p["builtin"] === "boolean" && p["builtin"];
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
    // builtin: true phases don't need a prompt/bash/command field
    if (!hasPrompt && !hasBash && !hasCommand && !isBuiltin) {
      throw new WorkflowConfigError(
        workflowName,
        `phases[${i}].${p["name"]} must have one of 'prompt:', 'bash:', or 'command:'`,
      );
    }

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

  if (raw["merge"] !== undefined) {
    throw new WorkflowConfigError(workflowName, "top-level 'merge' is no longer supported; use explicit create-pr/pr-wait/merge phases");
  }
  if (raw["pr"] !== undefined) {
    throw new WorkflowConfigError(workflowName, "top-level 'pr' is no longer supported; use explicit create-pr/pr-wait phases");
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
export function loadWorkflowConfig(
  workflowName: string,
  projectRoot: string,
): WorkflowConfig {
  const directPath = workflowName.endsWith(".yaml") || workflowName.endsWith(".yml")
    ? isAbsolute(workflowName) ? workflowName : join(projectRoot, workflowName)
    : null;
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

  // Tier 1: global override
  const globalPath = getForemanHomePath("workflows", `${workflowName}.yaml`);
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

  // Tier 2: bundled default
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
    `no workflow config found at ${globalPath} or bundled defaults`,
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
 * Returns true when a workflow YAML exists either in ~/.foreman/workflows/
 * or in the bundled defaults directory.
 */
export function hasWorkflowConfig(workflowName: string): boolean {
  const globalPath = getForemanHomePath("workflows", `${workflowName}.yaml`);
  return existsSync(globalPath) || getBundledWorkflowPath(workflowName) !== null;
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
 * YAML files installed in ~/.foreman/workflows/. Sorted and deduplicated.
 */
export function listAvailableWorkflows(): string[] {
  const names = new Set<string>();

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
 * preflight so newly added bundled workflow files are installed on the fly
 * instead of blocking dispatch for existing installs.
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
 * Find locally installed workflow configs that differ from bundled defaults.
 *
 * A workflow is considered stale when the installed YAML content does not match
 * the bundled version. Operators must run `foreman init --force` after editing
 * source workflows/prompts so runtime dispatch uses the intended lifecycle.
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
      const localRaw = readFileSync(localPath, "utf-8").trimEnd();
      const bundledRaw = readFileSync(bundledPath, "utf-8").trimEnd();
      if (localRaw !== bundledRaw) stale.push(name);
    } catch {
      // Parse/read error in local or bundled file — skip, let checkWorkflows handle it
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
function collectTaskTypeDeclarations(): Map<string, string[]> {
  const result = new Map<string, string[]>();

  for (const workflowName of listAvailableWorkflows()) {
    try {
      const config = loadWorkflowConfig(workflowName, "");
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

export function buildTaskTypeWorkflowMap(): Map<string, string> {
  const result = new Map<string, string>();

  for (const [taskType, workflows] of collectTaskTypeDeclarations()) {
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
export function validateTaskTypeUniqueness(): TaskTypeUniquenessResult {
  const duplicates: Array<{ taskType: string; workflows: string[] }> = [];

  for (const [taskType, workflows] of collectTaskTypeDeclarations()) {
    if (workflows.length > 1) {
      duplicates.push({ taskType, workflows: [...workflows].sort() });
    }
  }

  return { valid: duplicates.length === 0, duplicates };
}

/**
 * Resolve the workflow name for a task.
 *
 * Resolution order:
 *  1. `workflowOverride` — explicit override (e.g. `foreman run --workflow <name>`)
 *  2. `workflow:<name>` label on the task
 *  3. Workflow YAML `task_type` declarations
 *  4. `taskTypeWorkflowMap[taskType]` — explicit config mapping
 *  5. `taskTypeWorkflowMap["default"]` — fallback for unknown types
 *  6. `{taskType}.yaml` in global (~/.foreman/workflows/) or bundled workflows
 *  7. "default" (hard fallback)
 *
 * When `taskTypeWorkflowMap` is not provided (undefined), steps 4–5 are skipped
 * and the resolution falls back to workflow declarations/file-existence checks.
 *
 * The explicit override is trusted as-is — callers (the CLI) validate it
 * against loadable workflows before dispatch.
 */
export function resolveWorkflowName(
  taskType: string,
  labels?: string[],
  taskTypeWorkflowMap?: Record<string, string>,
  workflowOverride?: string,
  workflowDeclaredMap?: Record<string, string>,
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
  const declaredWorkflow = workflowDeclaredMap?.[taskType] ?? buildTaskTypeWorkflowMap().get(taskType);
  if (declaredWorkflow && hasWorkflowConfig(declaredWorkflow)) {
    return declaredWorkflow;
  }

  // 3. Explicit taskTypeWorkflowMap mapping remains a compatibility fallback.
  if (taskTypeWorkflowMap) {
    const mappedWorkflow = taskTypeWorkflowMap[taskType];
    if (mappedWorkflow && hasWorkflowConfig(mappedWorkflow)) {
      return mappedWorkflow;
    }
    // 4. Default fallback from config mapping
    const defaultWorkflow = taskTypeWorkflowMap["default"];
    if (defaultWorkflow && hasWorkflowConfig(defaultWorkflow)) {
      return defaultWorkflow;
    }
  }

  // 5. File-existence fallback (backward compatible with pre-config behavior)
  if (taskType) {
    const globalPath = getForemanHomePath("workflows", `${taskType}.yaml`);
    if (existsSync(globalPath)) {
      return taskType;
    }
    const bundledPath = join(BUNDLED_WORKFLOWS_DIR, `${taskType}.yaml`);
    if (existsSync(bundledPath)) {
      return taskType;
    }
  }

  // 6. Hard fallback to default
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
 * @param priorityStr   - Task priority string ("P0"–"P4", "0"–"4", or undefined).
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
