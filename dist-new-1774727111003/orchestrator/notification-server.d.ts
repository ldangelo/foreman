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
import type { NotificationBus } from "./notification-bus.js";
export declare class NotificationServer {
    private bus;
    private server;
    private _port;
    constructor(bus: NotificationBus);
    /** Full URL for workers to POST to, e.g. "http://127.0.0.1:54321". */
    get url(): string;
    /** The OS-assigned port number (available after start()). */
    get port(): number;
    /** Start the HTTP server, binding to a random available port on loopback. */
    start(): Promise<void>;
    /** Gracefully stop the HTTP server. */
    stop(): Promise<void>;
    private handleRequest;
}
//# sourceMappingURL=notification-server.d.ts.map