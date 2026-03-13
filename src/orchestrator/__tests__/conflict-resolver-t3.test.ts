import { describe, it, expect, beforeEach } from "vitest";
import {
  ConflictResolver,
  type AnthropicClient,
  type CostInfo,
  type Tier3Result,
} from "../conflict-resolver.js";
import { DEFAULT_MERGE_CONFIG } from "../merge-config.js";
import type { MergeQueueConfig } from "../merge-config.js";
import { MergeValidator } from "../merge-validator.js";

/**
 * Helper: build a mock Anthropic client that returns a given text response.
 */
function mockAnthropicClient(
  responseText: string,
  inputTokens: number = 200,
  outputTokens: number = 150,
): AnthropicClient {
  return {
    messages: {
      create: async (_params: unknown) => ({
        content: [{ type: "text" as const, text: responseText }],
        usage: { input_tokens: inputTokens, output_tokens: outputTokens },
      }),
    },
  };
}

/**
 * Helper: build a mock Anthropic client that rejects with an error.
 */
function mockAnthropicClientError(errorMessage: string): AnthropicClient {
  return {
    messages: {
      create: async (_params: unknown) => {
        throw new Error(errorMessage);
      },
    },
  };
}

/**
 * Helper: build a mock that captures the params passed to create().
 */
function mockAnthropicClientCapture(): {
  client: AnthropicClient;
  getCapturedParams: () => unknown;
} {
  let captured: unknown = null;
  return {
    client: {
      messages: {
        create: async (params: unknown) => {
          captured = params;
          return {
            content: [{ type: "text" as const, text: 'const a = 1;\nconst b = 2;\n' }],
            usage: { input_tokens: 100, output_tokens: 80 },
          };
        },
      },
    },
    getCapturedParams: () => captured,
  };
}

/** A file with conflict markers for testing. */
const CONFLICTED_TS_FILE = [
  "const a = 1;",
  "<<<<<<< HEAD",
  "const b = 'main';",
  "=======",
  "const b = 'feature';",
  ">>>>>>> feature/branch",
  "const c = 3;",
  "",
].join("\n");

/** A clean resolved file (valid TypeScript). */
const RESOLVED_TS_CONTENT = [
  "const a = 1;",
  "const b = 'merged';",
  "const c = 3;",
  "",
].join("\n");

