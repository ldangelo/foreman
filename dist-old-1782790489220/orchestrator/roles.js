/**
 * Agent role definitions and prompt templates for the specialization pipeline.
 *
 * Pipeline: Explorer → Developer → QA → Reviewer
 * Each sub-agent runs as a separate SDK query() call, sequentially in the
 * same worktree. Communication is via report files (EXPLORER_REPORT.md, etc).
 */
import { getExplorerBudget, getDeveloperBudget, getQaBudget, getReviewerBudget, getPlanStepBudget, getSentinelBudget, getTroubleshooterBudget, getDefaultModel, } from "../lib/config.js";
import { loadAndInterpolate } from "./template-loader.js";
import { loadPrompt, PromptNotFoundError, expandCommandPlaceholders } from "../lib/prompt-loader.js";
import { PI_PHASE_CONFIGS } from "./pi-rpc-spawn-strategy.js";
export { PI_PHASE_CONFIGS };
export const PLAN_STEP_CONFIG = {
    model: getDefaultModel(),
    maxBudgetUsd: getPlanStepBudget(),
    // Sufficient for typical PRD/TRD generation runs; raise if plan steps hit the turn limit
    maxTurns: 50,
};
/**
 * Complete vocabulary of Claude Code agent tools available in the running process
 * environment. Used to compute disallowed tools as the complement of each role's
 * allowedTools whitelist.
 */
export const ALL_AGENT_TOOLS = [
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
];
/**
 * Compute the disallowed tools for a role config.
 * Returns all SDK tools NOT in the role's allowedTools whitelist.
 */
