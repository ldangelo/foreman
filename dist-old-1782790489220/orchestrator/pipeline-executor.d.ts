/**
 * pipeline-executor.ts — Generic workflow-driven pipeline executor.
 *
 * Iterates the phases defined in a WorkflowConfig YAML and executes each
 * one via runPhase(). All phase-specific behavior (mail hooks, artifacts,
 * retry loops, file reservations, verdict parsing) is driven by the YAML
 * config — no hardcoded phase names.
 *
 * This replaces the ~450-line hardcoded runPipeline() in agent-worker.ts.
 */
import type { WorkflowConfig, WorkflowPhaseConfig, WorkflowSandboxConfig } from "../lib/workflow-loader.js";
import type { TaskMeta } from "../lib/interpolate.js";
import type { ProjectHooksConfig } from "../lib/project-config.js";
import type { PhaseRecord } from "./session-log.js";
import type { AgentMailClient } from "../lib/agent-mail-client.js";
import type { ForemanStore } from "../lib/store.js";
import type { RunProgress } from "../lib/store.js";
import type { VcsBackend } from "../lib/vcs/index.js";
import { HeartbeatManager } from "./heartbeat-manager.js";
import { type PhaseRecord as ActivityPhaseRecord } from "./activity-logger.js";
type AnyMailClient = AgentMailClient;
/** Function signature matching the runPhase() in agent-worker.ts. */
export type RunPhaseFn = (role: any, prompt: string, config: any, progress: RunProgress, logFile: string, store: ForemanStore, notifyClient: any, agentMailClient?: AnyMailClient | null, observability?: PhaseObservabilityInput, observabilityWriter?: PipelineObservabilityWriter) => Promise<PhaseResult>;
export interface PhaseResult {
    success: boolean;
    costUsd: number;
    turns: number;
    tokensIn: number;
    tokensOut: number;
    error?: string;
    outputText?: string;
    traceFile?: string;
    traceMarkdownFile?: string;
    traceWarnings?: string[];
    commandHonored?: boolean;
    filesChanged?: string[];
    /** Stop remaining phases and treat the pipeline as successful. Used by builtins that complete work without a PR. */
    stopPipelineSuccess?: boolean;
}
export interface PhaseObservabilityInput {
    phaseType?: "prompt" | "command" | "bash" | "builtin";
    expectedArtifact?: string;
    resolvedCommand?: string;
    workflowName?: string;
    workflowPath?: string;
}
export interface PipelineObservabilityWriter {
    updateProgress?: (progress: RunProgress) => Promise<void> | void;
    logEvent?: (eventType: "phase-start" | "complete" | "heartbeat", data: Record<string, unknown>) => Promise<void> | void;
}
/** A child task within an epic pipeline run. */
export interface EpicTask {
    /** Bead/seed ID of the child task. */
    seedId: string;
    /** Title of the child task bead. */
    seedTitle: string;
    /** Description of the child task bead. */
    seedDescription?: string;
    /** GitHub issue number for this task (from github_issue_number field). */
    githubIssueNumber?: number;
}
export interface PipelineRunConfig {
    runId: string;
    projectId: string;
    seedId: string;
    seedTitle: string;
    seedDescription?: string;
    seedComments?: string;
    seedType?: string;
    seedLabels?: string[];
    /**
     * Bead priority string ("P0"–"P4", "0"–"4", or undefined).
     * Used to select the per-priority model from the workflow YAML models map.
     */
    seedPriority?: string;
    model: string;
    worktreePath: string;
    projectPath?: string;
    env: Record<string, string | undefined>;
    /** Override target branch for finalize rebase/push and auto-merge. */
    targetBranch?: string;
    /** GitHub issue number for this task (from github_issue_number field). */
    githubIssueNumber?: number;
    /**
     * VCS backend instance for computing backend-specific commands.
     * When provided, finalize and reviewer prompts are rendered with
     * backend-specific VCS command variables (TRD-026, TRD-027).
     * Falls back to git defaults when absent.
     */
    vcsBackend?: VcsBackend;
    /**
     * Optional task ID from native task store.
     * When present, pipeline-executor passes it to onTaskPhaseChange(taskId, phaseName)
     * at each phase transition (REQ-012).
     */
    taskId?: string | null;
    /**
     * Parent epic bead ID. When set, this run is part of an epic execution.
     * Used to link child task results back to the parent epic.
     */
    epicId?: string;
    /** Task metadata for placeholder interpolation in bash/command phases (REQ-008). */
    taskMeta?: TaskMeta;
    /** Directory guardrail config (FR-1). Passed through to PiRunOptions.guardrailConfig. */
    guardrailConfig?: {
        mode?: "auto-correct" | "veto" | "disabled";
        expectedCwd?: string;
        allowedPaths?: string[];
    };
    /** Workspace lifecycle hooks for afterRun (passed through from WorkerConfig). */
    hooks?: ProjectHooksConfig;
}
export interface PipelineContext {
    config: PipelineRunConfig;
    workflowConfig: WorkflowConfig;
    store: ForemanStore;
    logFile: string;
    notifyClient: any;
    agentMailClient: AnyMailClient | null;
    /**
     * Optional task lifecycle callback for phase-level visibility.
     * When present, invoked after each successful phase completion with the
     * task ID and phase name.
     */
    onTaskPhaseChange?: (taskId: string | null | undefined, phaseName: string) => Promise<void> | void;
    /**
     * Optional task note callback for append-only phase timeline visibility.
     */
    onTaskPhaseNote?: (taskId: string | null | undefined, phaseName: string, kind: "progress" | "failure" | "qa" | "review" | "final" | "system", body: string, metadata?: Record<string, unknown>) => Promise<void> | void;
    /**
     * Optional registered-aware observability writer for the normal single-task
     * phase progress/event path.
     */
    observabilityWriter?: PipelineObservabilityWriter;
    /**
     * Epic mode: ordered list of child tasks to execute.
     * When set, the pipeline executor runs taskPhases for each task
     * instead of running all phases in sequence for a single task.
     */
    epicTasks?: EpicTask[];
    /** The runPhase function from agent-worker.ts */
    runPhase: RunPhaseFn;
    /** Execute a TypeScript builtin phase such as create-pr. */
    runBuiltinPhase?: (phase: import("../lib/workflow-loader.js").WorkflowPhaseConfig, progress?: RunProgress) => Promise<PhaseResult>;
    /** Register an agent identity for mail */
    registerAgent: (client: AnyMailClient | null, roleHint: string) => Promise<void>;
    /** Send structured mail */
    sendMail: (client: AnyMailClient | null, to: string, subject: string, body: Record<string, unknown>) => void;
    /** Send plain-text mail */
    sendMailText: (client: AnyMailClient | null, to: string, subject: string, body: string) => void;
    /** Reserve files for an agent */
    reserveFiles: (client: AnyMailClient | null, paths: string[], agentName: string, leaseSecs?: number) => void;
    /** Release file reservations */
    releaseFiles: (client: AnyMailClient | null, paths: string[], agentName: string) => void;
    /** Mark pipeline as stuck */
    markStuck: (...args: any[]) => Promise<void>;
    /** Log function */
    log: (msg: string) => void;
    /** Prompt loader options */
    promptOpts: {
        projectRoot: string;
        workflow: string;
    };
    /**
     * Epic mode callback: update a child task bead's status.
     * Called when a task starts (in_progress) or completes (closed/failed).
     */
    onTaskStatusChange?: (taskSeedId: string, status: "in_progress" | "completed" | "failed") => Promise<void>;
    /**
     * Epic mode callback: create a bug bead when QA fails on a task.
     * Returns the created bug bead ID, or undefined if creation fails.
     */
    onTaskQaFailure?: (taskSeedId: string, taskTitle: string, epicId: string) => Promise<string | undefined>;
    /**
     * Epic mode callback: close a bug bead when QA passes after retry.
     */
    onTaskQaPass?: (bugBeadId: string) => Promise<void>;
    /**
     * Called when a rate limit (429) is detected.
     * Used for alerting (P1) and per-model rate limit tracking (P2).
     * @param model - The model that was rate limited
     * @param phase - The phase where the rate limit occurred
     * @param error - The error message
     * @param retryAfterSeconds - Optional Retry-After header value
     */
    onRateLimit?: (model: string, phase: string, error: string, retryAfterSeconds?: number) => void;
    /**
     * Called after the last phase (finalize) completes.
     * Responsible for: reading finalize mail, enqueuing to merge queue,
     * updating run status, resetting seed on failure, sending branch-ready mail.
     * @param info.success - Whether the pipeline completed successfully.
     *                        Only send branch-ready when success=true AND currentPhase=finalize.
     */
    onPipelineComplete?: (info: {
        progress: RunProgress;
        phaseRecords: PhaseRecord[];
        retryCounts: Record<string, number>;
        success: boolean;
    }) => Promise<void>;
    /**
     * Task metadata for placeholder interpolation in bash/command phases (REQ-008).
     * Passed from the dispatcher via WorkerConfig.taskMeta.
     * Undefined for legacy runs without taskMeta.
     */
    taskMeta?: TaskMeta;
    /**
     * Heartbeat manager for periodic observability events during active phases (FR-3).
     * Created in executePipeline when vcsBackend is available and heartbeat is enabled.
     */
    heartbeatManager?: HeartbeatManager;
    /**
     * Activity log phase records accumulated during pipeline execution (FR-4).
     * Finalized and written as ACTIVITY_LOG.json at pipeline end.
     */
    activityPhases?: ActivityPhaseRecord[];
}
/**
 * Detect if an error is a rate limit (429) error.
 * Returns true if the error indicates a rate limit, false otherwise.
 */
