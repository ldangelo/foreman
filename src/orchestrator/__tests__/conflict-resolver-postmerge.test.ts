import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  ConflictResolver,
  type PostMergeTestResult,
} from "../conflict-resolver.js";
import { DEFAULT_MERGE_CONFIG } from "../merge-config.js";
import type { MergeQueueConfig } from "../merge-config.js";

/**
 * MQ-T042 / MQ-T043: Post-merge test runner tests.
 *
 * The runPostMergeTests() method should:
 * - Skip tests when noTests flag is true
 * - Skip tests when only Tier 1/2 resolution was used
 * - Run tests when any file was resolved at Tier 3 or 4
 * - Return passed: true on test success
 * - Revert merge commit (git reset --hard HEAD~1) and return MQ-007 on failure
 */

// We mock node:child_process execFile to control test command execution.
// Note: execFile (not exec) is used intentionally -- it does not invoke a
// shell and is safe against command-injection. The mock is purely for test
// isolation so no real processes are spawned.
vi.mock("node:child_process", () => {
  const actual = vi.importActual("node:child_process");
  return {
    ...actual,
    execFile: vi.fn(),
  };
});

import { execFile } from "node:child_process";

const execFileMock = vi.mocked(execFile);

/** Helper to make execFile resolve or reject for specific commands. */
function setupExecFile(options: {
  testPasses?: boolean;
  testStdout?: string;
  testStderr?: string;
}): void {
  const { testPasses = true, testStdout = "", testStderr = "" } = options;

  execFileMock.mockImplementation(
    (cmd: string, args?: readonly string[] | unknown, ...rest: unknown[]) => {
      const callback =
        typeof rest[rest.length - 1] === "function"
          ? (rest[rest.length - 1] as Function)
          : typeof args === "function"
            ? (args as Function)
            : rest.find((r) => typeof r === "function") as
                | Function
                | undefined;

      // Git commands always succeed
      if (cmd === "git") {
        if (callback) {
          callback(null, { stdout: "", stderr: "" });
        }
        return {} as ReturnType<typeof execFile>;
      }

      // Test command
      if (testPasses) {
        if (callback) {
          callback(null, { stdout: testStdout, stderr: testStderr });
        }
      } else {
        const err = new Error("test failed") as Error & {
          stdout: string;
          stderr: string;
          code: number;
        };
        err.stdout = testStdout || "FAIL src/foo.test.ts";
        err.stderr = testStderr || "Test suite failed to run";
        err.code = 1;
        if (callback) {
          callback(err, { stdout: err.stdout, stderr: err.stderr });
        }
      }

      return {} as ReturnType<typeof execFile>;
    },
  );
}

