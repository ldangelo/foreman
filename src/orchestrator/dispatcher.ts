import { writeFile, mkdir, open, readdir, unlink } from "node:fs/promises";
import { existsSync, unlinkSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { spawn, execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { runWithPiSdk } from "./pi-sdk-runner.js";

import type { ITaskClient, Issue } from "../lib/task-client.js";
import type { EventType, ForemanStore, NativeTask, Run } from "../lib/store.js";
import type { RunStatus } from "./read-models.js";
import { STUCK_RETRY_CONFIG, calculateStuckBackoffMs, PIPELINE_TIMEOUTS, getDefaultModel } from "../lib/config.js";
import type { BvClient } from "../lib/bv.js";
import { installDependencies, runSetupWithCache, runWorkspaceHook } from "../lib/setup.js";
import { extractBranchLabel, isDefaultBranch, applyBranchLabel, isValidBranchLabel, normalizeBranchLabel } from "../lib/branch-label.js";
import { workerAgentMd } from "./templates.js";
import { normalizePriority } from "../lib/priority.js";
import { PLAN_STEP_CONFIG } from "./roles.js";
import { isPiAvailable } from "./pi-rpc-spawn-strategy.js";
import { resolveWorkflowType } from "../lib/workflow-config-loader.js";
import { loadWorkflowConfig, resolveWorkflowName } from "../lib/workflow-loader.js";
import { getTaskOrder } from "./task-ordering.js";
import { getPoolConfig } from "../lib/db/pool-manager.js";
import type { EpicTask } from "./pipeline-executor.js";
import { loadProjectConfig, resolveVcsConfig } from "../lib/project-config.js";
import { getWorkspacePath } from "../lib/workspace-paths.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
import type { VcsBackend } from "../lib/vcs/index.js";
import { checkAndRebaseStaleWorktree } from "./stale-worktree-check.js";
import { WorktreeManager } from "../lib/worktree-manager.js";
import type { TaskMeta } from "../lib/interpolate.js";
import { getRunReportsDir } from "../lib/report-paths.js";
import type {
  SeedInfo,
  DispatchResult,
  DispatchedTask,
  SkippedTask,
  ResumedTask,
  RuntimeSelection,
  ModelSelection,
  PlanStepDispatched,
} from "./types.js";
import type { RuntimeMode } from "../cli/commands/run.js";
import type { TaskOrderingClient } from "./task-ordering.js";

interface DispatcherDependencyRef {
  id: string;
}

interface DispatcherDependentRef {
  status: string;
}

interface DispatcherBeadsIssueDetail {
  children?: string[];
  dependents?: DispatcherDependentRef[];
  dependencies?: Array<string | DispatcherDependencyRef>;
}

interface NativeTaskOps {
  hasNativeTasks(): Promise<boolean>;
  getReadyTasks(): Promise<NativeTask[]>;
  getTaskByExternalId(externalId: string): Promise<NativeTask | null>;
  getTaskById(id: string): Promise<NativeTask | null>;
  claimTask(taskId: string, runId: string): Promise<boolean>;
  updateTaskStatus?(taskId: string, status: string): Promise<void>;
  updateTaskLabels?(taskId: string, labels: string[]): Promise<void>;
}

type Awaitable<T> = T | Promise<T>;

interface OrphanedWorkerConfigStore {
  getRun(runId: string): Awaitable<Run | null>;
}

interface BaseBranchRunLookup {
  getRunsForSeed(seedId: string): Awaitable<Run[]>;
}

export interface DispatcherOverrides {
  getRecentFailureCount?: (projectId: string, since: string) => Promise<number>;
  nativeTaskOps?: NativeTaskOps;
  getActiveSeedIds?: () => Promise<string[]>;
  hasActiveOrPendingRun?: (seedId: string) => Promise<boolean>;
  getActiveAgentCount?: () => Promise<number>;
  externalProjectId?: string;
  getRunsByStatus?: (status: RunStatus, projectId: string) => Promise<Run[]>;
  getRunsForSeed?: (seedId: string, projectId: string) => Promise<Run[]>;
  getRun?: (runId: string) => Promise<Run | null>;
  getActiveRuns?: (projectId: string) => Promise<Run[]>;
  runOps?: {
    createRun?: (args: {
      runId: string;
      projectId: string;
      seedId: string;
      agentType: string;
      branchName: string;
      worktreePath: string | null;
      baseBranch?: string | null;
      mergeStrategy?: Run["merge_strategy"];
    }) => Promise<Run | void>;
    updateRun?: (runId: string, updates: Partial<Pick<Run, "status" | "session_key" | "worktree_path" | "started_at" | "completed_at">>) => Promise<void>;
    sendMessage?: (runId: string, senderAgentType: string, recipientAgentType: string, subject: string, body: string) => Promise<void>;
    logEvent?: (runId: string, projectId: string, eventType: string, payload: Record<string, unknown>) => Promise<void>;
  };
}



/**
 * Convert a NativeTask row into a normalized Issue so that native tasks can be
 * processed by the same dispatch loop that handles Beads issues.
 *
 * Priority is stored as INTEGER (0–4) in the native store; normalise to string
 * form ('P0'–'P4') so the existing normalizePriority() helper works correctly.
 */
export function nativeTaskToIssue(task: NativeTask): Issue {
  let githubIssueNumber: number | undefined;
  if (task.external_id?.startsWith("github:")) {
    const match = task.external_id.match(/#(\d+)$/);
    if (match) {
      githubIssueNumber = parseInt(match[1]!, 10);
    }
  }
  return {
    id: task.id,
    title: task.title,
    type: task.type,
    priority: `P${task.priority}`,
    status: task.status,
    assignee: null,
    parent: null,
    created_at: task.created_at,
    updated_at: task.updated_at,
    description: task.description ?? undefined,
    labels: task.labels ?? undefined,
    githubIssueNumber,
  };
}

// ── Dispatcher ──────────────────────────────────────────────────────────

export class Dispatcher {
  private bvFallbackWarned = false;

  constructor(
    private seeds: ITaskClient,
    private store: ForemanStore,
    private projectPath: string,
    private bvClient?: BvClient | null,
    private overrides?: DispatcherOverrides,
  ) {}

  private requireRegisteredRunOp<K extends keyof NonNullable<DispatcherOverrides["runOps"]>>(
    method: K,
  ): NonNullable<NonNullable<DispatcherOverrides["runOps"]>[K]> {
    const op = this.overrides?.runOps?.[method];
    if (op) {
      return op;
    }

    const projectId = this.overrides?.externalProjectId;
    throw new Error(`Registered dispatcher write override missing runOps.${String(method)} for project ${projectId ?? "unknown"}`);
  }

  private validateRegisteredRunOps(requiredMethods: Array<keyof NonNullable<DispatcherOverrides["runOps"]>>): void {
    if (!this.overrides?.externalProjectId) return;

    for (const method of requiredMethods) {
      this.requireRegisteredRunOp(method);
    }
  }

  private async createRunRecord(
    projectId: string,
    seedId: string,
    agentType: string,
    worktreePath: string | null,
    branchName: string,
    opts?: {
      baseBranch?: string | null;
      mergeStrategy?: Run["merge_strategy"];
      sessionKey?: string | null;
    },
  ): Promise<Run> {
    if (this.overrides?.externalProjectId) {
      const createRun = this.requireRegisteredRunOp("createRun");
      const runId = randomUUID();
      const createdAt = new Date().toISOString();
      const run = await createRun({
        runId,
        projectId,
        seedId,
        agentType,
        branchName,
        worktreePath,
        baseBranch: opts?.baseBranch ?? null,
        mergeStrategy: opts?.mergeStrategy ?? null,
      });
      if (run) {
        return run;
      }
      return {
        id: runId,
        project_id: projectId,
        seed_id: seedId,
        agent_type: agentType,
        session_key: null,
        worktree_path: worktreePath,
        status: "pending",
        started_at: null,
        completed_at: null,
        created_at: createdAt,
        progress: null,
        tmux_session: null,
        base_branch: opts?.baseBranch ?? null,
        merge_strategy: opts?.mergeStrategy ?? "auto",
      };
    }

    const run = this.store.createRun(projectId, seedId, agentType, worktreePath ?? undefined, opts ? {
      ...opts,
      mergeStrategy: opts.mergeStrategy ?? undefined,
    } : undefined);
    return run;
  }

  private mapRunStatusForExternal(status: Run["status"]): "pending" | "running" | "success" | "failure" | "cancelled" | "skipped" | null {
    switch (status) {
      case "pending":
        return "pending";
      case "running":
        return "running";
      case "completed":
      case "merged":
      case "pr-created":
        return "success";
      case "failed":
      case "test-failed":
      case "stuck":
      case "conflict":
        return "failure";
      case "reset":
        return "cancelled";
      default:
        return null;
    }
  }

  private async updateRunRecord(
    runId: string,
    updates: Partial<Pick<Run, "status" | "session_key" | "worktree_path" | "started_at" | "completed_at">>,
  ): Promise<void> {
    const shouldPreserveTerminalSuccess = (currentStatus: Run["status"] | undefined, nextStatus: Run["status"] | undefined): boolean =>
      currentStatus !== undefined
      && nextStatus !== undefined
      && (currentStatus === "merged" || currentStatus === "pr-created")
      && (nextStatus === "failed" || nextStatus === "stuck");

    if (this.overrides?.externalProjectId) {
      const currentRun = this.overrides.getRun ? await this.overrides.getRun(runId) : null;
      if (shouldPreserveTerminalSuccess(currentRun?.status, updates.status)) {
        return;
      }

      const updateRun = this.requireRegisteredRunOp("updateRun");
      const normalized = { ...updates };
      if (updates.status) {
        const mapped = this.mapRunStatusForExternal(updates.status);
        if (!mapped) return;
        normalized.status = mapped as Run["status"];
      }
      await updateRun(runId, normalized);
      return;
    }

    const currentRun = "getRun" in this.store
      ? this.store.getRun(runId)
      : null;
    if (shouldPreserveTerminalSuccess(currentRun?.status, updates.status)) {
      return;
    }

    this.store.updateRun(runId, updates);
  }

  private async updateNativeTaskStatus(taskId: string, status: string): Promise<void> {
    if (this.overrides?.nativeTaskOps?.updateTaskStatus) {
      await this.overrides.nativeTaskOps.updateTaskStatus(taskId, status);
      return;
    }

    const storeWithNativeUpdate = this.store as ForemanStore & {
      updateTaskStatus?: (taskId: string, status: string) => void | Promise<void>;
      getDb?: () => { prepare: (sql: string) => { run: (params: Record<string, unknown>) => unknown } };
    };

    if (typeof storeWithNativeUpdate.updateTaskStatus === "function") {
      await storeWithNativeUpdate.updateTaskStatus(taskId, status);
      return;
    }

    if (typeof storeWithNativeUpdate.getDb === "function") {
      storeWithNativeUpdate.getDb()
        .prepare("UPDATE tasks SET status = @status, updated_at = @now WHERE id = @taskId")
        .run({ taskId, status, now: new Date().toISOString() });
    }
  }

  private async sendMailRecord(
    runId: string,
    senderAgentType: string,
    recipientAgentType: string,
    subject: string,
    body: string,
  ): Promise<void> {
    if (this.overrides?.externalProjectId) {
      const sendMessage = this.requireRegisteredRunOp("sendMessage");
      await sendMessage(runId, senderAgentType, recipientAgentType, subject, body);
      return;
    }

    this.store.sendMessage(runId, senderAgentType, recipientAgentType, subject, body);
  }

  private async logEventRecord(
    projectId: string,
    eventType: EventType,
    payload: Record<string, unknown>,
    runId: string,
  ): Promise<void> {
    if (this.overrides?.externalProjectId) {
      const logEvent = this.requireRegisteredRunOp("logEvent");
      await logEvent(runId, projectId, eventType, payload);
      return;
    }

    this.store.logEvent(projectId, eventType, payload, runId);
  }

  private async getActiveRunsRecord(projectId: string): Promise<Run[]> {
    if (this.overrides?.getActiveRuns) {
      return this.overrides.getActiveRuns(projectId);
    }
    return this.store.getActiveRuns(projectId);
  }

  private async getRunsByStatusRecord(
    status: Run["status"],
    projectId: string,
  ): Promise<Run[]> {
    if (this.overrides?.getRunsByStatus) {
      return this.overrides.getRunsByStatus(status, projectId);
    }
    return this.store.getRunsByStatus(status, projectId);
  }

  private async getRunsForSeedRecord(
    seedId: string,
    projectId: string,
  ): Promise<Run[]> {
    if (this.overrides?.getRunsForSeed) {
      return this.overrides.getRunsForSeed(seedId, projectId);
    }
    return this.store.getRunsForSeed(seedId, projectId);
  }

  private async getRunRecord(runId: string): Promise<Run | null> {
    if (this.overrides?.getRun) {
      return this.overrides.getRun(runId);
    }
    return this.store.getRun(runId);
  }

  /**
   * Query ready seeds, create worktrees, write TASK.md, and record runs.
   */
  async dispatch(opts?: {
    maxAgents?: number;
    runtime?: RuntimeSelection;
    runtimeMode?: RuntimeMode;
    model?: ModelSelection;
    dryRun?: boolean;
    telemetry?: boolean;
    projectId?: string;
    pipeline?: boolean;
    skipExplore?: boolean;
    skipReview?: boolean;
    seedId?: string;
    /** URL of the notification server (e.g. "http://127.0.0.1:PORT") */
    notifyUrl?: string;
    /** Override target branch for merges (when working on a feature branch instead of default). */
    targetBranch?: string;
    /** P1: Stagger delay in milliseconds between dispatches to prevent thundering herd. */
    staggerMs?: number;
  }): Promise<DispatchResult> {
    const maxAgents = opts?.maxAgents ?? 5;
    const projectId = opts?.projectId ?? this.resolveProjectId();

    if (!opts?.dryRun && this.overrides?.externalProjectId) {
      this.validateRegisteredRunOps(["createRun", "updateRun", "logEvent", "sendMessage"]);
    }

    // ── Startup workspace cleanup: remove orphaned worktrees for terminal issues ──
    // Clean up worktrees for issues that were already in a terminal state when
    // the daemon was not running. This catches issues closed between daemon restarts.
    try {
      const cleaned = await this.cleanupTerminalStateWorktrees(projectId);
      if (cleaned > 0) {
        console.error(`[dispatch] Cleaned ${cleaned} orphaned worktree(s) for terminal issues`);
      }
    } catch (cleanupErr: unknown) {
      // Non-fatal: cleanup failures must not block dispatch
      const msg = cleanupErr instanceof Error ? cleanupErr.message : String(cleanupErr);
      console.error(`[dispatch] cleanupTerminalStateWorktrees failed: ${msg.slice(0, 200)}`);
    }

    // ── Reconciliation: stop runs whose issues are terminal ───────────────
    // Catch issues that were closed/completed while an agent was still running.
    // These runs would otherwise continue until completion, wasting resources.
    try {
      const stopped = await this.reconcileRunningIssues(projectId);
      if (stopped > 0) {
        console.error(`[dispatch] Stopped ${stopped} run(s) with terminal issues`);
      }
    } catch (reconcileErr: unknown) {
      // Non-fatal: reconciliation failures must not block dispatch
      const msg = reconcileErr instanceof Error ? reconcileErr.message : String(reconcileErr);
      console.error(`[dispatch] reconcileRunningIssues failed: ${msg.slice(0, 200)}`);
    }

    // ── onError=stop guard ─────────────────────────────────────────────────
    // When the workflow's onError is "stop", refuse to dispatch if any recent
    // runs ended in a terminal failure state.
    try {
      const wfConfig = loadWorkflowConfig("default", this.projectPath);
      if (wfConfig.onError === "stop") {
        const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
        const failedCount = this.overrides?.getRecentFailureCount
          ? await this.overrides.getRecentFailureCount(projectId, since)
          : this.store.getRunsByStatusesSince(["test-failed", "failed", "stuck", "conflict"], since, projectId).length;
        if (failedCount > 0) {
          log(`[dispatch] onError=stop — ${failedCount} failed run(s) detected. Refusing to dispatch until resolved. Use 'foreman reset' to clear.`);
          return {
            dispatched: [],
            skipped: [],
            resumed: [],
             activeAgents: (await this.getActiveRunsRecord(projectId)).length,
           };
         }
       }
    } catch {
      // Workflow config not found — continue with default behavior
    }

    // ── Per-state concurrency limits (Backlog-006) ─────────────────────────
    // Load concurrency config and build a map of active runs by issue state.
    // States not in byState are unlimited (only constrained by global limit).
    let concurrencyConfig: import("../lib/project-config.js").ConcurrencyConfig | undefined;
    const activeRunsByState: Map<string, number> = new Map();
    try {
      const projectCfg = loadProjectConfig(this.projectPath);
      concurrencyConfig = projectCfg?.concurrency;
    } catch {
      // Non-fatal: concurrency config is optional
    }

    // Determine how many agent slots are available
    const activeRuns = await this.getActiveRunsRecord(projectId);
    const activeAgentCount = this.overrides?.getActiveAgentCount
      ? await this.overrides.getActiveAgentCount()
      : activeRuns.length;
    // Apply concurrency.global override if specified (caps the effective maxAgents)
    const effectiveMaxAgents = concurrencyConfig?.global != null && concurrencyConfig.global > 0
      ? Math.min(maxAgents, concurrencyConfig.global)
      : maxAgents;
    const available = Math.max(0, effectiveMaxAgents - activeAgentCount);

    // Build state count map from active runs (after config loaded so byState limits available)
    if (concurrencyConfig?.byState) {
      await Promise.all(
        activeRuns.map(async (run) => {
          try {
            // Look up task from native store: try external_id first, then id
            const task = this.overrides?.nativeTaskOps
              ? await this.overrides.nativeTaskOps.getTaskByExternalId(run.seed_id)
                ?? await this.overrides.nativeTaskOps.getTaskById(run.seed_id)
              : this.store.getTaskByExternalId(run.seed_id)
                ?? this.store.getTaskById(run.seed_id);
            if (task) {
              const state = task.status;
              activeRunsByState.set(state, (activeRunsByState.get(state) ?? 0) + 1);
            }
          } catch {
            // Task not found — skip this run from state count
          }
        }),
      );
    }

    // Track per-state pending dispatches within this cycle
    const statePendingCount: Record<string, number> = {};

    // ── Native task store ─────────────────────────────────────────────────
    // Load ready tasks from the native store exclusively.
    const nativeTasks = this.overrides?.nativeTaskOps
      ? await this.overrides.nativeTaskOps.getReadyTasks()
      : this.store.getReadyTasks();
    let readySeeds: Issue[] = nativeTasks.map(nativeTaskToIssue);

    // Sort ready seeds using bv triage scores when available, falling back to priority sort.
    if (!opts?.seedId) {
      if (this.bvClient) {
        const triageResult = await this.bvClient.robotTriage();
        if (triageResult !== null) {
          // Build a score map from bv recommendations
          const scoreMap = new Map<string, number>();
          for (const rec of triageResult.recommendations) {
            scoreMap.set(rec.id, rec.score);
          }
          readySeeds = [...readySeeds].sort((a, b) => {
            const hasA = scoreMap.has(a.id);
            const hasB = scoreMap.has(b.id);
            // Tasks in recommendations come before tasks not in recommendations
            if (hasA && !hasB) return -1;
            if (!hasA && hasB) return 1;
            if (hasA && hasB) {
              // Both ranked: sort by score descending
              return (scoreMap.get(b.id) ?? 0) - (scoreMap.get(a.id) ?? 0);
            }
            // Neither ranked: fall back to priority sort
            return normalizePriority(a.priority) - normalizePriority(b.priority);
          });
          log(`bv triage scored ${readySeeds.length} ready seeds`);
        } else {
          if (!this.bvFallbackWarned) {
            log("bv unavailable, using priority-sort fallback");
            this.bvFallbackWarned = true;
          }
          readySeeds = [...readySeeds].sort(
            (a, b) => normalizePriority(a.priority) - normalizePriority(b.priority),
          );
        }
      } else {
        // No bvClient provided — sort by priority
        readySeeds = [...readySeeds].sort(
          (a, b) => normalizePriority(a.priority) - normalizePriority(b.priority),
        );
      }
    }

    // Filter to a specific seed if requested
    if (opts?.seedId) {
      if (await this.hasMergedOutcomeWithoutLaterReset(opts.seedId, projectId)) {
        return {
          dispatched: [],
          skipped: [{
            seedId: opts.seedId,
            title: opts.seedId,
            reason: "Latest authoritative run already merged — use foreman reset/retry to rerun explicitly",
          }],
          resumed: [],
          activeAgents: activeRuns.length,
        };
      }
      let target = readySeeds.find((b) => b.id === opts.seedId);
      if (!target) {
        // Try external_id first (for tasks that have it set)
        let nativeMatch = this.overrides?.nativeTaskOps
          ? await this.overrides.nativeTaskOps.getTaskByExternalId(opts.seedId)
          : this.store.getTaskByExternalId(opts.seedId);
        // Fall back to id lookup when external_id is not set (common for native tasks)
        if (!nativeMatch) {
          nativeMatch = this.overrides?.nativeTaskOps
            ? await this.overrides.nativeTaskOps.getTaskById(opts.seedId)
            : this.store.getTaskById(opts.seedId);
        }
        if (nativeMatch) {
          if (nativeMatch.status === "ready") {
            target = nativeTaskToIssue(nativeMatch);
          } else {
            return {
              dispatched: [],
              skipped: [{
                seedId: opts.seedId,
                title: nativeMatch.title,
                reason: `Native task for ${opts.seedId} is ${nativeMatch.status} (not ready)`
              }],
              resumed: [],
              activeAgents: activeRuns.length,
            };
          }
        }
      }
      if (!target) {
        return {
          dispatched: [],
          skipped: [{ seedId: opts.seedId, title: opts.seedId, reason: `Task ${opts.seedId} not found` }],
          resumed: [],
          activeAgents: activeRuns.length,
        };
      }
      readySeeds = [target];
    }

    const dispatched: DispatchedTask[] = [];
    const skipped: SkippedTask[] = [];

    const resolveUsableBranchLabel = async (branch: string | undefined): Promise<string | undefined> => {
      const normalized = normalizeBranchLabel(branch);
      if (!normalized || !isValidBranchLabel(normalized)) return undefined;
      if (branchBackend?.name === "jujutsu") {
        const exists = await branchBackend.branchExists(this.projectPath, normalized).catch(() => false);
        if (!exists) return undefined;
      }
      return normalized;
    };

    // Detect current branch for auto-labeling (branch:<name> label).
    // Done once per dispatch() call using VcsBackend (TRD-015: migrate from git.js shims).
    let currentBranch: string | undefined;
    let defaultBranch: string | undefined;
    let branchBackend: VcsBackend | undefined;
    try {
      branchBackend = await VcsBackendFactory.create({ backend: "auto" }, this.projectPath);
      currentBranch = await resolveUsableBranchLabel(await branchBackend.getCurrentBranch(this.projectPath));
      defaultBranch = normalizeBranchLabel(await branchBackend.detectDefaultBranch(this.projectPath));
    } catch {
      // Non-fatal: branch detection failure must not block dispatch
    }

    // Skip seeds that already have an active run
    const activeSeedIds = new Set(
      this.overrides?.getActiveSeedIds
        ? await this.overrides.getActiveSeedIds()
        : activeRuns.map((r) => r.seed_id),
    );

    // Also skip seeds that have a completed-but-unmerged run (prevent duplicate runs)
    const completedRuns = await this.getRunsByStatusRecord("completed", projectId);
    const completedSeedIds = new Set(completedRuns.map((r) => r.seed_id));

    for (const seed of readySeeds) {
      if (await this.hasMergedOutcomeWithoutLaterReset(seed.id, projectId)) {
        skipped.push({
          seedId: seed.id,
          title: seed.title,
          reason: "Latest authoritative run already merged — explicit reset/retry required",
        });
        continue;
      }

      if (activeSeedIds.has(seed.id)) {
        skipped.push({
          seedId: seed.id,
          title: seed.title,
          reason: "Already has an active run",
        });
        continue;
      }

      if (completedSeedIds.has(seed.id)) {
        skipped.push({
          seedId: seed.id,
          title: seed.title,
          reason: "Has completed run awaiting merge — run 'foreman merge' or wait for auto-merge",
        });
        continue;
      }

      // ── Epic beads: dispatch through epic pipeline ─────────────────────────
      // Epic beads are dispatched as a single epic runner that executes all
      // child tasks sequentially within one worktree. Native task store does not
      // have children support, so epics dispatch as single-agent tasks.
      if (seed.type === "epic") {
        log(`[dispatch] Epic ${seed.id} — dispatching as single-agent task`);
        // Fall through to regular dispatch so the epic's phases
        // (developer → qa → finalize) run as a single worktree.
      }

      // Skip seeds that are in exponential backoff after recent stuck runs
      const backoffResult = await this.checkStuckBackoff(seed.id, projectId);
      if (backoffResult.inBackoff) {
        skipped.push({
          seedId: seed.id,
          title: seed.title,
          reason: backoffResult.reason ?? "In backoff period after recent stuck runs",
        });
        continue;
      }

      // ── Per-state concurrency limit check (Backlog-006) ─────────────────────
      // Check if this seed's target state has hit its per-state concurrency limit.
      // States not in byState are unlimited (only constrained by global available).
      if (concurrencyConfig?.byState) {
        const stateLimit = concurrencyConfig.byState[seed.status];
        if (stateLimit != null && stateLimit > 0) {
          const activeCount = activeRunsByState.get(seed.status) ?? 0;
          const pendingCount = statePendingCount[seed.status] ?? 0;
          if (activeCount + pendingCount >= stateLimit) {
            skipped.push({
              seedId: seed.id,
              title: seed.title,
              reason: `State '${seed.status}' concurrency limit reached (${stateLimit} active + pending)`,
            });
            continue;
          }
        }
      }

      if (dispatched.length >= available) {
        skipped.push({
          seedId: seed.id,
          title: seed.title,
          reason: `Agent limit reached (${effectiveMaxAgents})`,
        });
        continue;
      }

      // Track this pending dispatch for per-state limit accounting
      if (concurrencyConfig?.byState?.[seed.status] != null) {
        statePendingCount[seed.status] = (statePendingCount[seed.status] ?? 0) + 1;
      }

      // Fetch full issue details (description, notes/comments, labels) for agent context
      // Native-only: use nativeTaskOps.getTaskById() — never call this.seeds.show() as fallback
      let seedDetail: { description?: string | null; notes?: string | null; labels?: string[] } | undefined;
      try {
        if (this.overrides?.nativeTaskOps) {
          const nativeTask = await this.overrides.nativeTaskOps.getTaskById(seed.id);
          if (nativeTask) {
            seedDetail = {
              description: nativeTask.description,
              notes: null, // Native tasks do not support notes
              labels: nativeTask.labels ?? undefined,
            };
          }
        } else {
          // Non-native mode: use store.getTaskById() as primary, not this.seeds
          const storeTask = this.store.getTaskById(seed.id);
          if (storeTask) {
            seedDetail = {
              description: storeTask.description,
              notes: null,
              labels: storeTask.labels ?? undefined,
            };
          }
        }
      } catch {
        // Non-fatal: if fetch fails, proceed without detail context
        log(`Warning: failed to fetch details for seed ${seed.id}`);
      }

      // Fetch bead comments (design notes, reviewer feedback, etc.) for agent context
      // Native-only: skip comments fetch since native tasks do not support comments
      // Non-native mode: also skip since comments are a Beads-specific concept with no store equivalent
      const beadComments: string | null = null;

      // ── Branch label auto-labeling ─────────────────────────────────────────
      // If the current branch is not the default (main/master/dev), automatically
      // add a `branch:<currentBranch>` label to the bead so that refinery merges
      // the work into the correct branch instead of always targeting main/dev.
      //
      // Inheritance: if the seed has a parent bead with a branch: label, the child
      // inherits that label (even when the current branch is the default).
      //
      // Only applied when the bead doesn't already have a branch: label.
      if (currentBranch && defaultBranch) {
        const existingLabels: string[] = seedDetail?.labels ?? seed.labels ?? [];
        const existingBranchLabel = await resolveUsableBranchLabel(extractBranchLabel(existingLabels));

        if (!existingBranchLabel) {
          // Determine the branch to label with: prefer current non-default branch,
          // then check parent for inheritance.
          let labelBranch: string | undefined;

          if (!isDefaultBranch(currentBranch, defaultBranch)) {
            labelBranch = currentBranch;
          } else if (seed.parent) {
            // Check parent's branch: label for inheritance via native store
            try {
              const parentTask = this.overrides?.nativeTaskOps
                ? await this.overrides.nativeTaskOps.getTaskByExternalId(seed.parent)
                  ?? await this.overrides.nativeTaskOps.getTaskById(seed.parent)
                : this.store.getTaskByExternalId(seed.parent)
                  ?? this.store.getTaskById(seed.parent);
              if (parentTask) {
                const parentBranchLabel = await resolveUsableBranchLabel(extractBranchLabel(parentTask.labels ?? []));
                if (parentBranchLabel && !isDefaultBranch(parentBranchLabel, defaultBranch)) {
                  labelBranch = parentBranchLabel;
                }
              }
            } catch {
              // Non-fatal: parent label lookup failure must not block dispatch
            }
          }

          if (labelBranch) {
            const updatedLabels = applyBranchLabel(existingLabels, labelBranch);
            try {
              // Update labels via native store
              if (this.overrides?.nativeTaskOps?.updateTaskLabels) {
                await this.overrides.nativeTaskOps.updateTaskLabels(seed.id, updatedLabels);
              } else {
                this.store.updateTaskLabels(seed.id, updatedLabels);
              }
              log(`[foreman] Auto-labeled ${seed.id} with branch:${labelBranch}`);
              // Update seedDetail.labels so seedToInfo() sees the updated labels
              if (seedDetail) {
                seedDetail = { ...seedDetail, labels: updatedLabels };
              } else {
                seedDetail = { labels: updatedLabels };
              }
            } catch (labelErr: unknown) {
              // Non-fatal: label failure must not block dispatch
              const msg = labelErr instanceof Error ? labelErr.message : String(labelErr);
              log(`Warning: failed to add branch label to ${seed.id}: ${msg}`);
            }
          }
        }
      }

      const seedInfo = seedToInfo(seed, seedDetail, beadComments);
      const runtime: RuntimeSelection = "claude-code";
      // Pipeline model is now resolved per-phase from the workflow YAML + bead priority.
      // Use opts.model if provided (e.g. --model flag), otherwise fall back to the
      // developer-role default.  This value is the outer fallback only — executePipeline
      // will override it per phase via resolvePhaseModel().
      const model: ModelSelection = opts?.model ?? getDefaultModel() as ModelSelection;

      if (opts?.dryRun) {
        dispatched.push({
          seedId: seed.id,
          title: seed.title,
          runtime,
          model,
          worktreePath: getWorkspacePath(this.projectPath, seed.id),
          runId: "(dry-run)",
          branchName: `foreman/${seed.id}`,
        });
        continue;
      }

      try {
        // Pre-flight guard: re-check the DB just before creating the run.
        // The activeSeedIds snapshot above is stale by the time we reach this
        // point — a concurrent dispatch cycle may have already created a pending
        // run for this seed between our getActiveRuns() call and now.  This
        // just-in-time check prevents duplicate runs in that race window.
        const hasCompetingRun = this.overrides?.hasActiveOrPendingRun
          ? await this.overrides.hasActiveOrPendingRun(seed.id)
          : this.store.hasActiveOrPendingRun(seed.id, projectId);
        if (hasCompetingRun) {
          skipped.push({
            seedId: seed.id,
            title: seed.title,
            reason: "Another run was created concurrently (race guard)",
          });
          continue;
        }
        const attemptNumber = (await this.getRunsForSeedRecord(seed.id, projectId)).length + 1;
        if (await this.hasMergedOutcomeWithoutLaterReset(seed.id, projectId)) {
          skipped.push({
            seedId: seed.id,
            title: seed.title,
            reason: "Another run merged before dispatch could create a new run (merged guard)",
          });
          continue;
        }

        // 1. Resolve base branch (may stack on a dependency branch)
        const baseBranch = await resolveBaseBranch(
          seed.id,
          this.projectPath,
          {
            getRunsForSeed: (seedId: string) => this.overrides?.getRunsForSeed
              ? this.overrides.getRunsForSeed(seedId, projectId)
              : this.store.getRunsForSeed(seedId, projectId),
          },
          branchBackend,
        );
        if (baseBranch) {
          log(`[foreman] Stacking ${seed.id} on ${baseBranch}`);
        }

        // 1a. Load project config and resolve workflow name.
        // Invalid config is dispatch-blocking so workflow routing policy cannot
        // be silently ignored.
        const projectCfg = loadProjectConfig(this.projectPath);
        const resolvedWorkflow = resolveWorkflowName(
          seedInfo.type ?? "feature",
          seedInfo.labels,
          projectCfg?.taskTypeWorkflowMap,
        );
        let setupSteps: import("../lib/workflow-loader.js").WorkflowSetupStep[] | undefined;
        let setupCache: import("../lib/workflow-loader.js").WorkflowSetupCache | undefined;
        let vcsBackendName: 'git' | 'jujutsu' = 'git'; // default to git
        // TRD-007: capture merge strategy from workflow config
        let workflowMerge: 'auto' | 'pr' | 'none' = 'auto';
        // projectHooks is used in afterCreate/beforeRun hooks below the try block
        const projectHooks: import("../lib/project-config.js").ProjectHooksConfig | undefined = projectCfg?.hooks;
        try {
          const wfConfig = loadWorkflowConfig(resolvedWorkflow, this.projectPath);
          setupSteps = wfConfig.setup;
          setupCache = wfConfig.setupCache;
          workflowMerge = wfConfig.merge ?? 'auto';

          // Resolve VCS backend: workflow > project > auto-detect
          const resolvedVcs = resolveVcsConfig(wfConfig.vcs, projectCfg?.vcs);
          vcsBackendName = VcsBackendFactory.resolveBackend(resolvedVcs, this.projectPath);
        } catch {
          // Non-fatal: fall back to default installDependencies behavior
          log(`[foreman] Could not load workflow config '${resolvedWorkflow}' for setup steps — using default dependency install`);
        }

        // 1b. Create VcsBackend instance at startup (AC-020-1)
        // The instance encapsulates backend-specific VCS operations and its name
        // is propagated via FOREMAN_VCS_BACKEND so agent-worker can reconstruct
        // without re-detecting.
        let vcsBackend: VcsBackend | undefined;
        try {
          if (branchBackend?.name === vcsBackendName) {
            vcsBackend = branchBackend;
          } else {
            vcsBackend = await VcsBackendFactory.create({ backend: vcsBackendName }, this.projectPath);
          }
          log(`[foreman] Created VcsBackend: ${vcsBackend.name}`);
        } catch (vcsErr: unknown) {
          const vcsMsg = vcsErr instanceof Error ? vcsErr.message : String(vcsErr);
          log(`[foreman] VcsBackend creation failed: ${vcsMsg} — continuing without VcsBackend instance`);
        }

        // 2. Create worktree at ~/.foreman/worktrees/<projectId>/<beadId> via WorktreeManager (TRD-037)
        const worktreeManager = new WorktreeManager();
        const worktreeInfo = await worktreeManager.createWorktree({
          projectId,
          beadId: seed.id,
          repoPath: this.projectPath,
          baseBranch: baseBranch ?? defaultBranch,
        });
        const worktreePath = worktreeInfo.path;
        const branchName = worktreeInfo.branchName;
        const workspaceWasCreated = worktreeInfo.created ?? !worktreeInfo.exists;

        // Run setup steps / install dependencies (not part of VcsBackend interface)
        if (opts?.runtimeMode === "test") {
          log(`[foreman] Skipping workflow setup/install for ${seed.id} in test runtime`);
        } else if (setupSteps && setupSteps.length > 0) {
          await runSetupWithCache(worktreePath, this.projectPath, setupSteps, setupCache);
        } else {
          await installDependencies(worktreePath);
        }

        // Run afterCreate hook (one-time setup after workspace created)
        // Failures are fatal — block agent spawn
        if (workspaceWasCreated && projectHooks?.afterCreate) {
          const hookEnv: Record<string, string> = {
            FOREMAN_WORKSPACE_PATH: worktreePath,
            FOREMAN_ISSUE_ID: seed.id,
            FOREMAN_ISSUE_IDENTIFIER: seed.id,
            FOREMAN_ATTEMPT: String(attemptNumber),
          };
          try {
            await runWorkspaceHook(projectHooks, "afterCreate", worktreePath, hookEnv);
          } catch (hookErr: unknown) {
            const hookMsg = hookErr instanceof Error ? hookErr.message : String(hookErr);
            throw new Error(`afterCreate hook failed for ${seed.id}: ${hookMsg}`);
          }
        }

        // 3. Write TASK.md in the worktree (not AGENTS.md — avoids overwriting project file on merge)
        const taskMd = workerAgentMd(seedInfo, worktreePath, model);
        await writeFile(join(worktreePath, "TASK.md"), taskMd, "utf-8");

        // 4. Record run in store (include base_branch for stacking awareness)
        // TRD-007: pass merge_strategy from workflow config
        const run = await this.createRunRecord(
          projectId,
          seed.id,
          model,
          worktreePath,
          branchName,
          { baseBranch: baseBranch ?? null, mergeStrategy: workflowMerge },
        );

        // 5. Log dispatch event
        await this.logEventRecord(projectId, "dispatch", {
          seedId: seed.id,
          title: seed.title,
          model,
          worktreePath,
          branchName,
        }, run.id);

        // 5a. Send worktree-created mail so inbox shows worktree lifecycle event
        try {
          await this.sendMailRecord(run.id, "foreman", "foreman", "worktree-created", JSON.stringify({
            seedId: seed.id,
            title: seed.title,
            worktreePath,
            branchName,
            model,
            timestamp: new Date().toISOString(),
          }));
        } catch {
          // Non-fatal — mail is optional infrastructure
        }

        // 6. Mark seed as in_progress before spawning agent.
        // Atomic claim: UPDATE tasks SET status='in-progress', run_id=? WHERE id=? AND status='ready'
        // Native-only: use nativeTaskOps.claimTask() — never use legacy beads claim
        const claimed = this.overrides?.nativeTaskOps
          ? await this.overrides.nativeTaskOps.claimTask(seed.id, run.id)
          : typeof this.store.claimTask === "function"
            ? this.store.claimTask(seed.id, run.id)
            : false;
        if (!claimed) {
          // Another dispatcher instance claimed this task between our getReadyTasks() query
          // and now — skip it and clean up the run we just created.
          skipped.push({
            seedId: seed.id,
            title: seed.title,
            reason: "Already claimed by another dispatcher (atomic claim failed)",
          });
          // Best-effort cleanup: mark run as failed so it doesn't appear as active
          try {
            await this.updateRunRecord(run.id, { status: "failed", completed_at: new Date().toISOString() });
          } catch {
            // Non-fatal — run cleanup is best-effort
          }
          continue;
        }

        // 6a. Send bead-claimed mail so inbox shows bead lifecycle event
        try {
          await this.sendMailRecord(run.id, "foreman", "foreman", "bead-claimed", JSON.stringify({
            seedId: seed.id,
            title: seed.title,
            model,
            runId: run.id,
            timestamp: new Date().toISOString(),
          }));
        } catch {
          // Non-fatal — mail is optional infrastructure
        }

        // 7. Spawn the coding agent
        // Extract epic context if this seed was marked as an epic dispatch
        const epicTasksForSeed = (seed as unknown as Record<string, unknown>).__epicTasks as EpicTask[] | undefined;
        const epicIdForSeed = epicTasksForSeed ? seed.id : undefined;

        // Run beforeRun hook (before agent launch)
        // Failures are fatal — block agent spawn
        if (projectHooks?.beforeRun) {
          const hookEnv: Record<string, string> = {
            FOREMAN_WORKSPACE_PATH: worktreePath,
            FOREMAN_ISSUE_ID: seed.id,
            FOREMAN_ISSUE_IDENTIFIER: seed.id,
            FOREMAN_ATTEMPT: String(attemptNumber),
          };
          try {
            await runWorkspaceHook(projectHooks, "beforeRun", worktreePath, hookEnv);
          } catch (hookErr: unknown) {
            const hookMsg = hookErr instanceof Error ? hookErr.message : String(hookErr);
            const now = new Date().toISOString();
            await this.updateRunRecord(run.id, { status: "failed", completed_at: now });
            try {
              await this.updateNativeTaskStatus(seed.id, "failed");
            } catch (taskErr: unknown) {
              const taskMsg = taskErr instanceof Error ? taskErr.message : String(taskErr);
              log(`[foreman] Could not mark ${seed.id} failed after beforeRun hook failure — ${taskMsg.slice(0, 200)}`);
            }
            throw new Error(`beforeRun hook failed for ${seed.id}: ${hookMsg}`);
          }
        }

        const { sessionKey } = await this.spawnAgent(
          model,
          worktreePath,
          seedInfo,
          run.id,
          opts?.telemetry,
          {
            pipeline: opts?.pipeline,
            skipExplore: opts?.skipExplore,
            skipReview: opts?.skipReview,
          },
          opts?.notifyUrl,
          vcsBackend,
          opts?.runtimeMode,
          opts?.targetBranch,
          epicTasksForSeed,
          epicIdForSeed,
          projectHooks,
          attemptNumber,
        );

        // Update run with session key
        await this.updateRunRecord(run.id, {
          session_key: sessionKey,
          status: "running",
          started_at: new Date().toISOString(),
        });

        dispatched.push({
          seedId: seed.id,
          title: seed.title,
          runtime,
          model,
          worktreePath,
          runId: run.id,
          branchName,
        });

        // P1: Apply stagger delay between dispatches to prevent thundering herd on Haiku quotas
        if (opts?.staggerMs && opts?.staggerMs > 0 && dispatched.length < readySeeds.length) {
          const staggerMsg = `[dispatch] Staggering ${opts.staggerMs / 1000}s before next dispatch...`;
          console.error(staggerMsg);
          await new Promise((resolve) => setTimeout(resolve, opts.staggerMs));
        }
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        skipped.push({
          seedId: seed.id,
          title: seed.title,
          reason: `Dispatch failed: ${message}`,
        });
      }
    }

    return {
      dispatched,
      skipped,
      resumed: [],
      activeAgents: activeAgentCount + dispatched.length,
    };
  }

  /**
   * Resume stuck/failed runs from previous dispatches.
   *
   * Finds runs in "stuck" or "failed" status, extracts their SDK session IDs,
   * and resumes them via the SDK's `resume` option. This continues the agent's
   * conversation from where it left off (e.g. after a rate limit).
   */
  async resumeRuns(opts?: {
    maxAgents?: number;
    model?: ModelSelection;
    telemetry?: boolean;
    statuses?: Array<"stuck" | "failed">;
    /** URL of the notification server (e.g. "http://127.0.0.1:PORT") */
    notifyUrl?: string;
    runtimeMode?: RuntimeMode;
  }): Promise<DispatchResult> {
    const maxAgents = opts?.maxAgents ?? 5;
    const projectId = this.resolveProjectId();
    const statuses = opts?.statuses ?? ["stuck"];

    if (this.overrides?.externalProjectId) {
      this.validateRegisteredRunOps(["createRun", "updateRun", "logEvent"]);
    }

    // Find resumable runs
    const resumableRuns = (await Promise.all(
      statuses.map((status) => this.getRunsByStatusRecord(status, projectId)),
    )).flat();

    const activeRuns = await this.getActiveRunsRecord(projectId);
    const activeAgentCount = this.overrides?.getActiveAgentCount
      ? await this.overrides.getActiveAgentCount()
      : activeRuns.length;
    const available = Math.max(0, maxAgents - activeAgentCount);

    const resumed: ResumedTask[] = [];
    const skipped: SkippedTask[] = [];

    for (const run of resumableRuns) {
      if (resumed.length >= available) {
        skipped.push({
          seedId: run.seed_id,
          title: run.seed_id,
          reason: `Agent limit reached (${maxAgents})`,
        });
        continue;
      }

      // Extract SDK session ID from session_key
      // Format: foreman:sdk:<model>:<runId>:session-<sessionId>
      const sessionId = extractSessionId(run.session_key);
      if (!sessionId) {
        skipped.push({
          seedId: run.seed_id,
          title: run.seed_id,
          reason: "No SDK session ID found — cannot resume (was this a CLI-spawned run?)",
        });
        continue;
      }

      // Check worktree still exists
      if (!run.worktree_path) {
        skipped.push({
          seedId: run.seed_id,
          title: run.seed_id,
          reason: "No worktree path — cannot resume",
        });
        continue;
      }

      const model = (opts?.model ?? run.agent_type) as ModelSelection;
      const previousStatus = run.status;

      log(`Resuming agent for ${run.seed_id} [${model}] session=${sessionId}`);

      // Create a new run record for the resumed attempt
      const newRun = await this.createRunRecord(
        projectId,
        run.seed_id,
        model,
        run.worktree_path,
        `foreman/${run.seed_id}`,
      );

      // Log resume event
      await this.logEventRecord(projectId, "restart", {
        seedId: run.seed_id,
        model,
        previousRunId: run.id,
        previousStatus,
        sessionId,
      }, newRun.id);

      // Mark old run as restarted
      await this.updateRunRecord(run.id, {
        status: "failed",
        completed_at: new Date().toISOString(),
      });

      // Mark seed as in_progress before spawning resumed agent
      // Native-only: use updateNativeTaskStatus which routes through nativeTaskOps
      await this.updateNativeTaskStatus(run.seed_id, "in_progress");

      // Spawn the resumed agent
      const { sessionKey } = await this.resumeAgent(
        model,
        run.worktree_path,
        { id: run.seed_id, title: run.seed_id },
        newRun.id,
        sessionId,
        opts?.telemetry,
        opts?.notifyUrl,
        opts?.runtimeMode,
      );

      await this.updateRunRecord(newRun.id, {
        session_key: sessionKey,
        status: "running",
        started_at: new Date().toISOString(),
      });

      resumed.push({
        seedId: run.seed_id,
        title: run.seed_id,
        model,
        runId: newRun.id,
        sessionId,
        previousStatus,
      });
    }

    return {
      dispatched: [],
      skipped,
      resumed,
      activeAgents: activeAgentCount + resumed.length,
    };
  }

  /**
   * Dispatch a planning step (PRD/TRD) without creating a worktree.
   * Runs Claude Code via SDK and waits for completion.
   */
  async dispatchPlanStep(
    projectId: string,
    seed: SeedInfo,
    ensembleCommand: string,
    input: string,
    outputDir: string,
  ): Promise<PlanStepDispatched> {
    this.validateRegisteredRunOps(["createRun", "updateRun", "logEvent"]);

    // 1. Record run in store
    const run = await this.createRunRecord(projectId, seed.id, "claude-code", null, `foreman/${seed.id}`);

    // 2. Log dispatch event
    await this.logEventRecord(projectId, "dispatch", {
      seedId: seed.id,
      title: seed.title,
      ensembleCommand,
      outputDir,
      type: "plan-step",
    }, run.id);

    // 3. Build the prompt
    const prompt = `${ensembleCommand} ${input}\n\nSave all outputs to the ${outputDir}/ directory.`;

    const sessionKey = `foreman:plan:${run.id}`;
    await this.updateRunRecord(run.id, {
      session_key: sessionKey,
      status: "running",
      started_at: new Date().toISOString(),
    });

    try {
      const planResult = await runWithPiSdk({
        prompt,
        systemPrompt: `You are a planning agent. ${ensembleCommand} for the task: ${seed.title}`,
        cwd: this.projectPath,
        model: PLAN_STEP_CONFIG.model,
      });

      if (planResult.success) {
        await this.updateRunRecord(run.id, {
          status: "completed",
          completed_at: new Date().toISOString(),
        });
        await this.logEventRecord(projectId, "complete", {
          seedId: seed.id,
          title: seed.title,
          costUsd: planResult.costUsd,
          numTurns: planResult.turns,
        }, run.id);
      } else {
        const reason = planResult.errorMessage ?? "Pi plan step failed";
        await this.updateRunRecord(run.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        await this.logEventRecord(projectId, "fail", {
          seedId: seed.id,
          reason,
          costUsd: planResult.costUsd,
        }, run.id);
        throw new Error(reason);
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      // Only update if not already updated by the result handler above
      const currentRun = await this.getRunRecord(run.id);
      if (currentRun?.status === "running") {
        await this.updateRunRecord(run.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        await this.logEventRecord(projectId, "fail", {
          seedId: seed.id,
          reason: message,
        }, run.id);
      }
      throw err;
    }

    return {
      seedId: seed.id,
      title: seed.title,
      runId: run.id,
      sessionKey,
    };
  }

  /**
   * Build the TASK.md content for a seed (exposed for testing).
   *
   * Model selection is now handled per-phase by the workflow YAML `models` map
   * (see resolvePhaseModel in workflow-loader.ts). The TASK.md model field shows
   * the developer-phase default as informational context.
   */
  generateAgentInstructions(seed: SeedInfo, worktreePath: string): string {
    // Use developer-role default for TASK.md informational display.
    // The actual per-phase model is resolved from workflow YAML at runtime.
    const model: ModelSelection = getDefaultModel() as ModelSelection;
    return workerAgentMd(seed, worktreePath, model);
  }

  // ── Agent Spawning ─────────────────────────────────────────────────────

  /**
   * Build the spawn prompt for an agent (exposed for testing — TRD-012).
   * Returns the multi-line string passed to the worker as its initial prompt.
   */
  buildSpawnPrompt(seedId: string, seedTitle: string): string {
    return [
      `Read TASK.md and implement the task described.`,
      `Use br (beads_rust) to track your progress.`,
      `When completely finished:`,
      `  Save your session log to SessionLogs/session-$(date +%d%m%y-%H:%M).md (mkdir -p SessionLogs first)`,
      `  br sync --flush-only`,
      `  git add .`,
      `  git commit -m "${seedTitle} (${seedId})"`,
      `  git push -u origin foreman/${seedId}`,
      `NOTE: Do NOT close the bead manually — it will be closed automatically after the branch merges to main.`,
    ].join("\n");
  }

  /**
   * Build the resume prompt for an agent (exposed for testing — TRD-012).
   */
  buildResumePrompt(seedId: string, seedTitle: string): string {
    return [
      `You were previously working on this task but were interrupted (likely by a rate limit).`,
      `Continue where you left off. Check your progress so far and complete the remaining work.`,
      `When completely finished:`,
      `  Save your session log to SessionLogs/session-$(date +%d%m%y-%H:%M).md (mkdir -p SessionLogs first)`,
      `  br sync --flush-only`,
      `  git add .`,
      `  git commit -m "${seedTitle} (${seedId})"`,
      `  git push -u origin foreman/${seedId}`,
      `NOTE: Do NOT close the bead manually — it will be closed automatically after the branch merges to main.`,
    ].join("\n");
  }

  /**
   * Spawn a coding agent as a detached worker process.
   *
   * Writes a WorkerConfig JSON file and spawns `agent-worker.ts` as a
   * detached child process that survives the parent foreman process exiting.
   * The worker runs the SDK `query()` loop independently and updates the
   * Postgres store with progress/completion.
   */
  private async spawnAgent(
    model: ModelSelection,
    worktreePath: string,
    seed: SeedInfo,
    runId: string,
    telemetry?: boolean,
    pipelineOpts?: {
      pipeline?: boolean;
      skipExplore?: boolean;
      skipReview?: boolean;
    },
    notifyUrl?: string,
    vcsBackend?: VcsBackend,
    runtimeMode?: RuntimeMode,
    targetBranch?: string,
    epicTasks?: EpicTask[],
    epicId?: string,
    hooks?: import("../lib/project-config.js").ProjectHooksConfig,
    attemptNumber = 1,
  ): Promise<{ sessionKey: string }> {
    const prompt = this.buildSpawnPrompt(seed.id, seed.title);

    const env = buildWorkerEnv(telemetry, seed.id, runId, model, notifyUrl, vcsBackend, runtimeMode);
    const usePipeline = pipelineOpts?.pipeline ?? true;  // Pipeline by default

    const isEpic = epicTasks && epicTasks.length > 0;
    log(`Spawning ${isEpic ? "epic runner" : usePipeline ? "pipeline" : "worker"} for ${seed.id} [${model}] in ${worktreePath}${isEpic ? ` (${epicTasks.length} tasks)` : ""}`);

    const seedType = resolveWorkflowType(seed.type ?? "feature", seed.labels);
    const projectId = this.resolveProjectId();
    const staleWorktreeEventWriter = this.overrides?.externalProjectId
      ? async (eventType: "worktree-rebased" | "worktree-rebase-failed", payload: Record<string, unknown>) => {
          await this.logEventRecord(projectId, eventType as EventType, payload, runId);
        }
      : undefined;

    // FR-5: Check if worktree is stale and auto-rebase before spawning
    if (vcsBackend && targetBranch) {
      try {
        await checkAndRebaseStaleWorktree(
          vcsBackend,
          worktreePath,
          targetBranch,
          this.store,
          projectId,
          runId,
          seed.id,
          staleWorktreeEventWriter ? { autoRebase: true, failOnConflict: true, eventWriter: staleWorktreeEventWriter } : { autoRebase: true, failOnConflict: true },
        );
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        log(`[dispatch] Stale worktree check failed for ${seed.id}: ${msg}`);
        // Re-throw so the dispatch fails cleanly rather than spawning a broken worker
        throw err;
      }
    }

      const { pid } = await spawnWorkerProcess({
        runId,
        projectId: this.overrides?.externalProjectId ?? this.resolveProjectId(),
        seedId: seed.id,
        seedTitle: seed.title,
        seedDescription: seed.description,
        seedComments: seed.comments ?? undefined,
        model,
        worktreePath,
        projectPath: this.projectPath,
        prompt,
        env,
        pipeline: usePipeline,
        skipExplore: pipelineOpts?.skipExplore,
        skipReview: pipelineOpts?.skipReview,
        dbPath: join(this.projectPath, ".foreman", "foreman.db"),
        seedType,
        seedLabels: seed.labels,
        seedPriority: seed.priority,
        targetBranch,
        attemptNumber,
        epicTasks,
        epicId,
        taskId: seed.id,
        taskMeta: {
          id: seed.id,
          title: seed.title,
          description: seed.description ?? '',
          type: seed.type ?? '',
          priority: typeof seed.priority === 'number' ? seed.priority : 2,
          projectReportsDir: getRunReportsDir(this.overrides?.externalProjectId ?? this.resolveProjectId(), seed.id, runId),
        },
        githubIssueNumber: seed.githubIssueNumber,
        // FR-1: Directory guardrail — verify agent cwd matches expected worktree
        guardrailConfig: {
          expectedCwd: worktreePath,
          mode: "auto-correct",
        },
        // Workspace lifecycle hooks for afterRun
        hooks: hooks,
      });

      const sessionKey = buildSdkSessionKey(model, runId, pid);

      return { sessionKey };
  }

  // ── Session Resume ───────────────────────────────────────────────────

  /**
   * Resume a previously started agent session via a detached worker process.
   * The worker uses the SDK's `resume` option to continue the conversation.
   */
  private async resumeAgent(
    model: ModelSelection,
    worktreePath: string,
    seed: SeedInfo,
    runId: string,
    sdkSessionId: string,
    telemetry?: boolean,
    notifyUrl?: string,
    runtimeMode?: RuntimeMode,
  ): Promise<{ sessionKey: string }> {
    const resumePrompt = this.buildResumePrompt(seed.id, seed.title);

    const env = buildWorkerEnv(telemetry, seed.id, runId, model, notifyUrl, undefined, runtimeMode);
    log(`Resuming worker for ${seed.id} [${model}] session=${sdkSessionId}`);

    const { pid } = await spawnWorkerProcess({
      runId,
      projectId: this.overrides?.externalProjectId ?? this.resolveProjectId(),
      seedId: seed.id,
      seedTitle: seed.title,
      model,
      worktreePath,
      prompt: resumePrompt,
      env,
      resume: sdkSessionId,
      taskId: seed.id,
      dbPath: join(this.projectPath, ".foreman", "foreman.db"),
    });

    const sessionKey = buildSdkSessionKey(model, runId, pid, sdkSessionId);

    return { sessionKey };
  }

  // ── Private helpers ───────────────────────────────────────────────────

  /**
   * Return recent stuck runs for a seed within the configured time window.
   * Ordered by created_at DESC (most recent first).
   */
  private async getRecentStuckRuns(seedId: string, projectId: string): Promise<Run[]> {
    const cutoff = new Date(Date.now() - STUCK_RETRY_CONFIG.windowMs).toISOString();
    const allRuns = await this.getRunsForSeedRecord(seedId, projectId);
    return allRuns.filter(
      (r) => r.status === "stuck" && r.created_at >= cutoff,
    );
  }

  /**
   * Check whether a seed is currently in exponential backoff due to recent
   * stuck runs. Returns `{ inBackoff: false }` if the seed may be dispatched,
   * or `{ inBackoff: true, reason }` if it must be skipped this cycle.
   */
  private async checkStuckBackoff(
    seedId: string,
    projectId: string,
  ): Promise<{ inBackoff: boolean; reason?: string }> {
    const recentStuck = await this.getRecentStuckRuns(seedId, projectId);
    const stuckCount = recentStuck.length;

    if (stuckCount === 0) return { inBackoff: false };

    // If the seed has hit the hard limit, block it until the window rolls over
    if (stuckCount >= STUCK_RETRY_CONFIG.maxRetries) {
      return {
        inBackoff: true,
        reason: `Max stuck retries reached (${stuckCount}/${STUCK_RETRY_CONFIG.maxRetries} in window) — will retry after window resets`,
      };
    }

    // Calculate required backoff based on how many times it has been stuck
    const requiredDelayMs = calculateStuckBackoffMs(stuckCount);

    // Use the most recent stuck run's completed_at (or created_at) as the
    // reference timestamp for the backoff clock
    const lastRun = recentStuck[0]; // DESC order → first = most recent
    const refTimestamp = lastRun.completed_at ?? lastRun.created_at;
    const elapsedMs = Date.now() - new Date(refTimestamp).getTime();

    if (elapsedMs < requiredDelayMs) {
      const remainingSec = Math.ceil((requiredDelayMs - elapsedMs) / 1000);
      return {
        inBackoff: true,
        reason: `Stuck backoff active (attempt ${stuckCount}/${STUCK_RETRY_CONFIG.maxRetries}) — retry in ${remainingSec}s`,
      };
    }

    return { inBackoff: false };
  }

  /**
   * Returns true when an issue status indicates the issue is in a terminal state
   * (closed, completed, cancelled, done, duplicate) and any active runs should
   * be stopped or worktrees cleaned up.
   */
  private isTerminalState(status: string | null | undefined): boolean {
    if (!status) return false;
    const lower = status.toLowerCase();
    return lower === "closed" || lower === "completed" || lower === "cancelled" || lower === "done" || lower === "duplicate";
  }

  /**
   * Stop a run whose issue has transitioned to a terminal state.
   * Marks the run as stuck, logs the event, and archives the worktree.
   */
  private async cancelRun(run: Run, reason: string): Promise<void> {
    await this.updateRunRecord(run.id, {
      status: "stuck",
      completed_at: new Date().toISOString(),
    });
    await this.logEventRecord(run.project_id, "stuck", { reason }, run.id);

    // Archive the worktree for this run
    if (run.worktree_path) {
      const worktreeManager = new WorktreeManager();
      await worktreeManager.removeWorktree(run.project_id, run.seed_id, this.projectPath);
    }
  }

  /**
   * Reconcile active runs against their underlying issue state.
   * Stop any runs whose issues have transitioned to a terminal state
   * (closed/completed) or are no longer found.
   *
   * Called at the start of each dispatch cycle to catch issues that were
   * closed while an agent was still running.
   *
   * @returns The number of runs that were stopped.
   */
  private async reconcileRunningIssues(projectId: string): Promise<number> {
    const activeRuns = await this.getActiveRunsRecord(projectId);
    let stopped = 0;

    for (const run of activeRuns) {
      try {
        // Native-only: use nativeTaskOps to get task status, never this.seeds.show()
        let taskStatus: string | null = null;
        if (this.overrides?.nativeTaskOps) {
          const task = await this.overrides.nativeTaskOps.getTaskByExternalId(run.seed_id)
            ?? await this.overrides.nativeTaskOps.getTaskById(run.seed_id);
          if (task) {
            taskStatus = task.status;
          }
        } else {
          // Fallback to store (not beads) for non-native mode
          const task = this.store.getTaskByExternalId(run.seed_id)
            ?? this.store.getTaskById(run.seed_id);
          if (task) {
            taskStatus = task.status;
          }
        }

        if (taskStatus && this.isTerminalState(taskStatus)) {
          await this.cancelRun(run, "issue_terminal");
          stopped++;
        } else if (!taskStatus) {
          // Task not found — treat as terminal and stop the run
          await this.cancelRun(run, "issue_terminal");
          stopped++;
        }
      } catch (err: unknown) {
        // Error fetching task — treat as terminal and stop the run
        await this.cancelRun(run, "issue_terminal");
        stopped++;
      }
    }

    return stopped;
  }

  /**
   * Clean up orphaned worktrees for issues that are already in a terminal state
   * when the daemon starts. This handles the case where worktrees exist for
   * issues that were closed while the daemon was not running.
   *
   * Terminal states: closed, completed, cancelled, done, duplicate
   *
   * @returns The number of worktrees removed.
   *
   * Native-only: Returns 0 unconditionally since Beads fallback has been removed.
   *
   * NOTE: This method is a no-op in native-only mode. Worktree cleanup for
   * terminal issues is handled by:
   *   1. reconcileRunningIssues() — stops runs and archives worktrees for issues
   *      that transition to terminal state while the daemon is running.
   *   2. The daemon startup path calls cleanupTerminalStateWorktrees() to catch
   *      issues that were closed while the daemon was not running. However, since
   *      the native dispatcher does not call beads for status, and the native
   *      store does not expose a way to iterate all tasks with their worktrees,
   *      we rely on the reconciliation pass at the start of each dispatch cycle
   *      to catch terminal issues. Orphaned worktrees will be cleaned up on the
   *      next daemon restart if the issue status has been updated externally.
   */
  private async cleanupTerminalStateWorktrees(_projectId: string): Promise<number> {
    // Native-only dispatcher never calls this.seeds for fallback behavior.
    // Worktree cleanup for terminal issues is handled by reconcileRunningIssues()
    // during the dispatch cycle, which archives worktrees for runs whose issues
    // have transitioned to terminal state.
    return 0;
  }

  /**
   * Once a bead has a merged/PR-created run, it must not be dispatched again
   * unless a later explicit reset exists. This protects against stale bead
   * status or delayed queue writes causing accidental redispatch after merge.
   */
  private async hasMergedOutcomeWithoutLaterReset(
    seedId: string,
    projectId: string,
  ): Promise<boolean> {
    const runs = await this.getRunsForSeedRecord(seedId, projectId);
    for (const run of runs) {
      if (run.status === "reset") return false;
      if (run.status === "merged" || run.status === "pr-created") return true;
    }
    return false;
  }

  private resolveProjectId(): string {
    if (this.overrides?.externalProjectId) {
      return this.overrides.externalProjectId;
    }
    const project = this.store.getProjectByPath(this.projectPath);
    if (!project) {
      throw new Error(
        `No project registered for path ${this.projectPath}. Run 'foreman init' first.`,
      );
    }
    return project.id;
  }
}

// ── Utility ─────────────────────────────────────────────────────────────

/**
 * Resolve the base branch for a seed's worktree.
 *
 * For native-only mode: Native tasks do not have dependency information (unlike
 * Beads issues which support `br dep add`). This function returns undefined
 * (no stacking) for native tasks.
 *
 * For Beads mode (when nativeTaskOps is not configured): If any of the seed's
 * blocking dependencies have an unmerged local branch (i.e. a `foreman/<depId>`
 * branch exists locally and its latest run is "completed" but not yet "merged"),
 * stack the new worktree on top of that dependency branch instead of the default
 * branch.
 *
 * This allows agent B to build on top of agent A's work before A is merged.
 * After A merges, the refinery will rebase B onto main.
 *
 * Returns the dependency branch name (e.g. "foreman/story-1") or undefined
 * when no stacking is needed.
 *
 * Native-only: This function never calls this.seeds or any Beads client.
 * Stacking is disabled for native tasks since they lack dependency metadata.
 */
export async function resolveBaseBranch(
  _seedId: string,
  _projectPath: string,
  _runLookup: BaseBranchRunLookup,
  _backend?: Pick<VcsBackend, "branchExists">,
): Promise<string | undefined> {
  // Native-only: Native tasks do not have dependency information.
  // Beads dependency stacking is not supported in native-only mode.
  // Return undefined to disable stacking — tasks branch from default branch.
  return undefined;
}

// ── Worker Config (must match agent-worker.ts interface) ────────────────

export interface WorkerConfig {
  runId: string;
  projectId: string;
  seedId: string;
  seedTitle: string;
  seedDescription?: string;
  seedComments?: string;
  model: string;
  worktreePath: string;
  /** Project root directory (contains .beads/). Used as cwd for br commands. */
  projectPath?: string;
  prompt: string;
  env: Record<string, string>;
  resume?: string;
  pipeline?: boolean;
  skipExplore?: boolean;
  skipReview?: boolean;
  /** Legacy local-store path retained for compatibility only. */
  dbPath?: string;
  /**
   * Resolved workflow type (e.g. "smoke", "feature", "bug").
   * Derived from label-based override or bead type field.
   * Used for prompt-loader workflow scoping and spawn strategy selection.
   */
  seedType?: string;
  /**
   * Labels from the bead. Forwarded to agent-worker so it can resolve
   * `workflow:<name>` label overrides.
   */
  seedLabels?: string[];
  /**
   * Bead priority string ("P0"–"P4", "0"–"4", or undefined).
   * Forwarded to the pipeline executor to resolve per-priority models from YAML.
   */
  seedPriority?: string;
  /**
   * Override target branch for auto-merge after finalize.
   * When set, the agent worker merges into this branch instead of detectDefaultBranch().
   */
  targetBranch?: string;
  /**
   * Optional task ID from native task store (NativeTaskStore.claim()).
   * When present, pipeline will call taskStore.updatePhase(taskId, phaseName)
   * at each phase transition for phase-level visibility (REQ-012).
   * Null/undefined when no task ID is available — no-op via optional chaining.
   */
  taskId?: string | null;
  /**
   * Ordered list of child tasks for epic execution mode (TRD-2026-007).
   * When set, the worker runs the epic pipeline: taskPhases per child task,
   * then finalPhases once at the end.
   */
  epicTasks?: EpicTask[];
  /**
   * Parent epic bead ID (TRD-2026-007).
   * When set, this run is an epic execution — the worker executes all
   * epicTasks within a single worktree.
   */
  epicId?: string;
  /**
   * Task metadata for placeholder interpolation in bash/command phases (REQ-008).
   * Populated from the bead/seed that triggered this run.
   */
  taskMeta?: TaskMeta;
  /**
   * GitHub issue number for this task (from github_issue_number field).
   * When set, finalize commit messages are suffixed with "Fixes #{issueNumber}" (TRD-042).
   */
  githubIssueNumber?: number;
  /** One-based dispatch attempt number for lifecycle hook environment. */
  attemptNumber?: number;
  /**
   * Directory guardrail config (FR-1). When set, wraps tool factories with
   * cwd verification in the Pi SDK session. Prevents agents from operating
   * in the wrong worktree.
   */
  guardrailConfig?: {
    /** Guardrail enforcement mode. Default: `auto-correct`. */
    mode?: "auto-correct" | "veto" | "disabled";
    /** Expected working directory for this agent session. */
    expectedCwd?: string;
    /** Optional list of allowed path prefixes. */
    allowedPaths?: string[];
  };
  /**
   * Workspace lifecycle hooks for pre/post-run customization.
   * Loaded from project config and passed to the agent worker.
   */
  hooks?: import("../lib/project-config.js").ProjectHooksConfig;
}

// ── Spawn Strategy Pattern ──────────────────────────────────────────────

/** Result returned by a SpawnStrategy */
export interface SpawnResult {
  pid: number | null;
}

/** Strategy interface for spawning worker processes */
export interface SpawnStrategy {
  spawn(config: WorkerConfig): Promise<SpawnResult>;
}

/**
 * Resolve common paths needed by both spawn strategies.
 */
export function resolveWorkerPaths(
  homeDir?: string,
  orchestratorDirOverride?: string,
): {
  tsxBin: string;
  workerScript: string;
  logDir: string;
  projectRoot: string;
  runnerArgs: string[];
} {
  const __filename = fileURLToPath(import.meta.url);
  const __dirname = orchestratorDirOverride ?? dirname(__filename);
  const projectRoot = join(__dirname, "..", "..");
  const tsWorkerScript = join(__dirname, "agent-worker.ts");
  const jsWorkerScript = join(__dirname, "agent-worker.js");
  const workerScript = existsSync(tsWorkerScript) ? tsWorkerScript : jsWorkerScript;
  const runnerArgs = workerScript.endsWith(".ts")
    ? ["--import", join(projectRoot, "node_modules", "tsx", "dist", "loader.mjs"), workerScript]
    : [workerScript];
  return {
    tsxBin: process.execPath,
    workerScript,
    logDir: join(homeDir ?? process.env.HOME ?? "/tmp", ".foreman", "logs"),
    projectRoot,
    runnerArgs,
  };
}


/**
 * Spawn worker as a detached child process (original behavior).
 */
export class DetachedSpawnStrategy implements SpawnStrategy {
  async spawn(config: WorkerConfig): Promise<SpawnResult> {
    const homeDir = config.env.HOME ?? process.env.HOME ?? "/tmp";
    const { tsxBin, logDir, projectRoot, runnerArgs } = resolveWorkerPaths(homeDir);

    // Write config to temp file (worker reads + deletes it)
    const configDir = join(homeDir, ".foreman", "tmp");
    await mkdir(configDir, { recursive: true });
    const configPath = join(configDir, `worker-${config.runId}.json`);
    await writeFile(configPath, JSON.stringify(config), "utf-8");

    await mkdir(logDir, { recursive: true });
    const outFd = await open(join(logDir, `${config.runId}.out`), "w");
    const errFd = await open(join(logDir, `${config.runId}.err`), "w");

    // Use the fully-constructed env from config (includes ~/.local/bin prefix from buildWorkerEnv)
    // Strip CLAUDECODE so the worker can spawn its own Claude SDK session
    const spawnEnv: Record<string, string | undefined> = { ...config.env };
    delete spawnEnv.CLAUDECODE;
    if (spawnEnv.FOREMAN_RUNTIME_MODE === "test" || spawnEnv.NODE_ENV === "test" || process.env.FOREMAN_RUNTIME_MODE === "test" || process.env.NODE_ENV === "test") {
      // Detached workers spawned from tests must not survive the test process.
      // agent-worker installs a lightweight guard for this env flag.
      spawnEnv.FOREMAN_WORKER_TEST_GUARD = "1";
      spawnEnv.FOREMAN_WORKER_PARENT_PID = String(process.pid);
    }

    // Spawn with cwd = worktree. The agent works from the worktree, so npm ci,
    // npm run build, npm test, and git operations all target the correct tree.
    // runnerArgs uses absolute paths to agent-worker.ts so this works regardless of cwd.
    const child = spawn(tsxBin, [...runnerArgs, configPath], {
      detached: true,
      stdio: ["ignore", outFd.fd, errFd.fd],
      cwd: config.worktreePath,
      env: spawnEnv,
    });

    child.unref();

    // Close parent's file handles — child process has inherited its own copies of the fds
    await outFd.close();
    await errFd.close();

    log(`  Worker pid=${child.pid} for ${config.seedId}`);
    return { pid: child.pid ?? null };
  }
}

/**
 * Spawn agent-worker using DetachedSpawnStrategy.
 *
 * DetachedSpawnStrategy spawns agent-worker.ts, which runs the full pipeline
 * (explorer → developer → QA → reviewer → finalize) and calls runWithPi()
 * per phase with the correct phase prompt and Pi extension env vars.
 */
export async function spawnWorkerProcess(config: WorkerConfig): Promise<SpawnResult> {
  return new DetachedSpawnStrategy().spawn(config);
}

/**
 * Build a clean env record (string values only) for worker config.
 * Removes CLAUDECODE to allow nested Claude sessions.
 */
export function buildWorkerEnv(
  telemetry: boolean | undefined,
  seedId: string,
  runId: string,
  model: string,
  notifyUrl?: string,
  vcsBackend?: VcsBackend,
  runtimeMode?: RuntimeMode,
): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined && key !== "CLAUDECODE") {
      env[key] = value;
    }
  }
  const home = process.env.HOME ?? "/home/nobody";
  env.PATH = `${home}/.local/bin:/opt/homebrew/bin:${env.PATH ?? ""}`;
  env.TSX_DISABLE_IPC = "1";
  env.PI_PERMISSION_LEVEL = process.env.FOREMAN_PI_PERMISSION_LEVEL?.trim() || "bypassed";
  if (!env.DATABASE_URL) {
    const poolConfig = getPoolConfig();
    if (typeof poolConfig?.connectionString === "string") {
      env.DATABASE_URL = poolConfig.connectionString;
    }
  }

  if (notifyUrl) {
    env.FOREMAN_NOTIFY_URL = notifyUrl;
  }

  // Pass VCS backend name to workers via env var so they can instantiate the
  // correct backend without re-detecting (AC-020-2). The backend was already
  // resolved and instantiated by the dispatcher; we serialize just the name.
  if (vcsBackend?.name) {
    env.FOREMAN_VCS_BACKEND = vcsBackend.name;
  }

  if (runtimeMode) {
    env.FOREMAN_RUNTIME_MODE = runtimeMode;
  }

  if (telemetry) {
    env.CLAUDE_CODE_ENABLE_TELEMETRY = "1";
    env.OTEL_RESOURCE_ATTRIBUTES = [
      process.env.OTEL_RESOURCE_ATTRIBUTES,
      `foreman.seed_id=${seedId}`,
      `foreman.run_id=${runId}`,
      `foreman.model=${model}`,
    ].filter(Boolean).join(",");
  }

  return env;
}

function log(msg: string): void {
  const ts = new Date().toISOString().slice(11, 23);
  console.error(`[foreman ${ts}] ${msg}`);
}

export function buildSdkSessionKey(
  model: string,
  runId: string,
  pid: number | null,
  sdkSessionId?: string,
): string {
  const parts = [`foreman:sdk:${model}:${runId}`];
  if (pid != null) parts.push(`pid-${pid}`);
  if (sdkSessionId) parts.push(`session-${sdkSessionId}`);
  return parts.join(":");
}

/**
 * Extract the SDK session ID from a foreman session key.
 * Format: foreman:sdk:<model>:<runId>[:pid-<pid>]:session-<sessionId>
 */
function extractSessionId(sessionKey: string | null): string | null {
  if (!sessionKey) return null;
  const m = sessionKey.match(/session-(.+)$/);
  return m ? m[1] : null;
}

function seedToInfo(
  seed: Issue,
  detail?: { description?: string | null; notes?: string | null; labels?: string[] },
  beadComments?: string | null,
): SeedInfo {
  // Combine notes (from br show) and comments (from br comments) into a single
  // "Additional Context" block so agents receive all annotated context.
  const notesSection = detail?.notes ?? undefined;
  const commentsSection = beadComments ?? undefined;
  let combinedComments: string | undefined;
  if (notesSection && commentsSection) {
    combinedComments = `${notesSection}\n\n---\n\n**Comments:**\n\n${commentsSection}`;
  } else {
    combinedComments = notesSection ?? commentsSection;
  }

  return {
    id: seed.id,
    title: seed.title,
    description: detail?.description ?? seed.description ?? undefined,
    // Convert numeric priority (0-4) to string with "P" prefix (e.g., 0 → "P0", 2 → "P2")
    priority: typeof seed.priority === "number" ? `P${seed.priority}` : seed.priority,
    type: seed.type,
    labels: detail?.labels ?? seed.labels,
    comments: combinedComments,
  };
}

// ── Worker config file cleanup ────────────────────────────────────────────────

/**
 * Return the directory where worker config JSON files are written.
 */
export function workerConfigDir(): string {
  return join(homedir(), ".foreman", "tmp");
}

/**
 * Delete the worker config file for a specific run (if it still exists).
 * Safe to call even if the file has already been deleted by the worker.
 */
export async function deleteWorkerConfigFile(runId: string): Promise<void> {
  const configPath = join(workerConfigDir(), `worker-${runId}.json`);
  try {
    await unlink(configPath);
  } catch {
    // Already deleted or never created — ignore
  }
}

/**
 * Purge stale worker config files from ~/.foreman/tmp/ for runs that are no
 * longer active in the database.
 *
 * Worker config files are written by the dispatcher and deleted by the worker
 * on startup.  When a run is killed externally, the worker never starts and
 * the config file is never cleaned up.  This function removes orphaned files
 * for runs that are in a terminal state (failed, stuck, completed, etc.) or
 * are entirely absent from the DB.
 *
 * Returns the number of files deleted.
 */
export async function purgeOrphanedWorkerConfigs(
  store: OrphanedWorkerConfigStore,
): Promise<number> {
  const dir = workerConfigDir();
  let entries: string[];
  try {
    entries = await readdir(dir);
  } catch {
    // Directory does not exist — nothing to purge
    return 0;
  }

  const activeStatuses = new Set(["pending", "running"]);
  let deleted = 0;

  for (const entry of entries) {
    if (!entry.startsWith("worker-") || !entry.endsWith(".json")) continue;
    // Extract runId from filename: worker-<runId>.json
    const runId = entry.slice("worker-".length, -".json".length);
    if (!runId) continue;

    const run = await store.getRun(runId);
    // Delete if the run is terminal, unknown, or absent from the DB
    if (!run || !activeStatuses.has(run.status)) {
      try {
        await unlink(join(dir, entry));
        deleted++;
      } catch {
        // Already gone — ignore
      }
    }
  }

  return deleted;
}
