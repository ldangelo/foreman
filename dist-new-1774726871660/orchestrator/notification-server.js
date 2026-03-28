/**
 * Notification Server — HTTP endpoint that receives status/progress
 * notifications from detached agent worker processes.
 *
 * Workers POST JSON to POST /notify while the server is running.
 * If the server is not reachable (e.g. foreman exited), the worker
 * silently ignores the error and polling-based detection takes over.
 *
 * Lifecycle:
 *   const server = new NotificationServer(bus);
 *   await server.start();           // listen on random OS port
 *   console.log(server.url);        // "http://127.0.0.1:<port>"
 *   await server.stop();            // graceful shutdown
 */
import { createServer } from "node:http";
export class NotificationServer {
    bus;
    server = null;
    _port = null;
    constructor(bus) {
        this.bus = bus;
    }
    /** Full URL for workers to POST to, e.g. "http://127.0.0.1:54321". */
    get url() {
        if (this._port === null)
            throw new Error("NotificationServer not started");
        return `http://127.0.0.1:${this._port}`;
    }
    /** The OS-assigned port number (available after start()). */
    get port() {
        if (this._port === null)
            throw new Error("NotificationServer not started");
        return this._port;
    }
    /** Start the HTTP server, binding to a random available port on loopback. */
    async start() {
        return new Promise((resolve, reject) => {
            const srv = createServer((req, res) => {
                this.handleRequest(req, res);
            });
            srv.on("error", reject);
            // Port 0 tells the OS to assign any available port.
            srv.listen(0, "127.0.0.1", () => {
                const addr = srv.address();
                this._port = addr.port;
                this.server = srv;
                resolve();
            });
        });
    }
    /** Gracefully stop the HTTP server. */
    async stop() {
        return new Promise((resolve) => {
            if (!this.server) {
                resolve();
                return;
            }
            this.server.close(() => {
                this.server = null;
                this._port = null;
                resolve();
            });
        });
    }
    handleRequest(req, res) {
        if (req.method === "GET" && req.url === "/health") {
            res.writeHead(200, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ ok: true }));
            return;
        }
        if (req.method === "POST" && req.url === "/notify") {
            let body = "";
            // Guard flag: prevents the "end" handler from attempting a second response
            // after we have already replied (e.g. 413 for oversized payloads).
            let responded = false;
            req.on("data", (chunk) => {
                body += chunk.toString("utf-8");
                // Reject overly large payloads (guard against accidental abuse)
                if (body.length > 64 * 1024) {
                    responded = true;
                    res.writeHead(413, { "Content-Type": "application/json" });
                    res.end(JSON.stringify({ error: "payload too large" }));
                    req.destroy();
                }
            });
            req.on("end", () => {
                if (responded)
                    return;
                try {
                    const notification = JSON.parse(body);
                    if (!isValidNotification(notification)) {
                        responded = true;
                        res.writeHead(400, { "Content-Type": "application/json" });
                        res.end(JSON.stringify({ error: "invalid notification: missing type or runId" }));
                        return;
                    }
                    this.bus.notify(notification);
                    responded = true;
                    res.writeHead(200, { "Content-Type": "application/json" });
                    res.end(JSON.stringify({ ok: true }));
                }
                catch {
                    responded = true;
                    res.writeHead(400, { "Content-Type": "application/json" });
                    res.end(JSON.stringify({ error: "invalid JSON" }));
                }
            });
            return;
        }
        res.writeHead(404);
        res.end();
    }
}
function isValidNotification(n) {
    if (!n || typeof n !== "object")
        return false;
    const obj = n;
    return typeof obj.type === "string" && typeof obj.runId === "string";
}
//# sourceMappingURL=notification-server.js.map