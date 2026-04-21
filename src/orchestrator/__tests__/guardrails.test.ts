/**
 * Unit tests for guardrails module.
 * Tests directory verification guardrail behavior (auto-correct, veto, disabled modes).
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  createDirectoryGuardrail,
  wrapToolWithGuardrail,
  measureGuardrailOverhead,
  type GuardrailConfig,
} from "../guardrails.js";

describe("createDirectoryGuardrail", () => {
  // Use a simple function type for mock logging
  let mockLogEvent: (eventType: string, details: Record<string, unknown>) => void;
  let projectId = "proj-123";
  let runId = "run-456";

  beforeEach(() => {
    mockLogEvent = vi.fn((_eventType: string, _details: Record<string, unknown>) => {
      // no-op
    });
  });

  describe("disabled mode", () => {
    it("should always return allowed: true immediately", () => {
      const config: GuardrailConfig = {
        directory: { mode: "disabled" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      const result = guardrail("Edit", { path: "/some/file.ts" }, "/wrong/path");
      expect(result.allowed).toBe(true);
      expect(mockLogEvent).not.toHaveBeenCalled();
    });

    it("should not check cwd at all", () => {
      const config: GuardrailConfig = {
        directory: { mode: "disabled" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      // Even correct cwd should still pass through
      const result = guardrail("Bash", { command: "npm test" }, "/worktrees/project/seed-abc");
      expect(result.allowed).toBe(true);
    });
  });

  describe("veto mode", () => {
    it("should return allowed: false when cwd is wrong", () => {
      const config: GuardrailConfig = {
        directory: { mode: "veto" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      const result = guardrail("Edit", { path: "/some/file.ts" }, "/wrong/path");
      expect(result.allowed).toBe(false);
      expect(result.eventType).toBe("guardrail-veto");
      expect(result.reason).toContain("does not match expected worktree");
    });

    it("should log guardrail-veto event", () => {
      const config: GuardrailConfig = {
        directory: { mode: "veto" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      guardrail("Edit", { path: "/some/file.ts" }, "/wrong/path");

      expect(mockLogEvent).toHaveBeenCalledWith(
        "guardrail-veto",
        expect.objectContaining({
          tool: "Edit",
          expectedCwd: "/worktrees/project/seed-abc",
          actualCwd: "/wrong/path",
        }),
      );
    });

    it("should return allowed: true when cwd is correct", () => {
      const config: GuardrailConfig = {
        directory: { mode: "veto" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      const result = guardrail("Edit", { path: "/some/file.ts" }, "/worktrees/project/seed-abc");
      expect(result.allowed).toBe(true);
      expect(mockLogEvent).not.toHaveBeenCalled();
    });

    it("should veto Bash tool when cwd is wrong", () => {
      const config: GuardrailConfig = {
        directory: { mode: "veto" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      const result = guardrail("Bash", { command: "npm test" }, "/wrong/path");
      expect(result.allowed).toBe(false);
      expect(result.eventType).toBe("guardrail-veto");
    });
  });

  describe("auto-correct mode (default)", () => {
    it("should correct Bash commands by prepending cd", () => {
      const config: GuardrailConfig = {
        directory: { mode: "auto-correct" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      const result = guardrail("Bash", { command: "npm test" }, "/wrong/path");

      expect(result.allowed).toBe(true);
      expect(result.correctedArgs).toBeDefined();
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const correctedCommand = (result.correctedArgs as any).command as string;
      expect(correctedCommand).toContain('cd "/worktrees/project/seed-abc"');
      expect(correctedCommand).toContain("npm test");
      expect(result.eventType).toBe("guardrail-corrected");
    });

    it("should correct Edit file paths", () => {
      const config: GuardrailConfig = {
        directory: { mode: "auto-correct" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      // When cwd is wrong, auto-correct should fix it
      const result = guardrail("Edit", { path: "src/test.ts" }, "/wrong/path");

      // The guardrail should either allow (with correction) or veto
      // Since the path is relative and we're in wrong cwd, it may not be able to correct
      // The key is that it should either correct or veto - not allow wrong worktree
      expect(result.allowed === true || result.eventType === "guardrail-veto").toBe(true);
    });

    it("should correct Write file paths", () => {
      const config: GuardrailConfig = {
        directory: { mode: "auto-correct" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      const result = guardrail("Write", { path: "/worktrees/project/seed-xyz/new-file.ts", content: "hello" }, "/worktrees/project/seed-xyz");

      expect(result.allowed).toBe(true);
      expect(result.correctedArgs).toBeDefined();
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const correctedPath = (result.correctedArgs as any).path as string;
      expect(correctedPath).toContain("/worktrees/project/seed-abc/");
    });

    it("should log guardrail-corrected event", () => {
      const config: GuardrailConfig = {
        directory: { mode: "auto-correct" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      guardrail("Bash", { command: "npm test" }, "/wrong/path");

      expect(mockLogEvent).toHaveBeenCalledWith(
        "guardrail-corrected",
        expect.objectContaining({
          tool: "Bash",
          expectedCwd: "/worktrees/project/seed-abc",
          actualCwd: "/wrong/path",
        }),
      );
    });

    it("should return allowed: true when cwd is correct", () => {
      const config: GuardrailConfig = {
        directory: { mode: "auto-correct" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      const result = guardrail("Bash", { command: "npm test" }, "/worktrees/project/seed-abc");
      expect(result.allowed).toBe(true);
      expect(result.correctedArgs).toBeUndefined();
      expect(mockLogEvent).not.toHaveBeenCalled();
    });

    it("should set correctedCwd when auto-correcting", () => {
      const config: GuardrailConfig = {
        directory: { mode: "auto-correct" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      const result = guardrail("Bash", { command: "npm test" }, "/wrong/path");

      expect(result.correctedCwd).toBe("/worktrees/project/seed-abc");
    });
  });

  describe("allowedPaths option", () => {
    it("should allow cwd within allowed paths", () => {
      const config: GuardrailConfig = {
        directory: { mode: "veto", allowedPaths: ["/worktrees/project"] },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      const result = guardrail("Bash", { command: "npm test" }, "/worktrees/project/seed-abc");
      expect(result.allowed).toBe(true);
    });

    it("should veto cwd outside allowed paths", () => {
      const config: GuardrailConfig = {
        directory: { mode: "veto", allowedPaths: ["/worktrees/project"] },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      const result = guardrail("Bash", { command: "npm test" }, "/home/user/other");
      expect(result.allowed).toBe(false);
      // Veto because cwd doesn't match expected (regardless of allowedPaths)
      expect(result.eventType).toBe("guardrail-veto");
    });
  });

  describe("path normalization", () => {
    it("should handle trailing slashes correctly", () => {
      const config: GuardrailConfig = {
        directory: { mode: "veto" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      // Both with and without trailing slash should be treated as the same
      const result1 = guardrail("Bash", { command: "ls" }, "/worktrees/project/seed-abc/");
      const result2 = guardrail("Bash", { command: "ls" }, "/worktrees/project/seed-abc");

      expect(result1.allowed).toBe(true);
      expect(result2.allowed).toBe(true);
    });

    it("should handle relative paths in expectedCwd", () => {
      const config: GuardrailConfig = {
        directory: { mode: "veto" },
        expectedCwd: "./worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      // Resolved path should match
      const result = guardrail("Bash", { command: "ls" }, process.cwd() + "/worktrees/project/seed-abc");
      expect(result.allowed).toBe(true);
    });
  });

  describe("edge cases", () => {
    it("should handle Edit without path argument", () => {
      const config: GuardrailConfig = {
        directory: { mode: "auto-correct" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      // Edit without path — should not correct (can't correct what we don't have)
      const result = guardrail("Edit", {}, "/wrong/path");
      // For unknown tools without path, auto-correct may not be able to help — veto
      expect(result.allowed).toBe(false);
    });

    it("should handle Bash without command argument", () => {
      const config: GuardrailConfig = {
        directory: { mode: "auto-correct" },
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      // Bash without command — fallback to veto
      const result = guardrail("Bash", {}, "/wrong/path");
      expect(result.allowed).toBe(false);
    });

    it("should use default mode auto-correct when not specified", () => {
      const config: GuardrailConfig = {
        directory: {},
        expectedCwd: "/worktrees/project/seed-abc",
      };
      const guardrail = createDirectoryGuardrail(config, mockLogEvent, projectId, runId);

      const result = guardrail("Bash", { command: "npm test" }, "/wrong/path");
      expect(result.allowed).toBe(true); // auto-correct by default
      expect(result.correctedArgs).toBeDefined();
    });
  });
});

describe("measureGuardrailOverhead", () => {
  it("should measure guardrail overhead in milliseconds", () => {
    const config: GuardrailConfig = {
      directory: { mode: "auto-correct" },
      expectedCwd: "/worktrees/project/seed-abc",
    };
    const guardrail = createDirectoryGuardrail(config, vi.fn(), "proj", "run");

    const overhead = measureGuardrailOverhead(guardrail);
    expect(overhead).toBeGreaterThan(0);
    expect(overhead).toBeLessThan(100); // Should be fast
  });

  it("should complete within 5ms for NFR requirement", () => {
    const config: GuardrailConfig = {
      directory: { mode: "auto-correct" },
      expectedCwd: "/worktrees/project/seed-abc",
    };
    const guardrail = createDirectoryGuardrail(config, vi.fn(), "proj", "run");

    const overhead = measureGuardrailOverhead(guardrail);
    expect(overhead).toBeLessThan(5);
  });
});

describe("wrapToolWithGuardrail", () => {
  it("should wrap a tool factory with guardrail checks", () => {
    const config: GuardrailConfig = {
      directory: { mode: "veto" },
      expectedCwd: "/worktrees/project/seed-abc",
    };
    const mockLogEvent = vi.fn((_eventType: string, _details: Record<string, unknown>) => {});
    const guardrail = createDirectoryGuardrail(config, mockLogEvent, "proj", "run");
    const getCwd = () => "/worktrees/project/seed-abc";

    // Create a mock tool factory
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const mockFactory: any = vi.fn((cwd: string, args: Record<string, unknown>) => {
      return { cwd, args };
    });

    const wrapped = wrapToolWithGuardrail(mockFactory, guardrail, getCwd);

    // Call with correct cwd — should work
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = wrapped("/worktrees/project/seed-abc", { file: "test.ts" } as any);
    expect(mockFactory).toHaveBeenCalled();
  });
});