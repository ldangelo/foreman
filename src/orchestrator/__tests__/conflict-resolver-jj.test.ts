/**
 * Tests for ConflictResolver Jujutsu Adaptation (TRD-032-TEST).
 *
 * Acceptance Criteria:
 *   AC-T-032-1: Given a jj-format conflict file, when attemptTier3Resolution() runs,
 *               then conflict regions are identified and resolution is attempted.
 *   AC-T-032-2: Given a git-format conflict file and GitBackend, when
 *               attemptTier3Resolution() runs, then resolution succeeds (backward compat).
 *   AC-T-032-3: Given a JujutsuBackend, when attemptTier3Resolution() builds the prompt,
 *               then the prompt mentions jj/jujutsu conflict format; given GitBackend,
 *               the prompt mentions git conflict format.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import * as os from "node:os";
import { ConflictResolver } from "../conflict-resolver.js";
import { DEFAULT_MERGE_CONFIG } from "../merge-config.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

// ── Mock pi-sdk-runner so tests don't need a real Pi session ─────────────

vi.mock("../pi-sdk-runner.js", () => ({
  runWithPiSdk: vi.fn(),
}));

import { runWithPiSdk } from "../pi-sdk-runner.js";
const mockRunWithPi = vi.mocked(runWithPiSdk);

// ── Test config (no syntax checkers to avoid slow tsc/node invocations) ──

/**
 * A merge config without syntax checkers so tests run fast.
 * Syntax-checker behavior is covered by merge-validator tests.
 */
const TEST_CONFIG = {
  ...DEFAULT_MERGE_CONFIG,
  syntaxCheckers: {} as Record<string, string>,
};

// ── Conflict file fixtures ────────────────────────────────────────────────

/** Git-format conflict markers (classic HEAD / branch). */
const GIT_CONFLICTED_FILE = [
  "const a = 1;",
  "<<<<<<< HEAD",
  "const b = 'main';",
  "=======",
  "const b = 'feature';",
  ">>>>>>> feature/branch",
  "const c = 3;",
  "",
].join("\n");

/**
 * Jujutsu-format conflict markers.
 * Uses <<<<<<< / %%%%%%% / >>>>>>> delimiters.
 */
const JJ_CONFLICTED_FILE = [
  "const a = 1;",
  "<<<<<<< ours",
  "const b = 'main';",
  "%%%%%%%",
  "const b = 'feature';",
  ">>>>>>> theirs",
  "const c = 3;",
  "",
].join("\n");

/**
 * Jujutsu-format conflict markers (alternate +++++++/------- variant).
 */
const JJ_CONFLICTED_FILE_PLUS = [
  "const a = 1;",
  "<<<<<<< ours",
  "const b = 'main';",
  "+++++++",
  "+const b = 'feature';",
  "-const b = 'old';",
  ">>>>>>> theirs",
  "const c = 3;",
  "",
].join("\n");

/** Clean resolved TypeScript content (no conflict markers). */
const RESOLVED_CONTENT = [
  "const a = 1;",
  "const b = 'merged';",
  "const c = 3;",
  "",
].join("\n");

// ── Mock factory helpers ──────────────────────────────────────────────────

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
 * Mock runWithPiSdk to write resolvedContent to opts.cwd/filePath and succeed.
 */
function mockPiWritesFile(filePath: string, resolvedContent: string, costUsd = 0.006) {
  mockRunWithPi.mockImplementation(async (opts) => {
    const fullPath = path.join(opts.cwd, filePath);
    await fs.mkdir(path.dirname(fullPath), { recursive: true });
    await fs.writeFile(fullPath, resolvedContent, "utf-8");
    return makeSuccessPiResult(costUsd);
  });
}

/**
 * Creates a fully-mocked VcsBackend for testing ConflictResolver.
 */
