import { execFile } from "node:child_process";
import { promisify } from "node:util";

import type { ForemanStore } from "../lib/store.js";
import type { BeadsClient } from "../lib/beads.js";
import { mergeWorktree, removeWorktree } from "../lib/git.js";
import type { MergeReport, MergedRun, ConflictRun, FailedRun } from "./types.js";

const execFileAsync = promisify(execFile);

// ── Helpers ──────────────────────────────────────────────────────────────

async function git(args: string[], cwd: string): Promise<string> {
  const { stdout } = await execFileAsync("git", args, {
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
    private beads: BeadsClient,
    private projectPath: string,
  ) {}

  /**
   * Find all completed (unmerged) runs and attempt to merge them into the target branch.
   * Optionally run tests after each merge.
   */
  async mergeCompleted(opts?: {
    targetBranch?: string;
    runTests?: boolean;
    testCommand?: string;
    projectId?: string;
  }): Promise<MergeReport> {
    const targetBranch = opts?.targetBranch ?? "main";
    const runTests = opts?.runTests ?? true;
    const testCommand = opts?.testCommand ?? "npm test";

    const completedRuns = this.store.getRunsByStatus("completed", opts?.projectId);

    const merged: MergedRun[] = [];
    const conflicts: ConflictRun[] = [];
    const testFailures: FailedRun[] = [];

    for (const run of completedRuns) {
      const branchName = `foreman/${run.bead_id}`;

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
            { beadId: run.bead_id, branchName, conflictFiles: result.conflicts },
            run.id,
          );
          conflicts.push({
            runId: run.id,
            beadId: run.bead_id,
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
              { beadId: run.bead_id, branchName, output: testResult.output.slice(0, 2000) },
              run.id,
            );
            testFailures.push({
              runId: run.id,
              beadId: run.bead_id,
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
          { beadId: run.bead_id, branchName, targetBranch },
          run.id,
        );
        merged.push({
          runId: run.id,
          beadId: run.bead_id,
          branchName,
        });
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        this.store.logEvent(
          run.project_id,
          "fail",
          { beadId: run.bead_id, branchName, error: message },
          run.id,
        );
        testFailures.push({
          runId: run.id,
          beadId: run.bead_id,
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

    const branchName = `foreman/${run.bead_id}`;

    if (strategy === "abort") {
      this.store.updateRun(run.id, {
        status: "failed",
        completed_at: new Date().toISOString(),
      });
      this.store.logEvent(
        run.project_id,
        "fail",
        { beadId: run.bead_id, reason: "Conflict resolution aborted by user" },
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
        { beadId: run.bead_id, branchName, strategy: "theirs" },
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
        { beadId: run.bead_id, error: message },
        run.id,
      );
      return false;
    }
  }
}
