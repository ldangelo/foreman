/**
 * Agent role definitions and prompt templates for the specialization pipeline.
 *
 * Pipeline: Explorer → Developer → QA → Reviewer
 * Each sub-agent runs as a separate SDK query() call, sequentially in the
 * same worktree. Communication is via report files (EXPLORER_REPORT.md, etc).
 */

import type { PermissionMode } from "@anthropic-ai/claude-agent-sdk";
import type { AgentRole, ModelSelection } from "./types.js";
import {
  getExplorerBudget,
  getDeveloperBudget,
  getQaBudget,
  getReviewerBudget,
  getPlanStepBudget,
  getSentinelBudget,
} from "../lib/config.js";
import { loadAndInterpolate } from "./template-loader.js";

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
  /** Maximum number of agent turns for this phase */
  maxTurns: number;
  /** Maximum token budget for this phase */
  maxTokens: number;
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
  model: "claude-sonnet-4-6",
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
 * Well-known Anthropic model identifiers (for documentation purposes only).
 * ModelSelection is now an open string type — any provider's model ID is accepted.
 *
 * @example "claude-opus-4-6" | "claude-sonnet-4-6" | "claude-haiku-4-5-20251001"
 *          "gpt-4o-mini" | "gemini-1.5-pro" (accepted by Pi RPC via set_model)
 */
const _ANTHROPIC_MODELS_DOC = [
  "claude-opus-4-6",
  "claude-sonnet-4-6",
  "claude-haiku-4-5-20251001",
] as const;
// Prevent unused-variable lint errors — this is intentionally documentation-only
void _ANTHROPIC_MODELS_DOC;

/**
 * Resolve a model selection from an environment variable, falling back to the
 * provided default.  Any non-empty string is accepted so that Pi RPC can route
 * to any model provider (e.g. "gpt-4o-mini", "gemini-1.5-pro").
 *
 * @param envVar  Name of the environment variable (e.g. "FOREMAN_EXPLORER_MODEL")
 * @param defaultModel  Hard-coded default used when the env var is absent or empty
 */
function resolveModel(envVar: string, defaultModel: ModelSelection): ModelSelection {
  const value = process.env[envVar];
  if (value === undefined || value === "") {
    return defaultModel;
  }
  return value;
}

/**
 * Hard-coded default model per phase.  Kept as a named constant so they can
 * be used both inside `buildRoleConfigs` and as a safe fallback when the
 * module-level initialisation catches an env-var validation error.
 */
const DEFAULT_MODELS: Readonly<Record<Exclude<AgentRole, "lead" | "worker" | "sentinel">, ModelSelection>> = {
  explorer: "claude-haiku-4-5-20251001",
  developer: "claude-sonnet-4-6",
  qa: "claude-sonnet-4-6",
  reviewer: "claude-sonnet-4-6",
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
      maxTurns: 30,
      maxTokens: 100_000,
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
      maxTurns: 80,
      maxTokens: 500_000,
    },
    qa: {
      role: "qa",
      model: resolveModel("FOREMAN_QA_MODEL", DEFAULT_MODELS.qa),
      maxBudgetUsd: getQaBudget(),
      permissionMode: "acceptEdits",
      reportFile: "QA_REPORT.md",
      allowedTools: ["Bash", "Edit", "Glob", "Grep", "Read", "TodoWrite", "Write"],
      maxTurns: 30,
      maxTokens: 200_000,
    },
    reviewer: {
      role: "reviewer",
      model: resolveModel("FOREMAN_REVIEWER_MODEL", DEFAULT_MODELS.reviewer),
      maxBudgetUsd: getReviewerBudget(),
      permissionMode: "acceptEdits",
      reportFile: "REVIEW.md",
      allowedTools: ["Glob", "Grep", "Read", "Write"],
      maxTurns: 20,
      maxTokens: 150_000,
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
        maxTurns: 30,
        maxTokens: 100_000,
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
        maxTurns: 80,
        maxTokens: 500_000,
      },
      qa: {
        role: "qa",
        model: DEFAULT_MODELS.qa,
        maxBudgetUsd: 3.00,
        permissionMode: "acceptEdits",
        reportFile: "QA_REPORT.md",
        allowedTools: ["Bash", "Edit", "Glob", "Grep", "Read", "TodoWrite", "Write"],
        maxTurns: 30,
        maxTokens: 200_000,
      },
      reviewer: {
        role: "reviewer",
        model: DEFAULT_MODELS.reviewer,
        maxBudgetUsd: 2.00,
        permissionMode: "acceptEdits",
        reportFile: "REVIEW.md",
        allowedTools: ["Glob", "Grep", "Read", "Write"],
        maxTurns: 20,
        maxTokens: 150_000,
      },
    };
  }
})();