function makeMockVcs(
  name: "git" | "jujutsu",
  overrides: Partial<Record<keyof VcsBackend, ReturnType<typeof vi.fn>>> = {},
): VcsBackend {
  return {
    name,
    // Repository introspection
    getRepoRoot: vi.fn().mockResolvedValue("/repo"),
    getMainRepoRoot: vi.fn().mockResolvedValue("/repo"),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    getCurrentBranch: vi.fn().mockResolvedValue("foreman/bd-test-001"),
    // Branch operations
    checkoutBranch: vi.fn().mockResolvedValue(undefined),
    branchExists: vi.fn().mockResolvedValue(true),
    branchExistsOnRemote: vi.fn().mockResolvedValue(true),
    deleteBranch: vi.fn().mockResolvedValue({ deleted: true }),
    // Workspace operations
    createWorkspace: vi.fn().mockResolvedValue({
      workspacePath: "/workspace",
      branchName: "foreman/bd-test-001",
    }),
    removeWorkspace: vi.fn().mockResolvedValue(undefined),
    listWorkspaces: vi.fn().mockResolvedValue([]),
    // Staging and commit
    stageAll: vi.fn().mockResolvedValue(undefined),
    commit: vi.fn().mockResolvedValue(undefined),
    push: vi.fn().mockResolvedValue(undefined),
    pull: vi.fn().mockResolvedValue(undefined),
    saveWorktreeState: vi.fn().mockResolvedValue(false),
    restoreWorktreeState: vi.fn().mockResolvedValue(undefined),
    // Rebase and merge
    rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    rebaseBranch: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    restackBranch: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    abortRebase: vi.fn().mockResolvedValue(undefined),
    merge: vi.fn().mockResolvedValue({ success: true, conflictingFiles: [] }),
    mergeWithStrategy: vi.fn().mockResolvedValue({ success: true, conflicts: [] }),
    rollbackFailedMerge: vi.fn().mockResolvedValue(undefined),
    stageFile: vi.fn().mockResolvedValue(undefined),
    stageFiles: vi.fn().mockResolvedValue(undefined),
    // Diff, status, conflict detection
    getHeadId: vi.fn().mockResolvedValue("abc1234"),
    fetch: vi.fn().mockResolvedValue(undefined),
    diff: vi.fn().mockResolvedValue(""),
    getModifiedFiles: vi.fn().mockResolvedValue([]),
    getConflictingFiles: vi.fn().mockResolvedValue([]),
    status: vi.fn().mockResolvedValue(""),
    cleanWorkingTree: vi.fn().mockResolvedValue(undefined),
    // Finalize support
    getFinalizeCommands: vi.fn().mockReturnValue({
      stageCommand: "git add -A",
      commitCommand: "git commit -m",
      pushCommand: "git push -u origin",
      integrateTargetCommand: "git pull --rebase origin",
      branchVerifyCommand: "git rev-parse --abbrev-ref HEAD",
      cleanCommand: "git clean -fd",
      restoreTrackedStateCommand: "git restore --source=HEAD --staged --worktree -- .beads/issues.jsonl",
    }),
    ...overrides,
  } as VcsBackend;
}

// ── Test Suite ────────────────────────────────────────────────────────────

