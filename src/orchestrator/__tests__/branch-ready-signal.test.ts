/**
 * TRD-023: Branch-Ready Signal via Agent Mail
 *
 * Tests that finalize() sends a "branch-ready" message to the merge-agent
 * Agent Mail inbox after a successful git push, and that it does NOT send
 * a message when push fails. Also verifies that Agent Mail errors are
 * swallowed (fire-and-forget).
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Mock setup ───────────────────────────────────────────────────────────────
//
// vi.hoisted() ensures mock variables are initialised before module factories.

const { mockExecFileSync, mockCloseSeed, mockEnqueueToMergeQueue, mockSendMessage } = vi.hoisted(() => ({
  mockExecFileSync: vi.fn(),
  mockCloseSeed: vi.fn<() => Promise<void>>().mockResolvedValue(undefined),
  mockEnqueueToMergeQueue: vi.fn().mockReturnValue({ success: true }),
  mockSendMessage: vi
    .fn<(to: string, subject: string, body: string) => Promise<void>>()
    .mockResolvedValue(undefined),
}));

vi.mock("node:child_process", () => ({
  execFileSync: mockExecFileSync,
}));

vi.mock("../task-backend-ops.js", () => ({
  closeSeed: mockCloseSeed,
}));

vi.mock("../agent-worker-enqueue.js", () => ({
  enqueueToMergeQueue: mockEnqueueToMergeQueue,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: vi.fn(() => ({
      getDb: vi.fn(() => ({})),
      close: vi.fn(),
    })),
  },
}));

// Mock AgentMailClient at the class level so we can assert on sendMessage calls.
// We use a class expression so `new AgentMailClient()` works correctly.
vi.mock("../agent-mail-client.js", () => {
  class AgentMailClient {
    sendMessage = mockSendMessage;
  }
  return { AgentMailClient };
});

import { finalize } from "../agent-worker-finalize.js";
import type { FinalizeConfig } from "../agent-worker-finalize.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeConfig(overrides: Partial<FinalizeConfig> = {}): FinalizeConfig {
  return {
    runId: "run-branch-ready-001",
    seedId: "bd-test-signal",
    seedTitle: "Test branch-ready signal",
    projectPath: "/tmp/fake-project",
    ...overrides,
  } as FinalizeConfig;
}

// ── Branch-Ready Signal — push succeeds ──────────────────────────────────────

describe("branch-ready signal — push succeeds", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-branch-ready-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockCloseSeed.mockReset().mockResolvedValue(undefined);
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
    mockSendMessage.mockReset().mockResolvedValue(undefined);

    // All git commands succeed
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("calls sendMessage after successful push", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(mockSendMessage).toHaveBeenCalledOnce();
  });

  it("sends message to 'merge-agent'", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    const [to] = mockSendMessage.mock.calls[0]!;
    expect(to).toBe("merge-agent");
  });

  it("sends message with subject 'Branch Ready'", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    const [, subject] = mockSendMessage.mock.calls[0]!;
    expect(subject).toBe("Branch Ready");
  });

  it("sends message body containing the branch name", async () => {
    const seedId = "bd-test-signal";
    await finalize(makeConfig({ worktreePath: tmpDir, seedId }), logFile);
    const [, , body] = mockSendMessage.mock.calls[0]!;
    expect(body).toContain(`foreman/${seedId}`);
  });

  it("body contains seedId", async () => {
    const seedId = "bd-test-signal";
    await finalize(makeConfig({ worktreePath: tmpDir, seedId }), logFile);
    const [, , body] = mockSendMessage.mock.calls[0]!;
    expect(body).toContain(seedId);
  });

  it("body contains branchName", async () => {
    const seedId = "bd-test-signal";
    await finalize(makeConfig({ worktreePath: tmpDir, seedId }), logFile);
    const [, , body] = mockSendMessage.mock.calls[0]!;
    expect(body).toContain(`foreman/${seedId}`);
  });

  it("sends exactly 3 arguments (no metadata)", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    const call = mockSendMessage.mock.calls[0]!;
    // to, subject, body — no 4th argument
    expect(call).toHaveLength(3);
  });

  it("message has correct to, subject, and non-empty body", async () => {
    const seedId = "bd-test-signal";
    await finalize(makeConfig({ worktreePath: tmpDir, seedId }), logFile);
    const [to, subject, body] = mockSendMessage.mock.calls[0]!;
    expect(to).toBe("merge-agent");
    expect(subject).toBe("Branch Ready");
    expect(body.length).toBeGreaterThan(0);
  });

  it("still returns success=true even when sendMessage is called", async () => {
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(result.success).toBe(true);
  });
});

// ── Branch-Ready Signal — push succeeds after rebase ─────────────────────────

describe("branch-ready signal — push succeeds after rebase (non-fast-forward)", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-branch-ready-rebase-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockCloseSeed.mockReset().mockResolvedValue(undefined);
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
    mockSendMessage.mockReset().mockResolvedValue(undefined);

    // First push throws non-fast-forward; pull --rebase and second push succeed.
    let pushCallCount = 0;
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (Array.isArray(args) && args[0] === "push") {
        pushCallCount++;
        if (pushCallCount === 1) {
          throw Object.assign(
            new Error(
              "To origin\n ! [rejected] foreman/bd-test-signal -> foreman/bd-test-signal (non-fast-forward)\nerror: failed to push some refs",
            ),
            { stderr: Buffer.from("") },
          );
        }
        return Buffer.from(""); // second push succeeds
      }
      if (Array.isArray(args) && args[0] === "pull") return Buffer.from(""); // rebase succeeds
      if (args[0] === "rev-parse") return Buffer.from("deadbeef\n");
      return Buffer.from("");
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("calls sendMessage exactly once after successful rebase + retry push", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(mockSendMessage).toHaveBeenCalledOnce();
  });

  it("sends message to 'merge-agent' after rebase path", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    const [to] = mockSendMessage.mock.calls[0]!;
    expect(to).toBe("merge-agent");
  });
});

// ── Branch-Ready Signal — push FAILS ─────────────────────────────────────────

describe("branch-ready signal — push fails", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-branch-ready-fail-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockCloseSeed.mockReset().mockResolvedValue(undefined);
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
    mockSendMessage.mockReset().mockResolvedValue(undefined);

    // git push fails
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (Array.isArray(args) && args[0] === "push") {
        throw new Error("remote: Permission to repo denied.");
      }
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("does NOT call sendMessage when push fails", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(mockSendMessage).not.toHaveBeenCalled();
  });

  it("returns success=false when push fails (no regression)", async () => {
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(result.success).toBe(false);
  });
});

// ── Branch-Ready Signal — rebase fails (deterministic failure) ────────────────

describe("branch-ready signal — rebase fails", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-branch-ready-rebasefail-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockCloseSeed.mockReset().mockResolvedValue(undefined);
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
    mockSendMessage.mockReset().mockResolvedValue(undefined);

    // push throws non-fast-forward; pull --rebase also throws (conflict).
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (Array.isArray(args) && args[0] === "push") {
        throw Object.assign(
          new Error("To origin\n ! [rejected] foreman/bd-test-signal -> foreman/bd-test-signal (non-fast-forward)\nerror: failed to push some refs"),
          { stderr: Buffer.from("") },
        );
      }
      if (Array.isArray(args) && args[0] === "pull") {
        throw new Error("CONFLICT (content): Merge conflict in src/foo.ts");
      }
      if (Array.isArray(args) && args[0] === "rebase" && args[1] === "--abort") return Buffer.from("");
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("does NOT call sendMessage when rebase fails", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(mockSendMessage).not.toHaveBeenCalled();
  });
});

// ── Branch-Ready Signal — Agent Mail throws (fire-and-forget) ─────────────────

describe("branch-ready signal — Agent Mail service down (fire-and-forget)", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-branch-ready-maildown-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockCloseSeed.mockReset().mockResolvedValue(undefined);
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });

    // sendMessage rejects — simulates Agent Mail being unavailable
    mockSendMessage.mockReset().mockRejectedValue(new Error("ECONNREFUSED: Agent Mail not running"));

    // All git commands succeed
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "rev-parse") return Buffer.from("abc1234\n");
      return Buffer.from("");
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("finalize() still returns normally when Agent Mail throws", async () => {
    await expect(finalize(makeConfig({ worktreePath: tmpDir }), logFile)).resolves.toMatchObject({
      success: true,
    });
  });

  it("push success is still reflected when Agent Mail throws", async () => {
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(result.success).toBe(true);
    expect(result.retryable).toBe(true);
  });

  it("closeSeed is still called when Agent Mail throws", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile);
    expect(mockCloseSeed).toHaveBeenCalledOnce();
  });
});
