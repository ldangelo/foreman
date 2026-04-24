import { describe, it, expect, beforeEach, vi } from "vitest";
import {
  ConflictResolver,
} from "../conflict-resolver.js";
import { DEFAULT_MERGE_CONFIG } from "../merge-config.js";
import type { MergeQueueConfig } from "../merge-config.js";
import type { MergeValidator, ValidationResult } from "../merge-validator.js";

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

function makeConfig(overrides?: Partial<MergeQueueConfig>): MergeQueueConfig {
  return {
    ...DEFAULT_MERGE_CONFIG,
    costControls: {
      maxFileLines: 1000,
      maxSessionBudgetUsd: 10.0,
    },
    ...overrides,
  };
}

// ── Tests ────────────────────────────────────────────────────────────────

describe("ConflictResolver - Cascade Orchestration (MQ-T038)", () => {
  let resolver: ConflictResolver;
  let config: MergeQueueConfig;

  beforeEach(() => {
    config = makeConfig();
    resolver = new ConflictResolver("/fake/project", config);
    // These tests intentionally exercise the internal fallback helper path.
    // Disable the default backend so local gitTry/git stubs stay authoritative.
    (resolver as unknown as { vcs?: unknown }).vcs = undefined;
  });

  describe("resolveConflicts(): clean merge (Tier 1 success)", () => {
    it("returns immediately without cascading when Tier 1 succeeds", async () => {
      // Stub attemptMerge to succeed
      const attemptMergeSpy = vi
        .spyOn(resolver, "attemptMerge")
        .mockResolvedValue({ success: true, conflictedFiles: [] });

      const result = await resolver.resolveConflicts("feature/foo", "main");

      expect(result.success).toBe(true);
      expect(result.resolvedTiers.size).toBe(0);
      expect(result.fallbackFiles).toEqual([]);
      expect(result.costs).toEqual([]);
      expect(attemptMergeSpy).toHaveBeenCalledOnce();
    });
  });

  describe("resolveConflicts(): multi-file cascade", () => {
    it("cascades per file: file A at Tier 2, file B at Tier 3", async () => {
      const resolvedContent = "const resolved = true;\n";
      resolver.setValidator(mockValidator());

      // Tier 1 fails with two conflicted files
      vi.spyOn(resolver, "attemptMerge").mockResolvedValue({
        success: false,
        conflictedFiles: ["src/fileA.ts", "src/fileB.ts"],
      });

      // Tier 2: fileA succeeds, fileB fails
      vi.spyOn(resolver, "attemptTier2Resolution").mockImplementation(
        async (filePath: string) => {
          if (filePath === "src/fileA.ts") return { success: true };
          return { success: false, reason: "Hunk verification failed" };
        },
      );

      // Tier 3: fileB succeeds (fileA never reaches Tier 3)
      vi.spyOn(resolver, "attemptTier3Resolution").mockResolvedValue({
        success: true,
        resolvedContent,
        cost: {
          inputTokens: 200,
          outputTokens: 150,
          inputCostUsd: 0.0006,
          outputCostUsd: 0.00225,
          totalCostUsd: 0.00285,
          estimatedCostUsd: 0.003,
          actualCostUsd: 0.00285,
          model: "claude-sonnet-4-6",
        },
      });

      // Stub the git and file helpers used during cascade
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const resolverAny = resolver as any;
      resolverAny.gitTry = vi.fn().mockResolvedValue({ ok: true, stdout: "", stderr: "" });
      resolverAny.git = vi.fn().mockResolvedValue("");
      resolverAny.readConflictedFile = vi.fn().mockResolvedValue("conflicted content");
      resolverAny.writeResolvedFile = vi.fn().mockResolvedValue(undefined);

      const result = await resolver.resolveConflicts("feature/multi", "main");

      expect(result.success).toBe(true);
      expect(result.resolvedTiers.get("src/fileA.ts")).toBe(2);
      expect(result.resolvedTiers.get("src/fileB.ts")).toBe(3);
      expect(result.fallbackFiles).toEqual([]);
      expect(result.costs.length).toBe(1); // Only Tier 3 has cost
    });
  });

  describe("resolveConflicts(): fallback aborts entire merge", () => {
    it("aborts merge when a single file reaches fallback (all tiers fail)", async () => {
      vi.spyOn(resolver, "attemptMerge").mockResolvedValue({
        success: false,
        conflictedFiles: ["src/problem.ts"],
      });

      vi.spyOn(resolver, "attemptTier2Resolution").mockResolvedValue({
        success: false,
        reason: "Hunk verification failed",
      });

      vi.spyOn(resolver, "attemptTier3Resolution").mockResolvedValue({
        success: false,
        error: "Pi failed",
      });

      vi.spyOn(resolver, "attemptTier4Resolution").mockResolvedValue({
        success: false,
        error: "Pi failed",
      });

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const resolverAny = resolver as any;
      resolverAny.gitTry = vi.fn().mockResolvedValue({ ok: true, stdout: "", stderr: "" });
      resolverAny.git = vi.fn().mockResolvedValue("");
      resolverAny.readConflictedFile = vi.fn().mockResolvedValue("conflicted content");

      const result = await resolver.resolveConflicts("feature/hard", "main");

      expect(result.success).toBe(false);
      expect(result.fallbackFiles).toContain("src/problem.ts");
      // Should have called merge --abort
      expect(resolverAny.gitTry).toHaveBeenCalledWith(["merge", "--abort"]);
    });

    it("aborts when one file fails all tiers even if others succeed", async () => {
      resolver.setValidator(mockValidator());

      vi.spyOn(resolver, "attemptMerge").mockResolvedValue({
        success: false,
        conflictedFiles: ["src/easy.ts", "src/hard.ts"],
      });

      vi.spyOn(resolver, "attemptTier2Resolution").mockResolvedValue({
        success: false,
        reason: "Failed",
      });

      // Tier 3: easy succeeds, hard fails
      vi.spyOn(resolver, "attemptTier3Resolution").mockImplementation(
        async (filePath: string) => {
          if (filePath === "src/easy.ts") {
            return { success: true, resolvedContent: "ok" };
          }
          return { success: false, error: "Cannot resolve" };
        },
      );

      // Tier 4: hard also fails
      vi.spyOn(resolver, "attemptTier4Resolution").mockResolvedValue({
        success: false,
        error: "Cannot resolve",
      });

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const resolverAny = resolver as any;
      resolverAny.gitTry = vi.fn().mockResolvedValue({ ok: true, stdout: "", stderr: "" });
      resolverAny.git = vi.fn().mockResolvedValue("");
      resolverAny.readConflictedFile = vi.fn().mockResolvedValue("conflicted content");
      resolverAny.writeResolvedFile = vi.fn().mockResolvedValue(undefined);

      const result = await resolver.resolveConflicts("feature/mixed", "main");

      expect(result.success).toBe(false);
      expect(result.fallbackFiles).toContain("src/hard.ts");
      expect(result.resolvedTiers.has("src/hard.ts")).toBe(false);
    });
  });

  describe("resolveConflicts(): resolvedTiers map", () => {
    it("populates resolvedTiers correctly for each file", async () => {
      resolver.setValidator(mockValidator());

      vi.spyOn(resolver, "attemptMerge").mockResolvedValue({
        success: false,
        conflictedFiles: ["a.ts", "b.ts", "c.ts"],
      });

      // a: Tier 2 succeeds
      // b: Tier 2 fails, Tier 3 succeeds
      // c: Tier 2 fails, Tier 3 fails, Tier 4 succeeds
      vi.spyOn(resolver, "attemptTier2Resolution").mockImplementation(
        async (filePath: string) => {
          if (filePath === "a.ts") return { success: true };
          return { success: false, reason: "Failed" };
        },
      );

      vi.spyOn(resolver, "attemptTier3Resolution").mockImplementation(
        async (filePath: string) => {
          if (filePath === "b.ts") {
            return {
              success: true,
              resolvedContent: "resolved",
              cost: {
                inputTokens: 100,
                outputTokens: 80,
                inputCostUsd: 0.0003,
                outputCostUsd: 0.0012,
                totalCostUsd: 0.0015,
                estimatedCostUsd: 0.002,
                actualCostUsd: 0.0015,
                model: "claude-sonnet-4-6",
              },
            };
          }
          return { success: false, error: "Cannot resolve" };
        },
      );

      vi.spyOn(resolver, "attemptTier4Resolution").mockResolvedValue({
        success: true,
        resolvedContent: "resolved by opus",
        cost: {
          inputTokens: 500,
          outputTokens: 300,
          inputCostUsd: 0.0075,
          outputCostUsd: 0.0225,
          totalCostUsd: 0.03,
          estimatedCostUsd: 0.035,
          actualCostUsd: 0.03,
          model: "claude-opus-4-6",
        },
      });

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const resolverAny = resolver as any;
      resolverAny.gitTry = vi.fn().mockResolvedValue({ ok: true, stdout: "", stderr: "" });
      resolverAny.git = vi.fn().mockResolvedValue("");
      resolverAny.readConflictedFile = vi.fn().mockResolvedValue("conflicted content");
      resolverAny.writeResolvedFile = vi.fn().mockResolvedValue(undefined);

      const result = await resolver.resolveConflicts("feature/three", "main");

      expect(result.success).toBe(true);
      expect(result.resolvedTiers.get("a.ts")).toBe(2);
      expect(result.resolvedTiers.get("b.ts")).toBe(3);
      expect(result.resolvedTiers.get("c.ts")).toBe(4);
      expect(result.fallbackFiles).toEqual([]);
    });
  });

  describe("resolveConflicts(): cost accumulation", () => {
    it("accumulates costs from Tier 3 and Tier 4 across files", async () => {
      resolver.setValidator(mockValidator());

      const tier3Cost = {
        inputTokens: 200,
        outputTokens: 150,
        inputCostUsd: 0.0006,
        outputCostUsd: 0.00225,
        totalCostUsd: 0.00285,
        estimatedCostUsd: 0.003,
        actualCostUsd: 0.00285,
        model: "claude-sonnet-4-6",
      };

      const tier4Cost = {
        inputTokens: 500,
        outputTokens: 300,
        inputCostUsd: 0.0075,
        outputCostUsd: 0.0225,
        totalCostUsd: 0.03,
        estimatedCostUsd: 0.035,
        actualCostUsd: 0.03,
        model: "claude-opus-4-6",
      };

      vi.spyOn(resolver, "attemptMerge").mockResolvedValue({
        success: false,
        conflictedFiles: ["x.ts", "y.ts"],
      });

      vi.spyOn(resolver, "attemptTier2Resolution").mockResolvedValue({
        success: false,
        reason: "Failed",
      });

      vi.spyOn(resolver, "attemptTier3Resolution").mockImplementation(
        async (filePath: string) => {
          if (filePath === "x.ts") {
            return { success: true, resolvedContent: "resolved", cost: tier3Cost };
          }
          return { success: false, error: "Cannot resolve", cost: tier3Cost };
        },
      );

      vi.spyOn(resolver, "attemptTier4Resolution").mockResolvedValue({
        success: true,
        resolvedContent: "resolved",
        cost: tier4Cost,
      });

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const resolverAny = resolver as any;
      resolverAny.gitTry = vi.fn().mockResolvedValue({ ok: true, stdout: "", stderr: "" });
      resolverAny.git = vi.fn().mockResolvedValue("");
      resolverAny.readConflictedFile = vi.fn().mockResolvedValue("conflicted content");
      resolverAny.writeResolvedFile = vi.fn().mockResolvedValue(undefined);

      const result = await resolver.resolveConflicts("feature/costly", "main");

      expect(result.success).toBe(true);
      // x.ts: Tier 3 cost, y.ts: Tier 3 cost (failed attempt) + Tier 4 cost
      expect(result.costs.length).toBe(3);
    });
  });

  describe("resolveConflicts(): Tier 3 and Tier 4 always attempted (Pi is always available)", () => {
    it("tries Tier 3 then Tier 4 when Tier 2 fails", async () => {
      const tier3Spy = vi.spyOn(resolver, "attemptTier3Resolution").mockResolvedValue({
        success: false,
        error: "Pi Tier 3 failed",
      });
      const tier4Spy = vi.spyOn(resolver, "attemptTier4Resolution").mockResolvedValue({
        success: false,
        error: "Pi Tier 4 failed",
      });

      vi.spyOn(resolver, "attemptMerge").mockResolvedValue({
        success: false,
        conflictedFiles: ["src/hard.ts"],
      });
      vi.spyOn(resolver, "attemptTier2Resolution").mockResolvedValue({
        success: false,
        reason: "Failed",
      });

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const resolverAny = resolver as any;
      resolverAny.gitTry = vi.fn().mockResolvedValue({ ok: true, stdout: "", stderr: "" });
      resolverAny.git = vi.fn().mockResolvedValue("");
      resolverAny.readConflictedFile = vi.fn().mockResolvedValue("conflicted content");

      const result = await resolver.resolveConflicts("feature/hard", "main");

      expect(result.success).toBe(false);
      expect(result.fallbackFiles).toContain("src/hard.ts");
      expect(tier3Spy).toHaveBeenCalled();
      expect(tier4Spy).toHaveBeenCalled();
    });
  });
});

