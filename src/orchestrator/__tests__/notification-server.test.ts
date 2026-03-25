import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { NotificationBus } from "../notification-bus.js";
import { NotificationServer } from "../notification-server.js";
import type { WorkerNotification } from "../types.js";

async function postJson(url: string, body: unknown): Promise<{ status: number; json: unknown }> {
  const resp = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = await resp.json();
  return { status: resp.status, json };
}

describe("NotificationServer", () => {
  let bus: NotificationBus;
  let server: NotificationServer;

  beforeEach(async () => {
    bus = new NotificationBus();
    server = new NotificationServer(bus);
    await server.start();
  });

  afterEach(async () => {
    await server.stop();
  });

  it("starts and exposes a URL on localhost", () => {
    expect(server.url).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/);
    expect(server.port).toBeGreaterThan(0);
  });

  it("GET /health returns 200 ok", async () => {
    const resp = await fetch(`${server.url}/health`);
    expect(resp.status).toBe(200);
    const json = await resp.json() as { ok: boolean };
    expect(json.ok).toBe(true);
  });

  it("POST /notify with valid status notification emits on bus and returns 200", async () => {
    const received: WorkerNotification[] = [];
    bus.onNotification((n) => received.push(n));

    const n: WorkerNotification = {
      type: "status",
      runId: "run-001",
      status: "completed",
      timestamp: new Date().toISOString(),
    };

    const { status, json } = await postJson(`${server.url}/notify`, n);

    expect(status).toBe(200);
    expect((json as { ok: boolean }).ok).toBe(true);
    expect(received).toHaveLength(1);
    expect(received[0]).toMatchObject({ type: "status", runId: "run-001", status: "completed" });
  });

  it("POST /notify with valid progress notification emits on bus", async () => {
    const received: WorkerNotification[] = [];
    bus.onNotification((n) => received.push(n));

    const n: WorkerNotification = {
      type: "progress",
      runId: "run-002",
      progress: {
        toolCalls: 3,
        toolBreakdown: {},
        filesChanged: [],
        turns: 1,
        costUsd: 0.005,
        tokensIn: 500,
        tokensOut: 100,
        lastToolCall: "Read",
        lastActivity: new Date().toISOString(),
      },
      timestamp: new Date().toISOString(),
    };

    const { status } = await postJson(`${server.url}/notify`, n);
    expect(status).toBe(200);
    expect(received).toHaveLength(1);
    expect(received[0]?.type).toBe("progress");
  });

  it("POST /notify with missing type returns 400", async () => {
    const { status } = await postJson(`${server.url}/notify`, { runId: "run-bad" });
    expect(status).toBe(400);
  });

  it("POST /notify with missing runId returns 400", async () => {
    const { status } = await postJson(`${server.url}/notify`, { type: "status" });
    expect(status).toBe(400);
  });

  it("POST /notify with invalid JSON returns 400", async () => {
    const resp = await fetch(`${server.url}/notify`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "not valid json",
    });
    expect(resp.status).toBe(400);
  });

  it("GET unknown path returns 404", async () => {
    const resp = await fetch(`${server.url}/unknown`);
    expect(resp.status).toBe(404);
  });

  it("can be stopped and restarted", async () => {
    await server.stop();
    // After stop, url should throw
    expect(() => server.url).toThrow();

    await server.start();
    expect(server.url).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/);
  });

  it("does not throw when stop() called on unstarted server", async () => {
    const fresh = new NotificationServer(new NotificationBus());
    await expect(fresh.stop()).resolves.toBeUndefined();
  });

  it("stop() resolves quickly even when a keep-alive connection is held open", async () => {
    // Simulate a keep-alive HTTP/1.1 connection by opening a persistent fetch
    // and not closing it. stop() should still resolve in < 500ms because it
    // calls closeAllConnections() before server.close().
    const abortCtrl = new AbortController();
    // Open a persistent connection (fetch with keepalive=true) — do not await it
    const pendingFetch = fetch(`${server.url}/health`, {
      keepalive: true,
      signal: abortCtrl.signal,
    }).catch(() => { /* expected to be aborted */ });

    // Give the connection a moment to be established
    await new Promise<void>((r) => setTimeout(r, 20));

    const start = Date.now();
    await server.stop();
    const elapsed = Date.now() - start;

    // Cleanup the dangling fetch
    abortCtrl.abort();
    await pendingFetch;

    // Should complete well within 500ms (not blocked waiting for keep-alive to drain)
    expect(elapsed).toBeLessThan(500);
    expect(() => server.url).toThrow(); // server is stopped
  });
});
