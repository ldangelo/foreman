import { execFile } from "node:child_process";
import { promisify } from "node:util";
import * as path from "node:path";
import * as fs from "node:fs/promises";
import { existsSync, mkdirSync, renameSync, unlinkSync } from "node:fs";
import type { MergeQueueConfig } from "./merge-config.js";
import { MergeValidator } from "./merge-validator.js";
import type { ConflictPatterns } from "./conflict-patterns.js";

const execFileAsync = promisify(execFile);

const MAX_BUFFER = 10 * 1024 * 1024;

// Report files that agents produce in the worktree root
export const REPORT_FILES = [
  "EXPLORER_REPORT.md",
  "DEVELOPER_REPORT.md",
  "QA_REPORT.md",
  "REVIEW.md",
  "FINALIZE_REPORT.md",
  "TASK.md",
  "AGENTS.md",
];

/** Shape of the Anthropic Messages API response (subset). */
export interface AnthropicMessage {
  content: Array<{ type: string; text: string }>;
  usage: { input_tokens: number; output_tokens: number };
}

/** Anthropic client interface for dependency injection. */
export interface AnthropicClient {
  messages: {
    create(params: Record<string, unknown>): Promise<AnthropicMessage>;
  };
}

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

/** Per-million-token pricing for supported models. */
const PRICING: Record<string, { inputPer1M: number; outputPer1M: number }> = {
  "claude-sonnet-4-6": { inputPer1M: 3.0, outputPer1M: 15.0 },
  "claude-opus-4-6": { inputPer1M: 15.0, outputPer1M: 75.0 },
};

const TIER3_MODEL = "claude-sonnet-4-6";
const TIER4_MODEL = "claude-opus-4-6";

const TIER3_SYSTEM_PROMPT =
  "You are a code merge conflict resolver. You will be given a file containing git conflict markers. " +
  "Resolve the conflicts by producing the correct merged version of the file. " +
  "Output ONLY the resolved file content. Do NOT include any explanation, comments about the resolution, " +
  "markdown fencing, or anything other than the exact file content.";

const TIER4_SYSTEM_PROMPT =
  "You are a code integration specialist. You will be given three things:\n" +
  "1. The canonical version of a file (from the target branch)\n" +
  "2. A diff showing changes made on a feature branch\n" +
  "3. The feature branch's version of the file\n\n" +
  "Apply the changes from the feature branch onto the canonical version.\n" +
  "Output ONLY the resulting file content. Do NOT include any explanation, comments about the integration, " +
  "markdown fencing, or anything other than the exact file content.";

/** Heuristic: approximate 4 characters per token. */
const CHARS_PER_TOKEN = 4;

export class ConflictResolver {
  private anthropicClient?: AnthropicClient;
  private validator?: MergeValidator;
  private patternLearning?: ConflictPatterns;
  private sessionCostUsd: number = 0;

  constructor(
    private projectPath: string,
    private config: MergeQueueConfig,
    anthropicClient?: AnthropicClient,
  ) {
    this.anthropicClient = anthropicClient;
  }

  /** Add to the running session cost total (for testing or external tracking). */
  addSessionCost(amount: number): void {
    this.sessionCostUsd += amount;
  }

  /** Get the current session cost total. */
  getSessionCost(): number {
    return this.sessionCostUsd;
  }

