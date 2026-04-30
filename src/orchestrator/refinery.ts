import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import type { ForemanStore } from "../lib/store.js";
import type { BeadGraph } from "../lib/beads.js";
import type { UpdateOptions } from "../lib/task-client.js";
// Note: removeWorktree shim removed in TRD-012; workspace removal now goes through this.vcsBackend.removeWorkspace()
import { extractBranchLabel, normalizeBranchLabel } from "../lib/branch-label.js";
import { archiveWorktreeReports } from "../lib/archive-reports.js";
import type { MergeReport, MergedRun, ConflictRun, FailedRun, PrReport, CreatedPr } from "./types.js";
import { PIPELINE_BUFFERS, PIPELINE_TIMEOUTS } from "../lib/config.js";
import { ConflictResolver } from "./conflict-resolver.js";
import { DEFAULT_MERGE_CONFIG } from "./merge-config.js";
import { enqueueCloseSeed, enqueueResetSeedToOpen, enqueueAddNotesToBead } from "./task-backend-ops.js";
import { syncBeadStatusAfterMerge } from "./auto-merge.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
import type { VcsBackend } from "../lib/vcs/index.js";
import { NativeTaskStore } from "../lib/task-store.js";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import type { Run, EventType } from "../lib/store.js";
import { closeLinkedGithubIssue, linkPrToGithubIssue } from "../daemon/github-poller.js";

const execFileAsync = promisify(execFile);

type Awaitable<T> = T | Promise<T>;

export interface RefineryRunLookup {
  getRun(id: string): Awaitable<Run | null>;
  getRunsByStatus(status: Run["status"], projectId?: string): Awaitable<Run[]>;
  getRunsByStatuses(statuses: Run["status"][], projectId?: string): Awaitable<Run[]>;
  getRunsByBaseBranch(baseBranch: string, projectId?: string): Awaitable<Run[]>;
}

export interface RefineryOptions {
  runLookup?: RefineryRunLookup;
  registeredProjectId?: string;
}

// ── Helpers ──────────────────────────────────────────────────────────────

/**
 * Run git commands that are NOT covered by the VcsBackend interface:
 *   - git log --oneline / git log ranges for PR body rendering and diagnostics
 */
async function gitSpecial(args: string[], cwd: string): Promise<string> {
  const { stdout } = await execFileAsync("git", args, {
    cwd,
    maxBuffer: PIPELINE_BUFFERS.maxBufferBytes,
    env: { ...process.env, GIT_EDITOR: "true" },
  });
  return stdout.trim();
}

async function gh(args: string[], cwd: string): Promise<string> {
  const { stdout } = await execFileAsync("gh", args, {
    cwd,
    maxBuffer: PIPELINE_BUFFERS.maxBufferBytes,
  });
  return stdout.trim();
}

function shouldCreateFreshPrAfterReopenFailure(err: unknown): boolean {
  const message = err instanceof Error ? err.message : String(err);
  return message.includes("Could not open the pull request")
    || message.includes("reopenPullRequest");
}

function shouldTreatLocalBranchDeleteFailureAsNonFatal(err: unknown): boolean {
  const message = err instanceof Error ? err.message : String(err);
  return message.includes("cannot delete branch")
    && message.includes("used by worktree");
}

async function runTestCommand(command: string, cwd: string): Promise<{ ok: boolean; output: string }> {
  const [cmd, ...args] = command.split(/\s+/);
  try {
    const { stdout, stderr } = await execFileAsync(cmd, args, {
      cwd,
      maxBuffer: PIPELINE_BUFFERS.maxBufferBytes,
      timeout: PIPELINE_TIMEOUTS.testExecutionMs,
    });
    return { ok: true, output: (stdout + "\n" + stderr).trim() };
  } catch (err: any) {
    return { ok: false, output: (err.stdout ?? "") + "\n" + (err.stderr ?? err.message) };
  }
}

// ── IRefineryTaskClient ───────────────────────────────────────────────────

/**
 * Minimal interface for the task-tracking client used by Refinery.
 *
 * This covers the two methods Refinery calls:
 *   - show(id): fetch issue detail for PR title/body generation
 *   - getGraph(): optional; used to order merges by dependency graph
 *
 * BeadsRustClient satisfies this interface.
 * BeadsRustClient does not implement getGraph(); the try/catch in
 * orderByDependencies will fall back to insertion order in that case.
 */
export interface IRefineryTaskClient {
  show(id: string): Promise<{ title?: string; description?: string | null; status: string; labels?: string[] }>;
  getGraph?(): Promise<BeadGraph>;
  update?(id: string, opts: UpdateOptions): Promise<void>;
}

// ── Refinery ─────────────────────────────────────────────────────────────

export class Refinery {
  private conflictResolver: ConflictResolver;
  private vcsBackend: VcsBackend;
  private readonly taskStore?: NativeTaskStore;
  private readonly runLookup: RefineryRunLookup;
  private readonly registeredProjectId?: string;
  private readonly postgresAdapter?: PostgresAdapter;

  constructor(
    private store: ForemanStore,
    private seeds: IRefineryTaskClient,
    private projectPath: string,
    vcsBackend?: VcsBackend,
    opts: RefineryOptions = {},
  ) {
    // Default to git for backward compatibility with callers that don't
    // provide an explicit VcsBackend (e.g. existing tests).
    this.vcsBackend = vcsBackend ?? VcsBackendFactory.createSync({ backend: "git" }, projectPath);
    this.conflictResolver = new ConflictResolver(projectPath, DEFAULT_MERGE_CONFIG, this.vcsBackend);
    this.runLookup = opts.runLookup ?? store;
    this.registeredProjectId = opts.registeredProjectId;
    if (this.registeredProjectId) {
      this.postgresAdapter = new PostgresAdapter();
    } else {
      this.taskStore = new NativeTaskStore(this.store.getDb());
    }
  }

  private async lookupRun(runId: string): Promise<Run | null> {
    return Promise.resolve(this.runLookup.getRun(runId));
  }

  private async lookupRunsByStatus(status: Run["status"], projectId?: string): Promise<Run[]> {
    return projectId === undefined
      ? Promise.resolve(this.runLookup.getRunsByStatus(status))
      : Promise.resolve(this.runLookup.getRunsByStatus(status, projectId));
  }

  private async lookupRunsByStatuses(statuses: Run["status"][], projectId?: string): Promise<Run[]> {
    return projectId === undefined
      ? Promise.resolve(this.runLookup.getRunsByStatuses(statuses))
      : Promise.resolve(this.runLookup.getRunsByStatuses(statuses, projectId));
  }

  private async lookupRunsByBaseBranch(baseBranch: string, projectId?: string): Promise<Run[]> {
    return projectId === undefined
      ? Promise.resolve(this.runLookup.getRunsByBaseBranch(baseBranch))
      : Promise.resolve(this.runLookup.getRunsByBaseBranch(baseBranch, projectId));
  }

  private async persistRunUpdate(run: Run, updates: Partial<Pick<Run, "status" | "completed_at" | "base_branch" | "pr_url" | "pr_state" | "pr_head_sha">>): Promise<void> {
    if (this.registeredProjectId && this.postgresAdapter) {
      try {
        await this.postgresAdapter.updateRun(this.registeredProjectId, run.id, updates);
        return;
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        console.warn(`[Refinery] Registered run update failed (non-fatal); falling back to local store: ${msg}`);
      }
    }

    try {
      await Promise.resolve(this.store.updateRun(run.id, updates));
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.warn(`[Refinery] Local run update failed (non-fatal): ${msg}`);
    }
  }

  private async persistRunEvent(run: Run, eventType: EventType, data: Record<string, unknown>): Promise<void> {
    if (this.registeredProjectId && this.postgresAdapter) {
      try {
        await this.postgresAdapter.logEvent(this.registeredProjectId, run.id, eventType, JSON.stringify(data));
        return;
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        console.warn(`[Refinery] Registered event write failed (non-fatal); falling back to local store: ${msg}`);
      }
    }

    try {
      this.store.logEvent(run.project_id, eventType, data, run.id);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.warn(`[Refinery] Local event write failed (non-fatal): ${msg}`);
    }
  }

