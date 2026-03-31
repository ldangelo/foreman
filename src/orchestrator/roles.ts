/**
 * Agent role definitions and prompt templates for the specialization pipeline.
 *
 * Pipeline: Explorer → Developer → QA → Reviewer
 * Each sub-agent runs as a separate SDK query() call, sequentially in the
 * same worktree. Communication is via report files (EXPLORER_REPORT.md, etc).
 */

import type { AgentRole, ModelSelection } from "./types.js";

/** Permission mode for DCG (Destructive Command Guard). */
type PermissionMode = "default" | "acceptEdits" | "bypassPermissions" | "plan";
import {
  getExplorerBudget,
  getDeveloperBudget,
  getQaBudget,
  getReviewerBudget,
  getPlanStepBudget,
  getSentinelBudget,
  getTroubleshooterBudget,
  getDefaultModel,
  getHighspeedModel,
} from "../lib/config.js";
import { loadAndInterpolate } from "./template-loader.js";
import { loadPrompt, PromptNotFoundError } from "../lib/prompt-loader.js";
import { PI_PHASE_CONFIGS } from "./pi-rpc-spawn-strategy.js";

export { PI_PHASE_CONFIGS };

// ── Role config ─────────────────────────────────────────────────────────

export interface RoleConfig {
  role: AgentRole;
  model: ModelSelection;
  maxBudgetUsd: number;
  /**
   * Permission mode for DCG (Destructive Command Guard).
   * - `"acceptEdits"`: Auto-accept file edits; guards against destructive ops
   * - `"dontAsk"`: Deny operations that would normally prompt (most restrictive)
   */
  permissionMode: PermissionMode;
  /** Report file this role produces */
  reportFile: string;
  /**
   * Whitelist of SDK tool names this role is allowed to use.
   * The complement (all tools NOT in this set) is passed as disallowedTools
   * to the SDK query() call to enforce role-based access control.
   */
  allowedTools: ReadonlyArray<string>;
  /**
   * Maximum number of conversation turns for this phase.
   * Used by Pi RPC strategy and SDK query() calls alike.
   */
  maxTurns?: number;
  /**
   * Maximum total token budget (input + output combined) for this phase.
   * Used by Pi RPC strategy to enforce per-phase limits.
   */
  maxTokens?: number;
}

// ── Plan step config ────────────────────────────────────────────────────

/**
 * Configuration for plan-step SDK queries (PRD/TRD generation via Ensemble).
 * Plan steps are not pipeline phases — no role or reportFile needed.
 */
export interface PlanStepConfig {
  model: ModelSelection;
  maxBudgetUsd: number;
  /** Maximum number of turns for a plan-step SDK query */
  maxTurns: number;
}

export const PLAN_STEP_CONFIG: PlanStepConfig = {
  model: getDefaultModel() as ModelSelection,
  maxBudgetUsd: getPlanStepBudget(),
  // Sufficient for typical PRD/TRD generation runs; raise if plan steps hit the turn limit
  maxTurns: 50,
};

/**
 * Complete vocabulary of Claude Code agent tools available in the running process
 * environment. Used to compute disallowed tools as the complement of each role's
 * allowedTools whitelist.
 */
export const ALL_AGENT_TOOLS: ReadonlyArray<string> = [
  "Agent",
  "AskUserQuestion",
  "Bash",
  "CronCreate",
  "CronDelete",
  "CronList",
  "Edit",
  "EnterPlanMode",
  "EnterWorktree",
  "ExitPlanMode",
  "ExitWorktree",
  "Glob",
  "Grep",
  "NotebookEdit",
  "Read",
  "SendMessage",
  "TaskOutput",
  "TaskStop",
  "TeamCreate",
  "TeamDelete",
  "TodoWrite",
  "WebFetch",
  "WebSearch",
  "Write",
] as const;

/**
 * Compute the disallowed tools for a role config.
 * Returns all SDK tools NOT in the role's allowedTools whitelist.
 */
export function getDisallowedTools(config: RoleConfig): string[] {
  const allowed = new Set(config.allowedTools);
  return ALL_AGENT_TOOLS.filter((tool) => !allowed.has(tool));
}

/**
 * All valid model selections.
 *
 * NOTE: These values must stay in sync with the `ModelSelection` union in
 * `types.ts`. If a new model is added to that union, add it here too —
 * otherwise the new value will be rejected at runtime when read from an
 * environment variable.
 */
const VALID_MODELS: readonly ModelSelection[] = [
  "anthropic/claude-opus-4-6",
  "anthropic/claude-sonnet-4-6",
  "anthropic/claude-haiku-4-5",
  "minimax/MiniMax-M2.7",
  "minimax/MiniMax-M2.7-highspeed",
  "openai/gpt-5.2-chat-latest"
];

