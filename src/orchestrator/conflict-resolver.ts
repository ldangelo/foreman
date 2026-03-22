import { execFile } from "node:child_process";
import { promisify } from "node:util";
import * as path from "node:path";
import * as fs from "node:fs/promises";
import { existsSync, mkdirSync, renameSync, unlinkSync } from "node:fs";
import type { MergeQueueConfig } from "./merge-config.js";
import { MergeValidator } from "./merge-validator.js";
import type { ConflictPatterns } from "./conflict-patterns.js";
import { REPORT_FILES } from "../lib/archive-reports.js";
import { runWithPi } from "./pi-runner.js";

const execFileAsync = promisify(execFile);

const MAX_BUFFER = 10 * 1024 * 1024;

// Re-export for backwards compatibility
export { REPORT_FILES };

/** Cost information for an AI resolution call. */
export interface CostInfo {
  inputTokens: number;
  outputTokens: number;
  inputCostUsd: number;
  outputCostUsd: number;
  totalCostUsd: number;
  estimatedCostUsd: number;
  actualCostUsd: number;
  model: string;
}

/** Result of a Tier 4 AI resolution attempt. */
export interface Tier4Result {
  success: boolean;
  resolvedContent?: string;
  cost?: CostInfo;
  error?: string;
  errorCode?: string;
}

/** Result of a Tier 3 AI resolution attempt. */
export interface Tier3Result {
  success: boolean;
  resolvedContent?: string;
  cost?: CostInfo;
  error?: string;
  errorCode?: string;
}

/** Result of the full per-file tier cascade. */
export interface CascadeResult {
  success: boolean;
  resolvedTiers: Map<string, number>;
  fallbackFiles: string[];
  costs: CostInfo[];
}

/** Result of post-merge test execution. */
export interface PostMergeTestResult {
  passed: boolean;
  skipped: boolean;
  skipReason?: string;
  output?: string;
  errorCode?: string;
}

/** Result of the fallback handler (conflict PR creation). */
export interface FallbackResult {
  prUrl?: string;
  error?: string;
}

export interface UntrackedCheckResult {
  conflicts: string[];
  action: "deleted" | "stashed" | "aborted" | "none";
  stashPath?: string;
  errorCode?: string;
}

export interface MergeAttemptResult {
  success: boolean;
  conflictedFiles: string[];
}

export interface Tier2Result {
  success: boolean;
  reason?: string;
}

const TIER3_MODEL = "claude-sonnet-4-6";
const TIER4_MODEL = "claude-opus-4-6";

/** Heuristic: approximate 4 characters per token. */
const CHARS_PER_TOKEN = 4;

export class ConflictResolver {
  private validator?: MergeValidator;
  private patternLearning?: ConflictPatterns;
  private sessionCostUsd: number = 0;

  constructor(
    private projectPath: string,
    private config: MergeQueueConfig,
  ) {}

  /** Add to the running session cost total (for testing or external tracking). */
  addSessionCost(amount: number): void {
    this.sessionCostUsd += amount;
  }

  /** Get the current session cost total. */
  getSessionCost(): number {
    return this.sessionCostUsd;
  }

  /** Set (or replace) the MergeValidator instance for AI output validation. */
  setValidator(validator: MergeValidator): void {
    this.validator = validator;
  }