  /**
   * Scan the committed diff between branchName and targetBranch for conflict markers.
   * Only looks at committed content (git diff), never at uncommitted working-tree files.
   * Uncommitted conflict markers (e.g. from a failed agent rebase) are intentionally ignored —
   * they don't exist in the branch that will be merged.
   * Returns a list of files containing markers (relative to repo root), or an empty array if clean.
   */
  private async scanForConflictMarkers(branchName: string, targetBranch: string): Promise<string[]> {
    try {
      const diff = await this.vcsBackend.diff(this.projectPath, targetBranch, branchName);
      if (!diff.trim()) return [];
      const files = new Set<string>();
      let currentFile = "";
      for (const line of diff.split("\n")) {
        if (line.startsWith("+++ b/")) {
          currentFile = line.slice(6); // strip "+++ b/"
        } else if ((line.startsWith("+<<<<<<<") || line.startsWith("+|||||||")) && currentFile) {
          files.add(currentFile);
        }
      }
      return [...files];
    } catch {
      // Any error (e.g. branch not found) — return clean to avoid blocking merge
      return [];
    }
  }

  /**
   * Check if a file path is a report/non-code file that can be auto-resolved.
   * Delegates to ConflictResolver.isReportFile().
   */
  private isReportFile(f: string): boolean {
    return ConflictResolver.isReportFile(f);
  }

  /**
   * During a rebase conflict, check if all conflicts are report files.
   * If so, auto-resolve them and continue rebase (looping until done).
   * If real code conflicts exist, abort rebase and return false.
   * Returns true if rebase completed successfully.
   * Delegates to ConflictResolver.autoResolveRebaseConflicts().
   */
  private async autoResolveRebaseConflicts(targetBranch: string): Promise<boolean> {
    return this.conflictResolver.autoResolveRebaseConflicts(targetBranch);
  }

  /**
   * Detect uncommitted changes in `.seeds/` and `.foreman/` and commit them
   * so that merge operations start from a clean state for state files.
   * No-op when there are no dirty state files.
   */
  private async autoCommitStateFiles(): Promise<void> {
    try {
      // Use vcsBackend.getModifiedFiles() to retrieve file paths with correct
      // per-line whitespace handling. This avoids the XY-code trimming issue
      // that occurs when using status() on the whole output string (git status
      // --porcelain lines starting with ' M' have a leading space that trim()
      // removes from the first line of the combined output).
      const modifiedFiles = await this.vcsBackend.getModifiedFiles(this.projectPath);
      if (modifiedFiles.length === 0) return;

      const stateFiles = modifiedFiles.filter(
        (path) => path.startsWith(".seeds/") || path.startsWith(".foreman/"),
      );

      if (stateFiles.length === 0) return;

      await this.vcsBackend.stageFiles(this.projectPath, stateFiles);
      await this.vcsBackend.commit(this.projectPath, "chore: auto-commit state files before merge");
    } catch (err: unknown) {
      // MQ-020: Auto-commit failure is non-fatal — log and continue
      const message = err instanceof Error ? err.message : String(err);
      console.error(`[MQ-020] Auto-commit state files failed (non-fatal): ${message}`);
    }
  }

  /**
   * Remove report files from the working tree before merging so they can't
   * conflict. Commits the removal if any tracked files were removed.
   * Delegates to ConflictResolver.removeReportFiles().
   */
  private async removeReportFiles(): Promise<void> {
    return this.conflictResolver.removeReportFiles();
  }

  /**
   * Archive report files after a successful merge.
   * Moves report files from the working tree into .foreman/reports/<name>-<seedId>.md
   * and creates a follow-up commit. Called after a successful squash merge so we
   * don't need to checkout branches or deal with dirty working trees.
   * Delegates to ConflictResolver.archiveReportsPostMerge().
   */
  private async archiveReportsPostMerge(seedId: string): Promise<void> {
    return this.conflictResolver.archiveReportsPostMerge(seedId);
  }

  /**
   * Fire-and-forget helper to send a mail message via the store.
   * Never throws — failures are silently ignored (mail is optional infrastructure).
   */
  private sendMail(
    runId: string,
    subject: string,
    body: Record<string, unknown>,
  ): void {
    void Promise.resolve().then(() => this.store.sendMessage(runId, "refinery", "foreman", subject, JSON.stringify({
        ...body,
        timestamp: new Date().toISOString(),
      }))).catch(() => {
      // Non-fatal — mail is optional infrastructure
    });
  }

  private isTestRuntime(): boolean {
    return (process.env.FOREMAN_RUNTIME_MODE ?? "").trim().toLowerCase() === "test";
  }

  private async getSeedContext(seedId: string): Promise<{ title: string; description: string }> {
    let seedTitle = seedId;
    let seedDescription = "";
    try {
      const seedInfo = await this.seeds.show(seedId);
      if (seedInfo) {
        seedTitle = seedInfo.title ?? seedId;
        seedDescription = seedInfo.description ?? "";
      }
    } catch {
      // Non-fatal — use defaults
    }
    return { title: seedTitle, description: seedDescription };
  }

  private async getExistingPrUrl(branchName: string): Promise<string | null> {
    try {
      const prUrl = await gh(["pr", "view", branchName, "--json", "url", "--jq", ".url"], this.projectPath);
      return prUrl.trim() || null;
    } catch {
      return null;
    }
  }

  private async getExistingPrState(branchName: string): Promise<{ state: string; headRefName?: string; headRefOid?: string; url?: string } | null> {
    try {
      const prRaw = await gh(["pr", "view", branchName, "--json", "state,headRefName,headRefOid,url", "--jq", "."], this.projectPath);
      const parsed = JSON.parse(prRaw) as { state?: string; headRefName?: string; headRefOid?: string; url?: string };
      if (!parsed.state) return null;
      return {
        state: parsed.state,
        headRefName: parsed.headRefName,
        headRefOid: parsed.headRefOid,
        url: parsed.url,
      };
    } catch {
      return null;
    }
  }


  private async finalizeSuccessfulMerge(run: import("../lib/store.js").Run, branchName: string, targetBranch: string): Promise<void> {
    if (run.worktree_path) {
      try {
        await archiveWorktreeReports(this.projectPath, run.worktree_path, run.seed_id);
      } catch {
        // Archive is best-effort — don't block worktree removal
      }
      try {
        await this.vcsBackend.removeWorkspace(this.projectPath, run.worktree_path);
      } catch {
        // Non-fatal — worktree may already be gone
      }
    }

    await this.persistRunUpdate(run, {
      status: "merged",
      completed_at: new Date().toISOString(),
    });
    await this.persistRunEvent(
      run,
      "merge",
      { seedId: run.seed_id, branchName, targetBranch },
    );

    this.sendMail(run.id, "merge-complete", {
      seedId: run.seed_id,
      branchName,
      targetBranch,
    });

    enqueueCloseSeed(this.store, run.seed_id, "refinery");
    await this.closeNativeTaskPostMerge(run.id, run.seed_id);

    this.sendMail(run.id, "bead-closed", {
      seedId: run.seed_id,
      branchName,
      targetBranch,
    });

    await this.rebaseStackedBranches(branchName, targetBranch);
  }

