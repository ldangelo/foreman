/**
 * ForemanDaemon — long-lived tRPC HTTP server.
 *
 * Starts as a standalone Node.js process. Validates Postgres connection on boot,
 * then listens for tRPC requests over Unix socket (primary) or HTTP (fallback).
 *
 * Configuration:
 * - Socket: ~/.foreman/daemon.sock (mode 0600)
 * - HTTP fallback: localhost:3847
 * - DATABASE_URL: from env or postgresql://localhost/foreman
 *
 * @module daemon
 */

import Fastify from "fastify";
import { fastifyRequestHandler } from "@trpc/server/adapters/fastify";
import { join } from "node:path";
import { mkdirSync, chmodSync, existsSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { initPool, healthCheck, destroyPool } from "../lib/db/pool-manager.js";
import { createContext } from "./router.js";
import { appRouter } from "./router.js";
import { createWebhookHandler } from "./webhook-handler.js";
import { ProjectRegistry } from "../lib/project-registry.js";
import { ForemanStore } from "../lib/store.js";
import { createTaskClient } from "../lib/task-client-factory.js";
import { Dispatcher } from "../orchestrator/dispatcher.js";
import { BvClient } from "../lib/bv.js";
import { createTrpcClient } from "../lib/trpc-client.js";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const DEFAULT_SOCKET_PATH = join(homedir(), ".foreman", "daemon.sock");
const DEFAULT_HTTP_PORT = 3847;
const DEFAULT_DISPATCH_INTERVAL_MS = 30_000; // 30 seconds
const DEFAULT_MAX_AGENTS = 5;

/**
 * Global handlers to prevent silent crashes.
 * Logs the error and exits with code 1 so the daemon can be restarted.
 */
process.on("uncaughtException", (err) => {
  console.error("[ForemanDaemon] Uncaught exception:", err);
  process.exit(1);
});

process.on("unhandledRejection", (reason) => {
  console.error("[ForemanDaemon] Unhandled rejection:", reason);
  process.exit(1);
});

/**
 * Exit with a clear error when Postgres connection fails on startup.
 * @param cause - The underlying error.
 */
function failStartup(cause: unknown): never {
  const msg =
    cause instanceof Error
      ? `Cannot connect to Postgres: ${cause.message}`
      : `Cannot connect to Postgres: ${String(cause)}`;
  console.error(`[ForemanDaemon] ${msg}`);
  console.error(
    "[ForemanDaemon] Check DATABASE_URL and ensure Postgres is running."
  );
  process.exit(1);
}

// ---------------------------------------------------------------------------
// ForemanDaemon
// ---------------------------------------------------------------------------

export class ForemanDaemon {
  private readonly fastify = Fastify({ logger: true });
  private _running = false;
  private _socketPath: string;
  private _httpPort: number;
  private _useSocket: boolean = true;
  private _dispatchInterval: ReturnType<typeof setInterval> | null = null;

  constructor(options?: {
    socketPath?: string;
    httpPort?: number;
  }) {
    this._socketPath = options?.socketPath ?? DEFAULT_SOCKET_PATH;
    this._httpPort = options?.httpPort ?? DEFAULT_HTTP_PORT;
  }

  get socketPath(): string {
    return this._socketPath;
  }

  get httpPort(): number {
    return this._httpPort;
  }

  get running(): boolean {
    return this._running;
  }

  /** Start the daemon. Validates Postgres, then listens on socket or HTTP. */
  async start(): Promise<void> {
    if (this._running) {
      throw new Error("ForemanDaemon already running");
    }

    // 1. Initialise Postgres pool.
    try {
      initPool();
    } catch (err: unknown) {
      failStartup(err);
    }

    // 2. Validate Postgres connection.
    try {
      await healthCheck();
      this.fastify.log.info("[ForemanDaemon] Postgres connection validated");
    } catch (err: unknown) {
      failStartup(err);
    }

    // 3. Mount tRPC handler on Fastify.
    this.fastify.all("/trpc/:path", async (req, res) => {
      const { path } = req.params as { path: string };
      return fastifyRequestHandler({
        router: appRouter,
        createContext,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        req: req as any,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        res: res as any,
        path,
      });
    });

    // 4. Health endpoint (no tRPC).
    this.fastify.get("/health", async () => ({ status: "ok" }));

    // 5. Webhook endpoint (TRD-061/062/063/064).
    // Reads FOREMAN_WEBHOOK_SECRET from env; skips if not set (daemon still starts).
    const webhookSecret = process.env.FOREMAN_WEBHOOK_SECRET;
    if (webhookSecret) {
      const { createContext: makeContext } = await import("./router.js");
      const ctx = await makeContext({ req: {} as never, res: {} as never });
      const webhookHandler = createWebhookHandler(
        { adapter: ctx.adapter, registry: ctx.registry },
        { secret: webhookSecret },
      );
      this.fastify.post("/webhook", webhookHandler);
      this.fastify.log.info("[ForemanDaemon] Webhook endpoint enabled at /webhook");
    } else {
      this.fastify.log.info(
        "[ForemanDaemon] FOREMAN_WEBHOOK_SECRET not set — webhook endpoint disabled",
      );
    }

    // 5. Attempt Unix socket first.
    await this.#listenOnSocket();

    // 6. Graceful shutdown.
    const shutdown = async (signal: string) => {
      this.fastify.log.info(`[ForemanDaemon] Received ${signal}, shutting down`);
      await this.stop();
    };
    process.on("SIGTERM", () => shutdown("SIGTERM"));
    process.on("SIGINT", () => shutdown("SIGINT"));

    this._running = true;

    // Start background dispatch loop
    await this.#startDispatchLoop();
  }

  /** Try to bind on the Unix socket. Fall back to HTTP on failure. */
  async #listenOnSocket(): Promise<void> {
    const socketDir = join(this._socketPath, "..");
    mkdirSync(socketDir, { recursive: true });

    // Clean up stale socket.
    if (existsSync(this._socketPath)) {
      try {
        unlinkSync(this._socketPath);
      } catch {
        // ignore
      }
    }

    try {
      await this.fastify.listen({
        path: this._socketPath,
      } as never);
      chmodSync(this._socketPath, 0o600);
      this.fastify.log.info(
        `[ForemanDaemon] Listening on Unix socket: ${this._socketPath}`
      );
      this._useSocket = true;
    } catch (err: unknown) {
      this.fastify.log.warn(
        `[ForemanDaemon] Unix socket bind failed (${(err as Error).message}), falling back to HTTP`
      );
      await this.#listenOnHttp();
    }
  }

  /** Bind on localhost:3847 as fallback. */
  async #listenOnHttp(): Promise<void> {
    try {
      await this.fastify.listen({ port: this._httpPort, host: "127.0.0.1" });
      this.fastify.log.info(
        `[ForemanDaemon] Listening on HTTP: http://localhost:${this._httpPort}`
      );
      this._useSocket = false;
    } catch (err: unknown) {
      this.fastify.log.error(
        `[ForemanDaemon] HTTP bind also failed: ${(err as Error).message}`
      );
      failStartup(err);
    }
  }

  /** Stop the daemon and release all resources. */
  async stop(): Promise<void> {
    if (!this._running) return;

    try {
      await this.fastify.close();
    } catch {
      // ignore
    }

    try {
      await destroyPool();
    } catch {
      // ignore
    }

    this.#stopDispatchLoop();
    this._running = false;
    this.fastify.log.info("[ForemanDaemon] Stopped");
  }

  /** Start the background dispatch loop for all registered projects. */
  async #startDispatchLoop(): Promise<void> {
    const intervalMs =
      parseInt(process.env.FOREMAN_DISPATCH_INTERVAL_MS ?? "", 10) ||
      DEFAULT_DISPATCH_INTERVAL_MS;
    const maxAgents =
      parseInt(process.env.FOREMAN_MAX_AGENTS ?? "", 10) ||
      DEFAULT_MAX_AGENTS;

    this.fastify.log.info(
      `[ForemanDaemon] Starting dispatch loop (interval: ${intervalMs}ms, maxAgents: ${maxAgents})`
    );

    // Run once immediately, then on interval
    await this.#dispatchAllProjects(maxAgents);

    this._dispatchInterval = setInterval(async () => {
      if (!this._running) return;
      try {
        await this.#dispatchAllProjects(maxAgents);
      } catch (err) {
        this.fastify.log.error(
          `[ForemanDaemon] Dispatch loop error: ${err instanceof Error ? err.message : String(err)}`
        );
      }
    }, intervalMs);
  }

  /** Stop the background dispatch loop. */
  #stopDispatchLoop(): void {
    if (this._dispatchInterval) {
      clearInterval(this._dispatchInterval);
      this._dispatchInterval = null;
      this.fastify.log.info("[ForemanDaemon] Dispatch loop stopped");
    }
  }

  /** Dispatch ready tasks for all registered projects. */
  async #dispatchAllProjects(maxAgents: number): Promise<void> {
    // Use tRPC client to get projects (same as listRegisteredProjects in CLI)
    let projects: Array<{ id: string; name: string; path: string; status: string }> = [];
    try {
      const client = createTrpcClient();
      projects = await client.projects.list() as typeof projects;
    } catch (err) {
      this.fastify.log.warn(
        `[ForemanDaemon] Failed to fetch projects via tRPC: ${err instanceof Error ? err.message : String(err)}`
      );
      return;
    }

    for (const project of projects) {
      if (project.status !== "active") continue;

      try {
        const { taskClient, backendType } = await createTaskClient(project.path);
        const store = ForemanStore.forProject(project.path);

        // Create BvClient if available (best effort)
        let bvClient: BvClient | null = null;
        try {
          bvClient = new BvClient(project.path);
        } catch {
          // BvClient not available — continue without it
        }

        const dispatcher = new Dispatcher(taskClient, store, project.path, bvClient);
        const result = await dispatcher.dispatch({ maxAgents });

        if (result.dispatched.length > 0) {
          this.fastify.log.info(
            `[ForemanDaemon] Dispatched ${result.dispatched.length} task(s) for project "${project.name}"`
          );
        }

        store.close();
      } catch (err) {
        this.fastify.log.error(
          `[ForemanDaemon] Failed to dispatch for project "${project.name}": ${err instanceof Error ? err.message : String(err)}`
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Main entry point (run directly with `node src/daemon/index.ts`)
// ---------------------------------------------------------------------------

if (import.meta.url === `file://${process.argv[1]}`) {
  const daemon = new ForemanDaemon();
  daemon.start().catch((err) => {
    console.error("[ForemanDaemon] Startup failed:", err);
    process.exit(1);
  });
}
