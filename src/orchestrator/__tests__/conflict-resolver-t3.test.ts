import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import * as os from "node:os";
import {
  ConflictResolver,
  type CostInfo,
  type Tier3Result,
} from "../conflict-resolver.js";
import { DEFAULT_MERGE_CONFIG } from "../merge-config.js";
import type { MergeQueueConfig } from "../merge-config.js";
import { MergeValidator } from "../merge-validator.js";

// ── Mock pi-runner ────────────────────────────────────────────────────────

vi.mock("../pi-sdk-runner.js", () => ({
  runWithPiSdk: vi.fn(),
}));

import { runWithPiSdk } from "../pi-sdk-runner.js";
const mockRunWithPi = vi.mocked(runWithPiSdk);

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

// ── Helpers ───────────────────────────────────────────────────────────────

function makeSuccessPiResult(costUsd = 0.006) {
  return {
    success: true,
    costUsd,
    turns: 2,
    toolCalls: 3,
    toolBreakdown: { Read: 1, Write: 2 },
    tokensIn: 1000,
    tokensOut: 500,
  };
}

function makeFailPiResult(errorMessage = "Pi session failed") {
  return {
    success: false,
    costUsd: 0,
    turns: 1,
    toolCalls: 0,
    toolBreakdown: {},
    tokensIn: 0,
    tokensOut: 0,
    errorMessage,
  };
}

/**
 * Mock runWithPi to write resolvedContent to opts.cwd/filePath and succeed.
 */
function mockPiWritesFile(filePath: string, resolvedContent: string, costUsd = 0.006) {
  mockRunWithPi.mockImplementation(async (opts) => {
    const fullPath = path.join(opts.cwd, filePath);
    await fs.mkdir(path.dirname(fullPath), { recursive: true });
    await fs.writeFile(fullPath, resolvedContent, "utf-8");
    return makeSuccessPiResult(costUsd);
  });
}