  async ensurePullRequestForRun(opts: {
    runId: string;
    baseBranch?: string;
    draft?: boolean;
    updateRunStatus?: boolean;
    bodyNote?: string;
    existingOk?: boolean;
  }): Promise<CreatedPr> {
    const run = await this.lookupRun(opts.runId);
    if (!run) throw new Error(`Run ${opts.runId} not found`);

    const baseBranch = opts.baseBranch ?? await this.vcsBackend.detectDefaultBranch(this.projectPath);
    const branchName = `foreman/${run.seed_id}`;

    if (!this.isTestRuntime()) {
      await this.vcsBackend.push(this.projectPath, branchName);
    }

    if (opts.existingOk !== false && !this.isTestRuntime()) {
      const existingPr = await this.getExistingPrState(branchName);
      if (existingPr?.headRefName === branchName && existingPr.url) {
        // AC-2: Never reuse PRs for older heads — verify HEAD SHA matches.
        // Only treat PR as stale when we know the GitHub-tracked SHA (headRefOid
        // is non-null) AND the current branch HEAD differs. When headRefOid is
        // null/undefined (GitHub API didn't track it), fall back to
        // branch-name-based reuse (the PR is still valid for this branch).
        const currentBranchHead = await this.vcsBackend
          .resolveRef(this.projectPath, branchName)
          .catch(() => null);
        if (
          existingPr.headRefOid !== null &&
          currentBranchHead !== null &&
          currentBranchHead !== existingPr.headRefOid
        ) {
          // HEAD SHA changed — PR is stale; create fresh PR below.
          // Log this mismatch so it's visible in run events.
          await this.persistRunEvent(run, "pr-stale", {
            seedId: run.seed_id,
            branchName,
            stalePrUrl: existingPr.url,
            staleHead: existingPr.headRefOid,
            currentHead: currentBranchHead,
          });
        } else {
          // HEAD SHA unchanged — safe to reuse the existing PR.
          let reopenedExistingPr = false;
          if (existingPr.state === "CLOSED") {
            try {
              await gh(["pr", "reopen", existingPr.url], this.projectPath);
              reopenedExistingPr = true;
            } catch (err: unknown) {
              if (!shouldCreateFreshPrAfterReopenFailure(err)) {
                throw err;
              }
            }
          }
          if (existingPr.state === "OPEN" || reopenedExistingPr) {
            await this.persistRunEvent(
              run,
              "pr-created",
              {
                seedId: run.seed_id,
                branchName,
                baseBranch,
                prUrl: existingPr.url,
                existing: true,
                reopened: reopenedExistingPr,
                draft: opts.draft ?? false,
              },
            );
            // Update PR metadata on the run record (AC-1, AC-6).
            const prState: Run["pr_state"] = opts.draft ?? false ? "draft" : "open";
            await this.persistRunUpdate(run, {
              status: opts.updateRunStatus ? "pr-created" : run.status,
              pr_url: existingPr.url,
              pr_state: prState,
              pr_head_sha: currentBranchHead ?? null,
            });
            return { runId: run.id, seedId: run.seed_id, branchName, prUrl: existingPr.url };
          }
        }
      }
    }

    const { title: seedTitle, description: seedDescription } = await this.getSeedContext(run.seed_id);
    let commitLog = "";
    try {
      commitLog = await gitSpecial(
        ["log", `${baseBranch}..${branchName}`, "--oneline"],
        this.projectPath,
      );
    } catch {
      // Non-fatal
    }

    const prTitle = `${seedTitle} (${run.seed_id})`;
    const body = [
      "## Summary",
      seedDescription || `Agent work for ${run.seed_id}`,
      opts.bodyNote ? `\n> ${opts.bodyNote}` : "",
      "",
      "## Commits",
      commitLog ? `\`\`\`\n${commitLog}\n\`\`\`` : "(no commits)",
      "",
      `Foreman run: \`${run.id}\``,
    ].join("\n");

    const prUrl = this.isTestRuntime()
      ? `foreman://pr/${run.seed_id}`
      : await gh((() => {
        const ghArgs = [
          "pr", "create",
          "--base", baseBranch,
          "--head", branchName,
          "--title", prTitle,
          "--body", body,
        ];
        if (opts.draft) ghArgs.push("--draft");
        return ghArgs;
      })(), this.projectPath);

    await this.persistRunEvent(
      run,
      "pr-created",
      { seedId: run.seed_id, branchName, baseBranch, prUrl, draft: opts.draft ?? false, existing: false },
    );
    if (opts.updateRunStatus) {
      await this.persistRunUpdate(run, { status: "pr-created" });
    }
    // Update PR metadata on the run record (AC-1, AC-6).
    // Capture the current branch HEAD as pr_head_sha so we can detect SHA changes.
    const currentHead = await this.vcsBackend
      .resolveRef(this.projectPath, branchName)
      .catch(() => null);
    const prState: import("../lib/store.js").Run["pr_state"] = opts.draft ?? false ? "draft" : "open";
    await this.persistRunUpdate(run, {
      pr_url: prUrl,
      pr_state: prState,
      pr_head_sha: currentHead ?? null,
    });

    // Link PR back to GitHub issue (TRD-032)
    await this.#linkPrToGithubIssue(run.id, prUrl);

    return { runId: run.id, seedId: run.seed_id, branchName, prUrl };
  }

