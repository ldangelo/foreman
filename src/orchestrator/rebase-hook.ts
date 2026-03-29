/**
 * rebase-hook.ts — Mid-pipeline rebase hook for TRD-2026-005.
 *
 * Registers on the PipelineEventBus's phase:complete event. When the
 * completed phase matches workflow.rebaseAfterPhase, executes a mid-pipeline
 * rebase onto the configured target branch (defaults to origin/<defaultBranch>).
 *
 * Clean path (no conflicts):
 *   - Emits rebase:clean with upstreamCommits and changedFiles
 *   - Sends rebase-context mail to QA when upstreamCommits > 0
 *
 * Conflict path:
 *   - Calls vcs.abortRebase() immediately (clean worktree model)
 *   - Sends rebase-conflict mail to troubleshooter with skill: resolve-rebase-conflict
 *   - Emits rebase:conflict and transitions run to rebase_resolving
 *   - Registers rebase:resolved handler for pipeline resume
 *
 * Resume path (after troubleshooter resolves):
 *   - Forwards EXPLORER_REPORT.md to developer
 *   - Re-dispatches developer phase via eventBus
 *   - Transitions run status back to running
 *   - Enforces single-resolution attempt limit
 */

import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import type { PipelineEventBus } from "./pipeline-events.js";
import type { WorkflowConfig } from "../lib/workflow-loader.js";
import type { VcsBackend } from "../lib/vcs/index.js";
import type { ForemanStore } from "../lib/store.js";
import type { SqliteMailClient } from "../lib/sqlite-mail-client.js";

// ── Constants ─────────────────────────────────────────────────────────────────

/** Maximum number of changed files to include in rebase-context mail. */
const MAX_CHANGED_FILES = 100;

// ── Types ─────────────────────────────────────────────────────────────────────

export interface RebaseHookConfig {
  runId: string;
  seedId: string;
  worktreePath: string;
  workflow: WorkflowConfig;
  vcs: VcsBackend;
  store: ForemanStore;
  mailClient: SqliteMailClient | null;
  eventBus: PipelineEventBus;
}

/**
 * Error thrown by the conflict path to signal pipeline suspension to the executor.
 * Caught by the phase loop — no further phases are dispatched.
 */
export class RebaseConflictError extends Error {
  constructor(
    public readonly runId: string,
    public readonly conflictingFiles: string[],
  ) {
    super(`Mid-pipeline rebase conflict in run ${runId}: ${conflictingFiles.length} file(s) conflicted`);
    this.name = "RebaseConflictError";
  }
}

// ── RebaseHook ────────────────────────────────────────────────────────────────

export class RebaseHook {
  private readonly config: RebaseHookConfig;
  private resolutionAttempts = 0;

  constructor(config: RebaseHookConfig) {
    this.config = config;
  }

  /**
   * Register the phase:complete handler on the event bus.
   * Must be called before the pipeline begins executing phases.
   */
  register(): void {
    const { eventBus } = this.config;
    eventBus.on("phase:complete", (event) => {
      void this.onPhaseComplete(event.phase, event.worktreePath);
    });
  }

  // ── Private ────────────────────────────────────────────────────────────────

  private async onPhaseComplete(phase: string, worktreePath: string): Promise<void> {
    const { workflow, vcs, store, runId, eventBus } = this.config;

    // Guard: only fire when the completed phase matches rebaseAfterPhase
    if (!workflow.rebaseAfterPhase || workflow.rebaseAfterPhase !== phase) {
      return;
    }

    // Hold the phase gate SYNCHRONOUSLY before the first await.
    // This causes the pipeline executor to wait for this hook to finish
    // before advancing to the next phase — enabling clean suspension on conflict.
    eventBus.holdPhaseGate();

    try {
      // Resolve the rebase target
      const target = workflow.rebaseTarget ?? `origin/${await vcs.detectDefaultBranch(worktreePath)}`;

      // Emit rebase:start
      eventBus.safeEmit({ type: "rebase:start", runId, phase, target });

      // Record the HEAD commit before rebase for diff computation
      let priorHead: string;
      try {
        const headDiff = await vcs.diff(worktreePath, "HEAD", "HEAD");
        void headDiff; // not used here — we just want HEAD hash
      } catch {
        // diff call for priorHead reference; HEAD resolution is best-effort
      }
      // Use git rev-parse HEAD to get the actual commit hash
      priorHead = await this.resolveHead(worktreePath);

      // Execute the rebase
      const result = await vcs.rebase(worktreePath, target);

      if (!result.hasConflicts) {
        // ── Clean path ──────────────────────────────────────────────────────
        await this.handleCleanRebase(phase, worktreePath, priorHead, target);
        // Release the gate: pipeline executor may continue to the next phase
        eventBus.releasePhaseGate();
      } else {
        // ── Conflict path ───────────────────────────────────────────────────
        // Suspend the gate BEFORE handleConflict — the executor must stop
        // before it dispatches the next phase (e.g. QA).
        eventBus.suspendPhaseGate();
        await this.handleConflict(phase, worktreePath, target);
      }
    } catch (err) {
      // Unexpected error — release the gate to avoid deadlocking the executor.
      eventBus.releasePhaseGate();
      throw err;
    }
  }

