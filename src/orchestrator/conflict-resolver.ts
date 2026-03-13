import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { MergeQueueConfig } from "./merge-config.js";

const execFileAsync = promisify(execFile);

const MAX_BUFFER = 10 * 1024 * 1024;

export interface MergeAttemptResult {
  success: boolean;
  conflictedFiles: string[];
}

export interface Tier2Result {
  success: boolean;
  reason?: string;
}

export class ConflictResolver {
  constructor(
    private projectPath: string,
    private config: MergeQueueConfig,
  ) {}

  /** Run a git command in the project directory. Returns trimmed stdout. */
  private async git(args: string[]): Promise<string> {
    const { stdout } = await execFileAsync("git", args, {
      cwd: this.projectPath,
      maxBuffer: MAX_BUFFER,
      env: { ...process.env, GIT_EDITOR: "true" },
    });
    return stdout.trim();
  }

  /**
   * Run a git command that may fail. Returns { ok, stdout, stderr }.
   */
  private async gitTry(
    args: string[],
  ): Promise<{ ok: boolean; stdout: string; stderr: string }> {
    try {
      const { stdout, stderr } = await execFileAsync("git", args, {
        cwd: this.projectPath,
        maxBuffer: MAX_BUFFER,
        env: { ...process.env, GIT_EDITOR: "true" },
      });
      return { ok: true, stdout: stdout.trim(), stderr: stderr.trim() };
    } catch (err: unknown) {
      const e = err as { stdout?: string; stderr?: string; message?: string };
      return {
        ok: false,
        stdout: (e.stdout ?? "").trim(),
        stderr: (e.stderr ?? e.message ?? "").trim(),
      };
    }
  }

  /**
   * Tier 1: Attempt a standard git merge.
   *
   * Runs `git merge --no-commit --no-ff <branchName>` from the current branch
   * (which should be targetBranch). On success, commits. On conflict, identifies
   * conflicted files and aborts the merge.
   */
  async attemptMerge(
    branchName: string,
    targetBranch: string,
  ): Promise<MergeAttemptResult> {
    // Ensure we are on the target branch
    await this.git(["checkout", targetBranch]);

    const mergeResult = await this.gitTry([
      "merge",
      "--no-commit",
      "--no-ff",
      branchName,
    ]);

    if (mergeResult.ok) {
      // No conflicts — commit the merge
      await this.git(["commit", "--no-edit"]);
      return { success: true, conflictedFiles: [] };
    }

    // Conflicts detected — identify conflicted files
    const diffResult = await this.gitTry([
      "diff",
      "--name-only",
      "--diff-filter=U",
    ]);
    const conflictedFiles = diffResult.stdout
      .split("\n")
      .map((f) => f.trim())
      .filter(Boolean);

    // Abort the merge to restore clean state
    await this.gitTry(["merge", "--abort"]);

    return { success: false, conflictedFiles };
  }

  /**
   * Tier 2: Per-file conflict resolution with dual-check gate.
   *
   * Must be called while a merge is in progress (after a failed attemptMerge
   * or after manually starting a merge). Applies two checks:
   *
   * 1. **Hunk verification**: Every line unique to the target version must
   *    appear in the branch version (meaning the branch incorporated the
   *    target's changes).
   * 2. **Threshold guard**: The number of discarded lines must not exceed
   *    `maxDiscardedLines` or `maxDiscardedPercent` of the target file.
   *
   * Both checks must pass. If they do, resolves the file using `--theirs`.
   */
  async attemptTier2Resolution(
    filePath: string,
    branchName: string,
    targetBranch: string,
  ): Promise<Tier2Result> {
    // Get the content of the file from both branches
    const targetResult = await this.gitTry([
      "show",
      `${targetBranch}:${filePath}`,
    ]);
    const branchResult = await this.gitTry([
      "show",
      `${branchName}:${filePath}`,
    ]);

    if (!targetResult.ok || !branchResult.ok) {
      return {
        success: false,
        reason: "Failed to retrieve file content from branches",
      };
    }

    const targetContent = targetResult.stdout;
    const branchContent = branchResult.stdout;

    // ── Check 1: Hunk verification ──
    // Find lines that are in the target but not in the base (ancestor).
    // Then verify those lines appear in the branch version.
    const mergeBaseResult = await this.gitTry([
      "merge-base",
      targetBranch,
      branchName,
    ]);
    const mergeBase = mergeBaseResult.ok ? mergeBaseResult.stdout : "";

    let baseContent = "";
    if (mergeBase) {
      const baseResult = await this.gitTry([
        "show",
        `${mergeBase}:${filePath}`,
      ]);
      baseContent = baseResult.ok ? baseResult.stdout : "";
    }

    const baseLines = new Set(baseContent.split("\n"));
    const branchLines = new Set(branchContent.split("\n"));

    // Lines added by the target branch (not in the common ancestor)
    const targetUniqueLines = targetContent
      .split("\n")
      .filter(
        (line) =>
          line.trim() !== "" && !baseLines.has(line) && !branchLines.has(line),
      );

    if (targetUniqueLines.length > 0) {
      return {
        success: false,
        reason: `Hunk verification failed: ${targetUniqueLines.length} target-side line(s) not found in branch version`,
      };
    }

    // ── Check 2: Threshold guard ──
    const diffResult = await this.gitTry([
      "diff",
      targetBranch,
      branchName,
      "--",
      filePath,
    ]);
    const diffOutput = diffResult.ok ? diffResult.stdout : "";

    const discardedLines = diffOutput
      .split("\n")
      .filter((l) => l.startsWith("-") && !l.startsWith("---")).length;

    const targetLines = targetContent.split("\n").length;
    const discardedPercent =
      targetLines > 0 ? (discardedLines / targetLines) * 100 : 0;

    const { maxDiscardedLines, maxDiscardedPercent } =
      this.config.tier2SafetyCheck;

    if (
      discardedLines > maxDiscardedLines ||
      discardedPercent > maxDiscardedPercent
    ) {
      return {
        success: false,
        reason: `Threshold guard failed: ${discardedLines} lines discarded (${discardedPercent.toFixed(1)}%), limits: ${maxDiscardedLines} lines / ${maxDiscardedPercent}%`,
      };
    }

    // ── Both checks passed — resolve using theirs ──
    await this.git(["checkout", "--theirs", filePath]);
    await this.git(["add", filePath]);

    return { success: true };
  }
}
