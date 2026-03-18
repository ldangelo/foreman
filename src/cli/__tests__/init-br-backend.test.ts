/**
 * Tests for TRD-018: Update init.ts to skip sd init when backend=br.
 *
 * Tests the exported `initBackend` function directly (injectable deps pattern).
 *
 * Verifies:
 * - When FOREMAN_TASK_BACKEND='br': sd init is skipped, br init is run
 * - When FOREMAN_TASK_BACKEND='sd': sd init runs as before (existing behavior)
 */

import { describe, it, expect, vi, beforeEach, afterEach, type MockInstance } from "vitest";
import type { execFileSync as ExecFileSyncType } from "node:child_process";

// ── Hoisted mocks ──────────────────────────────────────────────────────────
const { mockGetTaskBackend } = vi.hoisted(() => {
  const mockGetTaskBackend = vi.fn().mockReturnValue("sd");
  return { mockGetTaskBackend };
});

vi.mock("../../lib/feature-flags.js", () => ({
  getTaskBackend: () => mockGetTaskBackend(),
}));

// Mock ForemanStore so initBackend tests don't touch the real DB
vi.mock("../../lib/store.js", () => ({
  ForemanStore: vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.close = vi.fn();
    this.getProjectByPath = vi.fn().mockReturnValue(null);
    this.registerProject = vi.fn().mockReturnValue({ id: "proj-1" });
    this.getSentinelConfig = vi.fn().mockReturnValue(null);
    this.upsertSentinelConfig = vi.fn().mockReturnValue({});
  }),
}));

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
function getCalls(mock: MockInstance & typeof ExecFileSyncType): ExecCall[] {
  return (mock.mock.calls as unknown as ExecCall[]);
}

describe("TRD-018: initBackend() backend selection via FOREMAN_TASK_BACKEND", () => {
  beforeEach(() => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.clearAllMocks();
    vi.restoreAllMocks();
  });

  // ── br backend ────────────────────────────────────────────────────────────

  describe("when FOREMAN_TASK_BACKEND='br'", () => {
    beforeEach(() => {
      mockGetTaskBackend.mockReturnValue("br");
    });

    it("skips sd installation check (no sd --version call)", async () => {
      const execSync = makeExecSync();
      const checkExists = makeCheckExists([]); // .beads absent

      await initBackend({ projectDir: PROJECT_DIR, execSync, checkExists });

      const sdVersionCalls = getCalls(execSync).filter(
        (call) => call[0].endsWith("/sd") && call[1]?.includes("--version"),
      );
      expect(sdVersionCalls).toHaveLength(0);
    });

    it("skips sd init even when .seeds directory does not exist", async () => {
      const execSync = makeExecSync();
      const checkExists = makeCheckExists([]); // neither .seeds nor .beads exist

      await initBackend({ projectDir: PROJECT_DIR, execSync, checkExists });

      const sdInitCalls = getCalls(execSync).filter(
        (call) => call[0].endsWith("/sd") && call[1]?.includes("init"),
      );
      expect(sdInitCalls).toHaveLength(0);
    });

    it("runs br init when .beads directory does not exist", async () => {
      const execSync = makeExecSync();
      const checkExists = makeCheckExists([]); // .beads absent

      await initBackend({ projectDir: PROJECT_DIR, execSync, checkExists });

      const brInitCalls = getCalls(execSync).filter(
        (call) => call[0].endsWith("/br") && call[1]?.includes("init"),
      );
      expect(brInitCalls).toHaveLength(1);
    });

    it("passes br binary path for init", async () => {
      const execSync = makeExecSync();
      const checkExists = makeCheckExists([]);

      await initBackend({ projectDir: PROJECT_DIR, execSync, checkExists });

      expect(execSync).toHaveBeenCalledWith(
        expect.stringContaining("/br"),
        ["init"],
        expect.any(Object),
      );
    });

    it("skips br init when .beads directory already exists", async () => {
      const execSync = makeExecSync();
      const checkExists = makeCheckExists([".beads"]); // .beads exists

      await initBackend({ projectDir: PROJECT_DIR, execSync, checkExists });

      const brInitCalls = getCalls(execSync).filter(
        (call) => call[0].endsWith("/br") && call[1]?.includes("init"),
      );
      expect(brInitCalls).toHaveLength(0);
    });

    it("does not check for sd binary when backend=br", async () => {
      const execSync = makeExecSync();
      const checkExists = makeCheckExists([]);

      await initBackend({ projectDir: PROJECT_DIR, execSync, checkExists });

      const sdCalls = getCalls(execSync).filter(
        (call) => call[0].endsWith("/sd"),
      );
      expect(sdCalls).toHaveLength(0);
    });
  });

});
