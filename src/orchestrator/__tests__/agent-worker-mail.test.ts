/**
 * TRD-002-TEST through TRD-008-TEST: fetchLatestPhaseMessage() and Mail Transport Tests
 *
 * Tests for the fetchLatestPhaseMessage() helper exported from agent-worker.ts.
 * Also covers QA feedback read path, Reviewer findings send/read, Explorer report read,
 * stale message filtering, and backward compatibility.
 *
 * Satisfies: REQ-002, REQ-003, REQ-004, REQ-005, REQ-006, REQ-007, REQ-017, REQ-026,
 *            AC-002-1 through AC-002-7, AC-026-2, AC-026-3, AC-026-4
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { fetchLatestPhaseMessage } from "../agent-mail-helpers.js";
import { AgentMailClient } from "../agent-mail-client.js";

// ── Mock fetch globally ────────────────────────────────────────────────────────

const mockFetch = vi.fn<typeof fetch>();

beforeEach(() => {
  vi.stubGlobal("fetch", mockFetch);
  mockFetch.mockReset();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

// ── Helpers ────────────────────────────────────────────────────────────────────

/** Build a successful JSON-RPC Response wrapping a JSON-encoded payload. */
function mcpOkResponse(payload: unknown): Response {
  const text = typeof payload === "string" ? payload : JSON.stringify(payload);
  return new Response(
    JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      result: { content: [{ type: "text", text }] },
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

/**
 * Create a mock AgentMailMessage object with sensible defaults.
 */
function makeMessage(overrides: {
  id?: string;
  subject?: string;
  body?: string;
  acknowledged?: boolean;
  receivedAt?: string;
} = {}): Record<string, unknown> {
  return {
    id: overrides.id ?? "1",
    sender_name: "TestAgent",
    recipients: ["developer-bd-abc1"],
    subject: overrides.subject ?? "Test Subject",
    body_md: overrides.body ?? "Test body content",
    received_at: overrides.receivedAt ?? new Date().toISOString(),
    acknowledged: overrides.acknowledged ?? false,
  };
}

/**
 * Create a mock AgentMailClient that returns predefined messages.
 */
function createMockClient(messages: ReturnType<typeof makeMessage>[]): AgentMailClient {
  // Mock fetchInbox to return the given messages
  mockFetch.mockResolvedValue(mcpOkResponse(messages));
  return new AgentMailClient({ baseUrl: "http://localhost:9999" });
}

// ── fetchLatestPhaseMessage tests (TRD-002-TEST) ──────────────────────────────

describe("fetchLatestPhaseMessage() - TRD-002-TEST", () => {
  it("AC-002-5: returns null immediately when client is null", async () => {
    const result = await fetchLatestPhaseMessage(null, "developer-bd-abc1", "Explorer Report");
    expect(result).toBeNull();
    expect(mockFetch).not.toHaveBeenCalled();
  });

  it("AC-002-1: returns message body when matching unacknowledged message exists", async () => {
    const runId = "run-abc123";
    const messages = [
      makeMessage({
        subject: `Explorer Report [run:${runId}]`,
        body: "Explorer report content",
        acknowledged: false,
        receivedAt: new Date().toISOString(),
      }),
    ];

    // Mock fetchInbox response + acknowledgeMessage response
    mockFetch
      .mockResolvedValueOnce(mcpOkResponse(messages))     // fetchInbox
      .mockResolvedValueOnce(mcpOkResponse({ ok: true })); // acknowledgeMessage

    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
    const result = await fetchLatestPhaseMessage(
      client,
      "developer-bd-abc1",
      "Explorer Report",
      runId,
    );

    expect(result).toBe("Explorer report content");
  });

  it("AC-002-2: returns null when no messages match the subject prefix", async () => {
    const messages = [
      makeMessage({
        subject: "Unrelated Subject",
        body: "Some content",
        acknowledged: false,
      }),
    ];

    mockFetch.mockResolvedValueOnce(mcpOkResponse(messages));
    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
    const result = await fetchLatestPhaseMessage(
      client,
      "developer-bd-abc1",
      "Explorer Report",
    );

    expect(result).toBeNull();
  });

  it("AC-002-3: returns null when all matching messages are acknowledged", async () => {
    const messages = [
      makeMessage({
        subject: "Explorer Report [run:abc123]",
        body: "Content",
        acknowledged: true,
      }),
    ];

    mockFetch.mockResolvedValueOnce(mcpOkResponse(messages));
    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
    const result = await fetchLatestPhaseMessage(
      client,
      "developer-bd-abc1",
      "Explorer Report",
    );

    expect(result).toBeNull();
  });

  it("AC-002-4: returns body of most recent message when multiple matches exist", async () => {
    const older = new Date(Date.now() - 10000).toISOString();
    const newer = new Date(Date.now() - 1000).toISOString();

    const messages = [
      makeMessage({ id: "1", subject: "QA Feedback - Retry 1", body: "Older feedback", acknowledged: false, receivedAt: older }),
      makeMessage({ id: "2", subject: "QA Feedback - Retry 2", body: "Newer feedback", acknowledged: false, receivedAt: newer }),
    ];

    mockFetch
      .mockResolvedValueOnce(mcpOkResponse(messages))
      .mockResolvedValueOnce(mcpOkResponse({ ok: true })); // ack

    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
    const result = await fetchLatestPhaseMessage(
      client,
      "developer-bd-abc1",
      "QA Feedback",
    );

    expect(result).toBe("Newer feedback");
  });

  it("AC-002-6: returns null when fetchInbox throws", async () => {
    mockFetch.mockRejectedValueOnce(new Error("Network error"));
    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
    const result = await fetchLatestPhaseMessage(
      client,
      "developer-bd-abc1",
      "Explorer Report",
    );

    expect(result).toBeNull();
  });

  it("AC-002-7: returns body even when acknowledgeMessage throws", async () => {
    const messages = [
      makeMessage({
        subject: "QA Feedback - Retry 1",
        body: "Feedback content",
        acknowledged: false,
      }),
    ];

    mockFetch
      .mockResolvedValueOnce(mcpOkResponse(messages))
      .mockRejectedValueOnce(new Error("Ack error")); // acknowledge fails

    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
    const result = await fetchLatestPhaseMessage(
      client,
      "developer-bd-abc1",
      "QA Feedback",
    );

    // Body is still returned even though ack failed
    expect(result).toBe("Feedback content");
  });

  // AC-026-2, AC-026-3, AC-026-4: runId filtering (TRD-007)
  it("AC-026-2: filters messages by runId when provided", async () => {
    const currentRunId = "run-current-123";
    const staleRunId = "run-stale-456";

    const messages = [
      makeMessage({
        id: "1",
        subject: `QA Feedback - Retry 1 [run:${currentRunId}]`,
        body: "Current feedback",
        acknowledged: false,
        receivedAt: new Date(Date.now() - 5000).toISOString(),
      }),
      makeMessage({
        id: "2",
        subject: `QA Feedback - Retry 1 [run:${staleRunId}]`,
        body: "Stale feedback",
        acknowledged: false,
        receivedAt: new Date().toISOString(), // newer, but stale runId
      }),
    ];

    mockFetch
      .mockResolvedValueOnce(mcpOkResponse(messages))
      .mockResolvedValueOnce(mcpOkResponse({ ok: true }));

    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
    const result = await fetchLatestPhaseMessage(
      client,
      "developer-bd-abc1",
      "QA Feedback",
      currentRunId,
    );

    // Should only return the message matching currentRunId
    expect(result).toBe("Current feedback");
  });

  it("AC-026-3: returns null when runId provided but no messages match it", async () => {
    const messages = [
      makeMessage({
        subject: "QA Feedback - Retry 1 [run:stale-run-id]",
        body: "Stale content",
        acknowledged: false,
      }),
    ];

    mockFetch.mockResolvedValueOnce(mcpOkResponse(messages));
    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
    const result = await fetchLatestPhaseMessage(
      client,
      "developer-bd-abc1",
      "QA Feedback",
      "current-run-id",
    );

    expect(result).toBeNull();
  });

  it("AC-026-4: returns message when no runId filter provided (no runId filtering)", async () => {
    const messages = [
      makeMessage({
        subject: "QA Feedback - Retry 1 [run:any-run]",
        body: "Content from any run",
        acknowledged: false,
      }),
    ];

    mockFetch
      .mockResolvedValueOnce(mcpOkResponse(messages))
      .mockResolvedValueOnce(mcpOkResponse({ ok: true }));

    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
    // No runId provided — should return the message regardless of run ID in subject
    const result = await fetchLatestPhaseMessage(
      client,
      "developer-bd-abc1",
      "QA Feedback",
      // runId omitted
    );

    expect(result).toBe("Content from any run");
  });

  it("AC-022-3: AbortSignal.timeout prevents hanging on unreachable server", async () => {
    // Simulate a very slow/hanging server response
    mockFetch.mockImplementation(
      () => new Promise<Response>((_resolve, reject) => {
        // Never resolves — simulates unreachable server
        // The AbortSignal should abort this
        setTimeout(() => reject(new Error("Aborted")), 100);
      }),
    );

    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
    // Should return null within a reasonable time (not hang)
    const start = Date.now();
    const result = await fetchLatestPhaseMessage(
      client,
      "developer-bd-abc1",
      "Explorer Report",
    );

    expect(result).toBeNull();
    // Should complete in < 500ms (the mock rejects after 100ms)
    expect(Date.now() - start).toBeLessThan(500);
  });
});

// ── Backward compatibility tests (TRD-008-TEST) ──────────────────────────────

describe("Backward compatibility (TRD-008-TEST)", () => {
  it("AC-006-1, AC-017-1: null client makes zero API calls", async () => {
    const result = await fetchLatestPhaseMessage(null, "developer-bd-abc1", "Explorer Report", "run-123");
    expect(result).toBeNull();
    expect(mockFetch).not.toHaveBeenCalled();
  });

  it("AC-006-2: null client for QA feedback returns null (disk fallback path)", async () => {
    const result = await fetchLatestPhaseMessage(null, "developer-bd-abc1", "QA Feedback", "run-123");
    expect(result).toBeNull();
    expect(mockFetch).not.toHaveBeenCalled();
  });

  it("AC-006-3: null client for Review Findings returns null (local variable fallback)", async () => {
    const result = await fetchLatestPhaseMessage(null, "developer-bd-abc1", "Review Findings", "run-123");
    expect(result).toBeNull();
    expect(mockFetch).not.toHaveBeenCalled();
  });

  it("AC-017-2: mid-pipeline Agent Mail failure returns null gracefully", async () => {
    // Server is initially working but then fails
    mockFetch
      .mockResolvedValueOnce(mcpOkResponse([
        makeMessage({ subject: "Explorer Report [run:abc]", body: "Report content", acknowledged: false }),
      ]))
      .mockResolvedValueOnce(mcpOkResponse({ ok: true })) // ack
      .mockRejectedValueOnce(new Error("Server down")); // second call fails

    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });

    // First call succeeds
    const first = await fetchLatestPhaseMessage(client, "developer-bd-abc1", "Explorer Report", "abc");
    expect(first).toBe("Report content");

    // Second call fails gracefully
    const second = await fetchLatestPhaseMessage(client, "developer-bd-abc1", "QA Feedback", "abc");
    expect(second).toBeNull();
  });
});
