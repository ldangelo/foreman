import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import * as os from "node:os";
import {
  ConflictResolver,
  type Tier4Result,
} from "../conflict-resolver.js";
import { DEFAULT_MERGE_CONFIG } from "../merge-config.js";
import type { MergeQueueConfig } from "../merge-config.js";
import type { MergeValidator, ValidationResult } from "../merge-validator.js";

// ── Mock pi-runner ────────────────────────────────────────────────────────

vi.mock("../pi-sdk-runner.js", () => ({
  runWithPiSdk: vi.fn(),
}));

import { runWithPiSdk } from "../pi-sdk-runner.js";
const mockRunWithPi = vi.mocked(runWithPiSdk);

// ── Helpers ───────────────────────────────────────────────────────────────

const CANONICAL_CONTENT = "const a = 1;\nconst b = 2;\n";
const BRANCH_CONTENT = "const a = 1;\nconst b = 2;\nconst c = 3;\n";
const DIFF_OUTPUT = "--- a/file.ts\n+++ b/file.ts\n@@ -1,2 +1,3 @@\n+const c = 3;\n";
const RESOLVED_CODE = "const a = 1;\nconst b = 2;\nconst c = 3;\n";

function makeSuccessPiResult(costUsd = 0.05) {
  return {
    success: true,
    costUsd,
    turns: 3,
    toolCalls: 5,
    toolBreakdown: { Bash: 3, Write: 2 },
    tokensIn: 2000,
    tokensOut: 1000,
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
function mockPiWritesFile(filePath: string, resolvedContent: string, costUsd = 0.05) {
  mockRunWithPi.mockImplementation(async (opts) => {
    const fullPath = path.join(opts.cwd, filePath);
    await fs.mkdir(path.dirname(fullPath), { recursive: true });
    await fs.writeFile(fullPath, resolvedContent, "utf-8");
    return makeSuccessPiResult(costUsd);
  });
}

function mockValidator(result: ValidationResult = { valid: true }): MergeValidator {
  return {
    validate: vi.fn().mockResolvedValue(result),
    proseDetection: vi.fn().mockReturnValue(false),
    syntaxCheck: vi.fn().mockResolvedValue({ pass: true }),
    conflictMarkerCheck: vi.fn().mockReturnValue(false),
    markdownFencingCheck: vi.fn().mockReturnValue(false),
  } as unknown as MergeValidator;
}

/**
 * Stub the internal git helper for Tier 4 (which reads canonical from git show).
 */
function stubGitForTier4(
  resolver: ConflictResolver,
  options: {
    canonicalContent?: string;
    canonicalFails?: boolean;
  } = {},
): void {
  const {
    canonicalContent = CANONICAL_CONTENT,
    canonicalFails = false,
  } = options;

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = resolver as any;

  r.gitTry = vi.fn().mockImplementation((args: string[]) => {
    if (args[0] === "show") {
      if (canonicalFails) {
        return Promise.resolve({ ok: false, stdout: "", stderr: "not found" });
      }
      return Promise.resolve({ ok: true, stdout: canonicalContent, stderr: "" });
    }
    return Promise.resolve({ ok: true, stdout: "", stderr: "" });
  });

  r.git = vi.fn().mockResolvedValue("");
}

describe("ConflictResolver - Tier 4 Pi Reimagination", () => {
  let config: MergeQueueConfig;
  let tmpDir: string;

  beforeEach(async () => {
    config = {
      ...DEFAULT_MERGE_CONFIG,
      costControls: { maxFileLines: 1000, maxSessionBudgetUsd: 5.0 },
    };
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "cr-t4-test-"));
    vi.clearAllMocks();
  });

  afterEach(async () => {
    await fs.rm(tmpDir, { recursive: true, force: true });
  });

  describe("MQ-T034: Tier 4 resolution implementation", () => {
    it("successfully resolves via Pi reimagination", async () => {
      mockPiWritesFile("src/file.ts", RESOLVED_CODE);
      const resolver = new ConflictResolver(tmpDir, config);
      stubGitForTier4(resolver);
      resolver.setValidator(mockValidator({ valid: true }));

      const result = await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/add-c",
        "main",
      );

      expect(result.success).toBe(true);
      expect(result.resolvedContent).toBe(RESOLVED_CODE);
    });

    it("passes correct model (claude-opus-4-6) to runWithPi", async () => {
      mockPiWritesFile("src/file.ts", RESOLVED_CODE);
      const resolver = new ConflictResolver(tmpDir, config);
      stubGitForTier4(resolver);
      resolver.setValidator(mockValidator({ valid: true }));

      await resolver.attemptTier4Resolution("src/file.ts", "feature/test", "main");

      expect(mockRunWithPi).toHaveBeenCalledOnce();
      expect(mockRunWithPi.mock.calls[0][0].model).toBe("anthropic/claude-opus-4-6");
    });

    it("prompt tells Pi to read git context and write the file", async () => {
      mockPiWritesFile("src/file.ts", RESOLVED_CODE);
      const resolver = new ConflictResolver(tmpDir, config);
      stubGitForTier4(resolver);
      resolver.setValidator(mockValidator({ valid: true }));

      await resolver.attemptTier4Resolution("src/file.ts", "feature/test", "main");

      const prompt = mockRunWithPi.mock.calls[0][0].prompt;
      expect(prompt).toContain("src/file.ts");
      expect(prompt).toContain("git show");
      expect(prompt).toContain("feature/test");
      expect(prompt).toContain("main");
    });

    it("applies file size gate (MQ-013)", async () => {
      const smallConfig: MergeQueueConfig = {
        ...config,
        costControls: { maxFileLines: 5, maxSessionBudgetUsd: 5.0 },
      };
      const resolver = new ConflictResolver(tmpDir, smallConfig);
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
      expect(mockRunWithPi).not.toHaveBeenCalled();
    });

    it("returns error when canonical file cannot be read", async () => {
      const resolver = new ConflictResolver(tmpDir, config);
      stubGitForTier4(resolver, { canonicalFails: true });

      const result = await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/canonical|retrieve/i);
      expect(mockRunWithPi).not.toHaveBeenCalled();
    });

    it("returns error when Pi fails", async () => {
      mockRunWithPi.mockResolvedValue(makeFailPiResult("rate limit hit"));
      const resolver = new ConflictResolver(tmpDir, config);
      stubGitForTier4(resolver);

      const result = await resolver.attemptTier4Resolution(
        "src/file.ts",
        "feature/test",
        "main",
      );

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/rate limit hit/);
    });
  });

  describe("MQ-T035: Validation pipeline", () => {
    it("passes resolved content through validator", async () => {
      mockPiWritesFile("src/file.ts", RESOLVED_CODE);
      const validator = mockValidator({ valid: true });
      const resolver = new ConflictResolver(tmpDir, config);
      stubGitForTier4(resolver);
      resolver.setValidator(validator);

      await resolver.attemptTier4Resolution("src/file.ts", "feature/test", "main");

      expect(validator.validate).toHaveBeenCalledWith("src/file.ts", RESOLVED_CODE, ".ts");
    });

    it("returns failure when validation rejects Pi output", async () => {
      const proseOutput = "Here is what I integrated and why it makes sense.";
      mockPiWritesFile("src/file.ts", proseOutput);
      const validator = mockValidator({ valid: false, reason: "Content appears to be prose" });
      const resolver = new ConflictResolver(tmpDir, config);
      stubGitForTier4(resolver);
      resolver.setValidator(validator);

      const result = await resolver.attemptTier4Resolution("src/file.ts", "feature/test", "main");

      expect(result.success).toBe(false);
      expect(result.error).toContain("prose");
    });
  });

  describe("MQ-T036: Cost tracking with Opus pricing", () => {
    it("tracks cost from Pi result", async () => {
      mockPiWritesFile("src/file.ts", RESOLVED_CODE, 0.05);
      const resolver = new ConflictResolver(tmpDir, config);
      stubGitForTier4(resolver);
      resolver.setValidator(mockValidator({ valid: true }));

      const result = await resolver.attemptTier4Resolution("src/file.ts", "feature/test", "main");

      expect(result.success).toBe(true);
      expect(result.cost).toBeDefined();
      expect(result.cost!.actualCostUsd).toBeCloseTo(0.05, 6);
      expect(result.cost!.model).toBe("anthropic/claude-opus-4-6");
    });

    it("checks budget before invoking Pi", async () => {
      const tightConfig: MergeQueueConfig = {
        ...config,
        costControls: { maxFileLines: 1000, maxSessionBudgetUsd: 0.001 },
      };
      const resolver = new ConflictResolver(tmpDir, tightConfig);
      stubGitForTier4(resolver);
      resolver.addSessionCost(0.001);

      const result = await resolver.attemptTier4Resolution("src/file.ts", "feature/test", "main");

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/budget/i);
      expect(mockRunWithPi).not.toHaveBeenCalled();
    });

    it("accumulates cost across multiple calls", async () => {
      const resolver = new ConflictResolver(tmpDir, config);
      stubGitForTier4(resolver);
      resolver.setValidator(mockValidator({ valid: true }));

      mockPiWritesFile("src/file1.ts", RESOLVED_CODE, 0.05);
      await resolver.attemptTier4Resolution("src/file1.ts", "feature/test", "main");
      const firstCost = resolver.getSessionCost();
      expect(firstCost).toBeGreaterThan(0);

      stubGitForTier4(resolver); // re-stub for second call
      mockPiWritesFile("src/file2.ts", RESOLVED_CODE, 0.05);
      await resolver.attemptTier4Resolution("src/file2.ts", "feature/test", "main");
      const secondCost = resolver.getSessionCost();

      expect(secondCost).toBeGreaterThan(firstCost);
      expect(secondCost).toBeCloseTo(firstCost * 2, 6);
    });
  });
});
