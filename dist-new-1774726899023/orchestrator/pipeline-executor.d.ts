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
import type { WorkflowConfig } from "../lib/workflow-loader.js";
import type { PhaseRecord } from "./session-log.js";
import type { SqliteMailClient } from "../lib/sqlite-mail-client.js";
import type { ForemanStore, RunProgress } from "../lib/store.js";
import type { VcsBackend } from "../lib/vcs/index.js";
type AnyMailClient = SqliteMailClient;
/** Function signature matching the runPhase() in agent-worker.ts. */
export type RunPhaseFn = (role: any, prompt: string, config: any, progress: RunProgress, logFile: string, store: ForemanStore, notifyClient: any, agentMailClient?: AnyMailClient | null) => Promise<PhaseResult>;
export interface PhaseResult {
    success: boolean;
    costUsd: number;
    turns: number;
    tokensIn: number;
    tokensOut: number;
    error?: string;
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
    skipExplore?: boolean;
    skipReview?: boolean;
    env: Record<string, string | undefined>;
    /** Override target branch for finalize rebase/push and auto-merge. */
    targetBranch?: string;
    /**
     * VCS backend instance for computing backend-specific commands.
     * When provided, finalize and reviewer prompts are rendered with
     * backend-specific VCS command variables (TRD-026, TRD-027).
     * Falls back to git defaults when absent.
     */
    vcsBackend?: VcsBackend;
}
export interface PipelineContext {
    config: PipelineRunConfig;
    workflowConfig: WorkflowConfig;
    store: ForemanStore;
    logFile: string;
    notifyClient: any;
    agentMailClient: AnyMailClient | null;
    /** The runPhase function from agent-worker.ts */
    runPhase: RunPhaseFn;
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
     * Called after the last phase (finalize) completes successfully.
     * Responsible for: reading finalize mail, enqueuing to merge queue,
     * updating run status, resetting seed on failure, sending branch-ready mail.
     */
    onPipelineComplete?: (info: {
        progress: RunProgress;
        phaseRecords: PhaseRecord[];
        retryCounts: Record<string, number>;
    }) => Promise<void>;
}
/**
 * Execute a workflow pipeline driven entirely by the YAML config.
 *
 * Iterates workflowConfig.phases in order. For each phase:
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
export {};
//# sourceMappingURL=pipeline-executor.d.ts.map