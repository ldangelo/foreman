/**
 * TRD-030-TEST: AI Conflict Resolution Tests
 *
 * Tests for MergeAgentDaemon.resolveConflictViaPi():
 * 1. Returns { resolved: true } when Pi sends agent_end
 * 2. Returns { resolved: false } when Pi process errors
 * 3. Returns { resolved: false } when Pi process closes without agent_end
 * 4. Returns { resolved: false } on timeout (simulated with short timeout)
 * 5. Sends the conflict diff in the prompt to Pi
 * 6. Returns { resolved: false, output } when pi binary not found (ENOENT)
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { EventEmitter, PassThrough } from "node:stream";

// ── Mocks ──────────────────────────────────────────────────────────────────────

const { mockSpawn } = vi.hoisted(() => ({
  mockSpawn: vi.fn(),
}));

vi.mock("node:child_process", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:child_process")>();
  return {
    ...original,
    spawn: mockSpawn,
  };
});

vi.mock("node:fs", () => ({
  existsSync: vi.fn().mockReturnValue(false),
}));

vi.mock("../agent-mail-client.js", () => {
  class MockAgentMailClient {
    fetchInbox = vi.fn().mockResolvedValue([]);
    sendMessage = vi.fn().mockResolvedValue(undefined);
  }
  return { AgentMailClient: MockAgentMailClient };
});

// Import after mocks
import { MergeAgentDaemon } from "../merge-agent.js";

// ── Helpers ────────────────────────────────────────────────────────────────────

function makeStore() {
  return {
    upsertMergeAgentConfig: vi.fn().mockReturnValue({
      id: 1,
      project_id: "proj-1",
      interval_seconds: 30,
      enabled: 1,
      pid: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }),
    updateRun: vi.fn(),
  };
}

function makeFakePiProcess() {
  const stdin = new PassThrough();
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const proc = Object.assign(new EventEmitter(), {
    stdin,
    stdout,
    stderr,
    pid: 77777,
    kill: vi.fn(),
  });
  return { proc, stdin, stdout, stderr };
}

// ── Tests ──────────────────────────────────────────────────────────────────────

describe("MergeAgentDaemon.resolveConflictViaPi()", () => {
  let daemon: MergeAgentDaemon;

  beforeEach(() => {
    const store = makeStore();
    daemon = new MergeAgentDaemon(store as never);
    mockSpawn.mockReset();
  });

  it("returns { resolved: true } when Pi emits agent_end", async () => {
    const { proc } = makeFakePiProcess();
    mockSpawn.mockReturnValue(proc);

    const resolvePromise = daemon.resolveConflictViaPi(
      "<<<<<<< HEAD\nfoo\n=======\nbar\n>>>>>>>",
      "run-1",
    );

    // Respond with agent_end
    setImmediate(() => {
      proc.stdout.emit(
        "data",
        JSON.stringify({ type: "agent_end", reason: "completed" }) + "\n",
      );
    });

    const result = await resolvePromise;
    expect(result.resolved).toBe(true);
  });

  it("sends the conflict diff text in the prompt to Pi", async () => {
    const { proc } = makeFakePiProcess();
    mockSpawn.mockReturnValue(proc);

    const sentData: string[] = [];
    proc.stdin.on("data", (chunk: Buffer) => {
      sentData.push(chunk.toString());
    });

    const conflictDiff = "<<<<<<< HEAD\nmy code\n=======\ntheir code\n>>>>>>>";
    const resolvePromise = daemon.resolveConflictViaPi(conflictDiff, "run-2");

    setImmediate(() => {
      proc.stdout.emit(
        "data",
        JSON.stringify({ type: "agent_end", reason: "done" }) + "\n",
      );
    });

    await resolvePromise;

    const fullSent = sentData.join("");
    const parsed = JSON.parse(fullSent.trim()) as { cmd: string; message: string };
    expect(parsed.cmd).toBe("prompt");
    expect(parsed.message).toContain(conflictDiff);
  });

  it("returns { resolved: false } when Pi process emits error event", async () => {
    const { proc } = makeFakePiProcess();
    mockSpawn.mockReturnValue(proc);

    const resolvePromise = daemon.resolveConflictViaPi("some conflict", "run-3");

    setImmediate(() => {
      proc.emit("error", new Error("ENOENT: pi not found"));
    });

    const result = await resolvePromise;
    expect(result.resolved).toBe(false);
    expect(result.output).toContain("error");
  });

  it("returns { resolved: false } when Pi process closes without agent_end", async () => {
    const { proc } = makeFakePiProcess();
    mockSpawn.mockReturnValue(proc);

    const resolvePromise = daemon.resolveConflictViaPi("diff content", "run-4");

    setImmediate(() => {
      proc.emit("close", 0);
    });

    const result = await resolvePromise;
    expect(result.resolved).toBe(false);
    expect(result.output).toContain("closed without agent_end");
  });

  it("returns { resolved: false } when spawn throws (pi binary not found)", async () => {
    mockSpawn.mockImplementation(() => {
      throw new Error("ENOENT: no such file or directory: 'pi'");
    });

    const result = await daemon.resolveConflictViaPi("conflict diff", "run-5");
    expect(result.resolved).toBe(false);
    expect(result.output).toContain("spawn pi");
  });

  it("collects text output from Pi events", async () => {
    const { proc } = makeFakePiProcess();
    mockSpawn.mockReturnValue(proc);

    const resolvePromise = daemon.resolveConflictViaPi("conflict content", "run-6");

    setImmediate(() => {
      proc.stdout.emit("data", JSON.stringify({ type: "text", text: "Resolution suggestion" }) + "\n");
      proc.stdout.emit("data", JSON.stringify({ type: "agent_end", reason: "done" }) + "\n");
    });

    const result = await resolvePromise;
    expect(result.resolved).toBe(true);
    expect(result.output).toContain("Resolution suggestion");
  });
});