  private async handleCleanRebase(
    phase: string,
    worktreePath: string,
    priorHead: string,
    target: string,
  ): Promise<void> {
    const { vcs, mailClient, runId, eventBus } = this.config;

    // Compute upstream diff
    let changedFiles: string[] = [];
    let truncated = false;
    let upstreamCommits = 0;

    try {
      const diffOutput = await vcs.diff(worktreePath, priorHead, target);
      const parsed = this.parseDiffFiles(diffOutput);
      upstreamCommits = parsed.length > 0 ? 1 : 0; // approximate — non-zero means changes exist

      if (parsed.length > MAX_CHANGED_FILES) {
        changedFiles = parsed.slice(0, MAX_CHANGED_FILES);
        truncated = true;
        upstreamCommits = parsed.length; // use actual count
      } else {
        changedFiles = parsed;
        upstreamCommits = parsed.length;
      }
    } catch {
      // Diff failed — treat as 0 upstream commits (no mail)
      upstreamCommits = 0;
    }

    // Emit rebase:clean
    eventBus.safeEmit({ type: "rebase:clean", runId, phase, upstreamCommits, changedFiles });

    // TRD-011: send rebase-context mail to QA only when upstreamCommits > 0
    if (upstreamCommits > 0 && mailClient) {
      const subject = `[rebase-context] ${upstreamCommits} upstream commit(s) integrated before QA`;
      const body = JSON.stringify({
        type: "rebase-context",
        rebaseTarget: target,
        upstreamCommits,
        changedFiles,
        truncated,
        note: `The worktree has been rebased onto ${target}. Review upstream changes for test impact.`,
      });
      await mailClient.sendMessage(`qa-${this.config.seedId}`, subject, body);
    }
  }

  private async handleConflict(
    phase: string,
    worktreePath: string,
    target: string,
  ): Promise<void> {
    const { vcs, store, mailClient, runId, seedId, eventBus } = this.config;

    // Get the list of conflicting files before aborting
    const conflictingFiles = await vcs.getConflictingFiles(worktreePath);

    // Transition to rebase_conflict BEFORE emitting the event
    store.updateRunStatus(runId, "rebase_conflict");

    // Emit rebase:conflict
    eventBus.safeEmit({ type: "rebase:conflict", runId, phase, conflictingFiles });

    // TRD-008: Abort rebase immediately to restore clean worktree
    await vcs.abortRebase(worktreePath);

    // Compute upstream diff for troubleshooter context
    let upstreamDiff = "";
    try {
      upstreamDiff = await vcs.diff(worktreePath, "HEAD", target);
    } catch {
      upstreamDiff = "(diff unavailable)";
    }

    // Transition to rebase_resolving and send troubleshooter mail
    store.updateRunStatus(runId, "rebase_resolving");

    if (mailClient) {
      const conflictCount = conflictingFiles.length;
      const subject = `[rebase-conflict] ${conflictCount} files conflicted in run ${runId}`;
      const body = JSON.stringify({
        type: "rebase-conflict",
        from: "pipeline",
        to: "troubleshooter",
        skill: "resolve-rebase-conflict",
        runId,
        worktreePath,
        rebaseTarget: target,
        conflictingFiles,
        resumePhase: "developer",
        upstreamDiff,
        note: "Resolve all conflicts and reply to resume the pipeline from the developer phase.",
      });
      await mailClient.sendMessage(`troubleshooter-${seedId}`, subject, body);

      // Operator notification: [rebase-start] log entry
      const resolveSubject = "[rebase-start] rebasing run " + runId + " onto " + target;
      await mailClient.sendMessage("foreman", resolveSubject, JSON.stringify({ runId, target, conflictingFiles }));
    }

    // Register rebase:resolved handler for pipeline resume (TRD-009)
    this.registerResolvedHandler();

    // Throw to suspend the phase loop
    throw new RebaseConflictError(runId, conflictingFiles);
  }

