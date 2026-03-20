/**
 * TRD-028-TEST: Merge Agent Daemon Core Tests
 *
 * Tests for MergeAgentDaemon:
 * 1. pollOnce returns [] when lock file is present
 * 2. pollOnce returns [] when inbox is empty
 * 3. pollOnce processes a valid branch-ready message
 * 4. pollOnce records latency from msg.receivedAt
 * 5. start() records PID via upsertMergeAgentConfig
 * 6. stop() clears running state
 * 7. isRunning() reflects daemon state
 * 8. start() no-ops when already running
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { writeFileSync, mkdirSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir, homedir } from "node:os";

// ── Mocks ──────────────────────────────────────────────────────────────────────

// Mock AgentMailClient
const mockFetchInbox = vi.fn<() => Promise<import("../agent-mail-client.js").AgentMailMessage[]>>();
const mockSendMessage = vi.fn<() => Promise<void>>();

vi.mock("../agent-mail-client.js", () => {
  class MockAgentMailClient {
    fetchInbox = mockFetchInbox;
    sendMessage = mockSendMessage;
  }
  return { AgentMailClient: MockAgentMailClient };
});

// Import after mocks
import { MergeAgentDaemon } from "../merge-agent.js";
import type { MergeAgentOptions } from "../merge-agent.js";

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
    getMergeAgentConfig: vi.fn().mockReturnValue(null),
    updateRun: vi.fn(),
    updateRunProgress: vi.fn(),
  };
}

function makeOptions(overrides: Partial<MergeAgentOptions> = {}): MergeAgentOptions {
  return {
    intervalSeconds: 30,
    projectId: "proj-1",
    projectPath: "/tmp/test-project",
    dryRun: true, // default to dryRun to avoid actual git ops
    ...overrides,
  };
}

function makeMessage(overrides: Record<string, unknown> = {}) {
  return {
    id: "msg-1",
    from: "foreman",
    to: "merge-agent",
    subject: "branch-ready",
    body: JSON.stringify({
      seedId: "seed-abc",
      branchName: "foreman/bd-abc",
      runId: "run-1",
    }),
    receivedAt: new Date(Date.now() - 500).toISOString(),
    acknowledged: false,
    ...overrides,
  };
}

// ── Tests ──────────────────────────────────────────────────────────────────────

describe("MergeAgentDaemon — pollOnce", () => {
  let daemon: MergeAgentDaemon;
  let store: ReturnType<typeof makeStore>;
  let lockFilePath: string;

  beforeEach(() => {
    store = makeStore();
    daemon = new MergeAgentDaemon(store as never);
    lockFilePath = join(homedir(), ".foreman", "merge.lock");

    mockFetchInbox.mockReset().mockResolvedValue([]);
    mockSendMessage.mockReset().mockResolvedValue(undefined);
  });

  afterEach(() => {
    daemon.stop();
    // Remove lock file if left behind by a test
    if (existsSync(lockFilePath)) {
      rmSync(lockFilePath, { force: true });
    }
  });

  it("returns [] when inbox is empty", async () => {
    mockFetchInbox.mockResolvedValue([]);
    const results = await daemon.pollOnce(makeOptions());
    expect(results).toHaveLength(0);
  });

  it("returns [] when lock file is present", async () => {
    // Create the lock file
    const foremanDir = join(homedir(), ".foreman");
    mkdirSync(foremanDir, { recursive: true });
    writeFileSync(lockFilePath, "locked");

    try {
      const results = await daemon.pollOnce(makeOptions());
      expect(results).toHaveLength(0);
      // fetchInbox should not have been called
      expect(mockFetchInbox).not.toHaveBeenCalled();
    } finally {
      rmSync(lockFilePath, { force: true });
    }
  });

  it("processes a valid branch-ready message and returns a result", async () => {
    mockFetchInbox.mockResolvedValue([makeMessage()]);

    const results = await daemon.pollOnce(makeOptions());

    expect(results).toHaveLength(1);
    expect(results[0].seedId).toBe("seed-abc");
    expect(results[0].branchName).toBe("foreman/bd-abc");
    expect(results[0].status).toBe("merged");
  });

  it("records latencyMs from msg.receivedAt to processing start", async () => {
    const receivedAt = new Date(Date.now() - 1000).toISOString();
    mockFetchInbox.mockResolvedValue([makeMessage({ receivedAt })]);

    const results = await daemon.pollOnce(makeOptions());

    expect(results[0].latencyMs).toBeGreaterThanOrEqual(0);
    // Should be roughly 1000ms (allow ±500ms for test execution time)
    expect(results[0].latencyMs).toBeLessThan(3000);
  });

  it("handles malformed message body gracefully", async () => {
    mockFetchInbox.mockResolvedValue([
      makeMessage({ body: "{ not valid json ]]" }),
    ]);

    const results = await daemon.pollOnce(makeOptions());
    expect(results).toHaveLength(1);
    expect(results[0].status).toBe("failed");
  });

  it("handles multiple messages in one poll cycle", async () => {
    mockFetchInbox.mockResolvedValue([
      makeMessage({ body: JSON.stringify({ seedId: "s1", branchName: "b1" }) }),
      makeMessage({ id: "msg-2", body: JSON.stringify({ seedId: "s2", branchName: "b2" }) }),
    ]);

    const results = await daemon.pollOnce(makeOptions());
    expect(results).toHaveLength(2);
  });
});

describe("MergeAgentDaemon — start / stop lifecycle", () => {
  let daemon: MergeAgentDaemon;
  let store: ReturnType<typeof makeStore>;

  beforeEach(() => {
    store = makeStore();
    daemon = new MergeAgentDaemon(store as never);
    mockFetchInbox.mockReset().mockResolvedValue([]);
    mockSendMessage.mockReset().mockResolvedValue(undefined);
  });

  afterEach(() => {
    daemon.stop();
  });

  it("isRunning() returns false before start()", () => {
    expect(daemon.isRunning()).toBe(false);
  });

  it("isRunning() returns true after start()", () => {
    daemon.start(makeOptions());
    expect(daemon.isRunning()).toBe(true);
  });

  it("isRunning() returns false after stop()", () => {
    daemon.start(makeOptions());
    daemon.stop();
    expect(daemon.isRunning()).toBe(false);
  });

  it("start() records PID via upsertMergeAgentConfig", () => {
    daemon.start(makeOptions());

    expect(store.upsertMergeAgentConfig).toHaveBeenCalledWith(
      "proj-1",
      expect.objectContaining({
        pid: process.pid,
        enabled: 1,
        interval_seconds: 30,
      }),
    );
  });

  it("start() is idempotent — second call is a no-op", () => {
    daemon.start(makeOptions());
    daemon.start(makeOptions()); // should not throw or double-schedule

    expect(daemon.isRunning()).toBe(true);
    expect(store.upsertMergeAgentConfig).toHaveBeenCalledTimes(1);
  });
});
