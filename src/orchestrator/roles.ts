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
 * All valid model selections.
 *
 * NOTE: These values must stay in sync with the `ModelSelection` union in
 * `types.ts`. If a new model is added to that union, add it here too —
 * otherwise the new value will be rejected at runtime when read from an
 * environment variable.
 */
const VALID_MODELS: readonly ModelSelection[] = [
  "claude-opus-4-6",
  "claude-sonnet-4-6",
  "claude-haiku-4-5-20251001",
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
  explorer: "claude-haiku-4-5-20251001",
  developer: "claude-sonnet-4-6",
  qa: "claude-sonnet-4-6",
  reviewer: "claude-sonnet-4-6",
  reproducer: "claude-sonnet-4-6",
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
    reproducer: {
      role: "reproducer",
      model: resolveModel("FOREMAN_REPRODUCER_MODEL", DEFAULT_MODELS.reproducer),
      maxBudgetUsd: 2.00,
      permissionMode: "acceptEdits",
      reportFile: "REPRODUCER_REPORT.md",
      // Read-only + write for report — no source modification (AC-015-3)
      allowedTools: ["Bash", "Glob", "Grep", "Read", "Write"],
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
      reproducer: {
        role: "reproducer",
        model: DEFAULT_MODELS.reproducer,
        maxBudgetUsd: 2.00,
        permissionMode: "acceptEdits",
        reportFile: "REPRODUCER_REPORT.md",
        allowedTools: ["Bash", "Glob", "Grep", "Read", "Write"],
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

/**
 * Built-in fallback prompt for the Reproducer phase.
 *
 * The Reproducer runs before the Developer for bug seeds. Its job is to
 * reproduce the bug, write REPRODUCER_REPORT.md, and send the report to
 * the Developer inbox. A CANNOT_REPRODUCE verdict stops the pipeline.
 *
 * TRD-020 [satisfies REQ-015, AC-015-1 through AC-015-4]
 */
export function reproducerPrompt(seedId: string, seedTitle: string, seedDescription: string, seedComments?: string): string {
  const commentsSection = seedComments ? `\n## Additional Context\n${seedComments}\n` : "";
  return `# Reproducer Agent

You are a **Reproducer** — your job is to reproduce a reported bug before implementation begins.

## Task
**Seed:** ${seedId} — ${seedTitle}
**Description:** ${seedDescription}
${commentsSection}
## Instructions
1. Read TASK.md for task context
2. Understand the bug description thoroughly
3. Set up the conditions to reproduce the bug:
   - Identify the relevant code paths
   - Understand what the expected behavior should be
   - Understand what the actual (broken) behavior is
4. Attempt to reproduce the bug:
   - Write a minimal reproduction case (test or script) that triggers the bug
   - Verify the bug actually occurs in the current codebase
5. Write your findings to **REPRODUCER_REPORT.md** in the worktree root
6. Write **SESSION_LOG.md** in the worktree root documenting your session

## REPRODUCER_REPORT.md Format
\`\`\`markdown
# Reproducer Report: ${seedTitle}

## Verdict: REPRODUCED | CANNOT_REPRODUCE

## Bug Summary
Brief description of the bug.

## Reproduction Steps
1. Step-by-step instructions to reproduce
2. ...

## Root Cause (if identified)
- What component is responsible
- Why the bug occurs

## Recommended Fix Approach
- Suggested implementation approach for the Developer phase
- Files to modify
- Key considerations
\`\`\`

## Rules
- **DO NOT implement the fix** — you are in read-and-reproduce mode only
- **DO NOT modify source files** — only create the reproduction case and write REPRODUCER_REPORT.md and SESSION_LOG.md
- If you CANNOT reproduce the bug, set Verdict to CANNOT_REPRODUCE and explain why
- A CANNOT_REPRODUCE verdict will stop the pipeline — the seed will be marked as stuck
- Be specific about what you tried and what you observed
`.trim();
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