/**
 * Resolve a model selection from an environment variable, falling back to the
 * provided default.  Throws if the env var is set to an unrecognised value.
 *
 * @param envVar  Name of the environment variable (e.g. "FOREMAN_EXPLORER_MODEL")
 * @param defaultModel  Hard-coded default used when the env var is absent
 */
function resolveModel(envVar: string, defaultModel: ModelSelection): ModelSelection {
  const value = process.env[envVar];
  if (value === undefined || value === "") {
    return defaultModel;
  }
  if (!(VALID_MODELS as string[]).includes(value)) {
    throw new Error(
      `Invalid model "${value}" in ${envVar}. ` +
      `Valid values are: ${VALID_MODELS.join(", ")}`,
    );
  }
  return value as ModelSelection;
}

/**
 * Hard-coded default model per phase.  Kept as a named constant so they can
 * be used both inside `buildRoleConfigs` and as a safe fallback when the
 * module-level initialisation catches an env-var validation error.
 */
const DEFAULT_MODELS: Readonly<Record<Exclude<AgentRole, "lead" | "worker" | "sentinel">, ModelSelection>> = {
  explorer: getDefaultModel() as ModelSelection,
  developer: getDefaultModel() as ModelSelection,
  qa: getDefaultModel() as ModelSelection,
  reviewer: getDefaultModel() as ModelSelection,
  finalize: getDefaultModel() as ModelSelection,
  troubleshooter: getDefaultModel() as ModelSelection,
};

/**
 * Build the role configuration map, honouring per-phase model overrides via
 * environment variables:
 *
 *   FOREMAN_EXPLORER_MODEL   — override model for the explorer phase
 *   FOREMAN_DEVELOPER_MODEL  — override model for the developer phase
 *   FOREMAN_QA_MODEL         — override model for the QA phase
 *   FOREMAN_REVIEWER_MODEL   — override model for the reviewer phase
 *
 * Each variable accepts any value from the ModelSelection union.  When a
 * variable is absent or empty the hard-coded default is used.
 */
export function buildRoleConfigs(): Record<Exclude<AgentRole, "lead" | "worker" | "sentinel">, RoleConfig> {
  return {
    explorer: {
      role: "explorer",
      model: resolveModel("FOREMAN_EXPLORER_MODEL", DEFAULT_MODELS.explorer),
      maxBudgetUsd: getExplorerBudget(),
      permissionMode: "acceptEdits",
      reportFile: "EXPLORER_REPORT.md",
      allowedTools: ["Glob", "Grep", "Read", "Write"],
    },
    developer: {
      role: "developer",
      model: resolveModel("FOREMAN_DEVELOPER_MODEL", DEFAULT_MODELS.developer),
      maxBudgetUsd: getDeveloperBudget(),
      permissionMode: "acceptEdits",
      reportFile: "DEVELOPER_REPORT.md",
      allowedTools: [
        "Agent", "Bash", "Edit", "Glob", "Grep", "Read",
        "TaskOutput", "TaskStop", "TodoWrite", "WebFetch", "WebSearch", "Write",
      ],
    },
    qa: {
      role: "qa",
      model: resolveModel("FOREMAN_QA_MODEL", DEFAULT_MODELS.qa),
      maxBudgetUsd: getQaBudget(),
      permissionMode: "acceptEdits",
      reportFile: "QA_REPORT.md",
      allowedTools: ["Bash", "Edit", "Glob", "Grep", "Read", "TodoWrite", "Write"],
    },
    reviewer: {
      role: "reviewer",
      model: resolveModel("FOREMAN_REVIEWER_MODEL", DEFAULT_MODELS.reviewer),
      maxBudgetUsd: getReviewerBudget(),
      permissionMode: "acceptEdits",
      reportFile: "REVIEW.md",
      allowedTools: ["Glob", "Grep", "Read", "Write"],
    },
    finalize: {
      role: "finalize",
      model: DEFAULT_MODELS.finalize,
      maxBudgetUsd: 1.00,
      permissionMode: "acceptEdits",
      reportFile: "FINALIZE_REPORT.md",
      allowedTools: ["Bash", "Glob", "Grep", "Read", "Write"],
    },
    troubleshooter: {
      role: "troubleshooter",
      model: resolveModel("FOREMAN_TROUBLESHOOTER_MODEL", DEFAULT_MODELS.troubleshooter),
      maxBudgetUsd: getTroubleshooterBudget(),
      permissionMode: "acceptEdits",
      reportFile: "TROUBLESHOOT_REPORT.md",
      allowedTools: ["Bash", "Edit", "Glob", "Grep", "Read", "Write"],
    },
  };
}

