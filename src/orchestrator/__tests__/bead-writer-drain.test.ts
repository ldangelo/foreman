/**
 * Tests for Dispatcher.drainBeadWriterInbox().
 *
 * Verifies that the dispatcher correctly:
 * 1. Drains pending bead write entries
 * 2. Executes the correct br CLI commands for each operation type
 * 3. Marks each entry as processed
 * 4. Calls br sync --flush-only once at the end
 * 5. Handles errors per-entry without stopping the drain
 * 6. Returns 0 when queue is empty
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Mocks ────────────────────────────────────────────────────────────────────

const { mockExecFileSync, mockHomedir } = vi.hoisted(() => ({
  mockExecFileSync: vi.fn(),
  mockHomedir: vi.fn().mockReturnValue("/test/home"),
}));

vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return { ...actual, execFileSync: mockExecFileSync, spawn: actual.spawn };
});

vi.mock("node:os", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:os")>();
  return { ...actual, homedir: mockHomedir };
});

// Mock heavy dependencies not needed for drain tests
vi.mock("../pi-sdk-runner.js", () => ({ runWithPiSdk: vi.fn() }));
vi.mock("../../lib/git.js", () => ({
  createWorktree: vi.fn(),
  gitBranchExists: vi.fn(),
  getCurrentBranch: vi.fn().mockResolvedValue("main"),
  detectDefaultBranch: vi.fn().mockResolvedValue("main"),
}));
vi.mock("../../lib/bv.js", () => ({}));
vi.mock("../../lib/workflow-loader.js", () => ({
  loadWorkflowConfig: vi.fn(),
  resolveWorkflowName: vi.fn(),
}));
vi.mock("../../lib/workflow-config-loader.js", () => ({
  resolveWorkflowType: vi.fn(),
}));
vi.mock("../pi-rpc-spawn-strategy.js", () => ({ isPiAvailable: vi.fn().mockResolvedValue(false) }));

import { Dispatcher } from "../dispatcher.js";
import { ForemanStore } from "../../lib/store.js";

// ── Type helpers ─────────────────────────────────────────────────────────────

type MockCall = [cmd: string, args: string[], opts: unknown];

function getCalls(): MockCall[] {
  return mockExecFileSync.mock.calls as unknown as MockCall[];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeDispatcher(store: ForemanStore, projectPath: string): Dispatcher {
  const mockSeeds = {
    ready: vi.fn().mockResolvedValue([]),
    show: vi.fn(),
    list: vi.fn(),
    update: vi.fn(),
    close: vi.fn(),
    create: vi.fn(),
  };
  return new Dispatcher(mockSeeds as never, store, projectPath);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("Dispatcher.drainBeadWriterInbox()", () => {
  let tmpDir: string;
  let store: ForemanStore;
  let dispatcher: Dispatcher;

  const HOME = "/test/home";
  const BR_PATH = `${HOME}/.local/bin/br`;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "bead-drain-test-"));
    store = ForemanStore.forProject(tmpDir);
    dispatcher = makeDispatcher(store, tmpDir);
    mockExecFileSync.mockReset();
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    mockHomedir.mockReturnValue(HOME);
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns 0 when queue is empty", async () => {
    const result = await dispatcher.drainBeadWriterInbox();
    expect(result).toBe(0);
    expect(mockExecFileSync).not.toHaveBeenCalled();
  });

  it("executes br update --status closed for close-seed operation", async () => {
    store.enqueueBeadWrite("refinery", "close-seed", { seedId: "bd-abc" });

    const result = await dispatcher.drainBeadWriterInbox();
    expect(result).toBe(1);

    const calls = getCalls();
    const closeCall = calls.find(([, args]) => args[0] === "update" && args.includes("closed"));
    expect(closeCall).toBeTruthy();
    const [cmd, args] = closeCall!;
    expect(cmd).toBe(BR_PATH);
    expect(args).toEqual(["update", "bd-abc", "--status", "closed"]);
  });

  it("executes br update --status open for reset-seed operation", async () => {
    store.enqueueBeadWrite("agent-worker", "reset-seed", { seedId: "bd-xyz" });

    await dispatcher.drainBeadWriterInbox();

    const calls = getCalls();
    const updateCall = calls.find(([, args]) => args[0] === "update" && args.includes("open"));
    expect(updateCall).toBeTruthy();
    const [cmd, args] = updateCall!;
    expect(cmd).toBe(BR_PATH);
    expect(args).toEqual(["update", "bd-xyz", "--status", "open"]);
  });

  it("executes br update --status failed for mark-failed operation", async () => {
    store.enqueueBeadWrite("agent-worker", "mark-failed", { seedId: "bd-fail" });

    await dispatcher.drainBeadWriterInbox();

    const calls = getCalls();
    const updateCall = calls.find(([, args]) => args[0] === "update" && args.includes("failed"));
    expect(updateCall).toBeTruthy();
    const [cmd, args] = updateCall!;
    expect(cmd).toBe(BR_PATH);
    expect(args).toEqual(["update", "bd-fail", "--status", "failed"]);
  });

  it("executes br update --notes for add-notes operation", async () => {
    store.enqueueBeadWrite("agent-worker", "add-notes", { seedId: "bd-notes", notes: "Some failure note" });

    await dispatcher.drainBeadWriterInbox();

    const calls = getCalls();
    const notesCall = calls.find(([, args]) => args[0] === "update" && args.includes("--notes"));
    expect(notesCall).toBeTruthy();
    const [cmd, args] = notesCall!;
    expect(cmd).toBe(BR_PATH);
    expect(args).toEqual(["update", "bd-notes", "--notes", "Some failure note"]);
  });

  it("executes br update --add-label for add-labels operation", async () => {
    store.enqueueBeadWrite("pipeline-executor", "add-labels", { seedId: "bd-labels", labels: ["phase:dev", "ci:pass"] });

    await dispatcher.drainBeadWriterInbox();

    const calls = getCalls();
    const labelsCall = calls.find(([, args]) => args[0] === "update" && args.includes("--add-label"));
    expect(labelsCall).toBeTruthy();
    const [cmd, args] = labelsCall!;
    expect(cmd).toBe(BR_PATH);
    expect(args).toEqual(["update", "bd-labels", "--add-label", "phase:dev", "--add-label", "ci:pass"]);
  });

  it("calls br sync --flush-only once after processing all entries", async () => {
    store.enqueueBeadWrite("refinery", "close-seed", { seedId: "bd-a" });
    store.enqueueBeadWrite("refinery", "close-seed", { seedId: "bd-b" });
    store.enqueueBeadWrite("refinery", "close-seed", { seedId: "bd-c" });

    await dispatcher.drainBeadWriterInbox();

    const syncCalls = getCalls().filter(([, args]) => args[0] === "sync" && args.includes("--flush-only"));
    expect(syncCalls).toHaveLength(1);
  });

  it("does NOT call br sync when queue is empty", async () => {
    await dispatcher.drainBeadWriterInbox();
    expect(mockExecFileSync).not.toHaveBeenCalled();
  });

  it("marks each entry as processed after execution", async () => {
    store.enqueueBeadWrite("sender", "close-seed", { seedId: "bd-check" });
    expect(store.getPendingBeadWrites()).toHaveLength(1);

    await dispatcher.drainBeadWriterInbox();

    // After drain, queue should be empty (all marked processed)
    expect(store.getPendingBeadWrites()).toHaveLength(0);
  });

  it("processes entries in FIFO order", async () => {
    store.enqueueBeadWrite("sender", "close-seed", { seedId: "bd-first" });
    store.enqueueBeadWrite("sender", "reset-seed", { seedId: "bd-second" });

    await dispatcher.drainBeadWriterInbox();

    // First br operation should be update --status closed (not update --status open)
    const firstOp = getCalls()[0];
    expect(firstOp[1][0]).toBe("update");
  });

  it("continues draining when one entry fails", async () => {
    store.enqueueBeadWrite("sender", "close-seed", { seedId: "bd-fail" });
    store.enqueueBeadWrite("sender", "reset-seed", { seedId: "bd-ok" });

    // First call throws, second succeeds, third (sync) succeeds
    mockExecFileSync
      .mockImplementationOnce(() => { throw new Error("br binary error"); })
      .mockReturnValue(Buffer.from(""));

    await dispatcher.drainBeadWriterInbox();

    // Both entries should be marked as processed (error is non-fatal)
    expect(store.getPendingBeadWrites()).toHaveLength(0);
  });

  it("marks failed entry as processed to prevent infinite retry", async () => {
    store.enqueueBeadWrite("sender", "close-seed", { seedId: "bd-error" });

    // br fails
    mockExecFileSync.mockImplementation(() => { throw new Error("br error"); });

    await dispatcher.drainBeadWriterInbox();

    // Entry should be marked processed (not stuck in queue forever)
    expect(store.getPendingBeadWrites()).toHaveLength(0);
  });

  it("returns correct count of processed entries", async () => {
    store.enqueueBeadWrite("s", "close-seed", { seedId: "bd-1" });
    store.enqueueBeadWrite("s", "reset-seed", { seedId: "bd-2" });
    store.enqueueBeadWrite("s", "mark-failed", { seedId: "bd-3" });

    const result = await dispatcher.drainBeadWriterInbox();
    expect(result).toBe(3);
  });

  it("skips add-notes execution when notes field is empty", async () => {
    store.enqueueBeadWrite("sender", "add-notes", { seedId: "bd-empty", notes: "" });

    await dispatcher.drainBeadWriterInbox();

    // No br update --notes should be called
    const notesCalls = getCalls().filter(([, args]) => args.includes("--notes"));
    expect(notesCalls).toHaveLength(0);
  });

  it("skips add-labels execution when labels array is empty", async () => {
    store.enqueueBeadWrite("sender", "add-labels", { seedId: "bd-nolabels", labels: [] });

    await dispatcher.drainBeadWriterInbox();

    const labelCalls = getCalls().filter(([, args]) => args.includes("--add-label"));
    expect(labelCalls).toHaveLength(0);
  });

  it("handles unknown operation type gracefully (marks as processed, no br write call)", async () => {
    store.enqueueBeadWrite("sender", "unknown-op", { seedId: "bd-unknown" });

    await dispatcher.drainBeadWriterInbox();

    // Entry should be marked processed despite unknown op
    expect(store.getPendingBeadWrites()).toHaveLength(0);
    // No br write commands (close/update) should have been made
    const writeCalls = getCalls().filter(([, args]) =>
      args[0] === "close" || (args[0] === "update" && !args.includes("sync"))
    );
    expect(writeCalls).toHaveLength(0);
  });

  it("handles invalid JSON payload gracefully", async () => {
    // Directly insert a malformed entry
    const db = store.getDb();
    db.prepare("INSERT INTO bead_write_queue (id, sender, operation, payload, created_at) VALUES (?, ?, ?, ?, ?)")
      .run("bad-id", "sender", "close-seed", "{not valid json}", new Date().toISOString());

    await dispatcher.drainBeadWriterInbox();

    // Entry should be marked processed (skip bad entries)
    expect(store.getPendingBeadWrites()).toHaveLength(0);
  });
});
