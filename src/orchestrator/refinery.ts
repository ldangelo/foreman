import { execFile } from "node:child_process";
import { promisify } from "node:util";

import type { ForemanStore, Run } from "../lib/store.js";
import { SeedsClient } from "../lib/seeds.js";
import { mergeWorktree, removeWorktree } from "../lib/git.js";
import type { MergeReport, MergedRun, ConflictRun, FailedRun, PrReport, CreatedPr, MultiRepoMergeOpts, MultiRepoMergeReport } from "./types.js";

const execFileAsync = promisify(execFile);

// ── Logging ──────────────────────────────────────────────────────────────

function log(msg: string): void {
  const ts = new Date().toISOString().slice(11, 23);
  console.error(`[foreman ${ts}] ${msg}`);
}

// ── Helpers ──────────────────────────────────────────────────────────────

async function git(args: string[], cwd: string): Promise<string> {
  const { stdout } = await execFileAsync("git", args, {
    cwd,
    maxBuffer: 10 * 1024 * 1024,
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
   * Get all completed runs that are ready to merge, optionally filtered to a single seed.
   */
  getCompletedRuns(projectId?: string, seedId?: string): Run[] {
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
  async orderByDependencies(runs: Run[]): Promise<Run[]> {
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

      const sorted: Run[] = [];
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
        if (!sorted.some((r) => r.id === run.id)) sorted.push(run);
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
        const result = await mergeWorktree(this.projectPath, branchName, targetBranch);

        if (!result.success) {
          // Merge conflicts — abort the merge to leave repo clean for next attempt
          try {
            await git(["merge", "--abort"], this.projectPath);
          } catch {
            // merge --abort may fail if already clean
          }

          this.store.updateRun(run.id, { status: "conflict" });
          this.store.logEvent(
            run.project_id,
            "conflict",
            { seedId: run.seed_id, branchName, conflictFiles: result.conflicts },
            run.id,
          );
          conflicts.push({
            runId: run.id,
            seedId: run.seed_id,
            branchName,
            conflictFiles: result.conflicts ?? [],
          });
          continue;
        }

        // Merge succeeded — optionally run tests
        if (runTests) {
          const testResult = await runTestCommand(testCommand, this.projectPath);

          if (!testResult.ok) {
            // Revert the merge
            await git(["reset", "--hard", "HEAD~1"], this.projectPath);

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
    try {
      await git(["checkout", "main"], this.projectPath);
      await git(["merge", branchName, "--no-ff", "-X", "theirs"], this.projectPath);

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
        { seedId: run.seed_id, branchName, strategy: "theirs" },
        run.id,
      );
      return true;
    } catch (err: unknown) {
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

  /**
   * Merge completed runs across multiple repositories.
   *
   * For each project path in opts.targetBranches, creates a Refinery for
   * that project and calls mergeCompleted() with the specified target branch
   * and optional test command.
   *
   * Projects whose path is not registered in the store are skipped.
   */
  async mergeMultiRepo(opts: MultiRepoMergeOpts): Promise<MultiRepoMergeReport> {
    const byProject: Record<string, MergeReport> = {};
    const errors: Record<string, string> = {};

    for (const [projectPath, targetBranch] of Object.entries(opts.targetBranches)) {
      const project = this.store.getProjectByPath(projectPath);
      if (!project) {
        log(`Project at ${projectPath} not registered — skipping merge`);
        byProject[projectPath] = { merged: [], conflicts: [], testFailures: [] };
        continue;
      }

      const projectSeeds = new SeedsClient(projectPath);
      const projectRefinery = new Refinery(this.store, projectSeeds, projectPath);

      try {
        const report = await projectRefinery.mergeCompleted({
          targetBranch,
          runTests: opts.runTests,
          testCommand: opts.testCommands?.[projectPath],
          projectId: project.id,
        });
        byProject[projectPath] = report;
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        log(`Failed to merge for project ${projectPath}: ${message}`);
        byProject[projectPath] = { merged: [], conflicts: [], testFailures: [] };
        errors[projectPath] = message;
      }
    }

    return { byProject, errors };
  }
}