/**
 * Module-level role configuration map, built once at import time.
 *
 * If an environment variable contains an unrecognised model string,
 * `buildRoleConfigs()` would throw and cause the module to fail to load
 * entirely — crashing the worker process before `main()` has a chance to
 * open the store and record the error.  The try/catch here prevents that:
 * on failure it logs a warning to stderr and falls back to the hard-coded
 * defaults so the process continues and can write a proper failure record.
 */
export const ROLE_CONFIGS: Record<Exclude<AgentRole, "lead" | "worker" | "sentinel">, RoleConfig> = (() => {
  try {
    return buildRoleConfigs();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.warn(
      `[foreman] roles: ${msg} — falling back to hard-coded defaults.`,
    );
    return {
      explorer: {
        role: "explorer",
        model: DEFAULT_MODELS.explorer,
        maxBudgetUsd: 1.00,
        permissionMode: "acceptEdits",
        reportFile: "EXPLORER_REPORT.md",
        allowedTools: ["Glob", "Grep", "Read", "Write"],
      },
      developer: {
        role: "developer",
        model: DEFAULT_MODELS.developer,
        maxBudgetUsd: 5.00,
        permissionMode: "acceptEdits",
        reportFile: "DEVELOPER_REPORT.md",
        allowedTools: [
          "Agent", "Bash", "Edit", "Glob", "Grep", "Read",
          "TaskOutput", "TaskStop", "TodoWrite", "WebFetch", "WebSearch", "Write",
        ],
      },
      qa: {
        role: "qa",
        model: DEFAULT_MODELS.qa,
        maxBudgetUsd: 3.00,
        permissionMode: "acceptEdits",
        reportFile: "QA_REPORT.md",
        allowedTools: ["Bash", "Edit", "Glob", "Grep", "Read", "TodoWrite", "Write"],
      },
      reviewer: {
        role: "reviewer",
        model: DEFAULT_MODELS.reviewer,
        maxBudgetUsd: 2.00,
        permissionMode: "acceptEdits",
        reportFile: "REVIEW.md",
        allowedTools: ["Glob", "Grep", "Read", "Write"],
      },
      finalize: {
        role: "finalize",
        model: DEFAULT_MODELS.finalize,
        maxBudgetUsd: 1.00,
        permissionMode: "acceptEdits",
        reportFile: "FINALIZE_REPORT.md",
        allowedTools: ["Bash", "Glob", "Grep", "Read", "Write"],
      },
      troubleshooter: {
        role: "troubleshooter",
        model: DEFAULT_MODELS.troubleshooter,
        maxBudgetUsd: 1.50,
        permissionMode: "acceptEdits",
        reportFile: "TROUBLESHOOT_REPORT.md",
        allowedTools: ["Bash", "Edit", "Glob", "Grep", "Read", "Write"],
      },
    };
  }
})();

/** Standalone role config for the sentinel (not part of the pipeline). */
export const SENTINEL_ROLE_CONFIG: RoleConfig = {
  role: "sentinel",
  model: getDefaultModel() as ModelSelection,
  maxBudgetUsd: getSentinelBudget(),
  permissionMode: "acceptEdits",
  reportFile: "SENTINEL_REPORT.md",
  allowedTools: ["Bash", "Glob", "Grep", "Read", "Write"],
};

// ── Prompt templates ────────────────────────────────────────────────────

/**
 * Options for controlling which prompt loader to use.
 * When projectRoot and workflow are provided, the unified loadPrompt()
 * is used (project-local → user global → error).
 * When omitted, falls back to the bundled template-loader (for tests and
 * backward compatibility with callers that don't have a project root).
 */
export interface PromptLoaderOpts {
  /** Absolute path to project root (contains .foreman/). Required for unified loader. */
  projectRoot?: string;
  /** Workflow name (e.g. "default", "smoke"). Defaults to "default". */
  workflow?: string;
}

/**
 * Internal helper: resolve a prompt using unified loader when projectRoot is
 * available, otherwise fall back to the bundled template-loader.
 *
 * @throws PromptNotFoundError when projectRoot is provided and the file is missing.
 */
function resolvePrompt(
  phase: string,
  vars: Record<string, string | undefined>,
  legacyFilename: string,
  opts?: PromptLoaderOpts,
): string {
  if (opts?.projectRoot) {
    const workflow = opts.workflow ?? "default";
    return loadPrompt(phase, vars, workflow, opts.projectRoot);
  }
  // Bundled fallback (backward compat / unit tests without project root)
  return loadAndInterpolate(legacyFilename, vars as Record<string, string>);
}

