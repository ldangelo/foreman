import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync, mkdirSync, renameSync, unlinkSync } from "node:fs";
import { join } from "node:path";

import type { ForemanStore } from "../lib/store.js";
import type { SeedsClient } from "../lib/seeds.js";
import { mergeWorktree, removeWorktree } from "../lib/git.js";
import type { MergeReport, MergedRun, ConflictRun, FailedRun, PrReport, CreatedPr } from "./types.js";

const execFileAsync = promisify(execFile);

// Report files that agents produce in the worktree root
const REPORT_FILES = [
  "EXPLORER_REPORT.md",
  "DEVELOPER_REPORT.md",
  "QA_REPORT.md",
  "REVIEW.md",
  "FINALIZE_REPORT.md",
  "TASK.md",
  "AGENTS.md",
];

// ── Helpers ──────────────────────────────────────────────────────────────

async function git(args: string[], cwd: string): Promise<string> {
  const { stdout } = await execFileAsync("git", args, {
    cwd,
    maxBuffer: 10 * 1024 * 1024,
    env: { ...process.env, GIT_EDITOR: "true" },
  });
  return stdout.trim();
}

async function gh(args: string[], cwd: string): Promise<string> {
  const { stdout } = await execFileAsync("gh", args, {
    cwd,
    maxBuffer: 10 * 1024 * 1024,
  });
  return stdout.trim();
}

async function runTestCommand(command: string, cwd: string): Promise<{ ok: boolean; output: string }> {
  const [cmd, ...args] = command.split(/\s+/);
  try {
    const { stdout, stderr } = await execFileAsync(cmd, args, {
      cwd,
      maxBuffer: 10 * 1024 * 1024,
      timeout: 5 * 60 * 1000, // 5 minute timeout for tests
    });
    return { ok: true, output: (stdout + "\n" + stderr).trim() };
  } catch (err: any) {
    return { ok: false, output: (err.stdout ?? "") + "\n" + (err.stderr ?? err.message) };
  }
}

// ── Refinery ─────────────────────────────────────────────────────────────

export class Refinery {
  constructor(
    private store: ForemanStore,
    private seeds: SeedsClient,
    private projectPath: string,
  ) {}

  /**
   * Check if a file path is a report/non-code file that can be auto-resolved.
   */
  private isReportFile(f: string): boolean {
    if (REPORT_FILES.includes(f)) return true;
    if (f.startsWith(".foreman/reports/")) return true;
    if (f.endsWith(".md") && REPORT_FILES.some((r) => f.startsWith(r.replace(".md", ".")))) return true;
    if (f === ".claude/settings.local.json") return true;
    return false;
  }

  /**
   * During a rebase conflict, check if all conflicts are report files.
   * If so, auto-resolve them and continue rebase (looping until done).
   * If real code conflicts exist, abort rebase and return false.
   * Returns true if rebase completed successfully.
   */
  private async autoResolveRebaseConflicts(targetBranch: string): Promise<boolean> {
    const MAX_ITERATIONS = 50; // safety limit
    for (let i = 0; i < MAX_ITERATIONS; i++) {
      // Get conflicted files
      let conflictFiles: string[];
      try {
        const out = await git(["diff", "--name-only", "--diff-filter=U"], this.projectPath);
        conflictFiles = out.split("\n").map((f) => f.trim()).filter(Boolean);
      } catch {
        conflictFiles = [];
      }

      if (conflictFiles.length === 0) {
        // No conflicts — rebase may have completed or we resolved the last step
        return true;
      }

      const codeConflicts = conflictFiles.filter((f) => !this.isReportFile(f));
      if (codeConflicts.length > 0) {
        // Real code conflicts — abort
        try { await git(["rebase", "--abort"], this.projectPath); } catch { /* already clean */ }
        return false;
      }

      // All conflicts are report files — auto-resolve by accepting ours (the branch version in rebase)
      for (const f of conflictFiles) {
        // In rebase context, --ours is the branch being rebased onto (target),
        // --theirs is the branch's own commits. We want the branch's version.
        await git(["checkout", "--theirs", f], this.projectPath).catch(() => {
          // File may have been deleted on one side — just remove it
          try { unlinkSync(join(this.projectPath, f)); } catch { /* gone */ }
        });
        await git(["add", "-f", f], this.projectPath).catch(() => {});
      }

      // Continue the rebase
      try {
        await git(["rebase", "--continue"], this.projectPath);
        return true; // rebase completed
      } catch {
        // More conflicts on the next commit — loop again
      }
    }

    // Hit iteration limit — abort to be safe
    try { await git(["rebase", "--abort"], this.projectPath); } catch { /* already clean */ }
    return false;
  }

  /**
   * Remove report files from the working tree before merging so they can't
   * conflict. Commits the removal if any tracked files were removed.
   */
  private async removeReportFiles(): Promise<void> {
    let removed = false;
    for (const report of REPORT_FILES) {
      const filePath = join(this.projectPath, report);
      if (existsSync(filePath)) {
        await git(["rm", "-f", report], this.projectPath).catch(() => {
          try { unlinkSync(filePath); } catch { /* already gone */ }
        });
        removed = true;
      }
    }
    if (removed) {
      // Only commit if there are staged changes (git rm of tracked files)
      try {
        await git(["commit", "-m", "Remove report files before merge"], this.projectPath);
      } catch {
        // Nothing staged (files were untracked) — that's fine
      }
    }
  }

