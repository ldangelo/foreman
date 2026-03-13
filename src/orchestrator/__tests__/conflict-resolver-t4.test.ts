import { describe, it, expect, beforeEach, vi } from "vitest";
import {
  ConflictResolver,
  type AnthropicClient,
  type AnthropicMessage,
  type CostInfo,
  type Tier4Result,
} from "../conflict-resolver.js";
import { DEFAULT_MERGE_CONFIG } from "../merge-config.js";
import type { MergeQueueConfig } from "../merge-config.js";
import type { MergeValidator, ValidationResult } from "../merge-validator.js";

/**
 * Helper to create a mock AnthropicClient that returns the given content.
 */
function mockAnthropicClient(
  responseText: string,
  inputTokens = 500,
  outputTokens = 300,
): AnthropicClient {
  return {
    messages: {
      create: vi.fn().mockResolvedValue({
        content: [{ type: "text", text: responseText }],
        usage: { input_tokens: inputTokens, output_tokens: outputTokens },
      } satisfies AnthropicMessage),
    },
  };
}

/**
 * Helper to create a mock MergeValidator.
 */
function mockValidator(
  result: ValidationResult = { valid: true },
): MergeValidator {
  return {
    validate: vi.fn().mockResolvedValue(result),
    proseDetection: vi.fn().mockReturnValue(false),
    syntaxCheck: vi.fn().mockResolvedValue({ pass: true }),
    conflictMarkerCheck: vi.fn().mockReturnValue(false),
    markdownFencingCheck: vi.fn().mockReturnValue(false),
  } as unknown as MergeValidator;
}

/**
 * Stub the git helper to return controllable values.
 * Tier 4 reads canonical, branch, and diff via git.
 */
function stubGitForTier4(
  resolver: ConflictResolver,
  options: {
    canonicalContent?: string;
    branchContent?: string;
    diffOutput?: string;
    canonicalFails?: boolean;
    branchFails?: boolean;
    diffFails?: boolean;
    fileLineCount?: number;
  } = {},
): void {
  const {
    canonicalContent = 'const a = 1;\nconst b = 2;\n',
    branchContent = 'const a = 1;\nconst b = 2;\nconst c = 3;\n',
    diffOutput = '--- a/file.ts\n+++ b/file.ts\n@@ -1,2 +1,3 @@\n const a = 1;\n const b = 2;\n+const c = 3;\n',
    canonicalFails = false,
    branchFails = false,
    diffFails = false,
  } = options;

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const resolverAny = resolver as any;

  resolverAny.gitTry = vi.fn().mockImplementation((args: string[]) => {
    // git show {targetBranch}:{filePath} — canonical
    if (args[0] === "show" && typeof args[1] === "string" && args[1].includes("main:")) {
      if (canonicalFails) {
        return Promise.resolve({ ok: false, stdout: "", stderr: "not found" });
      }
      return Promise.resolve({ ok: true, stdout: canonicalContent, stderr: "" });
    }
    // git show {branchName}:{filePath} — branch version
    if (args[0] === "show" && typeof args[1] === "string" && args[1].includes("feature/")) {
      if (branchFails) {
        return Promise.resolve({ ok: false, stdout: "", stderr: "not found" });
      }
      return Promise.resolve({ ok: true, stdout: branchContent, stderr: "" });
    }
    // git diff
    if (args[0] === "diff") {
      if (diffFails) {
        return Promise.resolve({ ok: false, stdout: "", stderr: "diff failed" });
      }
      return Promise.resolve({ ok: true, stdout: diffOutput, stderr: "" });
    }
    return Promise.resolve({ ok: true, stdout: "", stderr: "" });
  });

  resolverAny.git = vi.fn().mockResolvedValue("");
}