export { PromptNotFoundError };

/**
 * Generic prompt builder for any workflow phase.
 * Builds template variables from the pipeline context and resolves the prompt
 * via the standard prompt loader (project-local → bundled fallback).
 */
export function buildPhasePrompt(
  phaseName: string,
  context: {
    seedId: string;
    seedTitle: string;
    seedDescription: string;
    seedComments?: string;
    /** Bead type (e.g. "test", "task", "bug"). Used by finalize to handle
     *  "nothing to commit" as success for verification beads. */
    seedType?: string;
    runId?: string;
    hasExplorerReport?: boolean;
    feedbackContext?: string;
    baseBranch?: string;
    /** Absolute path to the worktree. Passed to finalize prompt so it can cd
     *  to the correct directory before running git commands. */
    worktreePath?: string;
    // ── VCS command variables (TRD-026: finalize phase) ───────────────────
    /** Command to stage all changes (e.g. 'git add -A'). Empty for auto-staging backends. */
    vcsStageCommand?: string;
    /** Command to commit staged changes. */
    vcsCommitCommand?: string;
    /** Command to push the branch to remote. */
    vcsPushCommand?: string;
    /** Command to rebase onto the base branch. */
    vcsRebaseCommand?: string;
    /** Command to verify the current branch name. */
    vcsBranchVerifyCommand?: string;
    /** Command to clean up the workspace. */
    vcsCleanCommand?: string;
    // ── VCS context variables (TRD-027: reviewer phase) ──────────────────
    /** VCS backend name (e.g. 'git' or 'jujutsu'). */
    vcsBackendName?: string;
    /** Branch prefix used for agent branches (e.g. 'foreman/'). */
    vcsBranchPrefix?: string;
  },
  opts?: PromptLoaderOpts,
): string {
  const commentsSection = context.seedComments ? `\n## Additional Context\n${context.seedComments}\n` : "";
  const explorerInstruction = context.hasExplorerReport
    ? `2. Read **EXPLORER_REPORT.md** for codebase context and recommended approach`
    : `2. Explore the codebase to understand the relevant architecture`;
  const feedbackSection = context.feedbackContext
    ? `\n## Previous Feedback\nAddress these issues from the previous review:\n${context.feedbackContext}\n`
    : "";

  const vars: Record<string, string> = {
    seedId: context.seedId,
    seedTitle: context.seedTitle,
    seedDescription: context.seedDescription,
    commentsSection,
    explorerInstruction,
    feedbackSection,
    runId: context.runId ?? "",
    agentRole: phaseName,
    baseBranch: context.baseBranch ?? "main",
    worktreePath: context.worktreePath ?? "",
    seedType: context.seedType ?? "",
    // VCS finalize command variables (TRD-026)
    vcsStageCommand: context.vcsStageCommand ?? "git add -A",
    vcsCommitCommand: context.vcsCommitCommand ?? `git commit -m "${context.seedTitle} (${context.seedId})"`,
    vcsPushCommand: context.vcsPushCommand ?? `git push -u origin foreman/${context.seedId}`,
    vcsRebaseCommand: context.vcsRebaseCommand ?? `git fetch origin && git rebase origin/${context.baseBranch ?? "main"}`,
    vcsBranchVerifyCommand: context.vcsBranchVerifyCommand ?? "git rev-parse --abbrev-ref HEAD",
    vcsCleanCommand: context.vcsCleanCommand ?? `git worktree remove --force ${context.worktreePath ?? ""}`,
    // VCS context variables (TRD-027)
    vcsBackendName: context.vcsBackendName ?? "git",
    vcsBranchPrefix: context.vcsBranchPrefix ?? "foreman/",
  };

  // Map phase names to legacy template filenames for bundled fallback.
  const legacyFilename = `${phaseName}-prompt.md`;
  return resolvePrompt(phaseName, vars, legacyFilename, opts);
}

export function explorerPrompt(seedId: string, seedTitle: string, seedDescription: string, seedComments?: string, runId?: string, opts?: PromptLoaderOpts): string {
  const commentsSection = seedComments ? `\n## Additional Context\n${seedComments}\n` : "";
  return resolvePrompt(
    "explorer",
    { seedId, seedTitle, seedDescription, commentsSection, runId: runId ?? "", agentRole: "explorer" },
    "explorer-prompt.md",
    opts,
  );
}