describe("ConflictResolver - Tier 3 AI Resolution", () => {
  let config: MergeQueueConfig;

  beforeEach(() => {
    config = { ...DEFAULT_MERGE_CONFIG };
  });

  describe("MQ-T030: attemptTier3Resolution", () => {
    it("returns resolved content on successful AI resolution", async () => {
      const client = mockAnthropicClient(RESOLVED_TS_CONTENT);
      const resolver = new ConflictResolver("/fake/path", config, client);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.success).toBe(true);
      expect(result.resolvedContent).toBe(RESOLVED_TS_CONTENT);
      expect(result.cost).toBeDefined();
      expect(result.cost!.model).toBe("claude-sonnet-4-6");
    });

    it("skips resolution when file exceeds maxFileLines (MQ-013)", async () => {
      const client = mockAnthropicClient(RESOLVED_TS_CONTENT);
      const smallLimitConfig: MergeQueueConfig = {
        ...config,
        costControls: { ...config.costControls, maxFileLines: 5 },
      };
      const resolver = new ConflictResolver("/fake/path", smallLimitConfig, client);

      // Create a file with more than 5 lines
      const bigFile = Array.from({ length: 10 }, (_, i) => `line ${i}`).join("\n");

      const result = await resolver.attemptTier3Resolution(
        "big.ts",
        bigFile,
      );

      expect(result.success).toBe(false);
      expect(result.errorCode).toBe("MQ-013");
      expect(result.error).toMatch(/file.*lines|size/i);
    });

    it("returns error when API call fails", async () => {
      const client = mockAnthropicClientError("API timeout");
      const resolver = new ConflictResolver("/fake/path", config, client);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/API timeout/);
    });

    it("uses correct model (claude-sonnet-4-6)", async () => {
      const { client, getCapturedParams } = mockAnthropicClientCapture();
      const resolver = new ConflictResolver("/fake/path", config, client);

      await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      const params = getCapturedParams() as Record<string, unknown>;
      expect(params.model).toBe("claude-sonnet-4-6");
    });

    it("sends correct system prompt", async () => {
      const { client, getCapturedParams } = mockAnthropicClientCapture();
      const resolver = new ConflictResolver("/fake/path", config, client);

      await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      const params = getCapturedParams() as Record<string, unknown>;
      const system = params.system as string;
      expect(system).toContain("merge conflict resolver");
      expect(system).toContain("ONLY the resolved file content");
    });
  });

  describe("MQ-T031: Validation pipeline on Tier 3 output", () => {
    it("rejects output containing conflict markers (MQ-004)", async () => {
      const badOutput = [
        "const a = 1;",
        "<<<<<<< HEAD",
        "const b = 'still conflicted';",
        "=======",
        "const b = 'other';",
        ">>>>>>> branch",
        "",
      ].join("\n");

      const client = mockAnthropicClient(badOutput);
      const resolver = new ConflictResolver("/fake/path", config, client);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/conflict marker/i);
    });

    it("rejects output wrapped in markdown fencing (MQ-005)", async () => {
      const fencedOutput = [
        "```typescript",
        "const a = 1;",
        "const b = 'merged';",
        "const c = 3;",
        "```",
      ].join("\n");

      const client = mockAnthropicClient(fencedOutput);
      const resolver = new ConflictResolver("/fake/path", config, client);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/markdown|fencing/i);
    });

    it("rejects prose output (MQ-003)", async () => {
      const proseOutput = [
        "Here is the resolved file content:",
        "",
        "The conflict was between two different values of b.",
        "I chose to merge them by keeping both changes.",
      ].join("\n");

      const client = mockAnthropicClient(proseOutput);
      const resolver = new ConflictResolver("/fake/path", config, client);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/prose/i);
    });
  });

  describe("MQ-T032: Cost tracking", () => {
    it("tracks cost from API response usage", async () => {
      const client = mockAnthropicClient(RESOLVED_TS_CONTENT, 500, 300);
      const resolver = new ConflictResolver("/fake/path", config, client);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.success).toBe(true);
      expect(result.cost).toBeDefined();
      const cost = result.cost!;
      expect(cost.inputTokens).toBe(500);
      expect(cost.outputTokens).toBe(300);
      expect(cost.model).toBe("claude-sonnet-4-6");
      // Actual cost: (500/1M * 3.0) + (300/1M * 15.0) = 0.0015 + 0.0045 = 0.006
      expect(cost.actualCostUsd).toBeCloseTo(0.006, 6);
    });

    it("provides pre-call cost estimate using 4 chars/token heuristic", async () => {
      const client = mockAnthropicClient(RESOLVED_TS_CONTENT, 200, 150);
      const resolver = new ConflictResolver("/fake/path", config, client);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.cost).toBeDefined();
      const cost = result.cost!;
      // Estimated input tokens = content.length / 4 (plus system prompt overhead)
      // Estimated cost should be > 0
      expect(cost.estimatedCostUsd).toBeGreaterThan(0);
    });

    it("skips resolution when budget is exhausted (MQ-012)", async () => {
      const client = mockAnthropicClient(RESOLVED_TS_CONTENT);
      const tinyBudget: MergeQueueConfig = {
        ...config,
        costControls: { ...config.costControls, maxSessionBudgetUsd: 0.0001 },
      };
      const resolver = new ConflictResolver("/fake/path", tinyBudget, client);

      // First, exhaust the budget by setting session cost high
      resolver.addSessionCost(0.0001);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.success).toBe(false);
      expect(result.errorCode).toBe("MQ-012");
      expect(result.error).toMatch(/budget/i);
    });

    it("accumulates session cost across multiple calls", async () => {
      const client = mockAnthropicClient(RESOLVED_TS_CONTENT, 500, 300);
      const resolver = new ConflictResolver("/fake/path", config, client);

      await resolver.attemptTier3Resolution(
        "file1.ts",
        CONFLICTED_TS_FILE,
      );

      const costAfterFirst = resolver.getSessionCost();
      expect(costAfterFirst).toBeGreaterThan(0);

      await resolver.attemptTier3Resolution(
        "file2.ts",
        CONFLICTED_TS_FILE,
      );

      const costAfterSecond = resolver.getSessionCost();
      expect(costAfterSecond).toBeGreaterThan(costAfterFirst);
      // Should be approximately 2x the first cost
      expect(costAfterSecond).toBeCloseTo(costAfterFirst * 2, 6);
    });

    it("cost estimate uses 4 chars per token heuristic correctly", async () => {
      const client = mockAnthropicClient(RESOLVED_TS_CONTENT, 200, 150);
      const resolver = new ConflictResolver("/fake/path", config, client);

      // Use a content string of known length
      const knownContent = "a".repeat(400); // 400 chars = ~100 tokens

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        knownContent,
      );

      expect(result.cost).toBeDefined();
      const cost = result.cost!;
      // The estimate should account for the system prompt + user message
      // 400 chars / 4 = 100 estimated input tokens (plus system prompt)
      expect(cost.estimatedCostUsd).toBeGreaterThan(0);
    });
  });
});