  /**
   * Link a created PR back to the originating GitHub issue.
   * Adds a comment to the GitHub issue referencing the PR URL.
   * Non-fatal — PR linking must not block PR creation.
   */
  async #linkPrToGithubIssue(runId: string, prUrl: string): Promise<void> {
    if (!this.registeredProjectId || !this.postgresAdapter) return;
    try {
      // Find the task linked to this run
      const [task] = await this.postgresAdapter.listTasks(this.registeredProjectId, {
        runId,
        limit: 1,
      });
      if (!task) return;
      const gh = new (await import("../lib/gh-cli.js")).GhCli();
      await linkPrToGithubIssue(gh, this.registeredProjectId, task.id, prUrl);
    } catch {
      // Non-fatal — best effort PR linking
    }
  }

  async mergePullRequest(opts: {
    runId: string;
    targetBranch?: string;
  }): Promise<MergeReport> {
    const merged: MergedRun[] = [];
    const conflicts: ConflictRun[] = [];
    const testFailures: FailedRun[] = [];
    const unexpectedErrors: FailedRun[] = [];
    const prsCreated: CreatedPr[] = [];

    const run = await this.lookupRun(opts.runId);
    if (!run) {
      unexpectedErrors.push({
        runId: opts.runId,
        seedId: "(unknown)",
        branchName: "(unknown)",
        error: "Run not found",
      });
      return { merged, conflicts, testFailures, unexpectedErrors, prsCreated };
    }

    const targetBranch = opts.targetBranch ?? await this.vcsBackend.detectDefaultBranch(this.projectPath);
    const branchName = `foreman/${run.seed_id}`;

    try {
      const pr = await this.ensurePullRequestForRun({
        runId: run.id,
        baseBranch: targetBranch,
        updateRunStatus: false,
      });
      prsCreated.push(pr);

      if (this.isTestRuntime()) {
        const report = await this.mergeCompleted({
          targetBranch,
          runTests: false,
          projectId: run.project_id,
          seedId: run.seed_id,
          runId: run.id,
        });
        merged.push(...report.merged);
        conflicts.push(...report.conflicts);
        testFailures.push(...report.testFailures);
        unexpectedErrors.push(...report.unexpectedErrors);
      } else {
        await gh(["pr", "merge", branchName, "--squash"], this.projectPath);

        await this.finalizeSuccessfulMerge(run, branchName, targetBranch);

        merged.push({
          runId: run.id,
          seedId: run.seed_id,
          branchName,
        });
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (!this.isTestRuntime() && shouldTreatLocalBranchDeleteFailureAsNonFatal(err)) {
        const existingPr = await this.getExistingPrState(branchName);
        const currentBranchHead = existingPr?.headRefOid
          ? await this.vcsBackend.resolveRef(this.projectPath, branchName).catch(() => null)
          : null;
        if (existingPr?.state === "MERGED" && currentBranchHead === existingPr.headRefOid) {
          await this.persistRunEvent(run, "merge-cleanup-fallback", { seedId: run.seed_id, branchName, error: message.slice(0, 400) });
          await this.finalizeSuccessfulMerge(run, branchName, targetBranch);
          merged.push({
            runId: run.id,
            seedId: run.seed_id,
            branchName,
          });
          return { merged, conflicts, testFailures, unexpectedErrors, prsCreated };
        }
      }
      await this.persistRunUpdate(run, { status: "failed" });
      await this.persistRunEvent(
        run,
        "fail",
        { seedId: run.seed_id, branchName, error: message },
      );
      this.sendMail(run.id, "merge-failed", {
        seedId: run.seed_id,
        branchName,
        reason: "unexpected-error",
        error: message.slice(0, 400),
      });
      unexpectedErrors.push({
        runId: run.id,
        seedId: run.seed_id,
        branchName,
        error: message,
      });
    }

    return { merged, conflicts, testFailures, unexpectedErrors, prsCreated };
  }

  /**
   * Close the native task (if any) linked to this run after a successful merge.
   *
   * Implements REQ-018: updateStatus(taskId, 'merged') on success, with fallback
   * to syncBeadStatusAfterMerge when taskId is null (beads-only mode).
   *
   * Non-fatal — failures are silently ignored so they don't block the merge flow.
   */
  private async closeNativeTaskPostMerge(runId: string, seedId: string): Promise<void> {
    try {
      if (this.registeredProjectId && this.postgresAdapter) {
        const [task] = await this.postgresAdapter.listTasks(this.registeredProjectId, {
          runId,
          limit: 1,
        });
        if (task) {
          await this.postgresAdapter.updateTask(this.registeredProjectId, task.id, { status: "merged" });
          // Auto-close the linked GitHub issue (TRD-032)
          await closeLinkedGithubIssue(this.postgresAdapter, new (await import("../lib/gh-cli.js")).GhCli(), this.registeredProjectId, task.id);
          return;
        }
      } else {
        const row = this.store.getDb()
          .prepare("SELECT id FROM tasks WHERE run_id = ?")
          .get(runId) as { id: string } | undefined;

        if (row && this.taskStore) {
          this.taskStore.updateStatus(row.id, "merged");
          return;
        }
      }

      // No native task — fall back to beads-only sync.
      // Note: syncBeadStatusAfterMerge does not actually use taskClient (only
      // enqueues bead status updates via store), so we cast to ITaskClient.
      await syncBeadStatusAfterMerge(
        this.store,
        this.seeds as unknown as import("../lib/task-client.js").ITaskClient,
        runId,
        seedId,
        this.projectPath,
        undefined,
        this.runLookup,
      );
    } catch {
      // Non-fatal — native task closure must not block the merge
    }
  }

  /**
   * Attempt to add a note to a bead explaining what went wrong.
   * Non-fatal — a failure to annotate the bead must not mask the original error.
   */
  private async addFailureNote(seedId: string, note: string): Promise<void> {
    // Enqueue instead of calling br directly — multiple agent workers run
    // refinery concurrently, and direct calls cause SQLITE_BUSY on beads DB.
    try {
      enqueueAddNotesToBead(this.store, seedId, note.slice(0, 500), "refinery");
    } catch (err: unknown) {
      // Non-fatal: best-effort annotation
      const message = err instanceof Error ? err.message : String(err);
      console.warn(`[Refinery] Failed to enqueue failure note for bead ${seedId}: ${message}`);
    }
  }

  /**
   * After a successful merge of `mergedBranch` into `targetBranch`, find all
   * stacked branches (seeds whose worktree was branched from `mergedBranch`)
   * and rebase them onto `targetBranch` so they pick up the latest code.
   *
   * Non-fatal: failures are logged as warnings; they do not abort the merge.
   */
  private async rebaseStackedBranches(
    mergedBranch: string,
    targetBranch: string,
  ): Promise<void> {
    try {
      // Query runs that were stacked on the just-merged branch
      const stackedRuns = await this.lookupRunsByBaseBranch(mergedBranch);
      if (stackedRuns.length === 0) return;

      for (const stackedRun of stackedRuns) {
        // Only rebase active (non-terminal) runs
        const activeStatuses: import("../lib/store.js").Run["status"][] = ["pending", "running", "completed"];
        if (!activeStatuses.includes(stackedRun.status)) continue;

        const stackedBranch = `foreman/${stackedRun.seed_id}`;
        const branchExists = await this.vcsBackend.branchExists(this.projectPath, stackedBranch);
        if (!branchExists) continue;

        try {
          const restackResult = await this.vcsBackend.restackBranch(
            this.projectPath,
            stackedBranch,
            mergedBranch,
            targetBranch,
          );
          if (!restackResult.success) {
            throw new Error(
              restackResult.conflictingFiles?.length
                ? `rebase conflicts: ${restackResult.conflictingFiles.join(", ")}`
                : "restack failed",
            );
          }
          console.error(`[Refinery] Rebased stacked branch ${stackedBranch} onto ${targetBranch} (was on ${mergedBranch})`);
          // Clear the stacked base branch after the restack.
          await this.persistRunUpdate(stackedRun, { base_branch: null });
        } catch (rebaseErr: unknown) {
          const msg = rebaseErr instanceof Error ? rebaseErr.message : String(rebaseErr);
          console.warn(`[Refinery] Warning: failed to rebase stacked branch ${stackedBranch} onto ${targetBranch}: ${msg.slice(0, 300)}`);
          // Abort any partial rebase to leave the repo in a clean state
          try { await this.vcsBackend.abortRebase(this.projectPath); } catch { /* already clean */ }
        }
      }
    } catch (err: unknown) {
      // Non-fatal: log and continue — stacked rebase failure must not block the merge
      const msg = err instanceof Error ? err.message : String(err);
      console.warn(`[Refinery] Warning: rebaseStackedBranches failed: ${msg.slice(0, 200)}`);
    }
  }

  /**
   * Push a conflicting branch and create a PR for manual resolution.
   * Returns the CreatedPr info, or null if PR creation fails.
   */
  private async createPrForConflict(
    run: import("../lib/store.js").Run,
    branchName: string,
    baseBranch: string,
    conflictNote: string,
  ): Promise<import("./types.js").CreatedPr | null> {
    try {
      // Push branch to origin (force-push since rebase may have rewritten history)
      await this.vcsBackend.push(this.projectPath, branchName, { force: true });

      // Get seed info for PR title/body
      let seedTitle = run.seed_id;
      let seedDescription = "";
      try {
        const seedInfo = await this.seeds.show(run.seed_id);
        if (seedInfo) {
          seedTitle = seedInfo.title ?? run.seed_id;
          seedDescription = seedInfo.description ?? "";
        }
      } catch { /* use defaults */ }

      const prTitle = `${seedTitle} (${run.seed_id})`;
      const body = [
        "## Summary",
        seedDescription || `Agent work for ${run.seed_id}`,
        "",
        "## Conflicts",
        `This branch has conflicts with \`${baseBranch}\` that need manual resolution:`,
        conflictNote,
        "",
        `Foreman run: \`${run.id}\``,
      ].join("\n");

      const prUrl = await gh(
        ["pr", "create", "--base", baseBranch, "--head", branchName, "--title", prTitle, "--body", body],
        this.projectPath,
      );

       await this.persistRunUpdate(run, { status: "pr-created" });
       await this.persistRunEvent(
         run,
         "pr-created",
         { seedId: run.seed_id, branchName, baseBranch, prUrl, conflictNote },
       );
      return { runId: run.id, seedId: run.seed_id, branchName, prUrl };
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
       await this.persistRunUpdate(run, { status: "conflict" });
       await this.persistRunEvent(
         run,
         "fail",
         { seedId: run.seed_id, branchName, error: `PR creation failed: ${message}` },
       );
      return null;
    }
  }

  /**
   * Get all completed runs that are ready to merge, optionally filtered to a single seed.
   *
   * When a seedId filter is active (i.e. `foreman merge --seed <id>`), we also
   * include runs in terminal failure states ("test-failed", "conflict", "failed")
   * so that a previously-failed merge can be retried without the user having to
   * manually reset the run's status back to "completed".
   *
   * Without a seedId filter we only return "completed" runs to avoid accidentally
   * re-attempting bulk merges of runs that failed for unrelated reasons.
   */
  async getCompletedRuns(projectId?: string, seedId?: string): Promise<import("../lib/store.js").Run[]> {
    if (seedId) {
      // For targeted retries, look in completed AND terminal failure states.
      const retryStatuses: import("../lib/store.js").Run["status"][] = [
        "completed",
        "test-failed",
        "conflict",
        "failed",
      ];
      const runs = await this.lookupRunsByStatuses(retryStatuses, projectId);
      const matching = runs.filter((r) => r.seed_id === seedId);
      // Prefer a completed run over newer stuck/failed runs for the same seed.
      // SQLite returns rows ordered by created_at DESC so stuck/failed may appear
      // first even though a completed run exists from an earlier attempt.
      const completedRun = matching.find((r) => r.status === "completed");
      return completedRun ? [completedRun] : matching.slice(0, 1);
    }
    return this.lookupRunsByStatus("completed", projectId);
  }

  /**
   * Order runs by seed dependency graph so that dependencies merge before dependents.
   * Falls back to insertion order if dependency info is unavailable.
   */
  async orderByDependencies(runs: import("../lib/store.js").Run[]): Promise<import("../lib/store.js").Run[]> {
    if (runs.length <= 1) return runs;

    try {
      if (!this.seeds.getGraph) return runs; // br backend has no getGraph
      const graph = await this.seeds.getGraph();
      // Build a map of seed_id → set of dependency seed_ids
      const depMap = new Map<string, Set<string>>();
      for (const edge of graph.edges) {
        if (!depMap.has(edge.from)) depMap.set(edge.from, new Set());
        depMap.get(edge.from)!.add(edge.to);
      }

      // Topological sort (Kahn's algorithm)
      const runMap = new Map(runs.map((r) => [r.seed_id, r]));
      const seedIds = new Set(runs.map((r) => r.seed_id));

      // Only consider deps within our run set
      const inDegree = new Map<string, number>();
      const adj = new Map<string, string[]>();
      for (const id of seedIds) {
        inDegree.set(id, 0);
        adj.set(id, []);
      }
      for (const id of seedIds) {
        const deps = depMap.get(id);
        if (!deps) continue;
        for (const dep of deps) {
          if (seedIds.has(dep)) {
            adj.get(dep)!.push(id);
            inDegree.set(id, (inDegree.get(id) ?? 0) + 1);
          }
        }
      }

      const queue: string[] = [];
      for (const [id, deg] of inDegree) {
        if (deg === 0) queue.push(id);
      }

      const sorted: import("../lib/store.js").Run[] = [];
      while (queue.length > 0) {
        const id = queue.shift()!;
        const run = runMap.get(id);
        if (run) sorted.push(run);
        for (const next of adj.get(id) ?? []) {
          const newDeg = (inDegree.get(next) ?? 1) - 1;
          inDegree.set(next, newDeg);
          if (newDeg === 0) queue.push(next);
        }
      }

      // Append any runs not in the graph (shouldn't happen, but safe)
      for (const run of runs) {
        if (!sorted.includes(run)) sorted.push(run);
      }

      return sorted;
    } catch {
      // Graph unavailable — fall back to original order
      return runs;
    }
  }

  /**
   * Find all completed (unmerged) runs and attempt to merge them into the target branch.
   * Optionally run tests after each merge. Merges in dependency order.
   *
   * Report files (QA_REPORT.md, REVIEW.md, TASK.md, AGENTS.md, etc.) are removed
   * before each merge to prevent conflicts, then archived to .foreman/reports/ after.
   * Only real code conflicts are reported as failures.
   */
  async mergeCompleted(opts?: {
    targetBranch?: string;
    runTests?: boolean;
    testCommand?: string;
    projectId?: string;
    seedId?: string;
    /**
     * Optional pre-fetched run to bypass the getCompletedRuns() query entirely.
     * When provided (e.g. from autoMerge's queue entry), this run is used directly
     * instead of querying for completed runs. This eliminates the race condition
     * where finalize marks a run completed but the query hasn't yet seen the update.
     */
    overrideRun?: import("../lib/store.js").Run;
    /**
     * Optional run ID to fetch the run directly by ID.
     * When provided, the run is fetched using store.getRun(runId) which doesn't
     * filter by status. This eliminates the race condition where the run status
     * hasn't been updated to 'completed' yet when autoMerge queries.
     */
    runId?: string;
  }): Promise<MergeReport> {
    const defaultTargetBranch = normalizeBranchLabel(
      opts?.targetBranch ?? await this.vcsBackend.detectDefaultBranch(this.projectPath),
    ) ?? "dev";
    const runTests = opts?.runTests ?? true;
    const testCommand = opts?.testCommand ?? "npm test";

    // Determine the runs to process:
    // 1. If runId is provided, fetch the run by ID directly (no status filter) - most reliable
    // 2. Else if overrideRun is provided, use it directly
    // 3. Else fall back to querying for completed runs
    let rawRuns: import("../lib/store.js").Run[];
    if (opts?.runId) {
      // Fetch by ID directly - bypasses status check entirely.
      // This is the most reliable path for immediate autoMerge calls because
      // the status update happens before autoMerge is called, but due to SQLite
      // WAL timing, the query might not see it immediately.
       const fetchedRun = await this.lookupRun(opts.runId);
       rawRuns = fetchedRun ? [fetchedRun] : [];
     } else if (opts?.overrideRun) {
       rawRuns = [opts.overrideRun];
     } else {
       rawRuns = await this.getCompletedRuns(opts?.projectId, opts?.seedId);
     }

    const completedRuns = await this.orderByDependencies(rawRuns);

    const merged: MergedRun[] = [];
    const conflicts: ConflictRun[] = [];
    const testFailures: FailedRun[] = [];
    // Runs that failed due to git/shell command errors (not test runner exit).
    // Kept separate from testFailures so auto-merge reports reason "unexpected-error"
    // rather than "test-failure" and uses the correct retry path (Fix 3).
    const unexpectedErrors: FailedRun[] = [];
    const prsCreated: import("./types.js").CreatedPr[] = [];

    for (const run of completedRuns) {
      const branchName = `foreman/${run.seed_id}`;

      // Resolve per-seed target branch: prefer branch: label on the bead,
      // fall back to the caller-supplied or auto-detected default.
      let targetBranch = defaultTargetBranch;
      try {
        const seedDetail = await this.seeds.show(run.seed_id);
        const branchLabel = normalizeBranchLabel(extractBranchLabel(seedDetail.labels));
        if (branchLabel) {
          targetBranch = branchLabel;
        }
      } catch {
        // Non-fatal — if label lookup fails, use default target
      }

      try {
        // Early guard: if the branch has no unique commits vs target, the agent committed
        // nothing. Creating a PR would fail ("no commits between ..."). Don't reset to open
        // (that would cause infinite redispatch to the same broken worktree). Mark as a
        // conflict so the user can investigate.
        const branchCommits = await gitSpecial(["log", "--oneline", `${targetBranch}..${branchName}`], this.projectPath).catch(() => "");
        if (!branchCommits.trim()) {
          console.warn(`[Refinery] Branch ${branchName} has no commits beyond ${targetBranch} — agent may not have committed work`);
          await this.addFailureNote(run.seed_id, `Branch ${branchName} has no unique commits beyond ${targetBranch}. The agent may not have committed its work. Manual intervention required — do not auto-reset.`);
            await this.persistRunUpdate(run, { status: "conflict" });
          this.sendMail(run.id, "merge-failed", {
            seedId: run.seed_id,
            branchName,
            reason: "no-commits",
            detail: `Branch ${branchName} has no unique commits beyond ${targetBranch}`,
          });
          conflicts.push({ runId: run.id, seedId: run.seed_id, branchName, conflictFiles: [] });
          continue;
        }

        // Scan for conflict markers in COMMITTED branch content (not working tree).
        // Working-tree conflict markers (e.g. leftover from a failed agent rebase) are
        // intentionally ignored — they don't exist in the commits that will be merged.
        {
          const markedFiles = await this.scanForConflictMarkers(branchName, targetBranch);
          if (markedFiles.length > 0) {
            this.sendMail(run.id, "merge-failed", {
              seedId: run.seed_id,
              branchName,
              reason: "conflict-markers",
              conflictFiles: markedFiles,
            });
            const pr = await this.createPrForConflict(
              run,
              branchName,
              targetBranch,
              `Unresolved conflict markers in: ${markedFiles.join(", ")}`,
            );
            if (pr) {
              prsCreated.push(pr);
            } else {
              await this.addFailureNote(run.seed_id, `Merge skipped: unresolved conflict markers in ${markedFiles.join(", ")}. PR creation also failed — manual intervention required.`);
              conflicts.push({ runId: run.id, seedId: run.seed_id, branchName, conflictFiles: markedFiles });
            }
            continue;
          }
        }

        // Commit any dirty state files (.seeds/, .foreman/) before merge
        await this.autoCommitStateFiles();

        // Remove report files so they can't cause merge conflicts
        await this.removeReportFiles();

        // Ensure branch is in local refs — sentinel/remote branches may only exist
        // on origin and not be fetched yet. Silently skip if the fetch fails (the
        // reconcile step already validates the branch exists).
        try {
          await this.vcsBackend.fetch(this.projectPath);
        } catch {
          // Fetch failure is non-fatal: branch may already be local, or the remote
          // may be unreachable. The subsequent rebase/merge will surface any real error.
        }

        // Rebase branch onto current target so it picks up all prior merges.
        // For git backends, refinery rebases the branch from the main repo.
        // For jujutsu backends, rebase the branch inside its own workspace so
        // we don't fall back to raw git rebase semantics in colocated jj repos.
        {
          let rebaseOk = true;
          const rebaseWorkspacePath = this.vcsBackend.name === "jujutsu"
            ? (run.worktree_path ?? this.projectPath)
            : this.projectPath;
          let stashedBeforeRebase = false;

          try {
            if (this.vcsBackend.name === "jujutsu") {
              // Finalize should have committed all task changes already. Clean any
              // leftover uncommitted artifacts in the agent workspace before rebasing.
              try {
                const dirty = await this.vcsBackend.status(rebaseWorkspacePath);
                if (dirty.trim()) {
                  await this.vcsBackend.cleanWorkingTree(rebaseWorkspacePath);
                }
              } catch {
                // best effort — rebase will surface a real error if workspace is still dirty
              }

              const rebaseResult = await this.vcsBackend.rebase(rebaseWorkspacePath, targetBranch);
              rebaseOk = rebaseResult.success;
            } else {
              // Ensure working directory is clean before rebase — a previous partial rebase
              // may have left patches applied but not committed. Save any uncommitted changes
              // so git rebase doesn't refuse to run.
              try {
                const dirty = await this.vcsBackend.status(this.projectPath);
                if (dirty.trim()) {
                  stashedBeforeRebase = await this.vcsBackend.saveWorktreeState(this.projectPath);
                }
              } catch {
                // save failure is non-fatal — rebase will fail with a clear message if still dirty
              }

              try {
                const rebaseResult = await this.vcsBackend.rebaseBranch(this.projectPath, branchName, targetBranch);
                if (!rebaseResult.success) {
                  throw new Error(
                    rebaseResult.conflictingFiles?.length
                      ? `rebase conflicts: ${rebaseResult.conflictingFiles.join(", ")}`
                      : "rebase failed",
                  );
                }
              } catch (err: unknown) {
                const errMsg = err instanceof Error ? err.message : String(err);
                if (errMsg.includes("already used by worktree") || errMsg.includes("is already checked out")) {
                  // Branch is checked out in an active worktree — git refuses to rebase it from
                  // the main repo. Skip rebase and fall back to direct merge.
                  console.warn(`[Refinery] Skipping rebase for ${branchName} (active worktree) — falling back to direct merge`);
                  rebaseOk = true;
                } else {
                  // Rebase hit conflicts — try to auto-resolve report files and continue
                  rebaseOk = await this.autoResolveRebaseConflicts(targetBranch);
                }
              }
            }
          } finally {
            // Return to target branch regardless
            try { await this.vcsBackend.checkoutBranch(this.projectPath, targetBranch); } catch { /* best effort */ }

            if (stashedBeforeRebase) {
              try { await this.vcsBackend.restoreWorktreeState(this.projectPath); } catch { /* best effort — may be empty */ }
            }
          }

          if (!rebaseOk) {
            await this.addFailureNote(
              run.seed_id,
              `Merge failed: conflict on ${new Date().toISOString().slice(0, 10)} — manual retry required. Rebase conflicts detected.`,
            );
            this.sendMail(run.id, "merge-failed", {
              seedId: run.seed_id,
              branchName,
              reason: "rebase-conflict",
            });
            const pr = await this.createPrForConflict(run, branchName, targetBranch, "Rebase conflicts");
            if (pr) {
              prsCreated.push(pr);
            } else {
              conflicts.push({ runId: run.id, seedId: run.seed_id, branchName, conflictFiles: [] });
            }
            continue;
          }
        }

        // Save pre-merge HEAD so we can revert merge + archive if tests fail
        const preMergeHead = await this.vcsBackend.getHeadId(this.projectPath);

        // Use squash merge so each feature branch becomes a single commit on
        // the target branch, regardless of how many commits the branch contains.
        // This prevents empty or noisy intermediate commits from polluting dev.
        const squashMergeOk = true;
        try {
          await this.vcsBackend.checkoutBranch(this.projectPath, targetBranch);
          const mergeResult = await this.vcsBackend.mergeWithoutCommit(this.projectPath, branchName, targetBranch);
          if (!mergeResult.success) {
            const conflictSummary = mergeResult.conflicts?.join(", ") || "merge conflict";
            throw new Error(`Merge conflict: ${conflictSummary}`);
          }
        } catch (mergeErr: unknown) {
          const mergeMsg = mergeErr instanceof Error ? mergeErr.message : String(mergeErr);

          // Check for conflicts
          let conflictingFiles: string[] = [];
          try {
            conflictingFiles = await this.vcsBackend.getConflictingFiles(this.projectPath);
          } catch {
            // best effort
          }

          if (mergeMsg.includes("CONFLICT") || mergeMsg.includes("Merge conflict") || conflictingFiles.length > 0) {
            const allConflicts = conflictingFiles;
            const reportConflicts = allConflicts.filter((f) => this.isReportFile(f));
            const codeConflicts = allConflicts.filter((f) => !this.isReportFile(f));

            if (codeConflicts.length > 0) {
              // Real code conflicts — abort merge and create PR instead
              try {
                await this.vcsBackend.abortMerge(this.projectPath);
              } catch {
                // abortMerge may fail if already clean; reset as fallback
                try { await this.vcsBackend.resetHard(this.projectPath, "HEAD"); } catch { /* best effort */ }
              }

              await this.addFailureNote(
                run.seed_id,
                `Merge failed: conflict on ${new Date().toISOString().slice(0, 10)} — manual retry required. Conflicting files: ${codeConflicts.join(", ")}`,
              );
              this.sendMail(run.id, "merge-failed", {
                seedId: run.seed_id,
                branchName,
                reason: "merge-conflict",
                conflictFiles: codeConflicts,
              });

              const pr = await this.createPrForConflict(run, branchName, targetBranch,
                `Conflicts in: ${codeConflicts.join(", ")}`);
              if (pr) {
                prsCreated.push(pr);
              } else {
                conflicts.push({ runId: run.id, seedId: run.seed_id, branchName, conflictFiles: codeConflicts });
              }
              continue;
            }

            // Only report-file conflicts — auto-resolve by accepting the branch version
            for (const f of reportConflicts) {
              await this.vcsBackend.checkoutFile(this.projectPath, "--theirs", f);
              await this.vcsBackend.stageFile(this.projectPath, f);
            }
          } else {
            // Non-conflict error — rethrow
            throw mergeErr;
          }
        }

        // Commit the squash merge (git merge --squash stages but does not commit)
        if (squashMergeOk) {
          // Build a concise squash commit message with seed info
          let squashMsg = `${branchName}: squash merge`;
          try {
            const seedDetail = await this.seeds.show(run.seed_id);
            if (seedDetail?.title) {
              squashMsg = `${seedDetail.title} (${run.seed_id})`;
            }
          } catch {
            // Non-fatal — use default message
          }
          try {
            await this.vcsBackend.commit(this.projectPath, squashMsg);
          } catch (commitErr: unknown) {
            // commit may fail if there's nothing to commit (empty squash)
            const commitMsg = commitErr instanceof Error ? commitErr.message : String(commitErr);
            if (!commitMsg.includes("nothing to commit")) {
              throw commitErr;
            }
          }
        }

        // Merge succeeded — archive report files so they don't conflict with next merge
        await this.archiveReportsPostMerge(run.seed_id);

        // Optionally run tests
        if (runTests) {
          const testResult = await runTestCommand(testCommand, this.projectPath);

          if (!testResult.ok) {
            // Revert the merge + archive commits
            await this.vcsBackend.resetHard(this.projectPath, preMergeHead);

            // Add failure note before resetting so the bead records why it was reset
            await this.addFailureNote(
              run.seed_id,
              `Merge failed: post-merge tests failed on ${new Date().toISOString().slice(0, 10)} — manual retry required. ${testResult.output.slice(0, 300)}`,
            );

            await this.persistRunUpdate(run, { status: "test-failed" });
            await this.persistRunEvent(
              run,
              "test-fail",
              { seedId: run.seed_id, branchName, output: testResult.output.slice(0, 2000) },
            );
            this.sendMail(run.id, "merge-failed", {
              seedId: run.seed_id,
              branchName,
              reason: "test-failure",
              output: testResult.output.slice(0, 500),
            });
            testFailures.push({
              runId: run.id,
              seedId: run.seed_id,
              branchName,
              error: testResult.output.slice(0, 500),
            });
            continue;
          }
        }

        // All good — clean up worktree and mark as merged
        if (run.worktree_path) {
          try {
            await archiveWorktreeReports(this.projectPath, run.worktree_path, run.seed_id);
          } catch {
            // Archive is best-effort — don't block worktree removal
          }
          try {
            await this.vcsBackend.removeWorkspace(this.projectPath, run.worktree_path);
          } catch {
            // Non-fatal — worktree may already be gone
          }
        }

        await this.persistRunUpdate(run, {
          status: "merged",
          completed_at: new Date().toISOString(),
        });
        await this.persistRunEvent(
          run,
          "merge",
          { seedId: run.seed_id, branchName, targetBranch },
        );

        // Send merge-complete mail so inbox shows a successful merge event
        this.sendMail(run.id, "merge-complete", {
          seedId: run.seed_id,
          branchName,
          targetBranch,
        });

        // Close the bead NOW — after the code has actually landed in main.
        // projectPath (repo root) is where .beads/ lives; not the worktree dir.
        enqueueCloseSeed(this.store, run.seed_id, "refinery");

        // Close native task post-merge (REQ-018) — updateStatus('merged') or fallback
        await this.closeNativeTaskPostMerge(run.id, run.seed_id);

        // Send bead-closed mail so inbox shows bead lifecycle completion
        this.sendMail(run.id, "bead-closed", {
          seedId: run.seed_id,
          branchName,
          targetBranch,
        });

        // Rebase any stacked branches (seeds that branched from this one) onto target.
        await this.rebaseStackedBranches(branchName, targetBranch);

        merged.push({
          runId: run.id,
          seedId: run.seed_id,
          branchName,
        });
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        // Update run status to "failed" so subsequent bead status sync has a
        // terminal status to map from (fixes the exception gap).
        await this.persistRunUpdate(run, { status: "failed" });
        await this.persistRunEvent(
          run,
          "fail",
          { seedId: run.seed_id, branchName, error: message },
        );
        this.sendMail(run.id, "merge-failed", {
          seedId: run.seed_id,
          branchName,
          reason: "unexpected-error",
          error: message.slice(0, 400),
        });
        await this.addFailureNote(run.seed_id, `Merge failed: ${message.slice(0, 400)}`);
        // Push to unexpectedErrors (not testFailures) so auto-merge reports
        // reason "unexpected-error" instead of "test-failure" (Fix 3).
        unexpectedErrors.push({
          runId: run.id,
          seedId: run.seed_id,
          branchName,
          error: message,
        });
      }
    }

    return { merged, conflicts, testFailures, unexpectedErrors, prsCreated };
  }

  /**
   * Resolve a conflicting run.
   * - 'theirs': re-attempt merge with -X theirs strategy
   * - 'abort': abandon the merge, mark run as failed
   */
  async resolveConflict(
    runId: string,
    strategy: "theirs" | "abort",
    opts?: {
      targetBranch?: string;
      runTests?: boolean;
      testCommand?: string;
    },
  ): Promise<boolean> {
    const run = await this.lookupRun(runId);
    if (!run) throw new Error(`Run ${runId} not found`);

    const branchName = `foreman/${run.seed_id}`;

    if (strategy === "abort") {
      await this.persistRunUpdate(run, {
        status: "failed",
        completed_at: new Date().toISOString(),
      });
      await this.persistRunEvent(run, "fail", { seedId: run.seed_id, reason: "Conflict resolution aborted by user" });
      await this.addFailureNote(run.seed_id, "Merge conflict resolution aborted by user.");
      return false;
    }

    // strategy === 'theirs' — attempt merge with -X theirs
    const targetBranch = opts?.targetBranch ?? await this.vcsBackend.detectDefaultBranch(this.projectPath);
    const runTests = opts?.runTests ?? true;
    const testCommand = opts?.testCommand ?? "npm test";
    const preMergeHead = await this.vcsBackend.getHeadId(this.projectPath);

    try {
      const mergeResult = await this.vcsBackend.mergeWithStrategy(
        this.projectPath,
        branchName,
        targetBranch,
        "theirs",
      );
      if (!mergeResult.success) {
        throw new Error(
          mergeResult.conflicts?.length
            ? `merge conflicts: ${mergeResult.conflicts.join(", ")}`
            : "merge failed",
        );
      }
    } catch (err: unknown) {
      // Merge failed — abort to leave repo in a clean state
      try {
        await this.vcsBackend.abortMerge(this.projectPath);
      } catch {
        // merge --abort may fail if there is nothing to abort
      }
      const message = err instanceof Error ? err.message : String(err);
        await this.persistRunUpdate(run, {
          status: "failed",
          completed_at: new Date().toISOString(),
        });
        await this.persistRunEvent(
          run,
          "fail",
          { seedId: run.seed_id, error: message },
        );
      await this.addFailureNote(run.seed_id, `Merge failed (theirs strategy): ${message.slice(0, 400)}. Manual retry required.`);
      return false;
    }

    // Merge succeeded — optionally run tests (Tier 2 safety gate)
    if (runTests) {
      const testResult = await runTestCommand(testCommand, this.projectPath);

      if (!testResult.ok) {
        // Revert the merge
        await this.vcsBackend.rollbackFailedMerge(this.projectPath, preMergeHead);

        await this.persistRunUpdate(run, {
          status: "test-failed",
          completed_at: new Date().toISOString(),
        });
        await this.persistRunEvent(run, "test-fail", { seedId: run.seed_id, branchName, output: testResult.output.slice(0, 2000) });
        await this.addFailureNote(run.seed_id, `Merge failed: tests failed after conflict resolution. Manual retry required. ${testResult.output.slice(0, 300)}`);
        return false;
      }
    }

    if (run.worktree_path) {
      try {
        await archiveWorktreeReports(this.projectPath, run.worktree_path, run.seed_id);
      } catch {
        // Archive is best-effort — don't block worktree removal
      }
      try {
        await this.vcsBackend.removeWorkspace(this.projectPath, run.worktree_path);
      } catch {
        // Non-fatal
      }
    }

    await this.persistRunUpdate(run, {
      status: "merged",
      completed_at: new Date().toISOString(),
    });
    await this.persistRunEvent(
      run,
      "merge",
      { seedId: run.seed_id, branchName, strategy: "theirs", targetBranch },
    );

    // Close the bead after successful conflict-resolution merge.
    enqueueCloseSeed(this.store, run.seed_id, "refinery");

    // Close native task post-merge (REQ-018) — updateStatus('merged') or fallback
    await this.closeNativeTaskPostMerge(run.id, run.seed_id);

    return true;
  }

  /**
   * Find all completed runs and create PRs for their branches.
   * Pushes branches to origin and uses `gh pr create`.
   *
   * MQ-T058d Investigation: Why `gh pr create` instead of `git town propose`
   * -------------------------------------------------------------------------
   * git town propose (v22.6.0) was investigated for PR creation. Findings:
   *   1. It DOES support --title and --body flags.
   *   2. However, it opens a browser window (`open https://github.com/...`)
   *      rather than creating the PR via the GitHub API.
   *   3. No PR URL is returned in stdout -- only a GitHub compare URL is
   *      opened in the system browser.
   *   4. It also runs `git fetch`, `git stash`, and `git push` as side-effects,
   *      which conflicts with our explicit push step above.
   *
   * Since Foreman agents run non-interactively (see CLAUDE.md critical
   * constraints: "agents hang on interactive prompts"), and we need the PR URL
   * returned for event logging, `gh pr create` remains the correct choice for
   * both normal-flow and conflict PRs.
   *
   * Conflict PRs (ConflictResolver.handleFallback) also use `gh pr create`
   * because they require structured titles with "[Conflict]" prefix and
   * detailed resolution metadata in the body.
   */
  async createPRs(opts?: {
    baseBranch?: string;
    draft?: boolean;
    projectId?: string;
  }): Promise<PrReport> {
    const baseBranch = opts?.baseBranch ?? await this.vcsBackend.detectDefaultBranch(this.projectPath);
    const draft = opts?.draft ?? false;

    const completedRuns = await this.getCompletedRuns(opts?.projectId);

    const created: CreatedPr[] = [];
    const failed: FailedRun[] = [];

    for (const run of completedRuns) {
      const branchName = `foreman/${run.seed_id}`;

      try {
        // Push branch to origin
        await this.vcsBackend.push(this.projectPath, branchName);

        // Build PR title and body
        const title = `${run.seed_id}: ${branchName.replace("foreman/", "")}`;

        // Try to get seed info for a better title/body
        let seedTitle = run.seed_id;
        let seedDescription = "";
        try {
          const seedInfo = await this.seeds.show(run.seed_id);
          if (seedInfo) {
            seedTitle = seedInfo.title ?? run.seed_id;
            seedDescription = seedInfo.description ?? "";
          }
        } catch {
          // Non-fatal — use defaults
        }

        // Get commit log for the PR body
        let commitLog = "";
        try {
          commitLog = await gitSpecial(
            ["log", `${baseBranch}..${branchName}`, "--oneline"],
            this.projectPath,
          );
        } catch {
          // Non-fatal
        }

        const prTitle = `${seedTitle} (${run.seed_id})`;
        const body = [
          "## Summary",
          seedDescription || `Agent work for ${run.seed_id}`,
          "",
          "## Commits",
          commitLog ? `\`\`\`\n${commitLog}\n\`\`\`` : "(no commits)",
          "",
          `Foreman run: \`${run.id}\``,
        ].join("\n");

        // Create PR via gh CLI
        const ghArgs = [
          "pr", "create",
          "--base", baseBranch,
          "--head", branchName,
          "--title", prTitle,
          "--body", body,
        ];
        if (draft) ghArgs.push("--draft");

        const prUrl = await gh(ghArgs, this.projectPath);

        await this.persistRunUpdate(run, { status: "pr-created" });
        await this.persistRunEvent(
          run,
          "pr-created",
          { seedId: run.seed_id, branchName, baseBranch, prUrl, draft },
        );
        created.push({
          runId: run.id,
          seedId: run.seed_id,
          branchName,
          prUrl,
        });

        // Suppress unused variable warning for `title`
        void title;
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        await this.persistRunEvent(
          run,
          "fail",
          { seedId: run.seed_id, branchName, error: message },
        );
        failed.push({
          runId: run.id,
          seedId: run.seed_id,
          branchName,
          error: message,
        });
      }
    }

    return { created, failed };
  }
}

