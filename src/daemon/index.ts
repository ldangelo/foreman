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
import { homedir } from "node:os";
import { join } from "node:path";
import { mkdirSync, chmodSync, existsSync, unlinkSync } from "node:fs";
import { initPool, healthCheck, destroyPool } from "../lib/db/pool-manager.js";
import { createContext, appRouter } from "./router.js";
import { createWebhookHandler } from "./webhook-handler.js";
import { createJiraWebhookHandler } from "./jira-webhook-handler.js";
import { createTrpcClient } from "../lib/trpc-client.js";
import { ForemanStore } from "../lib/store.js";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import { ProjectRegistry } from "../lib/project-registry.js";
import { createTaskClient } from "../lib/task-client-factory.js";
import { Dispatcher } from "../orchestrator/dispatcher.js";
import { BvClient } from "../lib/bv.js";
import { GitHubIssuesPoller } from "./github-poller.js";
import { JiraApiClient } from "./jira-api-client.js";
import { JiraIssuesPoller } from "./jira-poller.js";
import type { JiraConfig, JiraProjectConfig } from "../lib/project-config.js";
import { JiraTriggerHandler } from "../orchestrator/jira-trigger-handler.js";

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
  private _githubPoller: GitHubIssuesPoller | null = null;
  private _jiraPoller: JiraIssuesPoller | null = null;

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
    const foremanLabel = process.env.FOREMAN_GITHUB_LABEL ?? "foreman";
    if (webhookSecret) {
      const { createContext: makeContext } = await import("./router.js");
      const ctx = await makeContext({ req: {} as never, res: {} as never });
      const webhookHandler = createWebhookHandler(
        { adapter: ctx.adapter, registry: ctx.registry },
        { secret: webhookSecret, foremanLabel },
      );
      this.fastify.post("/webhook", webhookHandler);
      this.fastify.log.info("[ForemanDaemon] Webhook endpoint enabled at /webhook");
    } else {
      this.fastify.log.info(
      "[ForemanDaemon] FOREMAN_WEBHOOK_SECRET not set — webhook endpoint disabled",
      );
    }
    // 6. Jira webhook endpoint (TRD-019, TRD-022)
    await this.#startJiraWebhook();
    // 7. Attempt Unix socket first.
    await this.#listenOnSocket();
    // 8. Graceful shutdown.
    const shutdown = async (signal: string) => {
      this.fastify.log.info(`[ForemanDaemon] Received ${signal}, shutting down`);
      await this.stop();
    };
    process.on("SIGTERM", () => shutdown("SIGTERM"));
    process.on("SIGINT", () => shutdown("SIGINT"));
    this._running = true;
    // Start GitHub Issues polling loop (TRD-030, TRD-032)
    await this.#startGithubPoller();
    // Start Jira Issues polling loop
    await this.#startJiraPoller();
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

    // Persist Jira issue states before shutdown (AC-014-1)
    if (this._jiraPoller) {
      console.log("[ForemanDaemon] Persisting Jira issue states before shutdown");
      for (const project of this._jiraPoller["jiraConfig"].projects) {
        await this._jiraPoller.saveState(project.key);
      }
    }
    try {
      await destroyPool();
    } catch {
      // ignore
    }
    this.#stopDispatchLoop();
    this.#stopGithubPoller();
    this.#stopJiraPoller();
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

  /** Start the GitHub Issues polling loop. Creates the poller and starts it. */
  async #startGithubPoller(): Promise<void> {
    const foremanLabel =
      process.env.FOREMAN_GITHUB_LABEL ?? "foreman";
    const pollIntervalMs =
      parseInt(process.env.FOREMAN_GITHUB_POLL_INTERVAL_MS ?? "", 10) ||
      60_000;

    // Check if gh is installed before starting the poller
    const gh = new (await import("../lib/gh-cli.js")).GhCli();
    const ghInstalled = await gh.isInstalled();
    if (!ghInstalled) {
      this.fastify.log.info(
        "[ForemanDaemon] GitHub CLI (gh) not found — GitHub Issues polling disabled. Install gh from https://cli.github.com to enable."
      );
      return;
    }
    const adapter = new PostgresAdapter();
    const registry = new ProjectRegistry({ pg: adapter });
    this._githubPoller = new GitHubIssuesPoller(adapter, registry, {
      foremanLabel,
      pollIntervalMs,
    });
    this._githubPoller.start();
  }
  /** Stop the GitHub Issues polling loop. */
  #stopGithubPoller(): void {
    if (this._githubPoller) {
      this._githubPoller.stop();
      this._githubPoller = null;
    }
  }
  /** Start the Jira webhook endpoint if configured. */
  async #startJiraWebhook(): Promise<void> {
    // Load Jira webhook secret from env
    const jiraWebhookSecret = process.env.FOREMAN_JIRA_WEBHOOK_SECRET;
    if (!jiraWebhookSecret) {
      this.fastify.log.info(
        "[ForemanDaemon] FOREMAN_JIRA_WEBHOOK_SECRET not set — Jira webhook endpoint disabled",
      );
      return;
    }
    const loadConfig = async () => {
      const projectPath = process.cwd();
      return import("../lib/project-config.js").then(
        (m) => m.loadProjectConfig(projectPath),
        () => null,
      );
    };
    const adapter = new PostgresAdapter();
    const jiraWebhookHandler = createJiraWebhookHandler(
      {
        adapter,
        getProjectConfig: async (projectKey: string) => {
          const config = await loadConfig();
          if (!config?.issueTracker || config.issueTracker.backend !== "jira") return undefined;
          return config.issueTracker.jira.projects?.find((p) => p.key === projectKey);
        },
      },
      { secret: jiraWebhookSecret },
    );
    this.fastify.post("/webhooks/jira", jiraWebhookHandler);
    this.fastify.log.info("[ForemanDaemon] Jira webhook endpoint enabled at /webhooks/jira");
  }
  /** Start the Jira Issues polling loop. Skips if no Jira config found. */
  async #startJiraPoller(): Promise<void> {
    // Load project config to check for Jira configuration
    const projectPath = process.cwd();
    const config = await import("../lib/project-config.js").then(
      (m) => m.loadProjectConfig(projectPath),
      () => null,
    );
    if (!config?.issueTracker || config.issueTracker.backend !== "jira") {
      this.fastify.log.info(
        "[ForemanDaemon] No Jira configuration found — Jira Issues polling disabled"
      );
      return;
    }
    const jiraConfig: JiraConfig = config.issueTracker.jira;
    // Read API token from environment
    const apiToken = process.env[jiraConfig.apiTokenEnvVar];
    if (!apiToken) {
      this.fastify.log.warn(
        `[ForemanDaemon] Jira API token env var '${jiraConfig.apiTokenEnvVar}' not set — Jira Issues polling disabled`
      );
      return;
    }
    const adapter = new PostgresAdapter();
    const client = new JiraApiClient({
      apiUrl: jiraConfig.apiUrl,
      email: jiraConfig.email,
      apiToken,
    });
    // Create transition handlers for each project
    const handlers = new Map<string, JiraTriggerHandler>();
    for (const projectConfig of jiraConfig.projects) {
      handlers.set(
        projectConfig.key,
        new JiraTriggerHandler(adapter, projectConfig.key),
      );
    }
    const onTransition = async (
      issue: { key: string; fields?: { status?: { name?: string }; issuetype?: { name?: string } } },
      projectConfig: JiraProjectConfig,
    ): Promise<void> => {
      const handler = handlers.get(projectConfig.key);
      if (!handler) return;
      const mappedIssue = {
        key: issue.key,
        fields: {
          status: { name: issue.fields?.status?.name ?? "" },
          issuetype: { name: issue.fields?.issuetype?.name ?? "" },
        },
      };
      await handler.handleTransition({
        issue: mappedIssue as Parameters<typeof handler.handleTransition>[0]["issue"],
        projectConfig,
        jiraProjectId: projectConfig.key,
        source: "poll",
      });
    };
    this._jiraPoller = new JiraIssuesPoller(adapter, client, jiraConfig, onTransition);
    this._jiraPoller.start();
  }
  /** Stop the Jira Issues polling loop. */
  #stopJiraPoller(): void {
    if (this._jiraPoller) {
      this._jiraPoller.stop();
      this._jiraPoller = null;
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
        const { taskClient, backendType } = await createTaskClient(project.path, {
          registeredProjectId: project.id,
        });
        const store = ForemanStore.forProject(project.path);
        const pg = new PostgresAdapter();

        // Create BvClient if available (best effort)
        let bvClient: BvClient | null = null;
        try {
          bvClient = new BvClient(project.path);
        } catch {
          // BvClient not available — continue without it
        }

        const dispatcher = new Dispatcher(taskClient, store, project.path, bvClient, {
          externalProjectId: project.id,
          getRecentFailureCount: async (_projectId: string, since: string) => {
            const failures = await pg.listTasks(project.id, {
              status: ["failed", "stuck", "conflict"],
              limit: 1000,
            });
            return failures.filter((task) => task.updated_at >= since).length;
          },
          getActiveSeedIds: async () => {
            const activeRuns = await pg.listActiveRuns(project.id);
            return activeRuns.map((run) => run.seed_id);
          },
          getActiveAgentCount: async () => {
            const activeRuns = await pg.listActiveRuns(project.id);
            return activeRuns.length;
          },
          hasActiveOrPendingRun: async (seedId: string) => {
            const runs = await pg.listPipelineRuns(project.id, { beadId: seedId, limit: 20 });
            return runs.some((run) => ["pending", "running", "success"].includes(run.status));
          },
          nativeTaskOps: {
            hasNativeTasks: async () => pg.hasNativeTasks(project.id),
            getReadyTasks: async () => (await pg.listTasks(project.id, {
              status: ["ready"],
              limit: 1000,
            })) as never,
            getTaskByExternalId: async (externalId: string) => (await pg.getTaskByExternalId(project.id, externalId)) as never,
            getTaskById: async (taskId: string) => (await pg.getTask(project.id, taskId)) as never,
            claimTask: async (taskId: string, runId: string) => pg.claimTask(project.id, taskId, runId),
          },
          runOps: {
            createRun: async ({ runId, seedId, branchName, worktreePath, baseBranch, mergeStrategy, agentType }) => {
              const existing = await pg.listPipelineRuns(project.id, { beadId: seedId });
              await pg.createPipelineRun({
                id: runId,
                projectId: project.id,
                beadId: seedId,
                runNumber: existing.length + 1,
                branch: branchName,
                trigger: "bead",
                agentType,
                worktreePath: worktreePath ?? undefined,
                baseBranch: baseBranch ?? undefined,
                mergeStrategy: mergeStrategy ?? undefined,
              });
            },
            updateRun: async (runId, updates) => {
              const patch: {
                status?: string;
                sessionKey?: string;
                worktreePath?: string;
                startedAt?: string;
                finishedAt?: string;
              } = {};
              if (updates.status) patch.status = updates.status;
              if (updates.session_key !== undefined) patch.sessionKey = updates.session_key ?? undefined;
              if (updates.worktree_path !== undefined) patch.worktreePath = updates.worktree_path ?? undefined;
              if (updates.started_at) patch.startedAt = updates.started_at;
              if (updates.completed_at) patch.finishedAt = updates.completed_at;
              if (Object.keys(patch).length > 0) {
                await pg.updatePipelineRun(runId, patch);
              }
            },
            sendMessage: async (runId, senderAgentType, recipientAgentType, subject, body) => {
              await pg.sendMessage(project.id, runId, senderAgentType, recipientAgentType, subject, body);
            },
            logEvent: async (runId, _projectId, eventType, payload) => {
              const mappedEventType = eventType === "complete"
                ? "run:success"
                : eventType === "fail"
                  ? "run:failure"
                  : eventType === "restart" || eventType === "dispatch"
                    ? "run:queued"
                    : null;
              if (!mappedEventType) return;
              await pg.recordPipelineEvent({
                projectId: project.id,
                runId,
                taskId: payload.seedId as string | undefined,
                eventType: mappedEventType,
                payload,
              });
            },
          },
        });
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