  /**
   * Archive report files after a successful merge.
   * Moves report files from the working tree into .foreman/reports/<name>-<seedId>.md
   * and creates a follow-up commit. Called after mergeWorktree() succeeds so we
   * don't need to checkout branches or deal with dirty working trees.
   */
  private async archiveReportsPostMerge(seedId: string): Promise<void> {
    const reportsDir = join(this.projectPath, ".foreman", "reports");
    mkdirSync(reportsDir, { recursive: true });

    let moved = false;
    for (const report of REPORT_FILES) {
      const src = join(this.projectPath, report);
      if (existsSync(src)) {
        const baseName = report.replace(".md", "");
        const dest = join(reportsDir, `${baseName}-${seedId}.md`);
        renameSync(src, dest);
        await git(["add", "-f", dest], this.projectPath);
        await git(["rm", "--cached", report], this.projectPath).catch(() => {});
        moved = true;
      }
    }

    if (moved) {
      await git(["commit", "-m", `Archive reports for ${seedId}`], this.projectPath);
    }
  }

  /**
   * Get all completed runs that are ready to merge, optionally filtered to a single seed.
   */
  getCompletedRuns(projectId?: string, seedId?: string): import("../lib/store.js").Run[] {
    const completedRuns = this.store.getRunsByStatus("completed", projectId);
    if (seedId) {
      return completedRuns.filter((r) => r.seed_id === seedId);
    }
    return completedRuns;
  }

