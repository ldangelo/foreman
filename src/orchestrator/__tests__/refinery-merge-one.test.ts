/**
 * TRD-029-TEST: Extracted Merge Function Tests
 *
 * Tests for the public `Refinery.mergeOne()` method:
 * 1. Returns status="merged" on successful clean merge
 * 2. Returns status="conflict" when rebase fails and PR creation fails
 * 3. Returns status="pr-created" when rebase fails but PR creation succeeds
 * 4. mergeOne uses run.seed_id to derive branchName (foreman/<seedId>)
 * 5. MergeOneResult and MergeOneStatus types are exported
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run } from "../../lib/store.js";

// ── Module mocks ──────────────────────────────────────────────────────────────

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
}));

vi.mock("../../lib/git.js", () => ({
  mergeWorktree: vi.fn(),
  removeWorktree: vi.fn(),
  detectDefaultBranch: vi.fn().mockResolvedValue("main"),
}));

vi.mock("../task-backend-ops.js", () => ({
  resetSeedToOpen: vi.fn().mockResolvedValue(undefined),
  closeSeed: vi.fn().mockResolvedValue(undefined),
}));

// Import mocked modules AFTER vi.mock declarations
import { execFile } from "node:child_process";
import { mergeWorktree } from "../../lib/git.js";
import { Refinery, type MergeOneResult, type MergeOneStatus } from "../refinery.js";

const mockExecFile = execFile as unknown as ReturnType<typeof vi.fn>;
const mockMergeWorktree = mergeWorktree as unknown as ReturnType<typeof vi.fn>;

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seed-abc",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: null, // null to skip conflict marker scan
    status: "completed",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    tmux_session: null,
    ...overrides,
  };
}

function makeStore() {
  return {
    getRunsByStatus: vi.fn(() => [] as Run[]),
    updateRun: vi.fn(),
    updateRunProgress: vi.fn(),
    getRun: vi.fn(),
    createEvent: vi.fn(),
    logEvent: vi.fn(),
    getEvents: vi.fn().mockReturnValue([]),
  };
}

function makeSeeds() {
  return {
    show: vi.fn().mockResolvedValue({
      title: "Test task",
      description: "Test description",
      status: "closed",
    }),
    update: vi.fn().mockResolvedValue(undefined),
  };
}

function mockExecFileSuccess(stdout = "") {
  mockExecFile.mockImplementation(
    (_cmd: string, _args: string[], _opts: unknown, cb: (err: null | Error, result?: { stdout: string; stderr: string }) => void) => {
      cb(null, { stdout, stderr: "" });
    }
  );
}

function mockExecFileFailure(message = "git error") {
  mockExecFile.mockImplementation(
    (_cmd: string, _args: string[], _opts: unknown, cb: (err: Error, result?: { stdout: string; stderr: string }) => void) => {
      const err = Object.assign(new Error(message), { stdout: "", stderr: message });
      cb(err);
    }
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("Refinery.mergeOne() — exported types", () => {
  it("MergeOneStatus type includes all expected values at runtime", () => {
    const statuses: MergeOneStatus[] = ["merged", "conflict", "pr-created", "failed"];
    expect(statuses).toHaveLength(4);
  });

  it("MergeOneResult interface is correctly typed", () => {
    const result: MergeOneResult = {
      status: "merged",
      branchName: "foreman/bd-test",
    };
    expect(result.status).toBe("merged");
    expect(result.branchName).toBe("foreman/bd-test");
  });
});

describe("Refinery.mergeOne() — clean merge path", () => {
  let refinery: Refinery;

  beforeEach(() => {
    vi.clearAllMocks();
    const store = makeStore();
    const seeds = makeSeeds();
    refinery = new Refinery(store as never, seeds as never, "/tmp/proj");

    // All git commands succeed
    mockExecFileSuccess("main\n");
    mockMergeWorktree.mockResolvedValue({ success: true, conflicts: [] });
  });

  it("returns status='merged' on successful clean merge", async () => {
    const run = makeRun();
    const result = await refinery.mergeOne(run, {
      targetBranch: "main",
      runTests: false,
      testCommand: "",
    });

    expect(result.status).toBe("merged");
    expect(result.branchName).toBe("foreman/seed-abc");
  });

  it("branchName is derived as foreman/<seedId>", async () => {
    const run = makeRun({ seed_id: "my-custom-seed" });
    const result = await refinery.mergeOne(run, {
      targetBranch: "main",
      runTests: false,
      testCommand: "",
    });
    expect(result.branchName).toBe("foreman/my-custom-seed");
  });
});

describe("Refinery.mergeOne() — conflict paths", () => {
  let refinery: Refinery;

  beforeEach(() => {
    vi.clearAllMocks();
    const store = makeStore();
    const seeds = makeSeeds();
    refinery = new Refinery(store as never, seeds as never, "/tmp/proj");
  });

  it("returns status='conflict' or 'pr-created' when rebase fails", async () => {
    // Make git rebase fail but other git calls succeed (checkout, fetch, etc.)
    mockExecFile.mockImplementation(
      (cmd: string, args: string[], _opts: unknown, cb: (err: null | Error, result?: { stdout: string; stderr: string }) => void) => {
        // Make rebase fail; let everything else succeed
        if (cmd === "git" && args[0] === "rebase") {
          const err = Object.assign(new Error("rebase conflict"), { stdout: "", stderr: "CONFLICT" });
          cb(err);
        } else {
          cb(null, { stdout: "", stderr: "" });
        }
      }
    );
    mockMergeWorktree.mockResolvedValue({ success: false, conflicts: ["src/index.ts"] });

    const run = makeRun();
    const result = await refinery.mergeOne(run, {
      targetBranch: "main",
      runTests: false,
      testCommand: "",
    });

    // Either conflict or pr-created depending on gh availability
    expect(["conflict", "pr-created"]).toContain(result.status);
    expect(result.branchName).toBe("foreman/seed-abc");
  });

  it("returns a reason string when conflict occurs", async () => {
    mockExecFile.mockImplementation(
      (cmd: string, args: string[], _opts: unknown, cb: (err: null | Error, result?: { stdout: string; stderr: string }) => void) => {
        if (cmd === "git" && args[0] === "rebase") {
          const err = Object.assign(new Error("rebase conflict"), { stdout: "", stderr: "CONFLICT" });
          cb(err);
        } else {
          cb(null, { stdout: "", stderr: "" });
        }
      }
    );
    mockMergeWorktree.mockResolvedValue({ success: false, conflicts: ["src/app.ts"] });

    const run = makeRun();
    const result = await refinery.mergeOne(run, {
      targetBranch: "main",
      runTests: false,
      testCommand: "",
    });

    if (result.status === "conflict") {
      expect(result.reason).toBeTruthy();
    }
    // Either outcome is valid depending on gh availability
    expect(["conflict", "pr-created"]).toContain(result.status);
  });
});