// ── Dry-run merge ─────────────────────────────────────────────────────────────

export interface DryRunEntry {
  seedId: string;
  branchName: string;
  diffStat: string;
  hasConflicts: boolean;
  estimatedTier?: number;
  error?: string;
}

/**
 * Preview what merging branches into the target would look like.
 * Reads `git diff --stat` and detects conflicts via `git merge-tree`.
 * No git state is modified.
 *
 * @param projectPath   Repository root
 * @param targetBranch  Branch to merge into (e.g. "main")
 * @param branches      List of branches to check
 * @param filterSeedId  If set, only process this seed
 * @param conflictPatterns  Optional map of file -> resolution tier for estimated tier column
 */
export async function dryRunMerge(
  projectPath: string,
  targetBranch: string,
  branches: Array<{ branchName: string; seedId: string }>,
  filterSeedId?: string,
  conflictPatterns?: Map<string, number>,
): Promise<DryRunEntry[]> {
  const results: DryRunEntry[] = [];

  const filtered = filterSeedId
    ? branches.filter((b) => b.seedId === filterSeedId)
    : branches;

  for (const { branchName, seedId } of filtered) {
    try {
      // Get merge base
      const mergeBase = await gitReadOnly(
        ["merge-base", targetBranch, branchName],
        projectPath,
      );

      // Get diff stat (read-only)
      const diffStat = await gitReadOnly(
        ["diff", "--stat", `${targetBranch}...${branchName}`],
        projectPath,
      );

      // Detect conflicts via merge-tree (read-only, no state change)
      const mergeTreeOutput = await gitReadOnly(
        ["merge-tree", mergeBase, targetBranch, branchName],
        projectPath,
      );

      const hasConflicts = mergeTreeOutput.includes("changed in both");

      // Estimate resolution tier from conflict patterns
      let estimatedTier: number | undefined;
      if (hasConflicts && conflictPatterns && conflictPatterns.size > 0) {
        // Find the highest (worst) tier among conflicting files
        const conflictFileMatches = Array.from(conflictPatterns.entries())
          .filter(([file]) => mergeTreeOutput.includes(file));
        if (conflictFileMatches.length > 0) {
          estimatedTier = Math.max(...conflictFileMatches.map(([, tier]) => tier));
        }
      }

      results.push({ seedId, branchName, diffStat, hasConflicts, estimatedTier });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      results.push({
        seedId,
        branchName,
        diffStat: "",
        hasConflicts: false,
        error: message,
      });
    }
  }

  return results;
}