  /**
   * Order runs by seed dependency graph so that dependencies merge before dependents.
   * Falls back to insertion order if dependency info is unavailable.
   */
  async orderByDependencies(runs: import("../lib/store.js").Run[]): Promise<import("../lib/store.js").Run[]> {
    if (runs.length <= 1) return runs;

    try {
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
  }): Promise<MergeReport> {
    const targetBranch = opts?.targetBranch ?? "main";
    const runTests = opts?.runTests ?? true;
    const testCommand = opts?.testCommand ?? "npm test";

    const rawRuns = this.getCompletedRuns(opts?.projectId, opts?.seedId);
    const completedRuns = await this.orderByDependencies(rawRuns);

    const merged: MergedRun[] = [];
    const conflicts: ConflictRun[] = [];
    const testFailures: FailedRun[] = [];

    for (const run of completedRuns) {
      const branchName = `foreman/${run.seed_id}`;

      try {
        // Remove report files so they can't cause merge conflicts
        await this.removeReportFiles();

        // Rebase branch onto current target so it picks up all prior merges.
        // Auto-resolves report-file conflicts during rebase; aborts on real code conflicts.
        {
          let rebaseOk = true;
          try {
            await git(["rebase", targetBranch, branchName], this.projectPath);
          } catch {
            // Rebase hit conflicts — try to auto-resolve report files and continue
            rebaseOk = await this.autoResolveRebaseConflicts(targetBranch);
          }

          // Return to target branch regardless
          try { await git(["checkout", targetBranch], this.projectPath); } catch { /* best effort */ }

          if (!rebaseOk) {
            this.store.updateRun(run.id, { status: "conflict" });
            this.store.logEvent(
              run.project_id,
              "conflict",
              { seedId: run.seed_id, branchName, error: "Rebase failed with code conflicts" },
              run.id,
            );
            conflicts.push({
              runId: run.id,
              seedId: run.seed_id,
              branchName,
              conflictFiles: [],
            });
            continue;
          }
        }

        // Save pre-merge HEAD so we can revert merge + archive if tests fail
        const preMergeHead = await git(["rev-parse", "HEAD"], this.projectPath);

        const result = await mergeWorktree(this.projectPath, branchName, targetBranch);

        if (!result.success) {
          const allConflicts = result.conflicts ?? [];
          const reportConflicts = allConflicts.filter((f) => this.isReportFile(f));
          const codeConflicts = allConflicts.filter((f) => !this.isReportFile(f));

          if (codeConflicts.length > 0) {
            // Real code conflicts — abort and report
            try {
              await git(["merge", "--abort"], this.projectPath);
            } catch {
              // merge --abort may fail if already clean
            }

            this.store.updateRun(run.id, { status: "conflict" });
            this.store.logEvent(
              run.project_id,
              "conflict",
              { seedId: run.seed_id, branchName, conflictFiles: codeConflicts },
              run.id,
            );
            conflicts.push({
              runId: run.id,
              seedId: run.seed_id,
              branchName,
              conflictFiles: codeConflicts,
            });
            continue;
          }

          // Only report-file conflicts — auto-resolve by accepting the branch version
          for (const f of reportConflicts) {
            await git(["checkout", "--theirs", f], this.projectPath);
            await git(["add", "-f", f], this.projectPath);
          }
          await git(["commit", "--no-edit"], this.projectPath);
        }

        // Merge succeeded — archive report files so they don't conflict with next merge
        await this.archiveReportsPostMerge(run.seed_id);

        // Optionally run tests
        if (runTests) {
          const testResult = await runTestCommand(testCommand, this.projectPath);

          if (!testResult.ok) {
            // Revert the merge + archive commits
            await git(["reset", "--hard", preMergeHead], this.projectPath);

            this.store.updateRun(run.id, { status: "test-failed" });
            this.store.logEvent(
              run.project_id,
              "test-fail",
              { seedId: run.seed_id, branchName, output: testResult.output.slice(0, 2000) },
              run.id,
            );
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
            await removeWorktree(this.projectPath, run.worktree_path);
          } catch {
            // Non-fatal — worktree may already be gone
          }
        }

        this.store.updateRun(run.id, {
          status: "merged",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(
          run.project_id,
          "merge",
          { seedId: run.seed_id, branchName, targetBranch },
          run.id,
        );
        merged.push({
          runId: run.id,
          seedId: run.seed_id,
          branchName,
        });
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        this.store.logEvent(
          run.project_id,
          "fail",
          { seedId: run.seed_id, branchName, error: message },
          run.id,
        );
        testFailures.push({
          runId: run.id,
          seedId: run.seed_id,
          branchName,
          error: message,
        });
      }
    }

    return { merged, conflicts, testFailures };
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
    const run = this.store.getRun(runId);
    if (!run) throw new Error(`Run ${runId} not found`);

    const branchName = `foreman/${run.seed_id}`;

    if (strategy === "abort") {
      this.store.updateRun(run.id, {
        status: "failed",
        completed_at: new Date().toISOString(),
      });
      this.store.logEvent(
        run.project_id,
        "fail",
        { seedId: run.seed_id, reason: "Conflict resolution aborted by user" },
        run.id,
      );
      return false;
    }

    // strategy === 'theirs' — attempt merge with -X theirs
    const targetBranch = opts?.targetBranch ?? "main";
    const runTests = opts?.runTests ?? true;
    const testCommand = opts?.testCommand ?? "npm test";

    try {
      await git(["checkout", targetBranch], this.projectPath);
      await git(["merge", branchName, "--no-ff", "-X", "theirs"], this.projectPath);
    } catch (err: unknown) {
      // Merge failed — abort to leave repo in a clean state
      try {
        await git(["merge", "--abort"], this.projectPath);
      } catch {
        // merge --abort may fail if there is nothing to abort
      }
      const message = err instanceof Error ? err.message : String(err);
      this.store.updateRun(run.id, {
        status: "failed",
        completed_at: new Date().toISOString(),
      });
      this.store.logEvent(
        run.project_id,
        "fail",
        { seedId: run.seed_id, error: message },
        run.id,
      );
      return false;
    }

    // Merge succeeded — optionally run tests (Tier 2 safety gate)
    if (runTests) {
      const testResult = await runTestCommand(testCommand, this.projectPath);

      if (!testResult.ok) {
        // Revert the merge
        await git(["reset", "--hard", "HEAD~1"], this.projectPath);

        this.store.updateRun(run.id, {
          status: "test-failed",
          completed_at: new Date().toISOString(),
        });
        this.store.logEvent(
          run.project_id,
          "test-fail",
          { seedId: run.seed_id, branchName, output: testResult.output.slice(0, 2000) },
          run.id,
        );
        return false;
      }
    }

    if (run.worktree_path) {
      try {
        await removeWorktree(this.projectPath, run.worktree_path);
      } catch {
        // Non-fatal
      }
    }

    this.store.updateRun(run.id, {
      status: "merged",
      completed_at: new Date().toISOString(),
    });
    this.store.logEvent(
      run.project_id,
      "merge",
      { seedId: run.seed_id, branchName, strategy: "theirs", targetBranch },
      run.id,
    );
    return true;
  }

  /**
   * Find all completed runs and create PRs for their branches.
   * Pushes branches to origin and uses `gh pr create`.
   */
  async createPRs(opts?: {
    baseBranch?: string;
    draft?: boolean;
    projectId?: string;
  }): Promise<PrReport> {
    const baseBranch = opts?.baseBranch ?? "main";
    const draft = opts?.draft ?? false;

    const completedRuns = this.store.getRunsByStatus("completed", opts?.projectId);

    const created: CreatedPr[] = [];
    const failed: FailedRun[] = [];

    for (const run of completedRuns) {
      const branchName = `foreman/${run.seed_id}`;

      try {
        // Push branch to origin
        await git(["push", "-u", "origin", branchName], this.projectPath);

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
          commitLog = await git(
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

        this.store.updateRun(run.id, { status: "pr-created" });
        this.store.logEvent(
          run.project_id,
          "pr-created",
          { seedId: run.seed_id, branchName, baseBranch, prUrl, draft },
          run.id,
        );
        created.push({
          runId: run.id,
          seedId: run.seed_id,
          branchName,
          prUrl,
        });
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        this.store.logEvent(
          run.project_id,
          "fail",
          { seedId: run.seed_id, branchName, error: message },
          run.id,
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
