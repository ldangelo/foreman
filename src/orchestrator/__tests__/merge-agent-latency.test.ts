/**
 * TRD-034-TEST: Merge Processing Performance Tests
 *
 * Tests for latency tracking in MergeAgentDaemon.pollOnce():
 * 1. latencyMs is present in all result entries
 * 2. latencyMs approximates time from msg.receivedAt to processing start
 * 3. latencyMs is non-negative
 * 4. Multiple messages each have independent latency values
 * 5. Recent messages (just sent) have latency near 0
 * 6. Old messages (sent minutes ago) have large latency values
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Mocks ──────────────────────────────────────────────────────────────────────

const mockFetchInbox = vi.fn();
const mockSendMessage = vi.fn().mockResolvedValue(undefined);

vi.mock("../agent-mail-client.js", () => {
  class MockAgentMailClient {
    fetchInbox = mockFetchInbox;
    sendMessage = mockSendMessage;
  }
  return { AgentMailClient: MockAgentMailClient };
});

vi.mock("node:fs", () => ({
  existsSync: vi.fn().mockReturnValue(false), // no lock file
}));

// Import after mocks
import { MergeAgentDaemon } from "../merge-agent.js";
import type { MergeAgentOptions } from "../merge-agent.js";

// ── Helpers ────────────────────────────────────────────────────────────────────

function makeStore() {
  return {
    upsertMergeAgentConfig: vi.fn().mockReturnValue({ id: 1 }),
    updateRun: vi.fn(),
  };
}

const DEFAULT_OPTS: MergeAgentOptions = {
  intervalSeconds: 30,
  projectId: "proj-1",
  projectPath: "/tmp",
  dryRun: true,
};

function makeMessage(receivedAt: string, seedId = "seed-lat", id = "msg-1") {
  return {
    id,
    from: "foreman",
    to: "merge-agent",
    subject: "branch-ready",
    body: JSON.stringify({ seedId, branchName: `foreman/bd-${id}` }),
    receivedAt,
    acknowledged: false,
  };
}

// ── Tests ──────────────────────────────────────────────────────────────────────

describe("MergeAgentDaemon — latency tracking (TRD-034)", () => {
  let daemon: MergeAgentDaemon;

  beforeEach(() => {
    daemon = new MergeAgentDaemon(makeStore() as never);
    mockFetchInbox.mockReset().mockResolvedValue([]);
    mockSendMessage.mockReset().mockResolvedValue(undefined);
  });

  it("latencyMs is present in result for each processed message", async () => {
    const receivedAt = new Date(Date.now() - 100).toISOString();
    mockFetchInbox.mockResolvedValue([makeMessage(receivedAt)]);

    const results = await daemon.pollOnce(DEFAULT_OPTS);

    expect(results[0].latencyMs).toBeDefined();
    expect(typeof results[0].latencyMs).toBe("number");
  });

  it("latencyMs is non-negative", async () => {
    const receivedAt = new Date(Date.now() - 500).toISOString();
    mockFetchInbox.mockResolvedValue([makeMessage(receivedAt)]);

    const results = await daemon.pollOnce(DEFAULT_OPTS);

    expect(results[0].latencyMs).toBeGreaterThanOrEqual(0);
  });

  it("latencyMs approximates elapsed time since receivedAt", async () => {
    const delayMs = 2000;
    const receivedAt = new Date(Date.now() - delayMs).toISOString();
    mockFetchInbox.mockResolvedValue([makeMessage(receivedAt)]);

    const results = await daemon.pollOnce(DEFAULT_OPTS);

    // Allow generous tolerance: the recorded latency should be roughly 2000ms
    // (± 1000ms to account for test execution overhead)
    expect(results[0].latencyMs).toBeGreaterThanOrEqual(delayMs - 1000);
    expect(results[0].latencyMs).toBeLessThan(delayMs + 2000);
  });

  it("recent messages have latency near 0 (< 200ms)", async () => {
    const receivedAt = new Date(Date.now()).toISOString(); // just now
    mockFetchInbox.mockResolvedValue([makeMessage(receivedAt)]);

    const results = await daemon.pollOnce(DEFAULT_OPTS);

    // Should be very small — well under 200ms
    expect(results[0].latencyMs).toBeLessThan(200);
  });

  it("old messages have large latency (> 5000ms)", async () => {
    const receivedAt = new Date(Date.now() - 10_000).toISOString(); // 10 seconds ago
    mockFetchInbox.mockResolvedValue([makeMessage(receivedAt)]);

    const results = await daemon.pollOnce(DEFAULT_OPTS);

    expect(results[0].latencyMs).toBeGreaterThan(5_000);
  });

  it("multiple messages each have independent latency values", async () => {
    const now = Date.now();
    mockFetchInbox.mockResolvedValue([
      makeMessage(new Date(now - 1000).toISOString(), "seed-a", "msg-a"),
      makeMessage(new Date(now - 5000).toISOString(), "seed-b", "msg-b"),
    ]);

    const results = await daemon.pollOnce(DEFAULT_OPTS);

    expect(results).toHaveLength(2);
    const latencies = results.map((r) => r.latencyMs ?? 0);
    // The second message (5s old) should have higher latency than first (1s old)
    expect(latencies[1]).toBeGreaterThan(latencies[0]);
  });

  it("empty inbox returns empty results (no latency values to check)", async () => {
    mockFetchInbox.mockResolvedValue([]);

    const results = await daemon.pollOnce(DEFAULT_OPTS);
    expect(results).toHaveLength(0);
  });
});
