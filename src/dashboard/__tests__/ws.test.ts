import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { WebSocket, WebSocketServer } from "ws";
import { createServer, type Server } from "node:http";
import { attachWebSocket, broadcast, shutdownWs } from "../ws.js";

describe("WebSocket broadcasting", () => {
  let httpServer: Server;
  let wss: WebSocketServer;
  let clients: WebSocket[];
  const PORT = 19876; // unlikely to collide

  beforeEach(async () => {
    clients = [];
    httpServer = createServer();
    wss = attachWebSocket(httpServer);
    await new Promise<void>((resolve) => httpServer.listen(PORT, resolve));
  });

  afterEach(async () => {
    // Close all test clients
    for (const ws of clients) {
      if (ws.readyState === WebSocket.OPEN) ws.close();
    }
    await shutdownWs();
    await new Promise<void>((resolve, reject) => {
      httpServer.close((err) => (err ? reject(err) : resolve()));
    });
  });

  function connectClient(): Promise<WebSocket> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(`ws://localhost:${PORT}/ws`);
      clients.push(ws);
      ws.on("open", () => resolve(ws));
      ws.on("error", reject);
    });
  }

  function waitForMessage(ws: WebSocket): Promise<string> {
    return new Promise((resolve) => {
      ws.once("message", (data) => resolve(data.toString()));
    });
  }

  it("broadcasts message to all connected clients", async () => {
    const ws1 = await connectClient();
    const ws2 = await connectClient();

    const msg1 = waitForMessage(ws1);
    const msg2 = waitForMessage(ws2);

    broadcast({ type: "dispatch", data: { bead: "bd-1" } });

    const [r1, r2] = await Promise.all([msg1, msg2]);
    expect(r1).toBe(r2);
    const parsed = JSON.parse(r1);
    expect(parsed.type).toBe("dispatch");
    expect(parsed.data.bead).toBe("bd-1");
  });

  it("disconnected client does not crash broadcast", async () => {
    const ws1 = await connectClient();
    const ws2 = await connectClient();

    // Close ws1 and wait for it to fully close
    await new Promise<void>((resolve) => {
      ws1.on("close", () => resolve());
      ws1.close();
    });

    // Small delay to let the server process the close
    await new Promise((r) => setTimeout(r, 50));

    const msg2 = waitForMessage(ws2);
    // Should not throw even though ws1 is gone
    broadcast({ type: "complete", data: { status: "ok" } });

    const result = await msg2;
    const parsed = JSON.parse(result);
    expect(parsed.type).toBe("complete");
  });

  it("events are serialized as JSON strings", async () => {
    const ws1 = await connectClient();
    const msg = waitForMessage(ws1);

    const event = { type: "stuck" as const, data: { reason: "timeout", count: 3 } };
    broadcast(event);

    const raw = await msg;
    // Should be valid JSON
    const parsed = JSON.parse(raw);
    expect(parsed).toEqual(event);
    // The raw message should be a string (JSON serialized)
    expect(typeof raw).toBe("string");
  });
});
