/**
 * TRD-001-TEST: acknowledgeMessage() Registry Resolution Tests
 *
 * Verifies that acknowledgeMessage() resolves logical role names via agentRegistry,
 * mirroring the behavior of fetchInbox(). Tests AC-001-1, AC-001-2, AC-001-3.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
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
      result: {
        content: [{ type: "text", text }],
      },
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

/** Extract the parsed JSON body sent in the last fetch call. */
async function lastRequestBody(): Promise<Record<string, unknown>> {
  const calls = mockFetch.mock.calls;
  if (calls.length === 0) throw new Error("No fetch calls recorded");
  const lastCall = calls[calls.length - 1];
  const body = lastCall[1]?.body as string;
  return JSON.parse(body) as Record<string, unknown>;
}

/** Extract agent_name from the last acknowledge_message mcpCall. */
async function lastAcknowledgeAgentName(): Promise<string> {
  const body = await lastRequestBody();
  const params = body["params"] as Record<string, unknown>;
  const args = params["arguments"] as Record<string, unknown>;
  return String(args["agent_name"]);
}

// ── Tests ──────────────────────────────────────────────────────────────────────

describe("acknowledgeMessage() registry resolution (TRD-001)", () => {
  it("AC-001-1: resolves registered role name to adjective+noun name via agentRegistry", async () => {
    // Arrange: create client and manually seed the registry with a known mapping
    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });

    // Seed agentRegistry by calling ensureAgentRegistered with a mock response
    mockFetch.mockResolvedValueOnce(
      mcpOkResponse({ name: "SwiftFalcon" }),
    );
    await client.ensureAgentRegistered("developer-bd-abc1");

    // Arrange: mock acknowledge response
    mockFetch.mockResolvedValueOnce(mcpOkResponse({ acknowledged: true }));

    // Act: acknowledge message using the logical role name
    await client.acknowledgeMessage("developer-bd-abc1", 42);

    // Assert: the mcpCall received the resolved adjective+noun name, not the role name
    const agentName = await lastAcknowledgeAgentName();
    expect(agentName).toBe("SwiftFalcon");
    expect(agentName).not.toBe("developer-bd-abc1");
  });

  it("AC-001-2: passes raw name when role is NOT in agentRegistry", async () => {
    // Arrange: fresh client with empty registry
    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });

    // Arrange: mock acknowledge response
    mockFetch.mockResolvedValueOnce(mcpOkResponse({ acknowledged: true }));

    // Act: acknowledge with unregistered role name
    await client.acknowledgeMessage("unknown-role", 42);

    // Assert: raw name is passed through unchanged
    const agentName = await lastAcknowledgeAgentName();
    expect(agentName).toBe("unknown-role");
  });

  it("AC-001-3: fetchInbox and acknowledgeMessage resolve to the same agent name", async () => {
    // Arrange: create client and register a role
    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });

    // Register developer-bd-abc1 -> "ClearEagle"
    mockFetch.mockResolvedValueOnce(
      mcpOkResponse({ name: "ClearEagle" }),
    );
    await client.ensureAgentRegistered("developer-bd-abc1");

    // Mock fetchInbox response (returns empty array)
    mockFetch.mockResolvedValueOnce(
      mcpOkResponse([]),
    );

    // Act: call fetchInbox
    await client.fetchInbox("developer-bd-abc1", { limit: 5 });

    // Capture agent_name used in fetchInbox call
    const fetchBody = await lastRequestBody();
    const fetchParams = fetchBody["params"] as Record<string, unknown>;
    const fetchArgs = fetchParams["arguments"] as Record<string, unknown>;
    const fetchAgentName = String(fetchArgs["agent_name"]);

    // Mock acknowledgeMessage response
    mockFetch.mockResolvedValueOnce(mcpOkResponse({ acknowledged: true }));

    // Act: call acknowledgeMessage
    await client.acknowledgeMessage("developer-bd-abc1", 99);
    const ackAgentName = await lastAcknowledgeAgentName();

    // Assert: both calls resolved to the same agent name
    expect(fetchAgentName).toBe("ClearEagle");
    expect(ackAgentName).toBe("ClearEagle");
    expect(fetchAgentName).toBe(ackAgentName);
  });

  it("silent failure: acknowledgeMessage catches errors and does not throw", async () => {
    // Arrange: client with network error
    const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
    mockFetch.mockRejectedValueOnce(new Error("Network error"));

    // Act & Assert: should not throw
    await expect(
      client.acknowledgeMessage("any-role", 1),
    ).resolves.toBeUndefined();
  });
});
