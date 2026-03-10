import { WebSocketServer, WebSocket } from "ws";
import type { IncomingMessage } from "node:http";
import type { Server } from "node:http";

// ── Types ────────────────────────────────────────────────────────────────

export interface WsEvent {
  type: "dispatch" | "complete" | "merge" | "stuck";
  data: unknown;
}

// ── State ────────────────────────────────────────────────────────────────

const clients = new Set<WebSocket>();

let wss: WebSocketServer | null = null;

// ── Public API ───────────────────────────────────────────────────────────

/**
 * Attach a WebSocket server to an existing HTTP server.
 * Upgrades requests whose pathname starts with /ws.
 */
export function attachWebSocket(server: Server): WebSocketServer {
  wss = new WebSocketServer({ noServer: true });

  wss.on("connection", (ws) => {
    clients.add(ws);
    ws.on("close", () => clients.delete(ws));
    ws.on("error", () => clients.delete(ws));
  });

  server.on("upgrade", (req: IncomingMessage, socket, head) => {
    const url = new URL(req.url ?? "/", `http://${req.headers.host}`);
    if (url.pathname === "/ws") {
      wss!.handleUpgrade(req, socket, head, (ws) => {
        wss!.emit("connection", ws, req);
      });
    } else {
      socket.destroy();
    }
  });

  return wss;
}

/**
 * Broadcast an event to all connected WebSocket clients.
 */
export function broadcast(event: WsEvent): void {
  const payload = JSON.stringify(event);
  for (const ws of clients) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(payload);
    }
  }
}

/**
 * Gracefully close all connections and shut down the WebSocket server.
 */
export function shutdownWs(): Promise<void> {
  return new Promise((resolve) => {
    for (const ws of clients) {
      ws.close();
    }
    clients.clear();
    if (wss) {
      wss.close(() => resolve());
    } else {
      resolve();
    }
  });
}
