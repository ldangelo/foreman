/**
 * Integration tests for AgentMailClient send/receive flow.
 *
 * These tests use a live Agent Mail server at http://localhost:8766.
 * They are skipped automatically when the server is not reachable,
 * so they are safe to run in CI (will just be skipped).
 *
 * To run against a live server:
 *   npx vitest run src/orchestrator/__tests__/agent-mail-integration.test.ts
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { AgentMailClient } from "../agent-mail-client.js";

const AGENT_MAIL_URL = "http://localhost:8766";
const PROJECT_KEY = process.cwd();

// Two-level liveness check:
// serverUp       = health endpoint returns OK (used by healthCheck test)
// serverFunctional = register_agent also works (used by all other tests)
let serverUp = false;
let serverFunctional = false;

beforeAll(async () => {
  try {
    const res = await fetch(`${AGENT_MAIL_URL}/health`, { signal: AbortSignal.timeout(2000) });
    serverUp = res.ok;
    if (!serverUp) return;

    // Also verify that register_agent is functional (DB may be broken even if health is OK).
    const probe = await fetch(`${AGENT_MAIL_URL}/mcp`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 0,
        method: "tools/call",
        params: {
          name: "register_agent",
          arguments: {
            project_key: PROJECT_KEY,
            program: "foreman-probe",
            task_description: "Probe",
            model: "claude-sonnet-4-6",
          },
        },
      }),
      signal: AbortSignal.timeout(3000),
    });
    const probeJson = await probe.json() as { result?: { isError?: boolean } };
    serverFunctional = !probeJson.result?.isError;
  } catch {
    serverUp = false;
    serverFunctional = false;
  }
});

function skipIfOffline() {
  return !serverFunctional;
}

afterAll(async () => {
  // Purge test messages left in the foreman inbox to keep it clean.
  if (!serverFunctional) return;
  try {
    const cleanup = new AgentMailClient({ baseUrl: AGENT_MAIL_URL });
    await cleanup.ensureProject(PROJECT_KEY);
    const messages = await cleanup.fetchInbox("foreman", { limit: 50 });
    for (const m of messages) {
      if (!m.acknowledged) {
        try {
          await cleanup.acknowledgeMessage("foreman", parseInt(m.id, 10));
        } catch {
          // Non-fatal
        }
      }
    }
  } catch {
    // Non-fatal cleanup
  }
});

describe("AgentMailClient integration — send and receive", () => {
  it("healthCheck returns true when server is running", async () => {
    const client = new AgentMailClient({ baseUrl: AGENT_MAIL_URL, projectKey: PROJECT_KEY });
    const result = await client.healthCheck();
    if (!serverUp) {
      expect(result).toBe(false);
    } else {
      expect(result).toBe(true);
    }
  });

  it("ensureProject registers the project successfully", async () => {
    if (skipIfOffline()) return;

    const client = new AgentMailClient({ baseUrl: AGENT_MAIL_URL });
    // Should not throw
    await expect(client.ensureProject(PROJECT_KEY)).resolves.not.toThrow();
  });

  it("ensureProject auto-registers a foreman agent and stores its name", async () => {
    if (skipIfOffline()) return;

    const client = new AgentMailClient({ baseUrl: AGENT_MAIL_URL });
    await client.ensureProject(PROJECT_KEY);

    // The foreman agent name should be set (adjective+noun format)
    expect(client.agentName).not.toBeNull();
    expect(client.agentName).toMatch(/^[A-Z][a-z]+[A-Z][a-z]+$/); // e.g. "PearlHawk"
  });

  it("ensureAgentRegistered returns an adjective+noun name for a phase role", async () => {
    if (skipIfOffline()) return;

    const client = new AgentMailClient({ baseUrl: AGENT_MAIL_URL, projectKey: PROJECT_KEY });
    await client.ensureProject(PROJECT_KEY);

    const name = await client.ensureAgentRegistered("test-sender");
    expect(name).not.toBeNull();
    expect(name).toBeTruthy();
    // Name should follow adjective+noun pattern
    expect(name?.length).toBeGreaterThan(4);
  });

  it("sendMessage delivers to foreman inbox and fetchInbox receives it", async () => {
    if (skipIfOffline()) return;

    // ── Setup: two clients — sender and receiver ──────────────────────────
    const sender = new AgentMailClient({ baseUrl: AGENT_MAIL_URL });
    const receiver = new AgentMailClient({ baseUrl: AGENT_MAIL_URL });

    await sender.ensureProject(PROJECT_KEY);
    await receiver.ensureProject(PROJECT_KEY);

    // Register the receiver so it has a known inbox
    const receiverRole = `integration-test-receiver-${Date.now()}`;
    const receiverName = await receiver.ensureAgentRegistered(receiverRole);
    expect(receiverName).not.toBeNull();

    // Register the sender so it has a sending identity
    const senderRole = `integration-test-sender-${Date.now()}`;
    await sender.ensureAgentRegistered(senderRole);
    // sender.agentName is now the auto-generated name for senderRole

    // ── Send a test message from sender to receiver ─────────────────────
    const testSubject = `test-${Date.now()}`;
    const testBody = JSON.stringify({ type: "phase-complete", phase: "explorer", seedId: "bd-test" });

    // Register the receiver role in sender's registry so sendMessage can route to it
    await sender.ensureAgentRegistered(receiverRole);
    // Override the cached name to point at receiverName
    // (normally the sender would look up the recipient's registered name)
    // For this test, use sendMessage with the actual generated name directly
    // by passing it as the 'to' field — registry will fall back to raw value if not cached
    await sender.sendMessage(receiverName!, testSubject, testBody);

    // ── Fetch receiver inbox and find the message ────────────────────────
    const messages = await receiver.fetchInbox(receiverRole, { limit: 50 });
    const found = messages.find((m) => m.subject === testSubject);

    expect(found).toBeDefined();
    expect(found?.body).toBe(testBody);
  });

  it("sendMessage to foreman resolves to the registered foreman name", async () => {
    if (skipIfOffline()) return;

    const client = new AgentMailClient({ baseUrl: AGENT_MAIL_URL });
    await client.ensureProject(PROJECT_KEY);

    // foreman should be registered now (ensureProject calls ensureAgentRegistered("foreman"))
    const foremanName = client.resolveAgentName("foreman");
    expect(foremanName).not.toBeNull();

    // Sending to "foreman" should resolve to the real registered name
    // (this tests the routing logic inside sendMessage)
    const workerClient = new AgentMailClient({ baseUrl: AGENT_MAIL_URL, projectKey: PROJECT_KEY });
    await workerClient.ensureProject(PROJECT_KEY);

    // Register a worker identity for sending
    await workerClient.ensureAgentRegistered("worker-test");

    // Send to "foreman" — internally resolves to the registered foreman name
    await expect(
      workerClient.sendMessage("foreman", "worker-start", JSON.stringify({ seedId: "bd-test", phase: "developer" }))
    ).resolves.not.toThrow();

    // Fetch foreman inbox and verify the message arrived
    const inbox = await client.fetchInbox("foreman", { limit: 20 });
    const found = inbox.find((m) => m.subject === "worker-start");
    expect(found).toBeDefined();
  });
});
