/**
 * Tests for `foreman inbox` command logic.
 *
 * Covers:
 *   - `--all` without `--watch` shows messages from all runs chronologically
 *   - `--all` with `--agent` filters by recipient
 *   - `--all` with `--unread` filters unread only
 *   - `--all --watch` polls running runs (in addition to completed/failed)
 *   - Single-run mode still resolves the latest run when no flags are given
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";
import type { Message, Run } from "../../lib/store.js";

// ── Helpers ─────────────────────────────────────────────────────────────────

function makeTmpStore(): { store: ForemanStore; tmpDir: string } {
  const tmpDir = mkdtempSync(join(tmpdir(), "foreman-inbox-test-"));
  const store = new ForemanStore(join(tmpDir, "test.db"));
  return { store, tmpDir };
}

function seedRun(store: ForemanStore, seedId: string, status: Run["status"] = "running"): Run {
  const project = store.registerProject(`proj-${seedId}`, `/path/${seedId}`);
  const run = store.createRun(project.id, seedId, "claude-code");
  store.updateRun(run.id, { status });
  return { ...run, status };
}

function sendMessage(
  store: ForemanStore,
  runId: string,
  from: string,
  to: string,
  subject = "hello",
  body = "body",
): Message {
  return store.sendMessage(runId, from, to, subject, body);
}

// ── Unit tests for fetchMessages-like logic ──────────────────────────────────

describe("inbox --all one-shot mode (store layer)", () => {
  let store: ForemanStore;
  let tmpDir: string;

  beforeEach(() => {
    ({ store, tmpDir } = makeTmpStore());
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("getAllMessagesGlobal returns messages from all runs in chronological order", () => {
    const run1 = seedRun(store, "seed-1");
    const run2 = seedRun(store, "seed-2");

    const m1 = sendMessage(store, run1.id, "explorer", "developer", "msg-1");
    const m2 = sendMessage(store, run2.id, "explorer", "qa", "msg-2");
    const m3 = sendMessage(store, run1.id, "developer", "foreman", "msg-3");

    const messages = store.getAllMessagesGlobal(100);
    expect(messages.length).toBe(3);

    // Should be in chronological order (ASC created_at)
    const ids = messages.map((m) => m.id);
    expect(ids).toContain(m1.id);
    expect(ids).toContain(m2.id);
    expect(ids).toContain(m3.id);

    // Verify chronological: created_at timestamps should be non-decreasing
    for (let i = 1; i < messages.length; i++) {
      expect(new Date(messages[i]!.created_at).getTime()).toBeGreaterThanOrEqual(
        new Date(messages[i - 1]!.created_at).getTime(),
      );
    }
  });

  it("getAllMessagesGlobal respects the limit parameter", () => {
    const run = seedRun(store, "seed-limit");
    for (let i = 0; i < 10; i++) {
      sendMessage(store, run.id, "explorer", "developer", `msg-${i}`);
    }

    const messages = store.getAllMessagesGlobal(5);
    expect(messages.length).toBe(5);
  });

  it("getAllMessagesGlobal returns empty array when no messages exist", () => {
    const messages = store.getAllMessagesGlobal(50);
    expect(messages).toEqual([]);
  });

  it("agent filter can be applied to getAllMessagesGlobal results", () => {
    const run = seedRun(store, "seed-agent");
    sendMessage(store, run.id, "explorer", "developer", "for-dev");
    sendMessage(store, run.id, "explorer", "qa", "for-qa");
    sendMessage(store, run.id, "developer", "foreman", "for-foreman");

    const all = store.getAllMessagesGlobal(100);
    const devOnly = all.filter((m) => m.recipient_agent_type === "developer");
    expect(devOnly.length).toBe(1);
    expect(devOnly[0]!.subject).toBe("for-dev");
  });

  it("unread filter can be applied to getAllMessagesGlobal results", () => {
    const run = seedRun(store, "seed-unread");
    const m1 = sendMessage(store, run.id, "explorer", "developer", "unread-msg");
    const m2 = sendMessage(store, run.id, "explorer", "developer", "read-msg");

    // Mark m2 as read
    store.markMessageRead(m2.id);

    const all = store.getAllMessagesGlobal(100);
    const unreadOnly = all.filter((m) => m.read === 0);
    expect(unreadOnly.length).toBe(1);
    expect(unreadOnly[0]!.id).toBe(m1.id);
  });

  it("markMessageRead marks a specific message as read", () => {
    const run = seedRun(store, "seed-ack");
    const m = sendMessage(store, run.id, "explorer", "developer", "to-ack");

    expect(m.read).toBe(0);
    const changed = store.markMessageRead(m.id);
    expect(changed).toBe(true);

    const after = store.getAllMessagesGlobal(10);
    const found = after.find((msg) => msg.id === m.id);
    expect(found?.read).toBe(1);
  });
});

// ── Tests for --all --watch poll including running runs ──────────────────────

describe("inbox --all --watch: getRunsByStatuses includes running", () => {
  let store: ForemanStore;
  let tmpDir: string;

  beforeEach(() => {
    ({ store, tmpDir } = makeTmpStore());
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("getRunsByStatuses includes running runs when status is requested", () => {
    const runA = seedRun(store, "seed-running", "running");
    const runB = seedRun(store, "seed-completed", "completed");
    const runC = seedRun(store, "seed-failed", "failed");

    const allThree = store.getRunsByStatuses(["running", "completed", "failed"]);
    const ids = allThree.map((r) => r.id);

    expect(ids).toContain(runA.id);
    expect(ids).toContain(runB.id);
    expect(ids).toContain(runC.id);
  });

  it("getRunsByStatuses with only completed+failed misses running runs", () => {
    const runA = seedRun(store, "seed-running2", "running");
    const runB = seedRun(store, "seed-done", "completed");

    const completedFailed = store.getRunsByStatuses(["completed", "failed"]);
    const ids = completedFailed.map((r) => r.id);

    expect(ids).not.toContain(runA.id); // the bug: running is missed
    expect(ids).toContain(runB.id);
  });

  it("newly running run is detected when polling with running status included", () => {
    // Simulate: start with no running runs, then a run transitions to running
    const seenRunIds = new Set<string>();

    // Initial seed (empty — no running runs yet)
    const initRuns = store.getRunsByStatuses(["completed", "failed", "running"]);
    for (const r of initRuns) seenRunIds.add(r.id);
    expect(seenRunIds.size).toBe(0);

    // New run starts
    const newRun = seedRun(store, "seed-new-run", "running");

    // Poll — should detect the new running run
    const pollRuns = store.getRunsByStatuses(["completed", "failed", "running"]);
    const newRuns = pollRuns.filter((r) => !seenRunIds.has(r.id));

    expect(newRuns.length).toBe(1);
    expect(newRuns[0]!.id).toBe(newRun.id);
    expect(newRuns[0]!.status).toBe("running");
  });
});

// ── Integration: multi-run message scenario ──────────────────────────────────

describe("inbox --all: cross-run message aggregation", () => {
  let store: ForemanStore;
  let tmpDir: string;

  beforeEach(() => {
    ({ store, tmpDir } = makeTmpStore());
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("messages from multiple runs are all returned by getAllMessagesGlobal", () => {
    const run1 = seedRun(store, "multi-1", "completed");
    const run2 = seedRun(store, "multi-2", "running");
    const run3 = seedRun(store, "multi-3", "failed");

    sendMessage(store, run1.id, "explorer", "developer", "from-run1");
    sendMessage(store, run2.id, "developer", "qa", "from-run2");
    sendMessage(store, run3.id, "qa", "reviewer", "from-run3");

    const all = store.getAllMessagesGlobal(100);
    expect(all.length).toBe(3);

    const runIds = new Set(all.map((m) => m.run_id));
    expect(runIds.has(run1.id)).toBe(true);
    expect(runIds.has(run2.id)).toBe(true);
    expect(runIds.has(run3.id)).toBe(true);
  });

  it("single-run getAllMessages does NOT return messages from other runs", () => {
    const run1 = seedRun(store, "single-1", "completed");
    const run2 = seedRun(store, "single-2", "running");

    sendMessage(store, run1.id, "explorer", "developer", "run1-msg");
    sendMessage(store, run2.id, "explorer", "developer", "run2-msg");

    const run1Only = store.getAllMessages(run1.id);
    expect(run1Only.length).toBe(1);
    expect(run1Only[0]!.run_id).toBe(run1.id);
  });
});