export declare function isRateLimitError(error: string | undefined): boolean;
export declare function isMaxTurnsExceededError(error: string | undefined): boolean;
/** Return true when a failed phase should enter cooldown retry instead of terminal failure. */
export declare function shouldUseCooldownRetry(error: string | undefined, phase: Pick<WorkflowPhaseConfig, "retryAfterCooldown">): boolean;
export declare function applyEffectiveSandboxConfig(ctx: PipelineContext): void;
/**
 * Result of a bash phase execution.
 * Mirrors PhaseResult but includes stdout/stderr for artifact writing.
 */
export interface BashPhaseResult extends PhaseResult {
    stdout: string;
    stderr: string;
}
/**
 * Execute a bash phase via `/bin/sh -c` in the worktree directory.
 *
 * 1. Interpolate `{task.*}` placeholders using taskMeta from PipelineContext
 * 2. Run via execFile with cwd=worktreePath, timeout=120s
 * 3. Capture stdout + stderr
 * 4. Write artifact file if specified
 * 5. Return PASS (exit 0) or FAIL (non-zero exit code or timeout)
 */
export declare function runBashPhase(bashCommand: string, taskMeta: TaskMeta | undefined, cwd: string, artifactFile?: string, timeoutMs?: number, sandboxConfig?: WorkflowSandboxConfig): Promise<BashPhaseResult>;
/**
 * Execute a workflow pipeline driven entirely by the YAML config.
 *
 * Two modes:
 * - **Single-task mode** (default): iterates all `phases` in order for one task.
 * - **Epic mode**: when `ctx.epicTasks` is set AND workflow has `taskPhases`,
 *   iterates child tasks running only `taskPhases` per task (with per-task commits),
 *   then runs `finalPhases` once at the end.
 *
 * Per-phase behavior:
 *  1. Check skipIfArtifact (resume from crash)
 *  2. Register agent mail identity
 *  3. Send phase-started mail (if mail.onStart)
 *  4. Reserve files (if files.reserve)
 *  5. Run the phase via runPhase()
 *  6. Release files
 *  7. Handle success: send phase-complete mail, forward artifact, add labels
 *  8. Handle failure: send error mail, mark stuck
 *  9. If verdict phase: parse PASS/FAIL, handle retryWith loop
 */
export declare function executePipeline(ctx: PipelineContext): Promise<void>;
/**
 * Parse `git log --oneline` output from an epic worktree and extract
 * the task IDs of tasks that have already been committed.
 *
 * Commit messages follow the format: `<title> (<taskId>)`
 * For example: `Add user auth (task-7)` → extracts `task-7`.
 *
 * @returns A Set of completed task IDs found in the git history.
 */
export declare function parseCompletedTaskIds(gitLogOutput: string): Set<string>;
export {};
//# sourceMappingURL=pipeline-executor.d.ts.map