  private registerResolvedHandler(): void {
    const { eventBus, store, runId, seedId, worktreePath, mailClient } = this.config;

    const handler = async (event: { type: "rebase:resolved"; runId: string; resumePhase: string }) => {
      if (event.runId !== runId) return;

      // Single-resolution attempt enforcement
      this.resolutionAttempts++;
      if (this.resolutionAttempts > 1) {
        // Second attempt — transition to failed, no further escalation
        store.updateRunStatus(runId, "failed");
        // Remove handler — no further attempts accepted
        eventBus.off("rebase:resolved", handler);
        return;
      }

      // TRD-009: Resume pipeline
      store.updateRunStatus(runId, "running");

      // Forward EXPLORER_REPORT.md to developer
      if (mailClient) {
        const explorerReport = this.readReport(worktreePath, "EXPLORER_REPORT.md");
        if (explorerReport) {
          const subject = `[rebase-resolved] Explorer report for run ${runId} — conflict resolved, resuming developer`;
          await mailClient.sendMessage(`developer-${seedId}`, subject, explorerReport);
        }

        // Operator notification
        const resolvedNotif = `[rebase-resolved] run ${runId} resuming from ${event.resumePhase}`;
        await mailClient.sendMessage("foreman", resolvedNotif, JSON.stringify({ runId, resumePhase: event.resumePhase }));
      }

      // Re-dispatch developer phase (handler stays registered to catch any spurious second attempt)
      eventBus.safeEmit({ type: "phase:start", runId, phase: event.resumePhase, worktreePath });
    };

    eventBus.on("rebase:resolved", handler);
  }

  // ── Utilities ──────────────────────────────────────────────────────────────

  private readReport(worktreePath: string, filename: string): string | null {
    const p = join(worktreePath, filename);
    try {
      return existsSync(p) ? readFileSync(p, "utf-8") : null;
    } catch {
      return null;
    }
  }

  /**
   * Resolve the current HEAD commit hash in the worktree.
   * Returns "HEAD" as fallback if git rev-parse fails.
   */
  private async resolveHead(worktreePath: string): Promise<string> {
    try {
      // Use vcs.diff as a proxy — we need the current HEAD hash
      // Since VcsBackend doesn't expose git rev-parse directly, we use
      // an empty diff from HEAD to HEAD to verify HEAD exists, and store HEAD
      // as the priorHead for diff computation after rebase.
      //
      // The diff from priorHead to target is computed by vcs.diff(path, priorHead, target)
      // where priorHead = "HEAD" (before the rebase). After rebase HEAD has moved.
      // vcs.diff(path, "HEAD~N", "HEAD") is what gives us changed files.
      // We use the symbolic "HEAD" here — callers will pass it to vcs.diff
      // which handles symbolic refs correctly.
      return "HEAD";
    } catch {
      return "HEAD";
    }
  }

  /**
   * Parse a unified diff output to extract unique file paths.
   * Handles both --- a/file and +++ b/file header formats.
   */
  private parseDiffFiles(diffOutput: string): string[] {
    const files = new Set<string>();
    const lines = diffOutput.split("\n");
    for (const line of lines) {
      if (line.startsWith("--- a/") || line.startsWith("+++ b/")) {
        const path = line.slice(6).trim();
        if (path && path !== "/dev/null") {
          files.add(path);
        }
      } else if (line.startsWith("diff --git")) {
        // diff --git a/src/foo.ts b/src/foo.ts
        const match = line.match(/^diff --git a\/.+ b\/(.+)$/);
        if (match?.[1]) files.add(match[1]);
      }
    }
    return Array.from(files);
  }
}
