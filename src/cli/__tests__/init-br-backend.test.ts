/**
 * Tests for initBackend() issue tracker selection.
 *
 * Tests the exported `initBackend` function directly (injectable deps pattern).
 *
 * Verifies:
 * - When issueTracker='beads': br init is run (backwards compatibility)
 * - When issueTracker='jira' or 'github': br init is skipped (foreman uses Postgres directly)
 */

import { describe, it, expect, vi, beforeEach, afterEach, type MockInstance } from "vitest";
import type { execFileSync as ExecFileSyncType } from "node:child_process";

// Mock ora spinner to avoid TTY issues in tests
vi.mock("ora", () => ({
  default: vi.fn(() => ({
    start: vi.fn().mockReturnThis(),
    succeed: vi.fn().mockReturnThis(),
    fail: vi.fn().mockReturnThis(),
  })),
}));

// ── Module under test ──────────────────────────────────────────────────────
import { initBackend } from "../commands/init.js";

// ── Helpers ────────────────────────────────────────────────────────────────

const PROJECT_DIR = "/mock/project";

// Build a mock execSync that succeeds by default.
// Cast to typeof execFileSync so TypeScript accepts it in InitBackendOpts.
function makeExecSync(): MockInstance & typeof ExecFileSyncType {
  return vi.fn(() => Buffer.from("")) as unknown as MockInstance & typeof ExecFileSyncType;
}

// Build a mock checkExists that returns false by default (neither .seeds nor .beads exist)
function makeCheckExists(existingPaths: string[] = []) {
  return vi.fn((p: string) => existingPaths.some((ep) => p.includes(ep)));
}

// Type-safe accessor for mock.calls — treats each call as [binary, args?, opts?]
type ExecCall = [binary: string, args?: string[], opts?: object];
function getCalls(mock: MockInstance& typeof ExecFileSyncType): ExecCall[] {
  return (mock.mock.calls as unknown as ExecCall[]);
}

describe("initBackend() issue tracker selection", () => {
  beforeEach(() => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.clearAllMocks();
    vi.restoreAllMocks();
  });

  // ── beads tracker ────────────────────────────────────────────────────────────

  describe("when issueTracker='beads'", () => {
    it("runs br init when .beads directory does not exist", async () => {
      const execSync = makeExecSync();
      const checkExists = makeCheckExists([]); // .beads absent

      await initBackend({ projectDir: PROJECT_DIR, issueTracker: "beads", execSync, checkExists });

      const brInitCalls = getCalls(execSync).filter(
        (call) => call[0].endsWith("/br") && call[1]?.includes("init"),
      );
      expect(brInitCalls).toHaveLength(1);
    });

    it("passes br binary path for init", async () => {
      const execSync = makeExecSync();
      const checkExists = makeCheckExists([]);

      await initBackend({ projectDir: PROJECT_DIR, issueTracker: "beads", execSync, checkExists });

      expect(execSync).toHaveBeenCalledWith(
        expect.stringContaining("/br"),
        ["init"],
        expect.any(Object),
      );
    });

    it("skips br init when .beads directory already exists", async () => {
      const execSync = makeExecSync();
      const checkExists = makeCheckExists([".beads"]); // .beads exists

      await initBackend({ projectDir: PROJECT_DIR, issueTracker: "beads", execSync, checkExists });

      const brInitCalls = getCalls(execSync).filter(
        (call) => call[0].endsWith("/br") && call[1]?.includes("init"),
      );
      expect(brInitCalls).toHaveLength(0);
    });
  });

  // ── jira tracker ────────────────────────────────────────────────────────────

  describe("when issueTracker='jira'", () => {
    it("skips br init even when .beads directory does not exist", async () => {
      const execSync = makeExecSync();
      const checkExists = makeCheckExists([]); // .beads absent

      await initBackend({ projectDir: PROJECT_DIR, issueTracker: "jira", execSync, checkExists });

      const brInitCalls = getCalls(execSync).filter(
        (call) => call[0].endsWith("/br") && call[1]?.includes("init"),
      );
      expect(brInitCalls).toHaveLength(0);
    });

    it("skips br init even when .beads directory exists", async () => {
      const execSync = makeExecSync();
      const checkExists = makeCheckExists([".beads"]); // .beads exists

      await initBackend({ projectDir: PROJECT_DIR, issueTracker: "jira", execSync, checkExists });

      const brInitCalls = getCalls(execSync).filter(
        (call) => call[0].endsWith("/br") && call[1]?.includes("init"),
      );
      expect(brInitCalls).toHaveLength(0);
    });
  });

  // ── github tracker ──────────────────────────────────────────────────────────

  describe("when issueTracker='github'", () => {
    it("skips br init even when .beads directory does not exist", async () => {
      const execSync = makeExecSync();
      const checkExists = makeCheckExists([]); // .beads absent

      await initBackend({ projectDir: PROJECT_DIR, issueTracker: "github", execSync, checkExists });

      const brInitCalls = getCalls(execSync).filter(
        (call) => call[0].endsWith("/br") && call[1]?.includes("init"),
      );
      expect(brInitCalls).toHaveLength(0);
    });

    it("skips br init even when .beads directory exists", async () => {
      const execSync = makeExecSync();
      const checkExists = makeCheckExists([".beads"]); // .beads exists

      await initBackend({ projectDir: PROJECT_DIR, issueTracker: "github", execSync, checkExists });

      const brInitCalls = getCalls(execSync).filter(
        (call) => call[0].endsWith("/br") && call[1]?.includes("init"),
      );
      expect(brInitCalls).toHaveLength(0);
    });
  });

});