export function developerPrompt(
  seedId: string,
  seedTitle: string,
  seedDescription: string,
  hasExplorerReport: boolean,
  feedbackContext?: string,
  seedComments?: string,
  runId?: string,
  opts?: PromptLoaderOpts,
): string {
  // NOTE: These strings are injected at the {{explorerInstruction}} placeholder in
  // developer.md (formerly developer-prompt.md), which appears between hardcoded
  // step 1 and step 3 in the Instructions list. Both values must always begin with
  // "2. " to keep the list sequential. If a new step is added before the placeholder
  // in the template, update the numbering here to match.
  const explorerInstruction = hasExplorerReport
    ? `2. Read **EXPLORER_REPORT.md** for codebase context and recommended approach`
    : `2. Explore the codebase to understand the relevant architecture`;

  const feedbackSection = feedbackContext
    ? `\n## Previous Feedback\nAddress these issues from the previous review:\n${feedbackContext}\n`
    : "";

  const commentsSection = seedComments ? `\n## Additional Context\n${seedComments}\n` : "";

  return resolvePrompt(
    "developer",
    {
      seedId,
      seedTitle,
      seedDescription,
      explorerInstruction,
      feedbackSection,
      commentsSection,
      runId: runId ?? "",
      agentRole: "developer",
    },
    "developer-prompt.md",
    opts,
  );
}

export function qaPrompt(seedId: string, seedTitle: string, runId?: string, opts?: PromptLoaderOpts): string {
  return resolvePrompt(
    "qa",
    { seedId, seedTitle, runId: runId ?? "", agentRole: "qa" },
    "qa-prompt.md",
    opts,
  );
}

export function reviewerPrompt(seedId: string, seedTitle: string, seedDescription: string, seedComments?: string, runId?: string, opts?: PromptLoaderOpts): string {
  const commentsSection = seedComments ? `\n## Additional Context\n${seedComments}\n` : "";
  return resolvePrompt(
    "reviewer",
    { seedId, seedTitle, seedDescription, commentsSection, runId: runId ?? "", agentRole: "reviewer" },
    "reviewer-prompt.md",
    opts,
  );
}

export function finalizePrompt(seedId: string, seedTitle: string, runId?: string, baseBranch?: string, opts?: PromptLoaderOpts, worktreePath?: string): string {
  const resolvedBase = baseBranch ?? "main";
  const resolvedWorktree = worktreePath ?? "";
  return resolvePrompt(
    "finalize",
    {
      seedId,
      seedTitle,
      runId: runId ?? "",
      agentRole: "finalize",
      baseBranch: resolvedBase,
      worktreePath: resolvedWorktree,
      // Default to git commands for backward compatibility (TRD-026)
      vcsStageCommand: "git add -A",
      vcsCommitCommand: `git commit -m "${seedTitle} (${seedId})"`,
      vcsPushCommand: `git push -u origin foreman/${seedId}`,
      vcsRebaseCommand: `git fetch origin && git rebase origin/${resolvedBase}`,
      vcsBranchVerifyCommand: "git rev-parse --abbrev-ref HEAD",
      vcsCleanCommand: `git worktree remove --force ${resolvedWorktree}`,
    },
    "finalize-prompt.md",
    opts,
  );
}

export function sentinelPrompt(branch: string, testCommand: string, opts?: PromptLoaderOpts): string {
  return resolvePrompt(
    "sentinel",
    { branch, testCommand },
    "sentinel-prompt.md",
    opts,
  );
}

// ── Report parsing ──────────────────────────────────────────────────────

export type Verdict = "pass" | "fail" | "unknown";

/**
 * Parse a report file for a PASS/FAIL verdict.
 * Looks for "## Verdict: PASS" or "## Verdict: FAIL" patterns.
 */
export function parseVerdict(reportContent: string): Verdict {
  const verdictMatch = reportContent.match(/##\s*Verdict:\s*(PASS|FAIL)/i);
  if (!verdictMatch) return "unknown";
  return verdictMatch[1].toLowerCase() as Verdict;
}

/**
 * Extract issues from a review report for developer feedback.
 */
export function extractIssues(reportContent: string): string {
  // Extract everything between ## Issues and the next ## heading
  const issuesMatch = reportContent.match(/## Issues\n([\s\S]*?)(?=\n## |$)/);
  if (!issuesMatch) return "(no specific issues listed)";
  return issuesMatch[1].trim();
}

/**
 * Check if a report has actionable issues (CRITICAL, WARNING, or NOTE).
 */
export function hasActionableIssues(reportContent: string): boolean {
  const issues = extractIssues(reportContent);
  if (issues === "(no specific issues listed)") return false;
  return /\*\*\[(CRITICAL|WARNING|NOTE)\]\*\*/i.test(issues);
}
