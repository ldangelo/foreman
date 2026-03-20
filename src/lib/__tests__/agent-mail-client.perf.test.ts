/**
 * TRD-027: Agent Mail Client — Performance Benchmarks
 *
 * These tests run against a guaranteed-unreachable Agent Mail server
 * (localhost:19999) to verify that the client does not hang and respects its
 * configured timeout when the service is unavailable.
 *
 * A 100ms timeoutMs is used to keep the suite fast.  The assertions check
 * wall-clock elapsed time rather than mocks so that real network-stack
 * behaviour is exercised.
 */

import { describe, it, expect } from "vitest";
import { AgentMailClient } from "../../orchestrator/agent-mail-client.js";

// Use a port that is guaranteed to be closed on any developer machine.
const UNREACHABLE_URL = "http://localhost:19999";
const FAST_TIMEOUT_MS = 100;

function makeClient(): AgentMailClient {
  return new AgentMailClient({ baseUrl: UNREACHABLE_URL, timeoutMs: FAST_TIMEOUT_MS });
}

describe("TRD-027: AgentMailClient performance — unreachable service", () => {
  it("healthCheck completes in <500ms when service unreachable", async () => {
    const client = makeClient();
    const start = Date.now();
    const result = await client.healthCheck();
    const elapsed = Date.now() - start;

    expect(result).toBe(false);
    expect(elapsed).toBeLessThan(500);
  });

  it("sendMessage completes in <500ms when service unreachable", async () => {
    const client = makeClient();
    const start = Date.now();
    await client.sendMessage("other-agent", "test-subject", "test-body");
    const elapsed = Date.now() - start;

    // sendMessage is fire-and-forget void — just verify it doesn't hang.
    expect(elapsed).toBeLessThan(500);
  });

  it("100 sendMessage calls with unavailable service complete in <5000ms total", async () => {
    const client = makeClient();
    const start = Date.now();

    // Fire all 100 calls concurrently so we measure throughput, not latency×100.
    await Promise.all(
      Array.from({ length: 100 }, (_, i) =>
        client.sendMessage("other-agent", `subject-${i}`, `body-${i}`),
      ),
    );

    const elapsed = Date.now() - start;
    expect(elapsed).toBeLessThan(5000);
  });
});