describe("ConflictResolver - Fallback Handler (MQ-T039)", () => {
  let resolver: ConflictResolver;
  let config: MergeQueueConfig;

  beforeEach(() => {
    config = makeConfig();
    resolver = new ConflictResolver("/fake/project", config);
  });

  it("calls gh pr create with structured title and body", async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const resolverAny = resolver as any;

    // Mock execFileAsync via the gh helper
    resolverAny.execGh = vi.fn().mockResolvedValue("https://github.com/org/repo/pull/42");

    const resolvedTiers = new Map<string, number>();
    resolvedTiers.set("src/easy.ts", 2);

    const result = await resolver.handleFallback(
      "feature/conflict",
      "main",
      ["src/hard.ts"],
      resolvedTiers,
    );

    expect(result.prUrl).toBe("https://github.com/org/repo/pull/42");
    expect(result.error).toBeUndefined();

    // Verify gh was called with proper args
    const ghCall = resolverAny.execGh.mock.calls[0];
    expect(ghCall[0]).toContain("pr");
    expect(ghCall[0]).toContain("create");
  });

  it("returns error info when gh pr create fails", async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const resolverAny = resolver as any;
    resolverAny.execGh = vi.fn().mockRejectedValue(new Error("gh not installed"));

    const result = await resolver.handleFallback(
      "feature/broken",
      "main",
      ["src/broken.ts"],
      new Map(),
    );

    expect(result.prUrl).toBeUndefined();
    expect(result.error).toContain("gh not installed");
  });

  it("includes per-file tier attempts in PR body", async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const resolverAny = resolver as any;
    let capturedArgs: string[] = [];
    resolverAny.execGh = vi.fn().mockImplementation((args: string[]) => {
      capturedArgs = args;
      return Promise.resolve("https://github.com/org/repo/pull/99");
    });

    const resolvedTiers = new Map<string, number>();
    resolvedTiers.set("src/ok.ts", 3);

    await resolver.handleFallback(
      "feature/partial",
      "main",
      ["src/fail.ts"],
      resolvedTiers,
    );

    // Find the --body arg
    const bodyIdx = capturedArgs.indexOf("--body");
    expect(bodyIdx).toBeGreaterThan(-1);
    const body = capturedArgs[bodyIdx + 1];
    expect(body).toContain("src/fail.ts");
    expect(body).toContain("MQ-018");
  });
});
