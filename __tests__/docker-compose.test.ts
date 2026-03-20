/**
 * TRD-027-TEST: Docker Compose + Performance Tests
 *
 * Tests for the Agent Mail docker-compose.yml configuration and the
 * AgentMailClient performance characteristics when the server is unreachable.
 *
 * NOTE: These tests do NOT start Docker containers. They validate:
 * 1. docker-compose.yml structure (string pattern checks — no yaml dep needed)
 * 2. AgentMailClient P95 latency requirements with an unreachable server
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { AgentMailClient } from "../src/orchestrator/agent-mail-client.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

const COMPOSE_PATH = join(process.cwd(), "docker-compose.yml");
const UNREACHABLE_PORT = 19999; // guaranteed closed

function makeUnreachableClient() {
  return new AgentMailClient({
    baseUrl: `http://localhost:${UNREACHABLE_PORT}`,
    timeoutMs: 100,
  });
}

function percentile(sortedMs: number[], p: number): number {
  const idx = Math.ceil((p / 100) * sortedMs.length) - 1;
  return sortedMs[Math.max(0, idx)];
}

// ── docker-compose.yml structure tests ───────────────────────────────────────

describe("TRD-027: docker-compose.yml structure", () => {
  let raw: string;

  it("docker-compose.yml exists and is non-empty", () => {
    raw = readFileSync(COMPOSE_PATH, "utf-8");
    expect(raw.length).toBeGreaterThan(0);
    expect(raw).toContain("services:");
  });

  it("defines an agent-mail service", () => {
    raw = readFileSync(COMPOSE_PATH, "utf-8");
    expect(raw).toContain("agent-mail:");
  });

  it("agent-mail service exposes port 8765", () => {
    raw = readFileSync(COMPOSE_PATH, "utf-8");
    expect(raw).toMatch(/8765/);
  });

  it("agent-mail service has a healthcheck configuration", () => {
    raw = readFileSync(COMPOSE_PATH, "utf-8");
    expect(raw).toContain("healthcheck:");
    expect(raw).toMatch(/health/);
    expect(raw).toMatch(/8765/);
  });

  it("healthcheck has correct interval (30s), timeout (5s), retries (3)", () => {
    raw = readFileSync(COMPOSE_PATH, "utf-8");
    expect(raw).toContain("interval: 30s");
    expect(raw).toContain("timeout: 5s");
    expect(raw).toContain("retries: 3");
  });

  it("agent-mail service mounts a named volume for persistence", () => {
    raw = readFileSync(COMPOSE_PATH, "utf-8");
    // Must have a volumes: section under the service and a colon (named volume)
    expect(raw).toContain("volumes:");
    // volume mapping contains a colon
    expect(raw).toMatch(/agent-mail-data/);
  });

  it("top-level volumes section defines agent-mail-data", () => {
    raw = readFileSync(COMPOSE_PATH, "utf-8");
    // The top-level volumes section must list agent-mail-data
    const topLevelVolumesSection = raw.split("volumes:").slice(1).join("volumes:");
    expect(topLevelVolumesSection).toContain("agent-mail-data");
  });
});

// ── AgentMailClient performance benchmarks ────────────────────────────────────

describe("TRD-027: AgentMailClient performance — unreachable server", () => {
  it("healthCheck completes in <500ms when server is unreachable", async () => {
    const client = makeUnreachableClient();
    const start = performance.now();
    const result = await client.healthCheck();
    const elapsed = performance.now() - start;

    expect(result).toBe(false);
    expect(elapsed).toBeLessThan(500);
  });

  it("sendMessage completes in <500ms when server is unreachable", async () => {
    const client = makeUnreachableClient();
    const start = performance.now();
    await client.sendMessage("audit-log", "tool_call", JSON.stringify({ event: "test" }));
    const elapsed = performance.now() - start;

    expect(elapsed).toBeLessThan(500);
  });

  it("100 sendMessage calls complete in <10000ms total (P95 < 500ms)", async () => {
    const client = makeUnreachableClient();
    const durations: number[] = [];

    for (let i = 0; i < 100; i++) {
      const start = performance.now();
      await client.sendMessage("audit-log", "tool_call", JSON.stringify({ event: i }));
      durations.push(performance.now() - start);
    }

    const totalMs = durations.reduce((a, b) => a + b, 0);
    const sorted = [...durations].sort((a, b) => a - b);
    const p95 = percentile(sorted, 95);

    // Total must be under 10s (100 * 100ms timeout = 10s theoretical max)
    expect(totalMs).toBeLessThan(10_000);
    // P95 must be under 500ms (TRD AC-015-4)
    expect(p95).toBeLessThan(500);
  });

  it("fetchInbox returns [] and completes in <500ms when server is unreachable", async () => {
    const client = makeUnreachableClient();
    const start = performance.now();
    const result = await client.fetchInbox("test-agent");
    const elapsed = performance.now() - start;

    expect(result).toEqual([]);
    expect(elapsed).toBeLessThan(500);
  });
});
