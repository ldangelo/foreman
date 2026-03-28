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
import { PromptNotFoundError } from "../lib/prompt-loader.js";
import { PI_PHASE_CONFIGS } from "./pi-rpc-spawn-strategy.js";
export { PI_PHASE_CONFIGS };
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
export declare const PLAN_STEP_CONFIG: PlanStepConfig;
/**
 * Complete vocabulary of Claude Code agent tools available in the running process
 * environment. Used to compute disallowed tools as the complement of each role's
 * allowedTools whitelist.
 */
export declare const ALL_AGENT_TOOLS: ReadonlyArray<string>;
/**
 * Compute the disallowed tools for a role config.
 * Returns all SDK tools NOT in the role's allowedTools whitelist.
 */
export declare function getDisallowedTools(config: RoleConfig): string[];
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
export declare function buildRoleConfigs(): Record<Exclude<AgentRole, "lead" | "worker" | "sentinel">, RoleConfig>;
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
export declare const ROLE_CONFIGS: Record<Exclude<AgentRole, "lead" | "worker" | "sentinel">, RoleConfig>;
/** Standalone role config for the sentinel (not part of the pipeline). */
export declare const SENTINEL_ROLE_CONFIG: RoleConfig;
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
export { PromptNotFoundError };
/**
 * Generic prompt builder for any workflow phase.
 * Builds template variables from the pipeline context and resolves the prompt
 * via the standard prompt loader (project-local → bundled fallback).
 */
export declare function buildPhasePrompt(phaseName: string, context: {
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
}, opts?: PromptLoaderOpts): string;
export declare function explorerPrompt(seedId: string, seedTitle: string, seedDescription: string, seedComments?: string, runId?: string, opts?: PromptLoaderOpts): string;
export declare function developerPrompt(seedId: string, seedTitle: string, seedDescription: string, hasExplorerReport: boolean, feedbackContext?: string, seedComments?: string, runId?: string, opts?: PromptLoaderOpts): string;
export declare function qaPrompt(seedId: string, seedTitle: string, runId?: string, opts?: PromptLoaderOpts): string;
export declare function reviewerPrompt(seedId: string, seedTitle: string, seedDescription: string, seedComments?: string, runId?: string, opts?: PromptLoaderOpts): string;
export declare function finalizePrompt(seedId: string, seedTitle: string, runId?: string, baseBranch?: string, opts?: PromptLoaderOpts, worktreePath?: string): string;
export declare function sentinelPrompt(branch: string, testCommand: string, opts?: PromptLoaderOpts): string;
export type Verdict = "pass" | "fail" | "unknown";
/**
 * Parse a report file for a PASS/FAIL verdict.
 * Looks for "## Verdict: PASS" or "## Verdict: FAIL" patterns.
 */
export declare function parseVerdict(reportContent: string): Verdict;
/**
 * Extract issues from a review report for developer feedback.
 */
export declare function extractIssues(reportContent: string): string;
/**
 * Check if a report has actionable issues (CRITICAL, WARNING, or NOTE).
 */
export declare function hasActionableIssues(reportContent: string): boolean;
//# sourceMappingURL=roles.d.ts.map