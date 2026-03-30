import { writeFile, mkdir, open, readdir, unlink } from "node:fs/promises";
import { unlinkSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { spawn, execFileSync } from "node:child_process";
import { runWithPiSdk } from "./pi-sdk-runner.js";

import type { ITaskClient, Issue } from "../lib/task-client.js";
import type { ForemanStore, NativeTask } from "../lib/store.js";
import { STUCK_RETRY_CONFIG, calculateStuckBackoffMs, PIPELINE_TIMEOUTS } from "../lib/config.js";
import type { BvClient } from "../lib/bv.js";
import { installDependencies, runSetupWithCache } from "../lib/git.js";
import { GitBackend } from "../lib/vcs/git-backend.js";
import { extractBranchLabel, isDefaultBranch, applyBranchLabel } from "../lib/branch-label.js";
import { BeadsRustClient } from "../lib/beads-rust.js";
import { NativeTaskStore } from "../lib/task-store.js";
import { workerAgentMd } from "./templates.js";
import { normalizePriority } from "../lib/priority.js";
import { PLAN_STEP_CONFIG } from "./roles.js";
import { isPiAvailable } from "./pi-rpc-spawn-strategy.js";
import { resolveWorkflowType } from "../lib/workflow-config-loader.js";
import { loadWorkflowConfig, resolveWorkflowName } from "../lib/workflow-loader.js";
import { loadProjectConfig, resolveVcsConfig } from "../lib/project-config.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
import type { VcsBackend } from "../lib/vcs/index.js";
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

// ── Task store resolution (REQ-014 / REQ-017) ────────────────────────────

/**
 * Valid values for the FOREMAN_TASK_STORE environment variable.
 * - 'native': force native SQLite tasks table even if empty
 * - 'beads': force BeadsRustClient fallback even if native tasks exist
 * - 'auto' / undefined: auto-detect based on hasNativeTasks()
 */
export type TaskStoreMode = "native" | "beads" | "auto";

/**
 * Resolve the task store mode from the FOREMAN_TASK_STORE environment variable.
 *
 * Invalid values are treated as 'auto' and a warning is emitted.
 */
export function resolveTaskStoreMode(): TaskStoreMode {
  const raw = process.env.FOREMAN_TASK_STORE;
  if (!raw || raw === "auto") return "auto";
  if (raw === "native" || raw === "beads") return raw;
  console.error(
    `[dispatch] Warning: FOREMAN_TASK_STORE='${raw}' is not valid ('native'|'beads'|'auto'). Treating as 'auto'.`,
  );
  return "auto";
}

/**
 * Convert a NativeTask row into a normalized Issue so that native tasks can be
 * processed by the same dispatch loop that handles Beads issues.
 *
 * Priority is stored as INTEGER (0–4) in the native store; normalise to string
 * form ('P0'–'P4') so the existing normalizePriority() helper works correctly.
 */
export function nativeTaskToIssue(task: NativeTask): Issue {
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
    private taskStore?: NativeTaskStore,
  ) {}

  /**
   * Return the list of ready tasks, routing through the native task store
   * when available (REQ-014, REQ-017) or falling back to BeadsRustClient.
   *
   * Resolution order (highest priority first):
   *  1. FOREMAN_TASK_STORE=beads  — always use BeadsRustClient
   *  2. FOREMAN_TASK_STORE=native — always use NativeTaskStore
   *  3. auto (default)            — native if NativeTaskStore has rows, else beads
   */
  async getReadyTasks(): Promise<Issue[]> {
    if (this.resolveNativeMode()) {
      log("[dispatcher] Using native task store (tasks table)");
      return this.taskStore!.list({ status: "ready" });
    }

    // Beads fallback path (REQ-020 backward compatibility)
    log("[dispatcher] Using beads fallback (BeadsRustClient.ready())");
    return this.seeds.ready();
  }

  /**
   * Determine whether native-task-store mode is active.
   *
   * Resolution order (highest priority first):
   *  1. FOREMAN_TASK_STORE=beads  — always false (beads forced)
   *  2. FOREMAN_TASK_STORE=native — always true  (native forced)
   *  3. auto                      — true if taskStore injected and has rows
   *
   * Also validates FOREMAN_TASK_STORE and emits a warning on invalid values.
   */
  private resolveNativeMode(): boolean {
    const override = process.env.FOREMAN_TASK_STORE;

    // Validate env value; warn on unrecognised values but don't crash.
    if (override && override !== "native" && override !== "beads") {
      console.error(
        `[dispatcher] Warning: FOREMAN_TASK_STORE='${override}' is not recognised ` +
          `(expected 'native' or 'beads'). Ignoring and using auto-detection.`,
      );
    }

    if (override === "beads") return false;
    if (override === "native") return this.taskStore !== undefined;
    // Auto-detect: prefer native if NativeTaskStore is injected and has rows.
    return this.taskStore !== undefined && this.taskStore.hasNativeTasks();
  }

  /**
   * Query ready seeds, create worktrees, write TASK.md, and record runs.
   */
  async dispatch(opts?: {
    maxAgents?: number;
    runtime?: RuntimeSelection;
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
  }): Promise<DispatchResult> {
    const maxAgents = opts?.maxAgents ?? 5;
    const projectId = opts?.projectId ?? this.resolveProjectId();

    // Drain the bead write queue before dispatching new tasks.
    // This ensures any pending br operations from completed agent-workers are
    // processed by the single-writer dispatcher before we query br for ready seeds.
    try {
      const drained = await this.drainBeadWriterInbox();
      if (drained > 0) {
        console.error(`[bead-writer] Drained ${drained} pending bead write operations`);
      }
    } catch (drainErr: unknown) {
      // Non-fatal: log and continue — drain failures must not block dispatch
      const msg = drainErr instanceof Error ? drainErr.message : String(drainErr);
      console.error(`[bead-writer] Warning: drainBeadWriterInbox failed: ${msg.slice(0, 200)}`);
    }

    // Clear br's blocked_issues_cache before querying ready seeds.
    // The cache goes stale when beads are closed by the refinery, auto-close
    // logic, or manual operations outside br's normal flow.
    try {
      execFileSync("sqlite3", [
        join(this.projectPath, ".beads", "beads.db"),
        "DELETE FROM blocked_issues_cache;",
      ], { timeout: 5000 });
    } catch {
      // sqlite3 not available or .beads/beads.db missing — non-fatal
    }

    // ── onError=stop guard ─────────────────────────────────────────────────
    // When the workflow's onError is "stop", refuse to dispatch if any recent
    // runs ended in a terminal failure state.
    try {
      const wfConfig = loadWorkflowConfig("default", this.projectPath);
      if (wfConfig.onError === "stop") {
        const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
        const failureStatuses: Array<"test-failed" | "failed" | "stuck" | "conflict"> =
          ["test-failed", "failed", "stuck", "conflict"];
        const failedRuns = this.store.getRunsByStatusesSince(failureStatuses, since, projectId);
        if (failedRuns.length > 0) {
          log(`[dispatch] onError=stop — ${failedRuns.length} failed run(s) detected. Refusing to dispatch until resolved. Use 'foreman reset' to clear.`);
          return {
            dispatched: [],
            skipped: [],
            resumed: [],
            activeAgents: this.store.getActiveRuns(projectId).length,
          };
        }
      }
    } catch {
      // Workflow config not found — continue with default behavior
    }

    // Determine how many agent slots are available
    const activeRuns = this.store.getActiveRuns(projectId);
    const available = Math.max(0, maxAgents - activeRuns.length);

    // ── Task store coexistence (REQ-014 / REQ-017) ────────────────────────
    // Decide whether to query the native SQLite task store or fall back to
    // the BeadsRustClient based on FOREMAN_TASK_STORE and hasNativeTasks().
    const taskStoreMode = resolveTaskStoreMode();
    let usingNativeStore = false;

    if (taskStoreMode === "native") {
      usingNativeStore = true;
      console.error("[dispatch] FOREMAN_TASK_STORE=native — using native task store");
    } else if (taskStoreMode === "beads") {
      usingNativeStore = false;
      console.error("[dispatch] FOREMAN_TASK_STORE=beads — using beads fallback");
    } else {
      // 'auto': use native if tasks exist, otherwise fall back to beads
      usingNativeStore = this.store.hasNativeTasks();
      if (usingNativeStore) {
        console.error("[dispatch] Native tasks detected — using native task store (AC-014.1)");
      } else {
        console.error("[dispatch] No native tasks — using beads fallback (AC-014.1)");
      }
    }

    let readySeeds: Issue[];
    if (usingNativeStore) {
      const nativeTasks = this.store.getReadyTasks();
      readySeeds = nativeTasks.map(nativeTaskToIssue);
    } else {
      readySeeds = await this.seeds.ready();
    }

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
      let target = readySeeds.find((b) => b.id === opts.seedId);
      // If not in br ready (possibly due to stale blocked cache — beads_rust#204),
      // fetch directly and force-dispatch if it's open/in_progress.
      if (!target) {
        try {
          const bead = await this.seeds.show(opts.seedId);
          if (bead && bead.status !== "closed" && bead.status !== "completed") {
            log(`[dispatch] ${opts.seedId} not in br ready (stale cache?) — force-dispatching`);
            target = bead as unknown as Issue;
          }
        } catch { /* bead not found */ }
      }
      if (!target) {
        let reason = "Not found and not dispatchable";
        try {
          const bead = await this.seeds.show(opts.seedId);
          if (!bead) {
            reason = `Bead ${opts.seedId} not found`;
          } else if (bead.status === "closed" || bead.status === "completed") {
            reason = `Bead ${opts.seedId} is closed (already completed)`;
          } else if (bead.status === "in_progress") {
            reason = `Bead ${opts.seedId} is already in progress`;
          } else if (bead.status === "open") {
            reason = `Bead ${opts.seedId} is blocked (has unresolved dependencies)`;
          }
        } catch {
          // fall back to default reason
        }
        return {
          dispatched: [],
          skipped: [{ seedId: opts.seedId, title: opts.seedId, reason }],
          resumed: [],
          activeAgents: activeRuns.length,
        };
      }
      readySeeds = [target];
    }

    const dispatched: DispatchedTask[] = [];
    const skipped: SkippedTask[] = [];

    // Detect current branch for auto-labeling (branch:<name> label).
    // Done once per dispatch() call using VcsBackend (TRD-015: migrate from git.js shims).
    let currentBranch: string | undefined;
    let defaultBranch: string | undefined;
    try {
      const branchBackend = new GitBackend(this.projectPath);
      currentBranch = await branchBackend.getCurrentBranch(this.projectPath);
      defaultBranch = await branchBackend.detectDefaultBranch(this.projectPath);
    } catch {
      // Non-fatal: branch detection failure must not block dispatch
    }

    // Skip seeds that already have an active run
    const activeSeedIds = new Set(activeRuns.map((r) => r.seed_id));

    // Also skip seeds that have a completed-but-unmerged run (prevent duplicate runs)
    const completedRuns = this.store.getRunsByStatus("completed", projectId);
    const completedSeedIds = new Set(completedRuns.map((r) => r.seed_id));

    for (const seed of readySeeds) {
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

      // ── Auto-close feature/epic containers ────────────────────────────────
      // Feature and epic beads are organizational containers — never dispatch
      // agents for them. Instead, check if all children are closed and auto-close
      // the container bead when they are.
      if (seed.type === "feature" || seed.type === "epic") {
        try {
          const detail = await this.seeds.show(seed.id);
          const detailWithChildren = detail as { children?: string[]; status: string };
          const childIds = detailWithChildren.children ?? [];

          if (childIds.length === 0) {
            // No children — close the container directly
            await this.seeds.close(seed.id, "Auto-closed: no children (empty container)");
            log(`[dispatch] Auto-closed ${seed.id} (type: ${seed.type}) — no children`);
            skipped.push({
              seedId: seed.id,
              title: seed.title,
              reason: `Type '${seed.type}' auto-closed — no children`,
            });
          } else {
            // Check each child's status
            let openCount = 0;
            for (const childId of childIds) {
              try {
                const child = await this.seeds.show(childId);
                if (child.status !== "closed" && child.status !== "completed") {
                  openCount++;
                }
              } catch {
                // If we can't check a child, assume it's still open to be safe
                openCount++;
              }
            }

            if (openCount === 0) {
              await this.seeds.close(seed.id, "Auto-closed: all children completed");
              log(`[dispatch] Auto-closed ${seed.id} (type: ${seed.type}) — all children completed`);
              skipped.push({
                seedId: seed.id,
                title: seed.title,
                reason: `Type '${seed.type}' auto-closed — all ${childIds.length} children completed`,
              });
            } else {
              log(`[dispatch] Skipping ${seed.id} (type: ${seed.type}) — waiting on ${openCount} open children`);
              skipped.push({
                seedId: seed.id,
                title: seed.title,
                reason: `Type '${seed.type}' is an organizational container — waiting on ${openCount} open child${openCount === 1 ? "" : "ren"}`,
              });
            }
          }
        } catch (err: unknown) {
          // If we can't inspect the container, skip it rather than crashing
          const msg = err instanceof Error ? err.message : String(err);
          log(`[dispatch] Skipping ${seed.id} (type: ${seed.type}) — failed to check children: ${msg}`);
          skipped.push({
            seedId: seed.id,
            title: seed.title,
            reason: `Type '${seed.type}' is an organizational container — skipped (error checking children)`,
          });
        }
        continue;
      }

      // Skip seeds that are in exponential backoff after recent stuck runs
      const backoffResult = this.checkStuckBackoff(seed.id, projectId);
      if (backoffResult.inBackoff) {
        skipped.push({
          seedId: seed.id,
          title: seed.title,
          reason: backoffResult.reason ?? "In backoff period after recent stuck runs",
        });
        continue;
      }

      if (dispatched.length >= available) {
        skipped.push({
          seedId: seed.id,
          title: seed.title,
          reason: `Agent limit reached (${maxAgents})`,
        });
        continue;
      }

      // Fetch full issue details (description, notes/comments, labels) for agent context
      let seedDetail: { description?: string | null; notes?: string | null; labels?: string[] } | undefined;
      try {
        seedDetail = await this.seeds.show(seed.id);
      } catch {
        // Non-fatal: if show() fails, proceed without detail context
        log(`Warning: failed to fetch details for seed ${seed.id}`);
      }

      // Fetch bead comments (design notes, reviewer feedback, etc.) for agent context
      let beadComments: string | null = null;
      if (this.seeds.comments) {
        try {
          beadComments = await this.seeds.comments(seed.id);
        } catch {
          // Non-fatal: proceed without comments if fetch fails
          log(`Warning: failed to fetch comments for seed ${seed.id}`);
        }
      }

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
        const existingBranchLabel = extractBranchLabel(existingLabels);

        if (!existingBranchLabel) {
          // Determine the branch to label with: prefer current non-default branch,
          // then check parent for inheritance.
          let labelBranch: string | undefined;

          if (!isDefaultBranch(currentBranch, defaultBranch)) {
            labelBranch = currentBranch;
          } else if (seed.parent) {
            // Check parent's branch: label for inheritance
            try {
              const parentDetail = await this.seeds.show(seed.parent) as unknown as { labels?: string[] };
              const parentBranchLabel = extractBranchLabel(parentDetail.labels);
              if (parentBranchLabel && !isDefaultBranch(parentBranchLabel, defaultBranch)) {
                labelBranch = parentBranchLabel;
              }
            } catch {
              // Non-fatal: parent label lookup failure must not block dispatch
            }
          }

          if (labelBranch) {
            const updatedLabels = applyBranchLabel(existingLabels, labelBranch);
            try {
              await this.seeds.update(seed.id, { labels: updatedLabels });
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
      const model: ModelSelection = opts?.model ?? "anthropic/claude-sonnet-4-6";

      if (opts?.dryRun) {
        dispatched.push({
          seedId: seed.id,
          title: seed.title,
          runtime,
          model,
          worktreePath: join(this.projectPath, ".foreman-worktrees", seed.id),
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
        if (this.store.hasActiveOrPendingRun(seed.id, projectId)) {
          skipped.push({
            seedId: seed.id,
            title: seed.title,
            reason: "Another run was created concurrently (race guard)",
          });
          continue;
        }

        // 1. Resolve base branch (may stack on a dependency branch)
        const baseBranch = await resolveBaseBranch(seed.id, this.projectPath, this.store);
        if (baseBranch) {
          log(`[foreman] Stacking ${seed.id} on ${baseBranch}`);
        }

        // 1a. Load workflow config to get setup steps + cache config for worktree initialization
        const resolvedWorkflow = resolveWorkflowName(seedInfo.type ?? "feature", seedInfo.labels);
        let setupSteps: import("../lib/workflow-loader.js").WorkflowSetupStep[] | undefined;
        let setupCache: import("../lib/workflow-loader.js").WorkflowSetupCache | undefined;
        let vcsBackendName: 'git' | 'jujutsu' = 'git'; // default to git
        try {
          const wfConfig = loadWorkflowConfig(resolvedWorkflow, this.projectPath);
          setupSteps = wfConfig.setup;
          setupCache = wfConfig.setupCache;

          // Load project-level config (optional — returns null if .foreman/config.yaml absent)
          let projectVcs: import("../lib/project-config.js").ProjectConfig["vcs"] | undefined;
          try {
            const projectCfg = loadProjectConfig(this.projectPath);
            projectVcs = projectCfg?.vcs;
          } catch (projErr: unknown) {
            // Non-fatal: log and continue without project config
            const projMsg = projErr instanceof Error ? projErr.message : String(projErr);
            log(`[foreman] Could not load project config — ${projMsg}`);
          }

          // Resolve VCS backend: workflow > project > auto-detect
          const resolvedVcs = resolveVcsConfig(wfConfig.vcs, projectVcs);
          if (resolvedVcs.backend !== 'auto') {
            vcsBackendName = resolvedVcs.backend;
          } else {
            // Auto-detect: .jj/ → jujutsu, else git
            const { existsSync } = await import("node:fs");
            const { join: pathJoin } = await import("node:path");
            if (existsSync(pathJoin(this.projectPath, '.jj'))) {
              vcsBackendName = 'jujutsu';
            }
            // else: stay with 'git' default
          }
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
          vcsBackend = await VcsBackendFactory.create({ backend: vcsBackendName }, this.projectPath);
          log(`[foreman] Created VcsBackend: ${vcsBackend.name}`);
        } catch (vcsErr: unknown) {
          const vcsMsg = vcsErr instanceof Error ? vcsErr.message : String(vcsErr);
          log(`[foreman] VcsBackend creation failed: ${vcsMsg} — continuing without VcsBackend instance`);
        }

        // 2. Create workspace via VcsBackend (TRD-015: replaces createWorktree shim)
        // Falls back to GitBackend if vcsBackend creation failed (non-fatal).
        const workspaceBackend = vcsBackend ?? new GitBackend(this.projectPath);
        const workspaceResult = await workspaceBackend.createWorkspace(
          this.projectPath,
          seed.id,
          baseBranch,
        );
        const worktreePath = workspaceResult.workspacePath;
        const branchName = workspaceResult.branchName;

        // Run setup steps / install dependencies (not part of VcsBackend interface)
        if (setupSteps && setupSteps.length > 0) {
          await runSetupWithCache(worktreePath, this.projectPath, setupSteps, setupCache);
        } else {
          await installDependencies(worktreePath);
        }

        // 3. Write TASK.md in the worktree (not AGENTS.md — avoids overwriting project file on merge)
        const taskMd = workerAgentMd(seedInfo, worktreePath, model);
        await writeFile(join(worktreePath, "TASK.md"), taskMd, "utf-8");

        // 4. Record run in store (include base_branch for stacking awareness)
        const run = this.store.createRun(
          projectId,
          seed.id,
          model,
          worktreePath,
          { baseBranch: baseBranch ?? null },
        );

        // 5. Log dispatch event
        this.store.logEvent(projectId, "dispatch", {
          seedId: seed.id,
          title: seed.title,
          model,
          worktreePath,
          branchName,
        }, run.id);

        // 5a. Send worktree-created mail so inbox shows worktree lifecycle event
        try {
          this.store.sendMessage(run.id, "foreman", "foreman", "worktree-created", JSON.stringify({
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
        if (usingNativeStore) {
          // Atomic claim: UPDATE tasks SET status='in-progress', run_id=? WHERE id=? AND status='ready'
          // REQ-017 AC-017.2: claim + run_id linkage in one transaction (prevents double-dispatch).
          const claimed = this.store.claimTask(seed.id, run.id);
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
              this.store.updateRun(run.id, { status: "failed", completed_at: new Date().toISOString() });
            } catch {
              // Non-fatal — run cleanup is best-effort
            }
            continue;
          }
        } else {
          // Non-fatal: br may reject the claim due to stale blocked cache (beads_rust#204).
          // The agent can still run — the status update is cosmetic.
          try {
            await this.seeds.update(seed.id, { status: "in_progress" });
          } catch (claimErr: unknown) {
            const claimMsg = claimErr instanceof Error ? claimErr.message : String(claimErr);
            console.error(`[dispatch] Warning: br claim failed for ${seed.id} (non-fatal): ${claimMsg.slice(0, 200)}`);
          }
        }

        // 6a. Send bead-claimed mail so inbox shows bead lifecycle event
        try {
          this.store.sendMessage(run.id, "foreman", "foreman", "bead-claimed", JSON.stringify({
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
        // Pass taskId from native store (null in beads fallback mode — REQ-020).
        const taskId = nativeMode ? seed.id : null;
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
          opts?.targetBranch,
          taskId,
        );

        // Update run with session key
        this.store.updateRun(run.id, {
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
      activeAgents: activeRuns.length + dispatched.length,
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
  }): Promise<DispatchResult> {
    const maxAgents = opts?.maxAgents ?? 5;
    const projectId = this.resolveProjectId();
    const statuses = opts?.statuses ?? ["stuck"];

    // Find resumable runs
    const resumableRuns = statuses.flatMap(
      (s) => this.store.getRunsByStatus(s, projectId),
    );

    const activeRuns = this.store.getActiveRuns(projectId);
    const available = Math.max(0, maxAgents - activeRuns.length);

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
      const newRun = this.store.createRun(
        projectId,
        run.seed_id,
        model,
        run.worktree_path,
      );

      // Log resume event
      this.store.logEvent(projectId, "restart", {
        seedId: run.seed_id,
        model,
        previousRunId: run.id,
        previousStatus,
        sessionId,
      }, newRun.id);

      // Mark old run as restarted
      this.store.updateRun(run.id, {
        status: "failed",
        completed_at: new Date().toISOString(),
      });

      // Mark seed as in_progress before spawning resumed agent
      await this.seeds.update(run.seed_id, { status: "in_progress" });

      // Spawn the resumed agent
      const { sessionKey } = await this.resumeAgent(
        model,
        run.worktree_path,
        { id: run.seed_id, title: run.seed_id },
        newRun.id,
        sessionId,
        opts?.telemetry,
        opts?.notifyUrl,
      );

      this.store.updateRun(newRun.id, {
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
      activeAgents: activeRuns.length + resumed.length,
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
    // 1. Record run in store
    const run = this.store.createRun(projectId, seed.id, "claude-code");

    // 2. Log dispatch event
    this.store.logEvent(projectId, "dispatch", {
      seedId: seed.id,
      title: seed.title,
      ensembleCommand,
      outputDir,
      type: "plan-step",
    }, run.id);

    // 3. Build the prompt
    const prompt = `${ensembleCommand} ${input}\n\nSave all outputs to the ${outputDir}/ directory.`;

    const sessionKey = `foreman:plan:${run.id}`;
    this.store.updateRun(run.id, {
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
        this.store.updateRun(run.id, {
          status: "completed",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(projectId, "complete", {
          seedId: seed.id,
          title: seed.title,
          costUsd: planResult.costUsd,
          numTurns: planResult.turns,
        }, run.id);
      } else {
        const reason = planResult.errorMessage ?? "Pi plan step failed";
        this.store.updateRun(run.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(projectId, "fail", {
          seedId: seed.id,
          reason,
          costUsd: planResult.costUsd,
        }, run.id);
        throw new Error(reason);
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      // Only update if not already updated by the result handler above
      const currentRun = this.store.getRun(run.id);
      if (currentRun?.status === "running") {
        this.store.updateRun(run.id, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(projectId, "fail", {
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
    const model: ModelSelection = "anthropic/claude-sonnet-4-6";
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
   * SQLite store with progress/completion.
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
    targetBranch?: string,
    taskId?: string | null,
  ): Promise<{ sessionKey: string }> {
    const prompt = this.buildSpawnPrompt(seed.id, seed.title);

    const env = buildWorkerEnv(telemetry, seed.id, runId, model, notifyUrl, vcsBackend);
    const sessionKey = `foreman:sdk:${model}:${runId}`;
    const usePipeline = pipelineOpts?.pipeline ?? true;  // Pipeline by default

    log(`Spawning ${usePipeline ? "pipeline" : "worker"} for ${seed.id} [${model}] in ${worktreePath}`);

    const seedType = resolveWorkflowType(seed.type ?? "feature", seed.labels);

    await spawnWorkerProcess({
      runId,
      projectId: this.resolveProjectId(),
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
      taskId: taskId ?? null,
    });

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
  ): Promise<{ sessionKey: string }> {
    const resumePrompt = this.buildResumePrompt(seed.id, seed.title);

    const env = buildWorkerEnv(telemetry, seed.id, runId, model, notifyUrl);
    const sessionKey = `foreman:sdk:${model}:${runId}:session-${sdkSessionId}`;

    log(`Resuming worker for ${seed.id} [${model}] session=${sdkSessionId}`);

    await spawnWorkerProcess({
      runId,
      projectId: this.resolveProjectId(),
      seedId: seed.id,
      seedTitle: seed.title,
      model,
      worktreePath,
      prompt: resumePrompt,
      env,
      resume: sdkSessionId,
      dbPath: join(this.projectPath, ".foreman", "foreman.db"),
      taskId: null, // resume path: taskId not tracked (beads fallback mode)
    });

    return { sessionKey };
  }

  // ── Private helpers ───────────────────────────────────────────────────

  /**
   * Return recent stuck runs for a seed within the configured time window.
   * Ordered by created_at DESC (most recent first).
   */
  private getRecentStuckRuns(seedId: string, projectId: string) {
    const cutoff = new Date(Date.now() - STUCK_RETRY_CONFIG.windowMs).toISOString();
    const allRuns = this.store.getRunsForSeed(seedId, projectId);
    return allRuns.filter(
      (r) => r.status === "stuck" && r.created_at >= cutoff,
    );
  }

  /**
   * Check whether a seed is currently in exponential backoff due to recent
   * stuck runs. Returns `{ inBackoff: false }` if the seed may be dispatched,
   * or `{ inBackoff: true, reason }` if it must be skipped this cycle.
   */
  private checkStuckBackoff(
    seedId: string,
    projectId: string,
  ): { inBackoff: boolean; reason?: string } {
    const recentStuck = this.getRecentStuckRuns(seedId, projectId);
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
   * Drain the bead_write_queue and execute all pending br operations sequentially.
   *
   * This is the single writer for all br CLI operations — called by the dispatcher
   * process only. Agent-workers, refinery, pipeline-executor, and auto-merge enqueue
   * operations via ForemanStore.enqueueBeadWrite() instead of calling br directly,
   * eliminating concurrent SQLite lock contention on .beads/beads.jsonl.
   *
   * Each entry is processed in insertion order. If an individual operation fails,
   * the error is logged but draining continues (non-fatal per-entry). A single
   * `br sync --flush-only` is called at the end to persist all changes atomically.
   *
   * @returns Number of entries successfully processed.
   */
  async drainBeadWriterInbox(): Promise<number> {
    const pending = this.store.getPendingBeadWrites();
    if (pending.length === 0) return 0;

    const bin = join(homedir(), ".local", "bin", "br");
    const execOpts = {
      stdio: "pipe" as const,
      timeout: PIPELINE_TIMEOUTS.beadClosureMs,
      cwd: this.projectPath,
    };

    let processed = 0;

    for (const entry of pending) {
      try {
        let payload: Record<string, unknown>;
        try {
          payload = JSON.parse(entry.payload) as Record<string, unknown>;
        } catch {
          console.error(`[bead-writer] Invalid JSON payload for entry ${entry.id} (${entry.operation}) — skipping`);
          this.store.markBeadWriteProcessed(entry.id);
          continue;
        }

        const seedId = payload.seedId as string;

        // All br commands get --lock-timeout so they wait for concurrent agent
        // reads to release the SQLite lock instead of failing with SQLITE_BUSY.
        const lockArgs = ["--lock-timeout", "10000"];

        switch (entry.operation) {
          case "close-seed":
            // Use --no-db to write directly to JSONL, bypassing the SQLite blocked cache.
            execFileSync(bin, ["close", seedId, "--no-db", "--reason", "Completed via pipeline", ...lockArgs], execOpts);
            console.error(`[bead-writer] Closed seed ${seedId} via --no-db (from ${entry.sender})`);
            break;

          case "reset-seed":
            execFileSync(bin, ["update", seedId, "--status", "open", ...lockArgs], execOpts);
            console.error(`[bead-writer] Reset seed ${seedId} to open (from ${entry.sender})`);
            break;

          case "mark-failed":
            execFileSync(bin, ["update", seedId, "--status", "failed", ...lockArgs], execOpts);
            console.error(`[bead-writer] Marked seed ${seedId} as failed (from ${entry.sender})`);
            break;

          case "set-status": {
            const targetStatus = payload.status as string;
            execFileSync(bin, ["update", seedId, "--status", targetStatus, ...lockArgs], execOpts);
            console.error(`[bead-writer] Set seed ${seedId} to ${targetStatus} (from ${entry.sender})`);
            break;
          }

          case "add-notes": {
            const notes = payload.notes as string;
            if (notes) {
              execFileSync(bin, ["update", seedId, "--notes", notes, ...lockArgs], execOpts);
              console.error(`[bead-writer] Added notes to seed ${seedId} (from ${entry.sender})`);
            }
            break;
          }

          case "add-labels": {
            const labels = payload.labels as string[];
            if (labels && labels.length > 0) {
              const args = ["update", seedId, ...labels.flatMap((l) => ["--add-label", l]), ...lockArgs];
              execFileSync(bin, args, execOpts);
              console.error(`[bead-writer] Added labels [${labels.join(", ")}] to seed ${seedId} (from ${entry.sender})`);
            }
            break;
          }

          default:
            console.error(`[bead-writer] Unknown operation "${entry.operation}" for entry ${entry.id} — skipping`);
        }

        this.store.markBeadWriteProcessed(entry.id);
        processed++;
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[bead-writer] Error processing entry ${entry.id} (${entry.operation}): ${msg.slice(0, 200)}`);
        // Mark as processed even on error to avoid infinite retry loops.
        // The operator can check the log for details and fix manually.
        this.store.markBeadWriteProcessed(entry.id);
      }
    }

    // Close operations used --no-db (write directly to JSONL). Delete the br DB
    // so the next br command reimports from the corrected JSONL with a fresh
    // blocked cache. This ensures br ready reflects newly-unblocked beads.
    if (processed > 0) {
      try {
        // Force full re-export so JSONL stays in sync with the DB.
        // Regular --flush-only only exports "dirty" entries, but dirty flags
        // can get out of sync (e.g. after --no-db writes or interrupted sessions),
        // causing bv to see stale data. --force re-exports everything.
        // Use a longer timeout than individual bead operations since full export
        // scales with total issue count.
        execFileSync(bin, ["sync", "--flush-only", "--force"], {
          ...execOpts,
          timeout: Math.max(execOpts.timeout, 60_000),
        });
        // Clear the blocked_issues_cache so br ready reflects newly-unblocked beads.
        // Using sqlite3 CLI is safer and faster than deleting the entire DB.
        try {
          execFileSync("sqlite3", [
            join(this.projectPath, ".beads", "beads.db"),
            "DELETE FROM blocked_issues_cache;",
          ], execOpts);
          console.error(`[bead-writer] Cleared blocked_issues_cache after processing ${processed}/${pending.length} entries`);
        } catch {
          // Fallback: delete DB files if sqlite3 not available
          const beadsDir = join(this.projectPath, ".beads");
          for (const dbFile of ["beads.db", "beads.db-wal", "beads.db-shm"]) {
            try { unlinkSync(join(beadsDir, dbFile)); } catch { /* may not exist */ }
          }
          console.error(`[bead-writer] Deleted DB (fallback) after processing ${processed}/${pending.length} entries`);
        }
      } catch (flushErr: unknown) {
        const msg = flushErr instanceof Error ? flushErr.message : String(flushErr);
        console.error(`[bead-writer] Warning: post-drain cleanup failed: ${msg.slice(0, 200)}`);
      }
    }

    return processed;
  }

  private resolveProjectId(): string {
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
 * If any of the seed's blocking dependencies have an unmerged local branch
 * (i.e. a `foreman/<depId>` branch exists locally and its latest run is
 * "completed" but not yet "merged"), stack the new worktree on top of that
 * dependency branch instead of the default branch.
 *
 * This allows agent B to build on top of agent A's work before A is merged.
 * After A merges, the refinery will rebase B onto main.
 *
 * Returns the dependency branch name (e.g. "foreman/story-1") or undefined
 * when no stacking is needed.
 */
export async function resolveBaseBranch(
  seedId: string,
  projectPath: string,
  store: Pick<ForemanStore, "getRunsForSeed">,
): Promise<string | undefined> {
  const brClient = new BeadsRustClient(projectPath);
  try {
    const detail = await brClient.show(seedId);
    // detail.dependencies is string[] of dep IDs that this seed depends on
    for (const depId of detail.dependencies ?? []) {
      const depBranch = `foreman/${depId}`;
      // Check if this branch exists locally via VcsBackend (TRD-015: migrate from gitBranchExists shim)
      const depBackend = new GitBackend(projectPath);
      const branchExists = await depBackend.branchExists(projectPath, depBranch);
      if (!branchExists) continue;
      // Check if the dep's most recent run is "completed" (done but not yet merged)
      const depRuns = store.getRunsForSeed(depId);
      const latestDepRun = depRuns[0]; // DESC order → first = most recent
      if (latestDepRun && latestDepRun.status === "completed") {
        return depBranch; // Stack on this dependency branch
      }
    }
  } catch {
    // br may not be initialized or the seed may not have dependency info — ignore
  }
  return undefined; // Default: branch from main/current
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
  /** Absolute path to the SQLite DB file (e.g. .foreman/foreman.db) */
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
   * Null/undefined in beads fallback mode — no-op via optional chaining.
   */
  taskId?: string | null;
}

// ── Spawn Strategy Pattern ──────────────────────────────────────────────

/** Result returned by a SpawnStrategy */
export interface SpawnResult {
}

/** Strategy interface for spawning worker processes */
export interface SpawnStrategy {
  spawn(config: WorkerConfig): Promise<SpawnResult>;
}

/**
 * Resolve common paths needed by both spawn strategies.
 */
function resolveWorkerPaths(): { tsxBin: string; workerScript: string; logDir: string } {
  const __filename = fileURLToPath(import.meta.url);
  const __dirname = dirname(__filename);
  const projectRoot = join(__dirname, "..", "..");
  return {
    tsxBin: join(projectRoot, "node_modules", ".bin", "tsx"),
    workerScript: join(__dirname, "agent-worker.js"),
    logDir: join(process.env.HOME ?? "/tmp", ".foreman", "logs"),
  };
}


/**
 * Spawn worker as a detached child process (original behavior).
 */
export class DetachedSpawnStrategy implements SpawnStrategy {
  async spawn(config: WorkerConfig): Promise<SpawnResult> {
    const { tsxBin, workerScript, logDir } = resolveWorkerPaths();

    // Write config to temp file (worker reads + deletes it)
    const configDir = join(process.env.HOME ?? "/tmp", ".foreman", "tmp");
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

    // Spawn from the project root (where dist/ and node_modules/ live),
    // not the worktree. The worktree path is passed in config and used by
    // the agent for git operations. tsx resolves imports relative to the
    // script's location, but ESM resolution still checks cwd for some paths.
    const __filename = fileURLToPath(import.meta.url);
    const projectRoot = join(dirname(__filename), "..", "..");
    const child = spawn(tsxBin, [workerScript, configPath], {
      detached: true,
      stdio: ["ignore", outFd.fd, errFd.fd],
      cwd: projectRoot,
      env: spawnEnv,
    });

    child.unref();

    // Close parent's file handles — child process has inherited its own copies of the fds
    await outFd.close();
    await errFd.close();

    log(`  Worker pid=${child.pid} for ${config.seedId}`);
    return {};
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
function buildWorkerEnv(
  telemetry: boolean | undefined,
  seedId: string,
  runId: string,
  model: string,
  notifyUrl?: string,
  vcsBackend?: VcsBackend,
): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined && key !== "CLAUDECODE") {
      env[key] = value;
    }
  }
  const home = process.env.HOME ?? "/home/nobody";
  env.PATH = `${home}/.local/bin:/opt/homebrew/bin:${env.PATH ?? ""}`;

  if (notifyUrl) {
    env.FOREMAN_NOTIFY_URL = notifyUrl;
  }

  // Pass VCS backend name to workers via env var so they can instantiate the
  // correct backend without re-detecting (AC-020-2). The backend was already
  // resolved and instantiated by the dispatcher; we serialize just the name.
  if (vcsBackend?.name) {
    env.FOREMAN_VCS_BACKEND = vcsBackend.name;
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

/**
 * Extract the SDK session ID from a foreman session key.
 * Format: foreman:sdk:<model>:<runId>:session-<sessionId>
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
    priority: seed.priority,
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
  store: Pick<import("../lib/store.js").ForemanStore, "getRun">,
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

    const run = store.getRun(runId);
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