  /** Set (or replace) the ConflictPatterns instance for pattern learning (MQ-T067). */
  setPatternLearning(patterns: ConflictPatterns): void {
    this.patternLearning = patterns;
  }

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
   * Check for untracked files in the working tree that would conflict
   * with files added by the incoming branch.
   *
   * @param branchName   The branch to be merged
   * @param targetBranch The target branch (e.g. "main")
   * @param mode         How to handle conflicts: 'delete' (default), 'stash', or 'abort'
   */
  async checkUntrackedConflicts(
    branchName: string,
    targetBranch: string,
    mode: "delete" | "stash" | "abort" = "delete",
  ): Promise<UntrackedCheckResult> {
    // Get files added by the branch
    const addedResult = await this.gitTry([
      "diff",
      "--name-only",
      "--diff-filter=A",
      `${targetBranch}...${branchName}`,
    ]);
    const addedFiles = addedResult.ok
      ? addedResult.stdout.split("\n").map((f) => f.trim()).filter(Boolean)
      : [];

    if (addedFiles.length === 0) {
      return { conflicts: [], action: "none" };
    }

    // Get untracked files in the working tree
    const untrackedResult = await this.gitTry([
      "ls-files",
      "--others",
      "--exclude-standard",
    ]);
    const untrackedFiles = new Set(
      untrackedResult.ok
        ? untrackedResult.stdout.split("\n").map((f) => f.trim()).filter(Boolean)
        : [],
    );

    // Find intersection
    const conflicts = addedFiles.filter((f) => untrackedFiles.has(f));

    if (conflicts.length === 0) {
      return { conflicts: [], action: "none" };
    }

    if (mode === "abort") {
      return {
        conflicts,
        action: "aborted",
        errorCode: "MQ-014",
      };
    }

    if (mode === "stash") {
      const timestamp = Date.now();
      const stashDir = path.join(
        this.projectPath,
        ".foreman",
        "stashed",
        String(timestamp),
      );
      await fs.mkdir(stashDir, { recursive: true });

      for (const file of conflicts) {
        const src = path.join(this.projectPath, file);
        const destDir = path.join(stashDir, path.dirname(file));
        await fs.mkdir(destDir, { recursive: true });
        const dest = path.join(stashDir, file);
        await fs.rename(src, dest);
      }

      return {
        conflicts,
        action: "stashed",
        stashPath: stashDir,
      };
    }

    // Default: delete mode
    for (const file of conflicts) {
      const filePath = path.join(this.projectPath, file);
      await fs.unlink(filePath);
    }

    return {
      conflicts,
      action: "deleted",
    };
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

  /**
   * Estimate token count from a string using 4 chars/token heuristic.
   */
  private estimateTokens(text: string): number {
    return Math.ceil(text.length / CHARS_PER_TOKEN);
  }


  /**
   * Tier 3: AI-powered conflict resolution using Pi agent.
   *
   * Writes the conflicted file to disk, spawns a Pi session with a specialized
   * conflict-resolution prompt, then reads and validates the resolved content.
   *
   * @param filePath - The file path relative to the project root
   * @param fileContent - The file content with conflict markers
   */
  async attemptTier3Resolution(
    filePath: string,
    fileContent: string,
  ): Promise<Tier3Result> {
    // ── File size gate (MQ-013) ──
    const lineCount = fileContent.split("\n").length;
    if (lineCount > this.config.costControls.maxFileLines) {
      return {
        success: false,
        errorCode: "MQ-013",
        error: `File exceeds size limit: ${lineCount} lines > ${this.config.costControls.maxFileLines} max lines`,
      };
    }

    // ── Pre-call cost estimate (4 chars/token heuristic) ──
    const estimatedInputTokens = this.estimateTokens(fileContent) * 2; // prompt + content
    const estimatedCostUsd = (estimatedInputTokens / 1_000_000) * 3.0;

    // ── Budget check (MQ-012) ──
    const remainingBudget =
      this.config.costControls.maxSessionBudgetUsd - this.sessionCostUsd;
    if (estimatedCostUsd > remainingBudget) {
      return {
        success: false,
        errorCode: "MQ-012",
        error: `Session budget exhausted: estimated $${estimatedCostUsd.toFixed(6)} exceeds remaining $${remainingBudget.toFixed(6)}`,
      };
    }

    // ── Write conflicted content to disk so Pi can read it ──
    const fullPath = path.join(this.projectPath, filePath);
    await fs.mkdir(path.dirname(fullPath), { recursive: true });
    await fs.writeFile(fullPath, fileContent, "utf-8");

    // ── Run Pi conflict-resolution agent ──
    const prompt = [
      `You are resolving a git merge conflict. The file \`${filePath}\` contains conflict markers.`,
      ``,
      `Instructions:`,
      `1. Read the file \`${filePath}\``,
      `2. Examine git log or related files if you need context to understand each side's intent`,
      `3. Resolve ALL conflicts — produce a correct, logical merged result`,
      `4. Write the resolved content back to \`${filePath}\``,
      ``,
      `CRITICAL RULES:`,
      `- The resolved file MUST contain ZERO conflict markers (no <<<<<<< HEAD, =======, or >>>>>>>)`,
      `- Write ONLY valid code — no explanations, no markdown fencing, no prose`,
    ].join("\n");

    const piResult = await runWithPi({
      prompt,
      systemPrompt: "",
      cwd: this.projectPath,
      model: TIER3_MODEL,
      env: process.env as Record<string, string>,
    });

    if (!piResult.success) {
      return {
        success: false,
        error: `Pi conflict resolution failed: ${piResult.errorMessage ?? "unknown error"}`,
      };
    }

    // ── Read resolved content back from disk ──
    let resolvedContent: string;
    try {
      resolvedContent = await fs.readFile(fullPath, "utf-8");
    } catch {
      return {
        success: false,
        error: "Failed to read resolved file after Pi session",
      };
    }

    // ── Track session cost ──
    this.sessionCostUsd += piResult.costUsd;

    const cost: CostInfo = {
      inputTokens: 0,
      outputTokens: 0,
      inputCostUsd: 0,
      outputCostUsd: 0,
      totalCostUsd: piResult.costUsd,
      estimatedCostUsd,
      actualCostUsd: piResult.costUsd,
      model: TIER3_MODEL,
    };

    // ── Validation pipeline (MQ-T031) ──
    const validator = this.validator ?? new MergeValidator(this.config);
    const ext = path.extname(filePath);

    const validation = await validator.validate(filePath, resolvedContent, ext);
    if (!validation.valid) {
      return {
        success: false,
        error: validation.reason ?? "Validation failed",
        cost,
      };
    }

    return {
      success: true,
      resolvedContent,
      cost,
    };
  }

  /**
   * Tier 4: AI-powered "reimagination" using Pi agent with Opus.
   *
   * Unlike Tier 3 which resolves conflict markers, Tier 4 spawns a Pi agent
   * that reads the canonical file, the branch version, and the diff from git,
   * then reimagines the branch changes applied onto the canonical version.
   *
   * @param filePath - The file path relative to the repo root
   * @param branchName - The feature branch name
   * @param targetBranch - The target branch (e.g. "main")
   */
  async attemptTier4Resolution(
    filePath: string,
    branchName: string,
    targetBranch: string,
  ): Promise<Tier4Result> {
    // ── Read canonical content for size gate and cost estimate ──
    const canonicalResult = await this.gitTry([
      "show",
      `${targetBranch}:${filePath}`,
    ]);
    if (!canonicalResult.ok) {
      return {
        success: false,
        error: "Failed to retrieve canonical file content from target branch",
      };
    }
    const canonicalContent = canonicalResult.stdout;

    // ── File size gate (MQ-013) ──
    const lineCount = canonicalContent.split("\n").length;
    if (lineCount > this.config.costControls.maxFileLines) {
      return {
        success: false,
        errorCode: "MQ-013",
        error: `File exceeds size limit: ${lineCount} lines > ${this.config.costControls.maxFileLines} max lines`,
      };
    }

    // ── Pre-call cost estimate ──
    const estimatedInputTokens = this.estimateTokens(canonicalContent) * 3; // prompt + canonical + branch + diff
    const estimatedCostUsd = (estimatedInputTokens / 1_000_000) * 15.0; // Opus pricing

    // ── Budget check ──
    const remainingBudget =
      this.config.costControls.maxSessionBudgetUsd - this.sessionCostUsd;
    if (estimatedCostUsd > remainingBudget) {
      return {
        success: false,
        error: `Session budget exhausted: estimated $${estimatedCostUsd.toFixed(6)} exceeds remaining $${remainingBudget.toFixed(6)}`,
      };
    }

    // ── Run Pi reimagination agent ──
    const prompt = [
      `You are integrating changes from a feature branch into the main branch for file \`${filePath}\`.`,
      ``,
      `Instructions:`,
      `1. Run: git show ${targetBranch}:${filePath}  (canonical main version)`,
      `2. Run: git show ${branchName}:${filePath}  (feature branch version)`,
      `3. Run: git diff ${targetBranch}...${branchName} -- ${filePath}  (what changed)`,
      `4. Apply the feature branch's changes onto the canonical version intelligently`,
      `5. Write the resulting merged content to \`${filePath}\` in the working directory`,
      ``,
      `CRITICAL RULES:`,
      `- Write ONLY the final file content — no explanations, no markdown, no prose`,
      `- The result must be valid code with ALL intended changes from both branches preserved`,
    ].join("\n");

    const piResult = await runWithPi({
      prompt,
      systemPrompt: "",
      cwd: this.projectPath,
      model: TIER4_MODEL,
      env: process.env as Record<string, string>,
    });

    if (!piResult.success) {
      return {
        success: false,
        error: `Pi reimagination failed: ${piResult.errorMessage ?? "unknown error"}`,
      };
    }

    // ── Read resolved content back from disk ──
    const fullPath = path.join(this.projectPath, filePath);
    let resolvedContent: string;
    try {
      resolvedContent = await fs.readFile(fullPath, "utf-8");
    } catch {
      return {
        success: false,
        error: "Failed to read resolved file after Pi session",
      };
    }

    // ── Track session cost ──
    this.sessionCostUsd += piResult.costUsd;

    const cost: CostInfo = {
      inputTokens: 0,
      outputTokens: 0,
      inputCostUsd: 0,
      outputCostUsd: 0,
      totalCostUsd: piResult.costUsd,
      estimatedCostUsd,
      actualCostUsd: piResult.costUsd,
      model: TIER4_MODEL,
    };

    // ── Validation pipeline (MQ-T035) ──
    const validator = this.validator ?? new MergeValidator(this.config);
    const ext = path.extname(filePath);

    const validation = await validator.validate(filePath, resolvedContent, ext);
    if (!validation.valid) {
      return {
        success: false,
        error: validation.reason ?? "Validation failed",
        cost,
      };
    }

    return {
      success: true,
      resolvedContent,
      cost,
    };
  }

  /**
   * Run a `gh` CLI command. Returns trimmed stdout.
   * Wrapped in its own method for easy mocking in tests.
   */
  private async execGh(args: string[]): Promise<string> {
    const { stdout } = await execFileAsync("gh", args, {
      cwd: this.projectPath,
      maxBuffer: MAX_BUFFER,
    });
    return stdout.trim();
  }

  /**
   * Per-file tier cascade orchestrator (MQ-T038).
   *
   * 1. Attempt a clean git merge (Tier 1).
   * 2. For each conflicted file, cascade through Tiers 2 → 3 → 4 → Fallback.
   * 3. If any file reaches Fallback, abort the entire merge.
   * 4. If all files resolve, commit the merge.
   */
  async resolveConflicts(
    branchName: string,
    targetBranch: string,
  ): Promise<CascadeResult> {
    const resolvedTiers = new Map<string, number>();
    const fallbackFiles: string[] = [];
    const costs: CostInfo[] = [];

    // ── Step 1: Tier 1 — standard git merge ──
    const mergeResult = await this.attemptMerge(branchName, targetBranch);
    if (mergeResult.success) {
      return { success: true, resolvedTiers, fallbackFiles, costs };
    }

    // ── Step 2: Re-start merge in --no-commit mode for per-file resolution ──
    await this.git(["checkout", targetBranch]);
    await this.gitTry(["merge", "--no-commit", "--no-ff", branchName]);

    // ── Step 3: Per-file cascade ──
    const ext = (f: string) => path.extname(f);

    for (const filePath of mergeResult.conflictedFiles) {
      let resolved = false;

      // Pattern learning: prefer fallback if file has repeated test failures (MQ-016)
      if (this.patternLearning?.shouldPreferFallback(filePath)) {
        fallbackFiles.push(filePath);
        continue;
      }

      // Tier 2
      const tier2 = await this.attemptTier2Resolution(
        filePath,
        branchName,
        targetBranch,
      );
      if (tier2.success) {
        resolvedTiers.set(filePath, 2);
        this.patternLearning?.recordOutcome(filePath, ext(filePath), 2, true);
        resolved = true;
        continue;
      }
      this.patternLearning?.recordOutcome(filePath, ext(filePath), 2, false, tier2.reason);

      // Tier 3 — Pi agent resolves conflict markers
      // Pattern learning: skip Tier 3 if consistently fails for this extension (MQ-015)
      const skipTier3 = this.patternLearning?.shouldSkipTier(ext(filePath), 3) ?? false;

      if (!skipTier3) {
        // Read the conflicted file content from the working tree
        const conflictedContent = await this.readConflictedFile(filePath);
        const tier3 = await this.attemptTier3Resolution(
          filePath,
          conflictedContent,
        );
        if (tier3.cost) costs.push(tier3.cost);
        if (tier3.success && tier3.resolvedContent) {
          await this.writeResolvedFile(filePath, tier3.resolvedContent);
          resolvedTiers.set(filePath, 3);
          this.patternLearning?.recordOutcome(filePath, ext(filePath), 3, true);
          resolved = true;
          continue;
        }
        this.patternLearning?.recordOutcome(filePath, ext(filePath), 3, false, tier3.error);
      }

      // Tier 4 — Pi agent reimagines the integration using Opus
      // Pattern learning: skip Tier 4 if consistently fails for this extension (MQ-015)
      const skipTier4 = this.patternLearning?.shouldSkipTier(ext(filePath), 4) ?? false;

      if (!skipTier4) {
        const tier4 = await this.attemptTier4Resolution(
          filePath,
          branchName,
          targetBranch,
        );
        if (tier4.cost) costs.push(tier4.cost);
        if (tier4.success && tier4.resolvedContent) {
          await this.writeResolvedFile(filePath, tier4.resolvedContent);
          resolvedTiers.set(filePath, 4);
          this.patternLearning?.recordOutcome(filePath, ext(filePath), 4, true);
          resolved = true;
          continue;
        }
        this.patternLearning?.recordOutcome(filePath, ext(filePath), 4, false, tier4.error);
      }

      // Fallback
      if (!resolved) {
        fallbackFiles.push(filePath);
      }
    }

    // ── Step 4: If any file reached fallback, abort ──
    if (fallbackFiles.length > 0) {
      await this.gitTry(["merge", "--abort"]);
      return { success: false, resolvedTiers, fallbackFiles, costs };
    }

    // ── Step 5: All files resolved — commit the merge ──
    await this.git(["commit", "--no-edit"]);
    return { success: true, resolvedTiers, fallbackFiles, costs };
  }

  /**
   * Read the content of a conflicted file from the working tree.
   */
  private async readConflictedFile(filePath: string): Promise<string> {
    const fullPath = path.join(this.projectPath, filePath);
    try {
      return await fs.readFile(fullPath, "utf-8");
    } catch {
      return "";
    }
  }

  /**
   * Write resolved content to a file and stage it.
   */
  private async writeResolvedFile(
    filePath: string,
    content: string,
  ): Promise<void> {
    const fullPath = path.join(this.projectPath, filePath);
    await fs.writeFile(fullPath, content, "utf-8");
    await this.git(["add", filePath]);
  }

  /**
   * Post-merge test runner (MQ-T042).
   *
   * Runs the project test suite after a merge that used AI resolution
   * (Tier 3 or Tier 4). Skips for clean merges and deterministic-only
   * resolution. On failure, reverts the merge commit with
   * `git reset --hard HEAD~1`.
   */
  async runPostMergeTests(
    resolvedTiers: Map<string, number>,
    testCommand: string = "npm test",
    noTests: boolean = false,
  ): Promise<PostMergeTestResult> {
    // Skip if --no-tests
    if (noTests) {
      return {
        passed: true,
        skipped: true,
        skipReason: "Tests disabled via --no-tests",
      };
    }

    // Check if any file used AI resolution (Tier 3 or 4)
    const usedAI = Array.from(resolvedTiers.values()).some(
      (tier) => tier >= 3,
    );
    if (!usedAI) {
      return {
        passed: true,
        skipped: true,
        skipReason: "No AI resolution used (Tier 1/2 only)",
      };
    }

    // Run tests
    const [cmd, ...args] = testCommand.split(/\s+/);
    try {
      await execFileAsync(cmd, args, {
        cwd: this.projectPath,
        timeout: 120_000,
        maxBuffer: MAX_BUFFER,
      });
      return { passed: true, skipped: false };
    } catch (err: unknown) {
      const e = err as {
        stdout?: string;
        stderr?: string;
        message?: string;
      };
      const output = (
        (e.stdout ?? "") +
        "\n" +
        (e.stderr ?? e.message ?? "")
      ).trim();

      // Revert the merge commit
      await this.git(["reset", "--hard", "HEAD~1"]);

      return {
        passed: false,
        skipped: false,
        output: output.slice(0, 2000),
        errorCode: "MQ-007",
      };
    }
  }

  /**
   * Fallback handler (MQ-T039).
   *
   * Aborts the current merge and creates a conflict PR via `gh pr create`
   * with structured metadata about which tiers were attempted.
   *
   * Uses `gh pr create` intentionally (not `git town propose`) -- see
   * MQ-T058d investigation in Refinery.createPRs() for full rationale.
   * Conflict PRs specifically need custom "[Conflict]" title prefix and
   * structured resolution metadata that require API-level control.
   */
  async handleFallback(
    branchName: string,
    targetBranch: string,
    fallbackFiles: string[],
    resolvedTiers: Map<string, number>,
  ): Promise<FallbackResult> {
    const title = `[Conflict] ${branchName}: merge conflicts require manual resolution`;

    // Build PR body with per-file tier attempts and error details
    const fileDetails = fallbackFiles
      .map((f) => `- \`${f}\`: all tiers exhausted (Tier 2, 3, 4 failed)`)
      .join("\n");

    const resolvedDetails =
      resolvedTiers.size > 0
        ? Array.from(resolvedTiers.entries())
            .map(([f, tier]) => `- \`${f}\`: resolved at Tier ${tier}`)
            .join("\n")
        : "None";

    const body = [
      `## Conflict Resolution Report`,
      ``,
      `**Error Code:** MQ-018`,
      `**Source Branch:** \`${branchName}\``,
      `**Target Branch:** \`${targetBranch}\``,
      ``,
      `### Files Requiring Manual Resolution`,
      fileDetails,
      ``,
      `### Previously Resolved Files`,
      resolvedDetails,
      ``,
      `### Details`,
      `All automated resolution tiers (Tier 2: deterministic, Tier 3: AI Sonnet, Tier 4: AI Opus) ` +
        `were attempted on the listed files but none succeeded. Manual conflict resolution is required.`,
    ].join("\n");

    try {
      const prUrl = await this.execGh([
        "pr",
        "create",
        "--head",
        branchName,
        "--base",
        targetBranch,
        "--title",
        title,
        "--body",
        body,
      ]);
      return { prUrl };
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      return { error: message };
    }
  }

  /**
   * Check if a file path is a report/non-code file that can be auto-resolved.
   */
  static isReportFile(f: string): boolean {
    if (REPORT_FILES.includes(f)) return true;
    if (f.startsWith(".foreman/reports/")) return true;
    if (f.endsWith(".md") && REPORT_FILES.some((r) => f.startsWith(r.replace(".md", ".")))) return true;
    if (f === ".claude/settings.local.json") return true;
    // Beads data files are auto-resolvable: take the branch version (latest bead state)
    if (f === ".beads/issues.jsonl" || f.startsWith(".beads/")) return true;
    return false;
  }

  /**
   * Remove report files from the working tree before merging so they can't
   * conflict. Commits the removal if any tracked files were removed.
   */
  async removeReportFiles(): Promise<void> {
    let removed = false;
    for (const report of REPORT_FILES) {
      const filePath = path.join(this.projectPath, report);
      if (existsSync(filePath)) {
        await this.git(["rm", "-f", report]).catch(() => {
          try { unlinkSync(filePath); } catch { /* already gone */ }
        });
        removed = true;
      }
    }
    if (removed) {
      // Only commit if there are staged changes (git rm of tracked files)
      try {
        await this.git(["commit", "-m", "Remove report files before merge"]);
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
  async archiveReportsPostMerge(seedId: string): Promise<void> {
    const reportsDir = path.join(this.projectPath, ".foreman", "reports");
    mkdirSync(reportsDir, { recursive: true });

    let moved = false;
    for (const report of REPORT_FILES) {
      const src = path.join(this.projectPath, report);
      if (existsSync(src)) {
        const baseName = report.replace(".md", "");
        const dest = path.join(reportsDir, `${baseName}-${seedId}.md`);
        renameSync(src, dest);
        await this.git(["add", "-f", dest]);
        await this.git(["rm", "--cached", report]).catch(() => {});
        moved = true;
      }
    }

    if (moved) {
      await this.git(["commit", "-m", `Archive reports for ${seedId}`]);
    }
  }

  /**
   * During a rebase conflict, check if all conflicts are report files.
   * If so, auto-resolve them and continue rebase (looping until done).
   * If real code conflicts exist, abort rebase and return false.
   * Returns true if rebase completed successfully.
   */
  async autoResolveRebaseConflicts(targetBranch: string): Promise<boolean> {
    const MAX_ITERATIONS = 50; // safety limit
    for (let i = 0; i < MAX_ITERATIONS; i++) {
      // Get conflicted files
      let conflictFiles: string[];
      try {
        const out = await this.git(["diff", "--name-only", "--diff-filter=U"]);
        conflictFiles = out.split("\n").map((f) => f.trim()).filter(Boolean);
      } catch {
        conflictFiles = [];
      }

      if (conflictFiles.length === 0) {
        // No conflicts — rebase may have completed or we resolved the last step
        return true;
      }

      const codeConflicts = conflictFiles.filter((f) => !ConflictResolver.isReportFile(f));
      if (codeConflicts.length > 0) {
        // Real code conflicts — abort
        try { await this.git(["rebase", "--abort"]); } catch { /* already clean */ }
        return false;
      }

      // All conflicts are report files — auto-resolve by accepting ours (the branch version in rebase)
      for (const f of conflictFiles) {
        // In rebase context, --ours is the branch being rebased onto (target),
        // --theirs is the branch's own commits. We want the branch's version.
        await this.git(["checkout", "--theirs", f]).catch(() => {
          // File may have been deleted on one side — just remove it
          try { unlinkSync(path.join(this.projectPath, f)); } catch { /* gone */ }
        });
        await this.git(["add", "-f", f]).catch(() => {});
      }

      // Continue the rebase
      try {
        await this.git(["rebase", "--continue"]);
        return true; // rebase completed
      } catch {
        // More conflicts on the next commit — loop again
      }
    }

    // Hit iteration limit — abort to be safe
    try { await this.git(["rebase", "--abort"]); } catch { /* already clean */ }
    return false;
  }
}