describe("ConflictResolver — Jujutsu Adaptation (TRD-032)", () => {
  let tmpDir: string;

  beforeEach(async () => {
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "cr-jj-test-"));
    vi.clearAllMocks();
  });

  afterEach(async () => {
    await fs.rm(tmpDir, { recursive: true, force: true });
  });

  // ── AC-T-032-2: Git backward compatibility ────────────────────────────

  describe("AC-T-032-2: Git-format conflict markers — backward compatibility", () => {
    it("resolves a git-format conflict file successfully with GitBackend", async () => {
      const mockVcs = makeMockVcs("git");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      const result = await resolver.attemptTier3Resolution("shared.ts", GIT_CONFLICTED_FILE);

      expect(result.success).toBe(true);
      expect(result.resolvedContent).toBe(RESOLVED_CONTENT);
    });

    it("calls Pi SDK when git-format conflict file is provided", async () => {
      const mockVcs = makeMockVcs("git");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      await resolver.attemptTier3Resolution("shared.ts", GIT_CONFLICTED_FILE);

      expect(mockRunWithPi).toHaveBeenCalledOnce();
    });

    it("resolves a git-format conflict without any VcsBackend (no-vcs backward compat)", async () => {
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG);
      const result = await resolver.attemptTier3Resolution("shared.ts", GIT_CONFLICTED_FILE);

      expect(result.success).toBe(true);
      expect(result.resolvedContent).toBe(RESOLVED_CONTENT);
    });

    it("resolves a git-format conflict with explicit undefined vcs (defaults to git behavior)", async () => {
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, undefined);
      const result = await resolver.attemptTier3Resolution("shared.ts", GIT_CONFLICTED_FILE);

      expect(result.success).toBe(true);
    });

    it("tracks cost from Pi result for git-format conflicts", async () => {
      const mockVcs = makeMockVcs("git");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT, 0.008);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      const result = await resolver.attemptTier3Resolution("shared.ts", GIT_CONFLICTED_FILE);

      expect(result.success).toBe(true);
      expect(result.cost?.actualCostUsd).toBeCloseTo(0.008, 6);
    });

    it("returns error when Pi fails on git-format conflict", async () => {
      const mockVcs = makeMockVcs("git");
      mockRunWithPi.mockResolvedValue(makeFailPiResult("API timeout"));

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      const result = await resolver.attemptTier3Resolution("shared.ts", GIT_CONFLICTED_FILE);

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/API timeout/);
    });

    it("respects file size gate (MQ-013) for git-format conflicts", async () => {
      const mockVcs = makeMockVcs("git");
      const smallLimitConfig = {
        ...TEST_CONFIG,
        costControls: { ...TEST_CONFIG.costControls, maxFileLines: 3 },
      };

      const resolver = new ConflictResolver(tmpDir, smallLimitConfig, mockVcs);
      const result = await resolver.attemptTier3Resolution("shared.ts", GIT_CONFLICTED_FILE);

      expect(result.success).toBe(false);
      expect(result.errorCode).toBe("MQ-013");
      expect(mockRunWithPi).not.toHaveBeenCalled();
    });
  });

  // ── AC-T-032-1: Jujutsu-format parsing ───────────────────────────────

  describe("AC-T-032-1: Jujutsu-format conflict marker parsing", () => {
    it("resolves a jj-format conflict file (%%% separator) successfully", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      const result = await resolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE);

      expect(result.success).toBe(true);
      expect(result.resolvedContent).toBe(RESOLVED_CONTENT);
    });

    it("calls Pi SDK when jj-format conflict file is provided", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      await resolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE);

      expect(mockRunWithPi).toHaveBeenCalledOnce();
    });

    it("resolves a jj-format conflict file (+++++++/------- variant) successfully", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      const result = await resolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE_PLUS);

      expect(result.success).toBe(true);
      expect(result.resolvedContent).toBe(RESOLVED_CONTENT);
    });

    it("writes jj-format conflicted content to disk before invoking Pi", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      const writtenContents: string[] = [];

      mockRunWithPi.mockImplementation(async (opts) => {
        const content = await fs.readFile(path.join(opts.cwd, "shared.ts"), "utf-8");
        writtenContents.push(content);
        await fs.writeFile(path.join(opts.cwd, "shared.ts"), RESOLVED_CONTENT);
        return makeSuccessPiResult();
      });

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      await resolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE);

      expect(writtenContents).toHaveLength(1);
      expect(writtenContents[0]).toBe(JJ_CONFLICTED_FILE);
    });

    it("respects file size gate (MQ-013) for jj-format conflicts", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      const smallLimitConfig = {
        ...TEST_CONFIG,
        costControls: { ...TEST_CONFIG.costControls, maxFileLines: 3 },
      };

      const resolver = new ConflictResolver(tmpDir, smallLimitConfig, mockVcs);
      const result = await resolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE);

      expect(result.success).toBe(false);
      expect(result.errorCode).toBe("MQ-013");
      expect(mockRunWithPi).not.toHaveBeenCalled();
    });

    it("respects budget gate (MQ-012) for jj-format conflicts", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      const tinyBudget = {
        ...TEST_CONFIG,
        costControls: { ...TEST_CONFIG.costControls, maxSessionBudgetUsd: 0.0001 },
      };

      const resolver = new ConflictResolver(tmpDir, tinyBudget, mockVcs);
      resolver.addSessionCost(0.0001);

      const result = await resolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE);

      expect(result.success).toBe(false);
      expect(result.errorCode).toBe("MQ-012");
      expect(mockRunWithPi).not.toHaveBeenCalled();
    });

    it("tracks cost after successful jj-format resolution", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT, 0.005);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      const result = await resolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE);

      expect(result.success).toBe(true);
      expect(result.cost?.actualCostUsd).toBeCloseTo(0.005, 6);
      expect(resolver.getSessionCost()).toBeCloseTo(0.005, 6);
    });

    it("rejects resolved jj content that still contains git conflict markers", async () => {
      const mockVcs = makeMockVcs("jujutsu");

      // Pi writes back content that still has git conflict markers
      const stillConflicted = [
        "const a = 1;",
        "<<<<<<< HEAD",
        "const b = 'still conflicted';",
        "=======",
        "const b = 'other';",
        ">>>>>>> branch",
        "",
      ].join("\n");

      mockPiWritesFile("shared.ts", stillConflicted);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      const result = await resolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE);

      // Validation should fail — conflict markers still present
      expect(result.success).toBe(false);
      expect(result.error).toMatch(/conflict marker/i);
    });
  });

  // ── AC-T-032-3: Backend-aware prompt ─────────────────────────────────

  describe("AC-T-032-3: Prompt includes backend-specific conflict format instructions", () => {
    it("prompt mentions 'jujutsu' or 'jj' when JujutsuBackend is active", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      await resolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE);

      expect(mockRunWithPi).toHaveBeenCalledOnce();
      const prompt: string = mockRunWithPi.mock.calls[0][0].prompt;

      // Must mention jujutsu or jj (case-insensitive)
      expect(prompt).toMatch(/jujutsu|jj/i);
    });

    it("prompt mentions '%%%%%%%' separator when JujutsuBackend is active", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      await resolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE);

      const prompt: string = mockRunWithPi.mock.calls[0][0].prompt;
      expect(prompt).toContain("%%%%%%%");
    });

    it("prompt still mentions the file path when JujutsuBackend is active", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      mockPiWritesFile("src/config.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      await resolver.attemptTier3Resolution("src/config.ts", JJ_CONFLICTED_FILE);

      const prompt: string = mockRunWithPi.mock.calls[0][0].prompt;
      expect(prompt).toContain("src/config.ts");
    });

    it("prompt still requires ZERO conflict markers in output when JujutsuBackend is active", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      await resolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE);

      const prompt: string = mockRunWithPi.mock.calls[0][0].prompt;
      expect(prompt).toContain("ZERO conflict markers");
    });

    it("prompt mentions 'git' when GitBackend is active", async () => {
      const mockVcs = makeMockVcs("git");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      await resolver.attemptTier3Resolution("shared.ts", GIT_CONFLICTED_FILE);

      expect(mockRunWithPi).toHaveBeenCalledOnce();
      const prompt: string = mockRunWithPi.mock.calls[0][0].prompt;

      expect(prompt).toContain("git");
    });

    it("prompt mentions git markers when GitBackend is active", async () => {
      const mockVcs = makeMockVcs("git");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      await resolver.attemptTier3Resolution("shared.ts", GIT_CONFLICTED_FILE);

      const prompt: string = mockRunWithPi.mock.calls[0][0].prompt;

      // Git prompt should mention standard git markers
      expect(prompt).toMatch(/<<<<<<< HEAD|=======|>>>>>>>/);
    });

    it("git prompt does NOT mention jujutsu", async () => {
      const mockVcs = makeMockVcs("git");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      await resolver.attemptTier3Resolution("shared.ts", GIT_CONFLICTED_FILE);

      const prompt: string = mockRunWithPi.mock.calls[0][0].prompt;

      // Git prompt should not mention jujutsu or jj
      expect(prompt).not.toMatch(/jujutsu/i);
      expect(prompt).not.toMatch(/\bjj\b/i);
    });

    it("jj prompt does NOT mention '=======' (git-only separator)", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      await resolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE);

      const prompt: string = mockRunWithPi.mock.calls[0][0].prompt;

      // jj prompt should not use the git-only separator
      expect(prompt).not.toContain("=======");
    });

    it("prompt is backend-aware when no VcsBackend provided (defaults to git-like prompt)", async () => {
      // Without a VcsBackend, default to git behavior
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG);
      await resolver.attemptTier3Resolution("shared.ts", GIT_CONFLICTED_FILE);

      const prompt: string = mockRunWithPi.mock.calls[0][0].prompt;
      expect(prompt).toContain("git");
      expect(prompt).not.toMatch(/jujutsu/i);
    });

    it("prompts differ between git and jujutsu backends", async () => {
      // Git resolution
      const gitVcs = makeMockVcs("git");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);
      const gitResolver = new ConflictResolver(tmpDir, TEST_CONFIG, gitVcs);
      await gitResolver.attemptTier3Resolution("shared.ts", GIT_CONFLICTED_FILE);
      const gitPrompt: string = mockRunWithPi.mock.calls[0][0].prompt;

      vi.clearAllMocks();

      // Jujutsu resolution
      const jjVcs = makeMockVcs("jujutsu");
      mockPiWritesFile("shared.ts", RESOLVED_CONTENT);
      const jjResolver = new ConflictResolver(tmpDir, TEST_CONFIG, jjVcs);
      await jjResolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE);
      const jjPrompt: string = mockRunWithPi.mock.calls[0][0].prompt;

      // The two prompts must differ
      expect(gitPrompt).not.toBe(jjPrompt);
      // Git prompt has git markers; jj prompt has jj markers
      expect(gitPrompt).toContain("git");
      expect(jjPrompt).toMatch(/jujutsu|jj/i);
    });
  });

  // ── Edge cases ────────────────────────────────────────────────────────

  describe("Edge cases", () => {
    it("accepts JujutsuBackend as third constructor argument", () => {
      const mockVcs = makeMockVcs("jujutsu");
      expect(
        () => new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs),
      ).not.toThrow();
    });

    it("accepts GitBackend as third constructor argument", () => {
      const mockVcs = makeMockVcs("git");
      expect(
        () => new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs),
      ).not.toThrow();
    });

    it("constructs without any VcsBackend (backward compatibility)", () => {
      expect(() => new ConflictResolver(tmpDir, TEST_CONFIG)).not.toThrow();
    });

    it("accumulates session cost across jj-format resolutions", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      mockPiWritesFile("file1.ts", RESOLVED_CONTENT, 0.005);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      await resolver.attemptTier3Resolution("file1.ts", JJ_CONFLICTED_FILE);
      const costAfterFirst = resolver.getSessionCost();
      expect(costAfterFirst).toBeGreaterThan(0);

      mockPiWritesFile("file2.ts", RESOLVED_CONTENT, 0.005);
      await resolver.attemptTier3Resolution("file2.ts", JJ_CONFLICTED_FILE);
      const costAfterSecond = resolver.getSessionCost();

      expect(costAfterSecond).toBeGreaterThan(costAfterFirst);
      expect(costAfterSecond).toBeCloseTo(costAfterFirst * 2, 5);
    });

    it("returns error when Pi fails on jj-format conflict", async () => {
      const mockVcs = makeMockVcs("jujutsu");
      mockRunWithPi.mockResolvedValue(makeFailPiResult("Rate limit exceeded"));

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, mockVcs);
      const result = await resolver.attemptTier3Resolution("shared.ts", JJ_CONFLICTED_FILE);

      expect(result.success).toBe(false);
      expect(result.error).toMatch(/Rate limit exceeded/);
    });

    it("passes the correct cwd and model to Pi regardless of backend", async () => {
      const jjVcs = makeMockVcs("jujutsu");
      mockPiWritesFile("src/util.ts", RESOLVED_CONTENT);

      const resolver = new ConflictResolver(tmpDir, TEST_CONFIG, jjVcs);
      await resolver.attemptTier3Resolution("src/util.ts", JJ_CONFLICTED_FILE);

      const callOpts = mockRunWithPi.mock.calls[0][0];
      expect(callOpts.cwd).toBe(tmpDir);
      expect(callOpts.model).toBe("anthropic/claude-sonnet-4-6");
    });
  });
});