describe("ConflictResolver - Tier 3 Pi Resolution", () => {
  let config: MergeQueueConfig;
  let tmpDir: string;

  beforeEach(async () => {
    config = { ...DEFAULT_MERGE_CONFIG };
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "cr-t3-test-"));
    vi.clearAllMocks();
  });

  afterEach(async () => {
    await fs.rm(tmpDir, { recursive: true, force: true });
  });

  describe("MQ-T030: attemptTier3Resolution", () => {
    it("returns resolved content on successful Pi resolution", async () => {
      mockPiWritesFile("shared.ts", RESOLVED_TS_CONTENT);
      const resolver = new ConflictResolver(tmpDir, config);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.success).toBe(true);
      expect(result.resolvedContent).toBe(RESOLVED_TS_CONTENT);
      expect(result.cost).toBeDefined();
      expect(result.cost!.model).toBe("anthropic/claude-sonnet-4-6");
    });

    it("passes the file path and cwd to runWithPi", async () => {
      mockPiWritesFile("src/shared.ts", RESOLVED_TS_CONTENT);
      const resolver = new ConflictResolver(tmpDir, config);

      await resolver.attemptTier3Resolution("src/shared.ts", CONFLICTED_TS_FILE);

      expect(mockRunWithPi).toHaveBeenCalledOnce();
      const callOpts = mockRunWithPi.mock.calls[0][0];
      expect(callOpts.cwd).toBe(tmpDir);
      expect(callOpts.model).toBe("anthropic/claude-sonnet-4-6");
      expect(callOpts.prompt).toContain("src/shared.ts");
    });

    it("prompt instructs Pi to resolve conflict markers", async () => {
      mockPiWritesFile("shared.ts", RESOLVED_TS_CONTENT);
      const resolver = new ConflictResolver(tmpDir, config);

      await resolver.attemptTier3Resolution("shared.ts", CONFLICTED_TS_FILE);

      const prompt = mockRunWithPi.mock.calls[0][0].prompt;
      expect(prompt).toContain("conflict");
      expect(prompt).toContain("shared.ts");
      expect(prompt).toContain("ZERO conflict markers");
    });

    it("writes conflicted content to disk before invoking Pi", async () => {
      const writtenFiles: string[] = [];
      mockRunWithPi.mockImplementation(async (opts) => {
        // Check the file was written
        const content = await fs.readFile(path.join(opts.cwd, "shared.ts"), "utf-8");
        writtenFiles.push(content);
        // Write resolved content
        await fs.writeFile(path.join(opts.cwd, "shared.ts"), RESOLVED_TS_CONTENT);
        return makeSuccessPiResult();
      });

      const resolver = new ConflictResolver(tmpDir, config);
      await resolver.attemptTier3Resolution("shared.ts", CONFLICTED_TS_FILE);

      expect(writtenFiles).toHaveLength(1);
      expect(writtenFiles[0]).toBe(CONFLICTED_TS_FILE);
    });

    it("skips resolution when file exceeds maxFileLines (MQ-013)", async () => {
      const smallLimitConfig: MergeQueueConfig = {
        ...config,
        costControls: { ...config.costControls, maxFileLines: 5 },
      };
      const resolver = new ConflictResolver(tmpDir, smallLimitConfig);

      const bigFile = Array.from({ length: 10 }, (_, i) => `line ${i}`).join("\n");

      const result = await resolver.attemptTier3Resolution("big.ts", bigFile);

      expect(result.success).toBe(false);
      expect(result.errorCode).toBe("MQ-013");
      expect(result.error).toMatch(/file.*lines|size/i);
      expect(mockRunWithPi).not.toHaveBeenCalled();
    });

    it("returns error when Pi fails", async () => {
      mockRunWithPi.mockResolvedValue(makeFailPiResult("API timeout"));
      const resolver = new ConflictResolver(tmpDir, config);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/API timeout/);
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

      mockPiWritesFile("shared.ts", badOutput);
      const resolver = new ConflictResolver(tmpDir, config);

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

      mockPiWritesFile("shared.ts", fencedOutput);
      const resolver = new ConflictResolver(tmpDir, config);

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

      mockPiWritesFile("shared.ts", proseOutput);
      const resolver = new ConflictResolver(tmpDir, config);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/prose/i);
    });
  });

  describe("MQ-T032: Cost tracking", () => {
    it("tracks cost from Pi result", async () => {
      mockPiWritesFile("shared.ts", RESOLVED_TS_CONTENT, 0.006);
      const resolver = new ConflictResolver(tmpDir, config);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.success).toBe(true);
      expect(result.cost).toBeDefined();
      const cost = result.cost!;
      expect(cost.actualCostUsd).toBeCloseTo(0.006, 6);
      expect(cost.model).toBe("anthropic/claude-sonnet-4-6");
    });

    it("provides pre-call cost estimate using 4 chars/token heuristic", async () => {
      mockPiWritesFile("shared.ts", RESOLVED_TS_CONTENT);
      const resolver = new ConflictResolver(tmpDir, config);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.cost).toBeDefined();
      expect(result.cost!.estimatedCostUsd).toBeGreaterThan(0);
    });

    it("skips resolution when budget is exhausted (MQ-012)", async () => {
      const tinyBudget: MergeQueueConfig = {
        ...config,
        costControls: { ...config.costControls, maxSessionBudgetUsd: 0.0001 },
      };
      const resolver = new ConflictResolver(tmpDir, tinyBudget);
      resolver.addSessionCost(0.0001);

      const result = await resolver.attemptTier3Resolution(
        "shared.ts",
        CONFLICTED_TS_FILE,
      );

      expect(result.success).toBe(false);
      expect(result.errorCode).toBe("MQ-012");
      expect(result.error).toMatch(/budget/i);
      expect(mockRunWithPi).not.toHaveBeenCalled();
    });

    it("accumulates session cost across multiple calls", async () => {
      mockPiWritesFile("file1.ts", RESOLVED_TS_CONTENT, 0.006);
      const resolver = new ConflictResolver(tmpDir, config);

      await resolver.attemptTier3Resolution("file1.ts", CONFLICTED_TS_FILE);
      const costAfterFirst = resolver.getSessionCost();
      expect(costAfterFirst).toBeGreaterThan(0);

      mockPiWritesFile("file2.ts", RESOLVED_TS_CONTENT, 0.006);
      await resolver.attemptTier3Resolution("file2.ts", CONFLICTED_TS_FILE);

      const costAfterSecond = resolver.getSessionCost();
      expect(costAfterSecond).toBeGreaterThan(costAfterFirst);
      expect(costAfterSecond).toBeCloseTo(costAfterFirst * 2, 6);
    });
  });
});