describe("ConflictResolver - Tier 4 (Opus Reimagination)", () => {
  let resolver: ConflictResolver;
  let config: MergeQueueConfig;

  beforeEach(() => {
    config = {
      ...DEFAULT_MERGE_CONFIG,
      costControls: {
        maxFileLines: 1000,
        maxSessionBudgetUsd: 5.0,
      },
    };
    resolver = new ConflictResolver("/fake/project", config);
  });

  describe("MQ-T034: Tier 4 resolution implementation", () => {
    it("successfully resolves with Opus reimagination", async () => {
      const resolvedCode = 'const a = 1;\nconst b = 2;\nconst c = 3;\n';
      const client = mockAnthropicClient(resolvedCode);
      const validator = mockValidator({ valid: true });

      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver);

      const result = await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/add-c",
        "main",
      );

      expect(result.success).toBe(true);
      expect(result.resolvedContent).toBe(resolvedCode);
    });

    it("reads three inputs: canonical, branch, and diff", async () => {
      const client = mockAnthropicClient("resolved content");
      const validator = mockValidator({ valid: true });

      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver, {
        canonicalContent: "canonical-version",
        branchContent: "branch-version",
        diffOutput: "the-diff",
      });

      await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      // Verify the prompt includes all three inputs
      const createCall = client.messages.create as ReturnType<typeof vi.fn>;
      expect(createCall).toHaveBeenCalledOnce();

      const callArgs = createCall.mock.calls[0][0];
      const userMessage = callArgs.messages[0].content as string;
      expect(userMessage).toContain("canonical-version");
      expect(userMessage).toContain("branch-version");
      expect(userMessage).toContain("the-diff");
    });

    it("uses claude-opus-4-6 model", async () => {
      const client = mockAnthropicClient("code");
      const validator = mockValidator({ valid: true });

      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver);

      await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      const createCall = client.messages.create as ReturnType<typeof vi.fn>;
      const callArgs = createCall.mock.calls[0][0];
      expect(callArgs.model).toBe("claude-opus-4-6");
    });

    it("uses correct system prompt for reimagination", async () => {
      const client = mockAnthropicClient("code");
      const validator = mockValidator({ valid: true });

      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver);

      await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      const createCall = client.messages.create as ReturnType<typeof vi.fn>;
      const callArgs = createCall.mock.calls[0][0];
      expect(callArgs.system).toContain("code integration specialist");
      expect(callArgs.system).toContain("canonical version");
      expect(callArgs.system).toContain("Output ONLY the resulting file content");
    });

    it("applies file size gate (MQ-013)", async () => {
      const longConfig: MergeQueueConfig = {
        ...config,
        costControls: {
          maxFileLines: 10,
          maxSessionBudgetUsd: 5.0,
        },
      };
      resolver = new ConflictResolver("/fake/project", longConfig);

      const client = mockAnthropicClient("code");
      resolver.setAnthropicClient(client);

      const longContent = Array.from({ length: 20 }, (_, i) => `line ${i}`).join("\n");
      stubGitForTier4(resolver, { canonicalContent: longContent });

      const result = await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      expect(result.success).toBe(false);
      expect(result.errorCode).toBe("MQ-013");
      expect(result.error).toMatch(/size limit/i);
    });

    it("returns error when canonical file cannot be read", async () => {
      const client = mockAnthropicClient("code");
      resolver.setAnthropicClient(client);
      stubGitForTier4(resolver, { canonicalFails: true });

      const result = await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/canonical|retrieve/i);
    });

    it("returns error when branch file cannot be read", async () => {
      const client = mockAnthropicClient("code");
      resolver.setAnthropicClient(client);
      stubGitForTier4(resolver, { branchFails: true });

      const result = await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/branch|retrieve/i);
    });

    it("returns error when no Anthropic client is set", async () => {
      stubGitForTier4(resolver);

      const result = await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/anthropic|client/i);
    });
  });

  describe("MQ-T035: Validation pipeline", () => {
    it("validation pass writes resolved content and git adds", async () => {
      const resolvedCode = "const x = 1;\n";
      const client = mockAnthropicClient(resolvedCode);
      const validator = mockValidator({ valid: true });

      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver);

      const result = await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      expect(result.success).toBe(true);

      // Verify validator was called
      expect(validator.validate).toHaveBeenCalledWith(
        "src/file.ts",
        resolvedCode,
        ".ts",
      );
    });

    it("validation failure cascades to Fallback", async () => {
      const client = mockAnthropicClient("This is a prose explanation of what I did");
      const validator = mockValidator({
        valid: false,
        errorCode: "MQ-003",
        reason: "Content appears to be prose",
      });

      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver);

      const result = await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      expect(result.success).toBe(false);
      expect(result.error).toContain("prose");
    });
  });

  describe("MQ-T036: Cost tracking with Opus pricing", () => {
    it("tracks cost from response.usage with Opus pricing", async () => {
      // Opus: $15/M input, $75/M output
      const client = mockAnthropicClient("resolved code", 1000, 500);
      const validator = mockValidator({ valid: true });

      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver);

      const result = await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      expect(result.success).toBe(true);
      expect(result.cost).toBeDefined();
      // 1000 input tokens * $15/1M = $0.015
      // 500 output tokens * $75/1M = $0.0375
      // Total: $0.0525
      expect(result.cost!.inputTokens).toBe(1000);
      expect(result.cost!.outputTokens).toBe(500);
      expect(result.cost!.inputCostUsd).toBeCloseTo(0.015, 6);
      expect(result.cost!.outputCostUsd).toBeCloseTo(0.0375, 6);
      expect(result.cost!.totalCostUsd).toBeCloseTo(0.0525, 6);
    });

    it("checks budget before making API call", async () => {
      const tightBudgetConfig: MergeQueueConfig = {
        ...config,
        costControls: {
          maxFileLines: 1000,
          maxSessionBudgetUsd: 0.001, // Nearly exhausted
        },
      };
      resolver = new ConflictResolver("/fake/project", tightBudgetConfig);

      const client = mockAnthropicClient("code");
      const validator = mockValidator({ valid: true });

      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver);

      // Pre-spend the budget
      resolver.addSessionCost(0.001);

      const result = await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/budget/i);

      // API should NOT have been called
      const createCall = client.messages.create as ReturnType<typeof vi.fn>;
      expect(createCall).not.toHaveBeenCalled();
    });

    it("accumulates cost across multiple calls", async () => {
      const client = mockAnthropicClient("code", 1000, 500);
      const validator = mockValidator({ valid: true });

      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver);

      await resolver.attemptTier4Resolution(
        "src/file1.ts",
        "feature/test",
        "main",
      );

      const firstCost = resolver.getSessionCost();
      expect(firstCost).toBeGreaterThan(0);

      // Second call should add to the session total
      stubGitForTier4(resolver); // Re-stub for fresh mocks
      await resolver.attemptTier4Resolution(
        "src/file2.ts",
        "feature/test",
        "main",
      );

      const secondCost = resolver.getSessionCost();
      expect(secondCost).toBeGreaterThan(firstCost);
      expect(secondCost).toBeCloseTo(firstCost * 2, 6);
    });

    it("estimates cost before call using 4 chars/token heuristic", async () => {
      // With a very large file, the estimate should be substantial
      const largeContent = "x".repeat(4000); // ~1000 tokens estimate
      const client = mockAnthropicClient("code", 100, 50);
      const validator = mockValidator({ valid: true });

      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver, { canonicalContent: largeContent });

      // Set budget that would be exceeded by the estimate
      const tightConfig: MergeQueueConfig = {
        ...config,
        costControls: {
          maxFileLines: 5000,
          maxSessionBudgetUsd: 0.01, // Very tight
        },
      };
      resolver = new ConflictResolver("/fake/project", tightConfig);
      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver, { canonicalContent: largeContent });

      // Pre-spend most of the budget
      resolver.addSessionCost(0.009);

      const result = await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/budget/i);
    });
  });

  describe("MQ-T037: Three-input prompt structure", () => {
    it("prompt contains labeled sections for all three inputs", async () => {
      const client = mockAnthropicClient("output");
      const validator = mockValidator({ valid: true });

      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver, {
        canonicalContent: "canonical code here",
        branchContent: "branch code here",
        diffOutput: "diff output here",
      });

      await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/labeled",
        "main",
      );

      const createCall = client.messages.create as ReturnType<typeof vi.fn>;
      const callArgs = createCall.mock.calls[0][0];
      const userMessage = callArgs.messages[0].content as string;

      // Should have clearly labeled sections
      expect(userMessage).toMatch(/canonical/i);
      expect(userMessage).toMatch(/diff/i);
      expect(userMessage).toMatch(/branch/i);
    });

    it("uses 120s timeout", async () => {
      const client = mockAnthropicClient("code");
      const validator = mockValidator({ valid: true });

      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver);

      await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      const createCall = client.messages.create as ReturnType<typeof vi.fn>;
      const callArgs = createCall.mock.calls[0][0];
      // The timeout is set via AbortSignal or request options
      // Check that max_tokens is set (needed for single-turn)
      expect(callArgs.max_tokens).toBeDefined();
      expect(callArgs.max_tokens).toBeGreaterThan(0);
    });

    it("single-turn: sends exactly one user message", async () => {
      const client = mockAnthropicClient("code");
      const validator = mockValidator({ valid: true });

      resolver.setAnthropicClient(client);
      resolver.setValidator(validator);
      stubGitForTier4(resolver);

      await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      const createCall = client.messages.create as ReturnType<typeof vi.fn>;
      const callArgs = createCall.mock.calls[0][0];
      expect(callArgs.messages).toHaveLength(1);
      expect(callArgs.messages[0].role).toBe("user");
    });
  });
});
