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
} from "../lib/config.js";

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
const DEFAULT_MODELS: Readonly<Record<Exclude<AgentRole, "lead" | "worker">, ModelSelection>> = {
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
export function buildRoleConfigs(): Record<Exclude<AgentRole, "lead" | "worker">, RoleConfig> {
  return {
    explorer: {
      role: "explorer",
      model: resolveModel("FOREMAN_EXPLORER_MODEL", DEFAULT_MODELS.explorer),
      maxBudgetUsd: getExplorerBudget(),
      permissionMode: "acceptEdits",
      reportFile: "EXPLORER_REPORT.md",
    },
    developer: {
      role: "developer",
      model: resolveModel("FOREMAN_DEVELOPER_MODEL", DEFAULT_MODELS.developer),
      maxBudgetUsd: getDeveloperBudget(),
      permissionMode: "acceptEdits",
      reportFile: "DEVELOPER_REPORT.md",
    },
    qa: {
      role: "qa",
      model: resolveModel("FOREMAN_QA_MODEL", DEFAULT_MODELS.qa),
      maxBudgetUsd: getQaBudget(),
      permissionMode: "acceptEdits",
      reportFile: "QA_REPORT.md",
    },
    reviewer: {
      role: "reviewer",
      model: resolveModel("FOREMAN_REVIEWER_MODEL", DEFAULT_MODELS.reviewer),
      maxBudgetUsd: getReviewerBudget(),
      permissionMode: "acceptEdits",
      reportFile: "REVIEW.md",
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
export const ROLE_CONFIGS: Record<Exclude<AgentRole, "lead" | "worker">, RoleConfig> = (() => {
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
      },
      developer: {
        role: "developer",
        model: DEFAULT_MODELS.developer,
        maxBudgetUsd: 5.00,
        permissionMode: "acceptEdits",
        reportFile: "DEVELOPER_REPORT.md",
      },
      qa: {
        role: "qa",
        model: DEFAULT_MODELS.qa,
        maxBudgetUsd: 3.00,
        permissionMode: "acceptEdits",
        reportFile: "QA_REPORT.md",
      },
      reviewer: {
        role: "reviewer",
        model: DEFAULT_MODELS.reviewer,
        maxBudgetUsd: 2.00,
        permissionMode: "acceptEdits",
        reportFile: "REVIEW.md",
      },
    };
  }
})();

// ── Prompt templates ────────────────────────────────────────────────────

export function explorerPrompt(seedId: string, seedTitle: string, seedDescription: string): string {
  return `# Explorer Agent

You are an **Explorer** — your job is to understand the codebase before implementation begins.

## Task
**Seed:** ${seedId} — ${seedTitle}
**Description:** ${seedDescription}

## Instructions
1. Read TASK.md for task context
2. Explore the codebase to understand the relevant architecture:
   - Find the files that will need to be modified
   - Identify existing patterns, conventions, and abstractions
   - Map dependencies and imports relevant to this task
   - Note any existing tests that cover the affected code
3. Write your findings to **EXPLORER_REPORT.md** in the worktree root

## EXPLORER_REPORT.md Format
\`\`\`markdown
# Explorer Report: ${seedTitle}

## Relevant Files
- path/to/file.ts — description of what it does and why it's relevant

## Architecture & Patterns
- Key patterns observed (naming conventions, abstractions, error handling)

## Dependencies
- What this code depends on, what depends on it

## Existing Tests
- Test files that cover the affected code

## Recommended Approach
- Step-by-step implementation plan based on what you found
- Potential pitfalls or edge cases to watch for
\`\`\`

## Rules
- **DO NOT modify any source code files** — you are read-only
- **DO NOT create new source files** — only write EXPLORER_REPORT.md
- Focus on understanding, not implementing
- Be specific — reference actual file paths and line numbers
- Keep the report concise and actionable for the Developer agent
`;
}

export function developerPrompt(
  seedId: string,
  seedTitle: string,
  seedDescription: string,
  hasExplorerReport: boolean,
  feedbackContext?: string,
): string {
  const explorerInstructions = hasExplorerReport
    ? `2. Read **EXPLORER_REPORT.md** for codebase context and recommended approach`
    : `2. Explore the codebase to understand the relevant architecture`;

  const feedbackSection = feedbackContext
    ? `\n## Previous Feedback\nAddress these issues from the previous review:\n${feedbackContext}\n`
    : "";

  return `# Developer Agent

You are a **Developer** — your job is to implement the task.
${feedbackSection}
## Task
**Seed:** ${seedId} — ${seedTitle}
**Description:** ${seedDescription}

## Instructions
1. Read TASK.md for task context
${explorerInstructions}
3. Implement the required changes
4. Write or update tests for your changes
5. Ensure the code compiles/lints cleanly

## Rules
- Stay focused on THIS task only — do not refactor unrelated code
- Follow existing codebase patterns and conventions
- Write tests for new functionality
- **DO NOT** commit, push, or close the seed — the pipeline handles that
- **DO NOT** run the full test suite — the QA agent handles that
- If blocked, write a note to BLOCKED.md explaining why

## Developer Report
After implementation, write **DEVELOPER_REPORT.md** summarizing your work:

\`\`\`markdown
# Developer Report: ${seedTitle}

## Approach
- Brief description of the implementation strategy

## Files Changed
- path/to/file.ts — what was changed and why

## Tests Added/Modified
- path/to/test.ts — what's covered

## Decisions & Trade-offs
- Any design decisions made and their rationale

## Known Limitations
- Anything deferred or not fully addressed
\`\`\`
`;
}

export function qaPrompt(seedId: string, seedTitle: string): string {
  return `# QA Agent

You are a **QA Agent** — your job is to verify the implementation works correctly.

## Task
Verify the implementation for: **${seedId} — ${seedTitle}**

## Instructions
1. Read TASK.md and EXPLORER_REPORT.md (if exists) for context
2. Review what the Developer changed (check git diff)
3. Run the existing test suite
4. If tests fail due to the changes, attempt to fix them
5. Write any additional tests needed for uncovered edge cases
6. Write your findings to **QA_REPORT.md**

## QA_REPORT.md Format
\`\`\`markdown
# QA Report: ${seedTitle}

## Verdict: PASS | FAIL

## Test Results
- Test suite: X passed, Y failed
- New tests added: N

## Issues Found
- (list any test failures, type errors, or regressions)

## Files Modified
- (list any test files you created or fixed)
\`\`\`

## Rules
- You may modify test files and fix minor issues in source code
- Focus on correctness and regressions, not style
- Be specific about failures — include error messages
- **DO NOT** commit, push, or close the seed
`;
}

export function reviewerPrompt(seedId: string, seedTitle: string, seedDescription: string): string {
  return `# Reviewer Agent

You are a **Code Reviewer** — your job is independent quality review.

## Task
Review the implementation for: **${seedId} — ${seedTitle}**
**Original requirement:** ${seedDescription}

## Instructions
1. Read TASK.md for the original task description
2. Read EXPLORER_REPORT.md (if exists) for architecture context
3. Read QA_REPORT.md for test results
4. Review ALL changed files (use git diff against the base branch)
5. Check for:
   - Bugs, logic errors, off-by-one errors
   - Security vulnerabilities (injection, XSS, etc.)
   - Missing edge cases or error handling
   - Whether the implementation actually satisfies the requirement
   - Code quality: naming, structure, unnecessary complexity
6. Write your findings to **REVIEW.md**

## REVIEW.md Format
\`\`\`markdown
# Code Review: ${seedTitle}

## Verdict: PASS | FAIL

## Summary
One paragraph assessment.

## Issues
- **[CRITICAL]** file:line — description (must fix)
- **[WARNING]** file:line — description (should fix)
- **[NOTE]** file:line — description (suggestion)

## Positive Notes
- What was done well
\`\`\`

## Rules
- **DO NOT modify any files** — you are read-only, only write REVIEW.md
- Be fair but thorough — PASS means ready to ship with no remaining issues
- Mark **FAIL** for any CRITICAL or WARNING issues that should be fixed
- Mark **PASS** only when there are no actionable issues remaining
- NOTEs are informational only and don't affect the verdict
- Any issue that can reasonably be fixed by the Developer should be a WARNING, not a NOTE
`;
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