/** Read-only git command — guaranteed not to modify state. */
async function gitReadOnly(args: string[], cwd: string): Promise<string> {
  const { stdout } = await execFileAsync("git", args, {
    cwd,
    maxBuffer: PIPELINE_BUFFERS.maxBufferBytes,
  });
  return stdout.trim();
}

// ── Beads preservation ────────────────────────────────────────────────────────

export interface BeadPreservationResult {
  preserved: boolean;
  error?: string;
}

/**
 * Preserve `.seeds/` changes from a branch before it is deleted.
 * Extracts `.seeds/` changes via `git diff`, writes a temp patch file,
 * applies it to the current index, and commits with a descriptive message.
 *
 * Error code MQ-019 on patch failure.
 *
 * @param projectPath   Repository root
 * @param branchName    Source branch containing seed changes
 * @param targetBranch  Target branch to apply changes to
 */
export async function preserveBeadChanges(
  projectPath: string,
  branchName: string,
  targetBranch: string,
  vcsBackend?: Pick<VcsBackend, "applyPatchToIndex" | "commit">,
): Promise<BeadPreservationResult> {
  const tmpPatchPath = join(projectPath, `.foreman-seed-patch-${Date.now()}.patch`);

  try {
    // Extract .seeds/ changes
    const patchContent = await gitReadOnly(
      ["diff", `${targetBranch}...${branchName}`, "--", ".seeds/"],
      projectPath,
    );

    if (!patchContent.trim()) {
      return { preserved: false };
    }

    // Write temp patch
    writeFileSync(tmpPatchPath, patchContent);

    const backend = vcsBackend ?? VcsBackendFactory.createSync({ backend: "git" }, projectPath);

    // Apply the patch to the index via VcsBackend.
    try {
      await backend.applyPatchToIndex(projectPath, tmpPatchPath);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      return { preserved: false, error: `MQ-019: ${message}` };
    }

    // Commit the seed changes with a descriptive message.
    const seedId = branchName.replace(/^foreman\//, "");
    await backend.commit(projectPath, `chore: preserve seed changes from ${seedId}`);

    return { preserved: true };
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    return { preserved: false, error: message };
  } finally {
    // Always clean up temp file
    try {
      unlinkSync(tmpPatchPath);
    } catch {
      // File may not have been created — ignore
    }
  }
}