/** Standalone role config for the sentinel (not part of the pipeline). */
export const SENTINEL_ROLE_CONFIG: RoleConfig = {
  role: "sentinel",
  model: "claude-sonnet-4-6",
  maxBudgetUsd: getSentinelBudget(),
  permissionMode: "acceptEdits",
  reportFile: "SENTINEL_REPORT.md",
  allowedTools: ["Bash", "Glob", "Grep", "Read", "Write"],
  maxTurns: 20,
  maxTokens: 100_000,
};

// ── Pi Phase Config ─────────────────────────────────────────────────────────

/**
 * Lightweight configuration for a Pi RPC pipeline phase.
 * Mirrors the relevant fields from `RoleConfig` but excludes SDK-specific
 * properties (permissionMode, maxBudgetUsd, reportFile, role) that are not
 * meaningful in the Pi RPC context.
 */
export interface PiPhaseConfig {
  /** Model identifier sent via set_model command to Pi */
  model: string;
  /** Tool names the phase is permitted to invoke */
  allowedTools: string[];
  /** Bash commands this phase must not execute (empty = no blocklist) */
  bashBlocklist?: string[];
  /** Maximum number of agent turns for this phase */
  maxTurns: number;
  /** Maximum token budget for this phase */
  maxTokens: number;
}

/**
 * Per-phase Pi RPC configuration map.
 *
 * Derived from `ROLE_CONFIGS` so model, maxTurns, maxTokens, and allowedTools
 * remain a single source of truth.  Any env-var overrides applied to
 * `ROLE_CONFIGS` (e.g. `FOREMAN_EXPLORER_MODEL`) are automatically reflected
 * here because we reference `ROLE_CONFIGS` at module-evaluation time.
 */
export const PI_PHASE_CONFIGS: Record<string, PiPhaseConfig> = {
  explorer: {
    model: ROLE_CONFIGS.explorer.model,
    allowedTools: [...ROLE_CONFIGS.explorer.allowedTools],
    maxTurns: ROLE_CONFIGS.explorer.maxTurns,
    maxTokens: ROLE_CONFIGS.explorer.maxTokens,
  },
  developer: {
    model: ROLE_CONFIGS.developer.model,
    allowedTools: [...ROLE_CONFIGS.developer.allowedTools],
    maxTurns: ROLE_CONFIGS.developer.maxTurns,
    maxTokens: ROLE_CONFIGS.developer.maxTokens,
  },
  qa: {
    model: ROLE_CONFIGS.qa.model,
    allowedTools: [...ROLE_CONFIGS.qa.allowedTools],
    maxTurns: ROLE_CONFIGS.qa.maxTurns,
    maxTokens: ROLE_CONFIGS.qa.maxTokens,
  },
  reviewer: {
    model: ROLE_CONFIGS.reviewer.model,
    allowedTools: [...ROLE_CONFIGS.reviewer.allowedTools],
    maxTurns: ROLE_CONFIGS.reviewer.maxTurns,
    maxTokens: ROLE_CONFIGS.reviewer.maxTokens,
  },
};

// ── Prompt templates ────────────────────────────────────────────────────

export function explorerPrompt(seedId: string, seedTitle: string, seedDescription: string, seedComments?: string): string {
  const commentsSection = seedComments ? `\n## Additional Context\n${seedComments}\n` : "";
  return loadAndInterpolate("explorer-prompt.md", { seedId, seedTitle, seedDescription, commentsSection });
}

export function developerPrompt(
  seedId: string,
  seedTitle: string,
  seedDescription: string,
  hasExplorerReport: boolean,
  feedbackContext?: string,
  seedComments?: string,
): string {
  // NOTE: These strings are injected at the {{explorerInstruction}} placeholder in
  // developer-prompt.md, which appears between hardcoded step 1 and step 3 in the
  // Instructions list. Both values must always begin with "2. " to keep the list
  // sequential. If a new step is added before the placeholder in the template,
  // update the numbering here to match.
  const explorerInstruction = hasExplorerReport
    ? `2. Read **EXPLORER_REPORT.md** for codebase context and recommended approach`
    : `2. Explore the codebase to understand the relevant architecture`;

  const feedbackSection = feedbackContext
    ? `\n## Previous Feedback\nAddress these issues from the previous review:\n${feedbackContext}\n`
    : "";

  const commentsSection = seedComments ? `\n## Additional Context\n${seedComments}\n` : "";

  return loadAndInterpolate("developer-prompt.md", {
    seedId,
    seedTitle,
    seedDescription,
    explorerInstruction,
    feedbackSection,
    commentsSection,
  });
}

export function qaPrompt(seedId: string, seedTitle: string): string {
  return loadAndInterpolate("qa-prompt.md", { seedId, seedTitle });
}

export function reviewerPrompt(seedId: string, seedTitle: string, seedDescription: string, seedComments?: string): string {
  const commentsSection = seedComments ? `\n## Additional Context\n${seedComments}\n` : "";
  return loadAndInterpolate("reviewer-prompt.md", { seedId, seedTitle, seedDescription, commentsSection });
}

export function sentinelPrompt(branch: string, testCommand: string): string {
  return loadAndInterpolate("sentinel-prompt.md", { branch, testCommand });
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
