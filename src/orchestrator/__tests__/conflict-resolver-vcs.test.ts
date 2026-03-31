/**
 * Tests for ConflictResolver VcsBackend migration (TRD-013-TEST).
 *
 * Acceptance Criteria:
 *   AC-T-013-1: Given a mock VcsBackend with conflicts, when autoResolveRebaseConflicts()
 *               runs, then VcsBackend.getConflictingFiles() is called.
 *   AC-T-013-2: Given a mock VcsBackend, when abort is triggered, then
 *               VcsBackend.abortRebase() is called.
 *   AC-T-013-3: Grep conflict-resolver.ts for execFileAsync("git" — zero matches.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ConflictResolver } from "../conflict-resolver.js";
import { DEFAULT_MERGE_CONFIG } from "../merge-config.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

// ── Mock pi-sdk-runner so Tier 3/4 tests don't need a real Pi session ──────
vi.mock("../pi-sdk-runner.js", () => ({
  runWithPiSdk: vi.fn(),
}));

// ── VcsBackend Mock Factory ─────────────────────────────────────────────────

/**
 * Creates a fully-mocked VcsBackend for testing ConflictResolver.
 * All methods default to success. Tests override individual methods as needed.
 */
function makeMockVcs(
  overrides: Partial<Record<keyof VcsBackend, ReturnType<typeof vi.fn>>> = {},
): VcsBackend {
  return {
    name: "git",
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
    createWorkspace: vi
      .fn()
      .mockResolvedValue({ workspacePath: "/workspace", branchName: "foreman/bd-test-001" }),
    removeWorkspace: vi.fn().mockResolvedValue(undefined),
    listWorkspaces: vi.fn().mockResolvedValue([]),
    // Staging and commit
    stageAll: vi.fn().mockResolvedValue(undefined),
    commit: vi.fn().mockResolvedValue(undefined),
    push: vi.fn().mockResolvedValue(undefined),
    pull: vi.fn().mockResolvedValue(undefined),
    // Rebase and merge
    rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    abortRebase: vi.fn().mockResolvedValue(undefined),
    merge: vi.fn().mockResolvedValue({ success: true, conflictingFiles: [] }),
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
      rebaseCommand: "git pull --rebase origin",
      branchVerifyCommand: "git rev-parse --abbrev-ref HEAD",
      cleanCommand: "git clean -fd",
      restoreTrackedStateCommand: "git restore --source=HEAD --staged --worktree -- .beads/issues.jsonl",
    }),
    ...overrides,
  } as VcsBackend;
}

// ── Test Suite ──────────────────────────────────────────────────────────────