export function getDisallowedTools(config) {
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
const VALID_MODELS = [
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
function resolveModel(envVar, defaultModel) {
    const value = process.env[envVar];
    if (value === undefined || value === "") {
        return defaultModel;
    }
    if (!VALID_MODELS.includes(value)) {
        throw new Error(`Invalid model "${value}" in ${envVar}. ` +
            `Valid values are: ${VALID_MODELS.join(", ")}`);
    }
    return value;
}
/**
 * Hard-coded default model per phase.  Kept as a named constant so they can
 * be used both inside `buildRoleConfigs` and as a safe fallback when the
 * module-level initialisation catches an env-var validation error.
 */
const DEFAULT_MODELS = {
    explorer: getDefaultModel(),
    developer: getDefaultModel(),
    qa: getDefaultModel(),
    reviewer: getDefaultModel(),
    finalize: getDefaultModel(),
    troubleshooter: getDefaultModel(),
    fix: getDefaultModel(),
    test: getDefaultModel(),
    prd: getDefaultModel(),
    trd: getDefaultModel(),
    implement: getDefaultModel(),
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
export function buildRoleConfigs() {
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
            allowedTools: ["Bash", "Glob", "Grep", "Read", "TodoWrite", "Write"],
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
        fix: {
            role: "fix",
            model: resolveModel("FOREMAN_FIX_MODEL", DEFAULT_MODELS.fix),
            maxBudgetUsd: getDeveloperBudget(),
            permissionMode: "acceptEdits",
            reportFile: "DEVELOPER_REPORT.md",
            allowedTools: [
                "Agent", "Bash", "Edit", "Glob", "Grep", "Read",
                "TaskOutput", "TaskStop", "TodoWrite", "WebFetch", "WebSearch", "Write",
            ],
        },
        test: {
            role: "test",
            model: resolveModel("FOREMAN_TEST_MODEL", DEFAULT_MODELS.test),
            maxBudgetUsd: getQaBudget(),
            permissionMode: "acceptEdits",
            reportFile: "TEST_RESULTS.md",
            allowedTools: ["Bash", "Edit", "Glob", "Grep", "Read", "TodoWrite", "Write"],
        },
        prd: {
            role: "prd",
            model: DEFAULT_MODELS.prd,
            maxBudgetUsd: 5.00,
            permissionMode: "acceptEdits",
            reportFile: "PRD.md",
            allowedTools: [
                "Agent", "Bash", "Edit", "Glob", "Grep", "Read",
                "TaskOutput", "TaskStop", "TodoWrite", "WebFetch", "WebSearch", "Write",
            ],
        },
        trd: {
            role: "trd",
            model: DEFAULT_MODELS.trd,
            maxBudgetUsd: 8.00,
            permissionMode: "acceptEdits",
            reportFile: "TRD.md",
            allowedTools: [
                "Agent", "Bash", "Edit", "Glob", "Grep", "Read",
                "TaskOutput", "TaskStop", "TodoWrite", "WebFetch", "WebSearch", "Write",
            ],
        },
        implement: {
            role: "implement",
            model: DEFAULT_MODELS.implement,
            maxBudgetUsd: 10.00,
            permissionMode: "acceptEdits",
            reportFile: "IMPLEMENT_REPORT.md",
            allowedTools: [
                "Agent", "Bash", "Edit", "Glob", "Grep", "Read",
                "TaskOutput", "TaskStop", "TodoWrite", "WebFetch", "WebSearch", "Write",
            ],
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
export const ROLE_CONFIGS = (() => {
    try {
        return buildRoleConfigs();
    }
    catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.warn(`[foreman] roles: ${msg} — falling back to hard-coded defaults.`);
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
                allowedTools: ["Bash", "Glob", "Grep", "Read", "TodoWrite", "Write"],
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
            fix: {
                role: "fix",
                model: DEFAULT_MODELS.fix,
                maxBudgetUsd: 5.00,
                permissionMode: "acceptEdits",
                reportFile: "DEVELOPER_REPORT.md",
                allowedTools: [
                    "Agent", "Bash", "Edit", "Glob", "Grep", "Read",
                    "TaskOutput", "TaskStop", "TodoWrite", "WebFetch", "WebSearch", "Write",
                ],
            },
            test: {
                role: "test",
                model: DEFAULT_MODELS.test,
                maxBudgetUsd: 3.00,
                permissionMode: "acceptEdits",
                reportFile: "TEST_RESULTS.md",
                allowedTools: ["Bash", "Edit", "Glob", "Grep", "Read", "TodoWrite", "Write"],
            },
            prd: {
                role: "prd",
                model: DEFAULT_MODELS.prd,
                maxBudgetUsd: 5.00,
                permissionMode: "acceptEdits",
                reportFile: "PRD.md",
                allowedTools: [
                    "Agent", "Bash", "Edit", "Glob", "Grep", "Read",
                    "TaskOutput", "TaskStop", "TodoWrite", "WebFetch", "WebSearch", "Write",
                ],
            },
            trd: {
                role: "trd",
                model: DEFAULT_MODELS.trd,
                maxBudgetUsd: 8.00,
                permissionMode: "acceptEdits",
                reportFile: "TRD.md",
                allowedTools: [
                    "Agent", "Bash", "Edit", "Glob", "Grep", "Read",
                    "TaskOutput", "TaskStop", "TodoWrite", "WebFetch", "WebSearch", "Write",
                ],
            },
            implement: {
                role: "implement",
                model: DEFAULT_MODELS.implement,
                maxBudgetUsd: 10.00,
                permissionMode: "acceptEdits",
                reportFile: "IMPLEMENT_REPORT.md",
                allowedTools: [
                    "Agent", "Bash", "Edit", "Glob", "Grep", "Read",
                    "TaskOutput", "TaskStop", "TodoWrite", "WebFetch", "WebSearch", "Write",
                ],
            },
        };
    }
})();
/** Standalone role config for the sentinel (not part of the pipeline). */
export const SENTINEL_ROLE_CONFIG = {
    role: "sentinel",
    model: getDefaultModel(),
    maxBudgetUsd: getSentinelBudget(),
    permissionMode: "acceptEdits",
    reportFile: "SENTINEL_REPORT.md",
    allowedTools: ["Bash", "Glob", "Grep", "Read", "Write"],
};
/**
 * Internal helper: resolve a prompt using unified loader when projectRoot is
 * available, otherwise fall back to the bundled template-loader.
 *
 * @throws PromptNotFoundError when projectRoot is provided and the file is missing.
 */
function resolvePrompt(phase, vars, legacyFilename, opts) {
    const promptName = opts?.promptName ?? phase;
    if (opts?.projectRoot) {
        const workflow = opts.workflow ?? "default";
        return loadPrompt(promptName, vars, workflow, opts.projectRoot);
    }
    // Bundled fallback (backward compat / unit tests without project root)
    const fallbackFilename = opts?.promptName ? `${opts.promptName}-prompt.md` : legacyFilename;
    return loadAndInterpolate(fallbackFilename, vars);
}
export { PromptNotFoundError };
/**
 * Generic prompt builder for any workflow phase.
 * Builds template variables from the pipeline context and resolves the prompt
 * via the standard prompt loader (project-local → bundled fallback).
 */
export function buildPhasePrompt(phaseName, context, opts) {
    const commentsSection = context.seedComments ? `\n## Additional Context\n${context.seedComments}\n` : "";
    const explorerInstruction = context.hasExplorerReport
        ? `2. Read **EXPLORER_REPORT.md** for codebase context and follow its **Implementation Plan** unless you document a justified deviation`
        : `2. Explore the codebase to understand the relevant architecture`;
    const explorerPreflightSection = context.requiresExplorerReport
        ? `## Pre-flight: Check EXPLORER_REPORT.md
After verifying /send-mail, check if \`EXPLORER_REPORT.md\` exists in the worktree root:
\`\`\`bash
test -f EXPLORER_REPORT.md || echo "MISSING"
\`\`\`
If it is missing, invoke and stop — do not proceed with implementation:
\`\`\`
/send-mail --run-id "{{runId}}" --from "{{agentRole}}" --to foreman --subject agent-error --body '{"phase":"developer","seedId":"{{seedId}}","error":"EXPLORER_REPORT.md is missing — explorer phase did not complete successfully"}'
\`\`\`
Then exit. Do not write any code. Do not write DEVELOPER_REPORT.md.`
        : "";
    const feedbackSection = context.feedbackContext
        ? `\n## Focused Repair Feedback\nAddress ONLY the issues below from the previous verification/review. Do not redesign unrelated code. Do not create temporary debug tests, console logs, or one-off debug files. Prefer the smallest patch that makes the reported verification pass. If you need to touch more than five source/test files, explain why in DEVELOPER_REPORT.md before doing so.\n${context.feedbackContext}\n`
        : "";
    const vars = {
        seedId: context.seedId,
        seedTitle: context.seedTitle,
        seedDescription: context.seedDescription,
        commentsSection,
        explorerInstruction,
        explorerPreflightSection,
        feedbackSection,
        runId: context.runId ?? "",
        agentRole: phaseName,
        baseBranch: context.baseBranch ?? "main",
        worktreePath: context.worktreePath ?? "",
        reportDir: context.reportDir ?? "",
        seedType: context.seedType ?? "",
        // VCS finalize command variables (TRD-026)
        vcsStageCommand: context.vcsStageCommand ?? "git add -A",
        vcsCommitCommand: context.vcsCommitCommand ?? `git commit -m "${context.seedTitle} (${context.seedId})"`,
        vcsPushCommand: context.vcsPushCommand ?? `git push -u origin foreman/${context.seedId}`,
        vcsIntegrateTargetCommand: context.vcsIntegrateTargetCommand ?? `git fetch origin && git rebase origin/${context.baseBranch ?? "main"}`,
        vcsBranchVerifyCommand: context.vcsBranchVerifyCommand ?? "git rev-parse --abbrev-ref HEAD",
        vcsCleanCommand: context.vcsCleanCommand ?? `git worktree remove --force ${context.worktreePath ?? ""}`,
        vcsRestoreTrackedStateCommand: context.vcsRestoreTrackedStateCommand ?? `git restore --source=HEAD --staged --worktree -- .beads/issues.jsonl 2>/dev/null || git restore --source=HEAD --worktree -- .beads/issues.jsonl 2>/dev/null || true`,
        qaValidatedTargetRef: context.qaValidatedTargetRef ?? "",
        currentTargetRef: context.currentTargetRef ?? "",
        shouldRunFinalizeValidation: context.shouldRunFinalizeValidation ?? "true",
        // VCS context variables (TRD-027)
        vcsBackendName: context.vcsBackendName ?? "git",
        vcsBranchPrefix: context.vcsBranchPrefix ?? "foreman/",
    };
    // Map phase names to legacy template filenames for bundled fallback.
    const legacyFilename = `${phaseName}-prompt.md`;
    const resolved = resolvePrompt(phaseName, vars, legacyFilename, opts);
    const cwd = context.worktreePath ?? process.cwd();
    return expandCommandPlaceholders(resolved, cwd);
}
export function explorerPrompt(seedId, seedTitle, seedDescription, seedComments, runId, opts) {
    const commentsSection = seedComments ? `\n## Additional Context\n${seedComments}\n` : "";
    return resolvePrompt("explorer", { seedId, seedTitle, seedDescription, commentsSection, runId: runId ?? "", agentRole: "explorer" }, "explorer-prompt.md", opts);
}
export function developerPrompt(seedId, seedTitle, seedDescription, hasExplorerReport, feedbackContext, seedComments, runId, opts) {
    // NOTE: These strings are injected at the {{explorerInstruction}} placeholder in
    // developer.md (formerly developer-prompt.md), which appears between hardcoded
    // step 1 and step 3 in the Instructions list. Both values must always begin with
    // "2. " to keep the list sequential. If a new step is added before the placeholder
    // in the template, update the numbering here to match.
    const explorerInstruction = hasExplorerReport
        ? `2. Read **EXPLORER_REPORT.md** for codebase context and follow its **Implementation Plan** unless you document a justified deviation`
        : `2. Explore the codebase to understand the relevant architecture`;
    const feedbackSection = feedbackContext
        ? `\n## Focused Repair Feedback\nAddress ONLY the issues below from the previous verification/review. Do not redesign unrelated code. Do not create temporary debug tests, console logs, or one-off debug files. Prefer the smallest patch that makes the reported verification pass. If you need to touch more than five source/test files, explain why in DEVELOPER_REPORT.md before doing so.\n${feedbackContext}\n`
        : "";
    const commentsSection = seedComments ? `\n## Additional Context\n${seedComments}\n` : "";
    return resolvePrompt("developer", {
        seedId,
        seedTitle,
        seedDescription,
        explorerInstruction,
        feedbackSection,
        commentsSection,
        runId: runId ?? "",
        agentRole: "developer",
    }, "developer-prompt.md", opts);
}
export function qaPrompt(seedId, seedTitle, runId, opts) {
    return resolvePrompt("qa", { seedId, seedTitle, runId: runId ?? "", agentRole: "qa" }, "qa-prompt.md", opts);
}
export function reviewerPrompt(seedId, seedTitle, seedDescription, seedComments, runId, opts) {
    const commentsSection = seedComments ? `\n## Additional Context\n${seedComments}\n` : "";
    return resolvePrompt("reviewer", { seedId, seedTitle, seedDescription, commentsSection, runId: runId ?? "", agentRole: "reviewer" }, "reviewer-prompt.md", opts);
}
export function finalizePrompt(seedId, seedTitle, runId, baseBranch, opts, worktreePath) {
    const resolvedBase = baseBranch ?? "main";
    const resolvedWorktree = worktreePath ?? "";
    return resolvePrompt("finalize", {
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
        vcsIntegrateTargetCommand: `git fetch origin && git rebase origin/${resolvedBase}`,
        vcsBranchVerifyCommand: "git rev-parse --abbrev-ref HEAD",
        vcsCleanCommand: `git worktree remove --force ${resolvedWorktree}`,
        qaValidatedTargetRef: "",
        currentTargetRef: "",
        shouldRunFinalizeValidation: "true",
    }, "finalize-prompt.md", opts);
}
export function sentinelPrompt(branch, testCommand, opts) {
    return resolvePrompt("sentinel", { branch, testCommand }, "sentinel-prompt.md", opts);
}
/**
 * Parse a report file for a PASS/FAIL verdict.
 * Looks for "## Verdict: PASS" or "## Verdict: FAIL" patterns.
 */
export function parseVerdict(reportContent) {
    const verdictMatch = reportContent.match(/##\s*Verdict:\s*(PASS|FAIL)/i);
    if (!verdictMatch)
        return "unknown";
    return verdictMatch[1].toLowerCase();
}
/**
 * Extract issues from a review report for developer feedback.
 */
export function parseFinalizeFailureScope(reportContent) {
    const inlineMatch = reportContent.match(/##\s*Failure Scope:\s*(?:\*\*)?(MODIFIED_FILES|UNRELATED_FILES|UNKNOWN)(?:\*\*)?/i);
    if (inlineMatch)
        return inlineMatch[1].toLowerCase();
    const sectionMatch = reportContent.match(/##\s*Failure Scope\s*\n(?:-\s*)?(?:\*\*)?(MODIFIED_FILES|UNRELATED_FILES|UNKNOWN)(?:\*\*)?/i);
    if (sectionMatch)
        return sectionMatch[1].toLowerCase();
    const analysisMatch = reportContent.match(/##\s*Failure Scope Analysis[\s\S]*?(?:###\s*)?Classification:\s*(?:\*\*)?(MODIFIED_FILES|UNRELATED_FILES|UNKNOWN)(?:\*\*)?/i);
    if (analysisMatch)
        return analysisMatch[1].toLowerCase();
    const fallbackMatch = reportContent.match(/Classification:\s*(?:\*\*)?(MODIFIED_FILES|UNRELATED_FILES|UNKNOWN)(?:\*\*)?/i);
    if (fallbackMatch)
        return fallbackMatch[1].toLowerCase();
    return "unknown";
}
export function parseFinalizeValidationStatus(reportContent) {
    const inlineMatch = reportContent.match(/##\s*Test Validation:\s*(?:\*\*)?(PASS|FAIL|SKIPPED)(?:\*\*)?/i);
    if (inlineMatch)
        return inlineMatch[1].toLowerCase();
    const sectionMatch = reportContent.match(/##\s*Test Validation\s*\n(?:-\s*Status:\s*)?(?:\*\*)?(PASS|FAIL|SKIPPED)(?:\*\*)?/i);
    if (sectionMatch)
        return sectionMatch[1].toLowerCase();
    const bulletMatch = reportContent.match(/##\s*Test Validation[\s\S]*?-\s*Status:\s*(PASS|FAIL|SKIPPED)/i);
    if (bulletMatch)
        return bulletMatch[1].toLowerCase();
    return "unknown";
}
export function parseFinalizeIntegrationStatus(reportContent) {
    const inlineMatch = reportContent.match(/##\s*Target Integration:\s*(?:\*\*)?(SUCCESS|FAIL|SKIPPED)(?:\*\*)?/i);
    if (inlineMatch)
        return inlineMatch[1].toLowerCase();
    const sectionMatch = reportContent.match(/##\s*Target Integration\s*\n(?:-\s*Status:\s*)?(?:\*\*)?(SUCCESS|FAIL|SKIPPED)(?:\*\*)?/i);
    if (sectionMatch)
        return sectionMatch[1].toLowerCase();
    const bulletMatch = reportContent.match(/##\s*Target Integration[\s\S]*?-\s*Status:\s*(SUCCESS|FAIL|SKIPPED)/i);
    if (bulletMatch)
        return bulletMatch[1].toLowerCase();
    return "unknown";
}
export function qaReportHasTestEvidence(reportContent) {
    const hasCommand = /(npm test|npx\s+vitest(?:\s+run)?|pnpm\s+vitest(?:\s+run)?|yarn\s+vitest(?:\s+run)?|vitest\s+run)/i.test(reportContent);
    const hasCounts = /(\b\d+\s+passed\b|\b\d+\s+failed\b|\btests? failed out of\b|\btests?:\s*\d+\s+passed[, ]+\d+\s+failed\b)/i.test(reportContent);
    return hasCommand && hasCounts;
}
export function extractIssues(reportContent) {
    // Extract everything between ## Issues and the next ## heading
    const issuesMatch = reportContent.match(/## Issues\n([\s\S]*?)(?=\n## |$)/);
    if (!issuesMatch)
        return "(no specific issues listed)";
    return issuesMatch[1].trim();
}
/**
 * Check if a report has actionable issues (CRITICAL, WARNING, or NOTE).
 */
export function hasActionableIssues(reportContent) {
    const issues = extractIssues(reportContent);
    if (issues === "(no specific issues listed)")
        return false;
    return /\*\*\[(CRITICAL|WARNING|NOTE)\]\*\*/i.test(issues);
}
//# sourceMappingURL=roles.js.map