  /** Set (or replace) the Anthropic client for AI resolution. */
  setAnthropicClient(client: AnthropicClient): void {
    this.anthropicClient = client;
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
   * Calculate USD cost from token counts and model pricing.
   */
  private calculateCost(
    inputTokens: number,
    outputTokens: number,
    model: string,
  ): number {
    const pricing = PRICING[model];
    if (!pricing) return 0;
    return (
      (inputTokens / 1_000_000) * pricing.inputPer1M +
      (outputTokens / 1_000_000) * pricing.outputPer1M
    );
  }

  /**
   * Tier 3: AI-powered conflict resolution using Anthropic Messages API.
   *
   * Reads the conflicted file content, sends it to Claude Sonnet for resolution,
   * validates the output, and returns the result with cost tracking.
   *
   * @param filePath - The file path (used for extension-based validation)
   * @param fileContent - The file content with conflict markers
   */
  async attemptTier3Resolution(
    filePath: string,
    fileContent: string,
  ): Promise<Tier3Result> {
    if (!this.anthropicClient) {
      return {
        success: false,
        error: "No Anthropic client configured for Tier 3 resolution",
      };
    }

    // ── File size gate (MQ-013) ──
    const lineCount = fileContent.split("\n").length;
    if (lineCount > this.config.costControls.maxFileLines) {
      return {
        success: false,
        errorCode: "MQ-013",
        error: `File exceeds size limit: ${lineCount} lines > ${this.config.costControls.maxFileLines} max lines`,
      };
    }

    // ── Pre-call cost estimate ──
    const estimatedInputTokens =
      this.estimateTokens(TIER3_SYSTEM_PROMPT) +
      this.estimateTokens(fileContent);
    // Estimate output as same size as input content
    const estimatedOutputTokens = this.estimateTokens(fileContent);
    const estimatedCostUsd = this.calculateCost(
      estimatedInputTokens,
      estimatedOutputTokens,
      TIER3_MODEL,
    );

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

    // ── Call Anthropic API ──
    let response: Awaited<
      ReturnType<AnthropicClient["messages"]["create"]>
    >;
    try {
      response = await this.anthropicClient.messages.create({
        model: TIER3_MODEL,
        max_tokens: 8192,
        system: TIER3_SYSTEM_PROMPT,
        messages: [
          {
            role: "user",
            content: `Resolve the merge conflicts in this file:\n\n${fileContent}`,
          },
        ],
      });
    } catch (err: unknown) {
      const message =
        err instanceof Error ? err.message : String(err);
      return {
        success: false,
        error: `Anthropic API call failed: ${message}`,
      };
    }

    // ── Extract response text ──
    const textBlock = response.content.find((b) => b.type === "text");
    if (!textBlock) {
      return {
        success: false,
        error: "No text content in API response",
      };
    }
    const resolvedContent = textBlock.text;

    // ── Actual cost from usage ──
    const { input_tokens: inputTokens, output_tokens: outputTokens } =
      response.usage;
    const actualCostUsd = this.calculateCost(
      inputTokens,
      outputTokens,
      TIER3_MODEL,
    );

    // Track session cost
    this.sessionCostUsd += actualCostUsd;

    const inputPricing = PRICING[TIER3_MODEL];
    const inputCostUsd = inputPricing
      ? (inputTokens / 1_000_000) * inputPricing.inputPer1M
      : 0;
    const outputCostUsd = inputPricing
      ? (outputTokens / 1_000_000) * inputPricing.outputPer1M
      : 0;

    const cost: CostInfo = {
      inputTokens,
      outputTokens,
      inputCostUsd,
      outputCostUsd,
      totalCostUsd: inputCostUsd + outputCostUsd,
      estimatedCostUsd,
      actualCostUsd,
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
   * Tier 4: AI-powered "reimagination" using Anthropic Messages API with Opus.
   *
   * Unlike Tier 3 which resolves conflict markers, Tier 4 reads the canonical
   * file, the branch file, and the diff, then reimagines the branch changes
   * applied onto the canonical version.
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
    if (!this.anthropicClient) {
      return {
        success: false,
        error: "No Anthropic client configured for Tier 4 resolution",
      };
    }

    // ── Read three inputs ──
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

    const branchResult = await this.gitTry([
      "show",
      `${branchName}:${filePath}`,
    ]);
    if (!branchResult.ok) {
      return {
        success: false,
        error: "Failed to retrieve branch file content",
      };
    }
    const branchContent = branchResult.stdout;

    const diffResult = await this.gitTry([
      "diff",
      `${targetBranch}...${branchName}`,
      "--",
      filePath,
    ]);
    const diffOutput = diffResult.ok ? diffResult.stdout : "";

    // ── File size gate (MQ-013) ──
    const lineCount = canonicalContent.split("\n").length;
    if (lineCount > this.config.costControls.maxFileLines) {
      return {
        success: false,
        errorCode: "MQ-013",
        error: `File exceeds size limit: ${lineCount} lines > ${this.config.costControls.maxFileLines} max lines`,
      };
    }

    // ── Pre-call cost estimate (4 chars/token heuristic) ──
    const promptText =
      TIER4_SYSTEM_PROMPT + canonicalContent + branchContent + diffOutput;
    const estimatedInputTokens = this.estimateTokens(promptText);
    // Estimate output as same size as canonical content
    const estimatedOutputTokens = this.estimateTokens(canonicalContent);
    const estimatedCostUsd = this.calculateCost(
      estimatedInputTokens,
      estimatedOutputTokens,
      TIER4_MODEL,
    );

    // ── Budget check ──
    const remainingBudget =
      this.config.costControls.maxSessionBudgetUsd - this.sessionCostUsd;
    if (estimatedCostUsd > remainingBudget) {
      return {
        success: false,
        error: `Session budget exhausted: estimated $${estimatedCostUsd.toFixed(6)} exceeds remaining $${remainingBudget.toFixed(6)}`,
      };
    }

    // ── Build user message with three labeled sections ──
    const userMessage =
      `## Canonical version (${targetBranch})\n\n${canonicalContent}\n\n` +
      `## Diff (${targetBranch}...${branchName})\n\n${diffOutput}\n\n` +
      `## Branch version (${branchName})\n\n${branchContent}`;

    // ── Call Anthropic API ──
    let response: AnthropicMessage;
    try {
      response = await this.anthropicClient.messages.create({
        model: TIER4_MODEL,
        max_tokens: 16384,
        system: TIER4_SYSTEM_PROMPT,
        messages: [
          {
            role: "user",
            content: userMessage,
          },
        ],
      });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      return {
        success: false,
        error: `Anthropic API call failed: ${message}`,
      };
    }

    // ── Extract response text ──
    const textBlock = response.content.find((b) => b.type === "text");
    if (!textBlock) {
      return {
        success: false,
        error: "No text content in API response",
      };
    }
    const resolvedContent = textBlock.text;

    // ── Actual cost from usage ──
    const { input_tokens: inputTokens, output_tokens: outputTokens } =
      response.usage;
    const pricing = PRICING[TIER4_MODEL];
    const inputCostUsd = pricing
      ? (inputTokens / 1_000_000) * pricing.inputPer1M
      : 0;
    const outputCostUsd = pricing
      ? (outputTokens / 1_000_000) * pricing.outputPer1M
      : 0;
    const actualCostUsd = inputCostUsd + outputCostUsd;

    // Track session cost
    this.sessionCostUsd += actualCostUsd;

    const cost: CostInfo = {
      inputTokens,
      outputTokens,
      inputCostUsd,
      outputCostUsd,
      totalCostUsd: actualCostUsd,
      estimatedCostUsd,
      actualCostUsd,
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

      // Tier 3 (only if Anthropic client is available)
      if (this.anthropicClient) {
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

        // Pattern learning: skip Tier 4 if consistently fails for this extension (MQ-015)
        const skipTier4 = this.patternLearning?.shouldSkipTier(ext(filePath), 4) ?? false;

        if (!skipTier4) {
          // Tier 4
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