describe("ConflictResolver.runPostMergeTests", () => {
  let resolver: ConflictResolver;
  let config: MergeQueueConfig;
  let mockVcs: { rollbackFailedMerge: ReturnType<typeof vi.fn> };

  beforeEach(() => {
    vi.clearAllMocks();
    config = { ...DEFAULT_MERGE_CONFIG };
    mockVcs = {
      rollbackFailedMerge: vi.fn().mockResolvedValue(undefined),
    };
    resolver = new ConflictResolver("/test/project", config, mockVcs as any);
  });

  describe("skipping conditions", () => {
    it("should skip tests when noTests flag is true", async () => {
      const tiers = new Map<string, number>([["file.ts", 3]]);
      const result = await resolver.runPostMergeTests(tiers, "npm test", true);

      expect(result.passed).toBe(true);
      expect(result.skipped).toBe(true);
      expect(result.skipReason).toContain("--no-tests");
    });

    it("should skip tests for Tier 1 only merges", async () => {
      const tiers = new Map<string, number>([["file.ts", 1]]);
      setupExecFile({ testPasses: true });
      const result = await resolver.runPostMergeTests(
        tiers,
        "npm test",
        false,
      );

      expect(result.passed).toBe(true);
      expect(result.skipped).toBe(true);
      expect(result.skipReason).toContain("No AI resolution");
    });

    it("should skip tests for Tier 2 only merges", async () => {
      const tiers = new Map<string, number>([
        ["file1.ts", 2],
        ["file2.ts", 2],
      ]);
      setupExecFile({ testPasses: true });
      const result = await resolver.runPostMergeTests(
        tiers,
        "npm test",
        false,
      );

      expect(result.passed).toBe(true);
      expect(result.skipped).toBe(true);
      expect(result.skipReason).toContain("No AI resolution");
    });

    it("should skip tests for empty tier map (clean merge)", async () => {
      const tiers = new Map<string, number>();
      setupExecFile({ testPasses: true });
      const result = await resolver.runPostMergeTests(
        tiers,
        "npm test",
        false,
      );

      expect(result.passed).toBe(true);
      expect(result.skipped).toBe(true);
      expect(result.skipReason).toContain("No AI resolution");
    });
  });

  describe("running tests for AI resolution", () => {
    it("should run tests when any file used Tier 3 resolution", async () => {
      const tiers = new Map<string, number>([["file.ts", 3]]);
      setupExecFile({ testPasses: true });
      const result = await resolver.runPostMergeTests(
        tiers,
        "npm test",
        false,
      );

      expect(result.passed).toBe(true);
      expect(result.skipped).toBe(false);
    });

    it("should run tests when any file used Tier 4 resolution", async () => {
      const tiers = new Map<string, number>([["file.ts", 4]]);
      setupExecFile({ testPasses: true });
      const result = await resolver.runPostMergeTests(
        tiers,
        "npm test",
        false,
      );

      expect(result.passed).toBe(true);
      expect(result.skipped).toBe(false);
    });

    it("should run tests when mixed tiers include Tier 3 or 4", async () => {
      const tiers = new Map<string, number>([
        ["file1.ts", 1],
        ["file2.ts", 2],
        ["file3.ts", 3],
      ]);
      setupExecFile({ testPasses: true });
      const result = await resolver.runPostMergeTests(
        tiers,
        "npm test",
        false,
      );

      expect(result.passed).toBe(true);
      expect(result.skipped).toBe(false);
    });
  });

  describe("test failure handling", () => {
    it("should revert merge and return MQ-007 on test failure", async () => {
      const tiers = new Map<string, number>([["file.ts", 3]]);
      setupExecFile({
        testPasses: false,
        testStdout: "FAIL src/foo.test.ts",
        testStderr: "Expected true to be false",
      });
      const result = await resolver.runPostMergeTests(
        tiers,
        "npm test",
        false,
      );

      expect(result.passed).toBe(false);
      expect(result.skipped).toBe(false);
      expect(result.errorCode).toBe("MQ-007");
      expect(result.output).toBeDefined();
      expect(result.output).toContain("FAIL");

      expect(mockVcs.rollbackFailedMerge).toHaveBeenCalledWith("/test/project", "HEAD~1");
    });

    it("should truncate output to 2000 characters on failure", async () => {
      const tiers = new Map<string, number>([["file.ts", 4]]);
      const longOutput = "x".repeat(3000);
      setupExecFile({
        testPasses: false,
        testStdout: longOutput,
        testStderr: "",
      });
      const result = await resolver.runPostMergeTests(
        tiers,
        "npm test",
        false,
      );

      expect(result.passed).toBe(false);
      expect(result.output).toBeDefined();
      expect(result.output!.length).toBeLessThanOrEqual(2000);
    });
  });

  describe("custom test command", () => {
    it("should use the provided test command", async () => {
      const tiers = new Map<string, number>([["file.ts", 3]]);
      setupExecFile({ testPasses: true });
      const result = await resolver.runPostMergeTests(
        tiers,
        "npx vitest run",
        false,
      );

      expect(result.passed).toBe(true);
      expect(result.skipped).toBe(false);

      // Verify the correct command was invoked
      const nonGitCalls = execFileMock.mock.calls.filter(
        (call) => call[0] !== "git",
      );
      expect(nonGitCalls.length).toBeGreaterThan(0);
      expect(nonGitCalls[0][0]).toBe("npx");
      expect(nonGitCalls[0][1]).toEqual(["vitest", "run"]);
    });
  });
});
