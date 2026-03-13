import { execFile } from "node:child_process";
import { promisify } from "node:util";
import * as path from "node:path";
import type { MergeQueueConfig } from "./merge-config.js";
import { MergeValidator } from "./merge-validator.js";

const execFileAsync = promisify(execFile);

const MAX_BUFFER = 10 * 1024 * 1024;

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
}