describe("ConflictResolver — VcsBackend Migration (TRD-013)", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "cr-vcs-test-"));
    vi.clearAllMocks();
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // ── AC-T-013-1 ─────────────────────────────────────────────────────────

  describe("AC-T-013-1: VcsBackend.getConflictingFiles() is called by autoResolveRebaseConflicts()", () => {
    it("calls getConflictingFiles() when no conflicts are present (returns true immediately)", async () => {
      const mockVcs = makeMockVcs({
        // No conflicts — method returns empty array
        getConflictingFiles: vi.fn().mockResolvedValue([]),
      });

      const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG, mockVcs);
      const result = await resolver.autoResolveRebaseConflicts("main");

      expect(result).toBe(true);
      expect(mockVcs.getConflictingFiles).toHaveBeenCalledOnce();
      expect(mockVcs.getConflictingFiles).toHaveBeenCalledWith(tmpDir);
    });

    it("calls getConflictingFiles() with the project path", async () => {
      const mockVcs = makeMockVcs({
        getConflictingFiles: vi.fn().mockResolvedValue([]),
      });

      const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG, mockVcs);
      await resolver.autoResolveRebaseConflicts("main");

      expect(mockVcs.getConflictingFiles).toHaveBeenCalledWith(tmpDir);
    });

    it("calls getConflictingFiles() when only report file conflicts exist (auto-resolve loop)", async () => {
      // First call returns report file conflicts; second call (after resolution) returns empty
      const mockVcs = makeMockVcs({
        getConflictingFiles: vi
          .fn()
          .mockResolvedValueOnce(["EXPLORER_REPORT.md"])
          .mockResolvedValueOnce([]),
      });

      const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG, mockVcs);
      const result = await resolver.autoResolveRebaseConflicts("main");

      // getConflictingFiles should be called at least once
      expect(mockVcs.getConflictingFiles).toHaveBeenCalled();
      expect(mockVcs.getConflictingFiles).toHaveBeenCalledWith(tmpDir);
      // Result may be true or false depending on git state (no real repo here)
      expect(typeof result).toBe("boolean");
    });

    it("calls getConflictingFiles() when code conflicts are present (triggers abort path)", async () => {
      const mockVcs = makeMockVcs({
        getConflictingFiles: vi.fn().mockResolvedValue(["src/main.ts"]),
        abortRebase: vi.fn().mockResolvedValue(undefined),
      });

      const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG, mockVcs);
      const result = await resolver.autoResolveRebaseConflicts("main");

      expect(mockVcs.getConflictingFiles).toHaveBeenCalledOnce();
      expect(mockVcs.getConflictingFiles).toHaveBeenCalledWith(tmpDir);
      // Code conflicts → abort → return false
      expect(result).toBe(false);
    });
  });

  // ── AC-T-013-2 ─────────────────────────────────────────────────────────

  describe("AC-T-013-2: VcsBackend.abortRebase() is called when abort is triggered", () => {
    it("calls abortRebase() when code conflicts are detected", async () => {
      const mockVcs = makeMockVcs({
        getConflictingFiles: vi.fn().mockResolvedValue(["src/main.ts"]),
        abortRebase: vi.fn().mockResolvedValue(undefined),
      });

      const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG, mockVcs);
      const result = await resolver.autoResolveRebaseConflicts("main");

      expect(result).toBe(false);
      expect(mockVcs.abortRebase).toHaveBeenCalledOnce();
      expect(mockVcs.abortRebase).toHaveBeenCalledWith(tmpDir);
    });

    it("calls abortRebase() when multiple code conflicts are detected", async () => {
      const mockVcs = makeMockVcs({
        getConflictingFiles: vi
          .fn()
          .mockResolvedValue(["src/main.ts", "src/util.ts", "src/config.ts"]),
        abortRebase: vi.fn().mockResolvedValue(undefined),
      });

      const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG, mockVcs);
      const result = await resolver.autoResolveRebaseConflicts("main");

      expect(result).toBe(false);
      expect(mockVcs.abortRebase).toHaveBeenCalledOnce();
      expect(mockVcs.abortRebase).toHaveBeenCalledWith(tmpDir);
    });

    it("calls abortRebase() when mixed code and report conflicts are detected", async () => {
      // Mix of code conflicts and report files — should still abort because of code conflict
      const mockVcs = makeMockVcs({
        getConflictingFiles: vi
          .fn()
          .mockResolvedValue(["EXPLORER_REPORT.md", "src/main.ts"]),
        abortRebase: vi.fn().mockResolvedValue(undefined),
      });

      const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG, mockVcs);
      const result = await resolver.autoResolveRebaseConflicts("main");

      expect(result).toBe(false);
      expect(mockVcs.abortRebase).toHaveBeenCalledOnce();
    });

    it("does NOT call abortRebase() when getConflictingFiles() returns empty", async () => {
      const mockVcs = makeMockVcs({
        getConflictingFiles: vi.fn().mockResolvedValue([]),
        abortRebase: vi.fn().mockResolvedValue(undefined),
      });

      const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG, mockVcs);
      await resolver.autoResolveRebaseConflicts("main");

      expect(mockVcs.abortRebase).not.toHaveBeenCalled();
    });

    it("calls abortRebase() even if it throws (graceful error handling)", async () => {
      const mockVcs = makeMockVcs({
        getConflictingFiles: vi.fn().mockResolvedValue(["src/main.ts"]),
        abortRebase: vi.fn().mockRejectedValue(new Error("rebase: not in progress")),
      });

      const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG, mockVcs);

      // Should not throw — the abort error is swallowed gracefully
      await expect(resolver.autoResolveRebaseConflicts("main")).resolves.toBe(false);
      expect(mockVcs.abortRebase).toHaveBeenCalledOnce();
    });
  });

  // ── AC-T-013-3 ─────────────────────────────────────────────────────────

  describe("AC-T-013-3: conflict-resolver.ts has zero execFileAsync('git') literal calls", () => {
    it("contains no execFileAsync(\"git\" string literals in conflict-resolver.ts", () => {
      // This is a static analysis test: verifies that TRD-013 removed all direct
      // git command invocations via execFileAsync("git", ...) from the class.
      //
      // The migration routes git operations through VcsBackend, which is the
      // backend-agnostic interface. Low-level git calls remaining in the file
      // would indicate an incomplete migration.

      // Resolve path relative to this test file (which lives in __tests__/)
      const sourceFile = join(
        import.meta.dirname ?? __dirname,
        "..",
        "conflict-resolver.ts",
      );

      const source = readFileSync(sourceFile, "utf-8");
      const matches = source.match(/execFileAsync\("git"/g);

      expect(matches).toBeNull();
    });
  });

  // ── VcsBackend injection behaviour ─────────────────────────────────────

  describe("VcsBackend constructor injection", () => {
    it("accepts a VcsBackend as the third constructor argument", () => {
      const mockVcs = makeMockVcs();
      expect(() => new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG, mockVcs)).not.toThrow();
    });

    it("constructs without a VcsBackend (backward compatibility)", () => {
      // vcs is optional — existing code that doesn't pass a VcsBackend still works
      expect(() => new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG)).not.toThrow();
    });

    it("uses provided VcsBackend methods in autoResolveRebaseConflicts instead of raw git", async () => {
      const mockVcs = makeMockVcs({
        getConflictingFiles: vi.fn().mockResolvedValue([]),
      });

      const resolver = new ConflictResolver(tmpDir, DEFAULT_MERGE_CONFIG, mockVcs);
      await resolver.autoResolveRebaseConflicts("main");

      // With VcsBackend injected, getConflictingFiles() should be used
      expect(mockVcs.getConflictingFiles).toHaveBeenCalled();
    });
  });
});
