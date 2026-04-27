/**
 * tRPC router for ForemanDaemon.
 *
 * Provides type-safe RPC procedures for all daemon operations.
 * Each procedure is wired to a PostgresAdapter method (skeleton phase: stubs).
 *
 * Architecture:
 * - Fastify receives HTTP requests
 * - @trpc/server handles routing + Zod input validation
 * - Procedures delegate to PostgresAdapter
 * - Context provides PoolManager and auth info
 *
 * @module daemon/router
 */

import { initTRPC, TRPCError } from "@trpc/server";
import type { inferRouterContext } from "@trpc/server";
import { z } from "zod";
import type { FastifyRequest, FastifyReply } from "fastify";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import {
  GhCli,
  GhNotInstalledError,
  GhNotAuthenticatedError,
  GhError,
} from "../lib/gh-cli.js";
import { ProjectRegistry } from "../lib/project-registry.js";
import { homedir } from "node:os";
import { join } from "node:path";

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

export interface Context {
  /** Fastify request object for access to headers, socket, etc. */
  req: FastifyRequest;
  res: FastifyReply;
  /** PostgresAdapter instance scoped to this request. */
  adapter: PostgresAdapter;
  /** GitHub CLI wrapper. */
  gh: GhCli;
  /** Project registry (JSON + Postgres dual-write). */
  registry: ProjectRegistry;
}

export async function createContext({
  req,
  res,
}: {
  req: FastifyRequest;
  res: FastifyReply;
}): Promise<Context> {
  const adapter = new PostgresAdapter();
  const registry = new ProjectRegistry({ pg: adapter });
  return {
    req,
    res,
    adapter,
    // Singleton instances shared across all requests in the daemon process
    gh: new GhCli(),
    registry,
  };
}

export type ContextFn = typeof createContext;
export type RouterContext = inferRouterContext<AppRouter>;

// ---------------------------------------------------------------------------
// Zod schemas
// ---------------------------------------------------------------------------

const PROJECT_ID_SCHEMA = z.string().min(1);
const PROJECT_NAME_SCHEMA = z.string().min(1).max(255);
const PROJECT_PATH_SCHEMA = z.string().min(1);
const STATUS_FILTER_SCHEMA = z
  .enum(["active", "paused", "archived"])
  .optional();

// Task schemas
const TASK_ID_SCHEMA = z.string().min(1);
const TASK_STATUS_VALUES = [
  "backlog", "ready", "in-progress",
  "explorer", "developer", "qa", "reviewer", "finalize",
  "merged", "closed", "conflict", "failed", "stuck", "blocked",
] as const;
const TASK_STATUS_SCHEMA = z.enum(TASK_STATUS_VALUES).optional();
const TASK_STATUS_ARRAY_SCHEMA = z.array(z.enum(TASK_STATUS_VALUES)).optional();
const TASK_PRIORITY_SCHEMA = z.number().int().min(0).max(4).optional();
const TASK_TYPE_SCHEMA = z.enum(["task", "bug", "feature", "story", "epic", "chore", "docs", "question"]).optional();

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

const t = initTRPC.context<Context>().create();

// ---------------------------------------------------------------------------
// Error helpers
// ---------------------------------------------------------------------------

class TrpcProjectError extends TRPCError {
  constructor(message: string) {
    super({ code: "BAD_REQUEST", message });
  }
}

// ---------------------------------------------------------------------------
// Tasks router
// ---------------------------------------------------------------------------

const tasksRouter = t.router({
  /**
   * List tasks for a project.
   * GET /trpc/tasks.list
   */
  list: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        status: TASK_STATUS_ARRAY_SCHEMA,
        runId: z.string().optional(),
        limit: z.number().int().min(1).max(1000).optional(),
      })
    )
    .query(async ({ input, ctx }) => {
      return ctx.adapter.listTasks(input.projectId, {
        status: input.status,
        runId: input.runId,
        limit: input.limit,
      });
    }),

  /**
   * Get a single task by ID.
   * GET /trpc/tasks.get
   */
  get: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        taskId: TASK_ID_SCHEMA,
      })
    )
    .query(async ({ input, ctx }) => {
      return ctx.adapter.getTask(input.projectId, input.taskId);
    }),

  /**
   * Create a new task.
   * POST /trpc/tasks.create
   */
  create: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        id: TASK_ID_SCHEMA,
        title: z.string().min(1).max(1000).optional(),
        description: z.string().optional(),
        type: TASK_TYPE_SCHEMA,
        priority: TASK_PRIORITY_SCHEMA,
        status: TASK_STATUS_SCHEMA,
        externalId: z.string().optional(),
        branch: z.string().optional(),
        createdAt: z.string().optional(),
        updatedAt: z.string().optional(),
        approvedAt: z.string().optional(),
        closedAt: z.string().optional(),
      })
    )
    .mutation(async ({ input, ctx }) => {
      return ctx.adapter.createTask(input.projectId, {
        id: input.id,
        title: input.title ?? input.id,
        description: input.description,
        type: input.type ?? "task",
        priority: input.priority ?? 2,
        status: input.status,
        external_id: input.externalId,
        branch: input.branch,
        created_at: input.createdAt,
        updated_at: input.updatedAt,
        approved_at: input.approvedAt,
        closed_at: input.closedAt,
      });
    }),

  /**
   * Update a task's fields.
   * POST /trpc/tasks.update
   */
  update: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        taskId: TASK_ID_SCHEMA,
        updates: z.object({
          title: z.string().min(1).max(1000).optional(),
          description: z.string().optional(),
          type: TASK_TYPE_SCHEMA,
          priority: TASK_PRIORITY_SCHEMA,
          status: TASK_STATUS_SCHEMA,
          branch: z.string().optional(),
          external_id: z.string().optional(),
        }),
      })
    )
    .mutation(async ({ input, ctx }) => {
      await ctx.adapter.updateTask(input.projectId, input.taskId, input.updates);
      return ctx.adapter.getTask(input.projectId, input.taskId);
    }),

  /**
   * Delete a task.
   * POST /trpc/tasks.delete
   */
  delete: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        taskId: TASK_ID_SCHEMA,
      })
    )
    .mutation(async ({ input, ctx }) => {
      await ctx.adapter.deleteTask(input.projectId, input.taskId);
      return { deleted: true, taskId: input.taskId };
    }),

  /**
   * Claim a task for a run.
   * Uses SELECT ... FOR UPDATE to prevent concurrent claims.
   * POST /trpc/tasks.claim
   */
  claim: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        taskId: TASK_ID_SCHEMA,
        runId: z.string().min(1),
      })
    )
    .mutation(async ({ input, ctx }) => {
      const claimed = await ctx.adapter.claimTask(
        input.projectId,
        input.taskId,
        input.runId
      );
      if (!claimed) return { claimed: false, taskId: input.taskId };
      return { claimed: true, taskId: input.taskId };
    }),

  /**
   * Approve a backlog task: transition to 'ready'.
   * POST /trpc/tasks.approve
   */
  approve: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        taskId: TASK_ID_SCHEMA,
      })
    )
    .mutation(async ({ input, ctx }) => {
      await ctx.adapter.approveTask(input.projectId, input.taskId);
      return ctx.adapter.getTask(input.projectId, input.taskId);
    }),

  close: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        taskId: TASK_ID_SCHEMA,
      })
    )
    .mutation(async ({ input, ctx }) => {
      await ctx.adapter.closeTask(input.projectId, input.taskId);
      return ctx.adapter.getTask(input.projectId, input.taskId);
    }),

  /**
   * Reset a task back to 'ready' state (clears run_id).
   * POST /trpc/tasks.reset
   */
  reset: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        taskId: TASK_ID_SCHEMA,
      })
    )
    .mutation(async ({ input, ctx }) => {
      await ctx.adapter.resetTask(input.projectId, input.taskId);
      return ctx.adapter.getTask(input.projectId, input.taskId);
    }),

  /**
   * Retry a failed/stuck task: transition to 'ready'.
   * POST /trpc/tasks.retry
   */
  retry: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        taskId: TASK_ID_SCHEMA,
      })
    )
    .mutation(async ({ input, ctx }) => {
      await ctx.adapter.retryTask(input.projectId, input.taskId);
      return ctx.adapter.getTask(input.projectId, input.taskId);
    }),

  addDependency: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        fromTaskId: TASK_ID_SCHEMA,
        toTaskId: TASK_ID_SCHEMA,
        type: z.enum(["blocks", "parent-child"]).default("blocks"),
      })
    )
    .mutation(async ({ input, ctx }) => {
      await ctx.adapter.addTaskDependency(input.projectId, input.fromTaskId, input.toTaskId, input.type);
      return { added: true };
    }),

  listDependencies: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        taskId: TASK_ID_SCHEMA,
        direction: z.enum(["incoming", "outgoing"]).optional(),
      })
    )
    .query(async ({ input, ctx }) => {
      return ctx.adapter.listTaskDependencies(input.projectId, input.taskId, input.direction ?? "outgoing");
    }),

  removeDependency: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        fromTaskId: TASK_ID_SCHEMA,
        toTaskId: TASK_ID_SCHEMA,
        type: z.enum(["blocks", "parent-child"]).default("blocks"),
      })
    )
    .mutation(async ({ input, ctx }) => {
      await ctx.adapter.removeTaskDependency(input.projectId, input.fromTaskId, input.toTaskId, input.type);
      return { removed: true };
    }),
});

// ---------------------------------------------------------------------------
// Runs router (TRD-033/034/035)
// ---------------------------------------------------------------------------

const RUN_STATUS_SCHEMA = z.enum(["pending", "running", "success", "failure", "cancelled", "skipped"]);
const RUN_TRIGGER_SCHEMA = z.enum(["push", "pr", "manual", "schedule", "bead"]).optional();
const PIPELINE_EVENT_TYPE_SCHEMA = z.enum([
  "run:queued", "run:started", "run:success", "run:failure", "run:cancelled",
  "task:claimed", "task:approved", "task:rejected", "task:reset", "bead:synced", "bead:conflict",
]);
const STREAM_SCHEMA = z.enum(["stdout", "stderr", "system"]);

const runsRouter = t.router({
  /**
   * Create a new pipeline run.
   * POST /trpc/runs.create
   */
  create: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        beadId: z.string().min(1),
        runNumber: z.number().int().min(0),
        branch: z.string().min(1),
        commitSha: z.string().optional(),
        trigger: RUN_TRIGGER_SCHEMA,
      })
    )
    .mutation(async ({ input, ctx }) => {
      return ctx.adapter.createPipelineRun({
        projectId: input.projectId,
        beadId: input.beadId,
        runNumber: input.runNumber,
        branch: input.branch,
        commitSha: input.commitSha,
        trigger: input.trigger,
      });
    }),

  /**
   * List runs for a project.
   * GET /trpc/runs.list
   */
  list: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        beadId: z.string().optional(),
        status: RUN_STATUS_SCHEMA.optional(),
        limit: z.number().int().min(1).max(500).optional(),
      })
    )
    .query(async ({ input, ctx }) => {
      return ctx.adapter.listPipelineRuns(input.projectId, {
        beadId: input.beadId,
        status: input.status,
        limit: input.limit,
      });
    }),

  /**
   * List active (pending/running) runs for a project.
   * GET /trpc/runs.listActive
   */
  listActive: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        beadId: z.string().optional(),
      })
    )
    .query(async ({ input, ctx }) => {
      const pending = await ctx.adapter.listPipelineRuns(input.projectId, {
        beadId: input.beadId,
        status: "pending",
      });
      const running = await ctx.adapter.listPipelineRuns(input.projectId, {
        beadId: input.beadId,
        status: "running",
      });
      return [...pending, ...running];
    }),

  /**
   * Get a single run by ID.
   * GET /trpc/runs.get
   */
  get: t.procedure
    .input(
      z.object({
        runId: z.string().uuid(),
      })
    )
    .query(async ({ input, ctx }) => {
      const run = await ctx.adapter.getPipelineRun(input.runId);
      if (!run) throw new TRPCError({ code: "NOT_FOUND", message: "Run not found" });
      return run;
    }),

  /**
   * Update run status (used by sentinel/pipeline to transition state).
   * POST /trpc/runs.updateStatus
   */
  updateStatus: t.procedure
    .input(
      z.object({
        runId: z.string().uuid(),
        status: RUN_STATUS_SCHEMA,
        startedAt: z.string().datetime().optional(),
        finishedAt: z.string().datetime().optional(),
      })
    )
    .mutation(async ({ input, ctx }) => {
      const run = await ctx.adapter.updatePipelineRun(input.runId, {
        status: input.status,
        startedAt: input.startedAt,
        finishedAt: input.finishedAt,
      });
      if (!run) throw new TRPCError({ code: "NOT_FOUND", message: "Run not found" });
      return run;
    }),

  /**
   * Finalize a run: set status + finishedAt atomically.
   * POST /trpc/runs.finalize
   */
  finalize: t.procedure
    .input(
      z.object({
        runId: z.string().uuid(),
        status: RUN_STATUS_SCHEMA,
        finishedAt: z.string().datetime().optional(),
      })
    )
    .mutation(async ({ input, ctx }) => {
      const run = await ctx.adapter.updatePipelineRun(input.runId, {
        status: input.status,
        finishedAt: input.finishedAt ?? new Date().toISOString(),
      });
      if (!run) throw new TRPCError({ code: "NOT_FOUND", message: "Run not found" });
      return run;
    }),

  // ── Events ────────────────────────────────────────────────────────────────

  /**
   * Record a pipeline event.
   * POST /trpc/runs.logEvent
   */
  logEvent: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        runId: z.string().uuid(),
        taskId: z.string().optional(),
        eventType: PIPELINE_EVENT_TYPE_SCHEMA,
        payload: z.record(z.string(), z.unknown()).optional(),
      })
    )
    .mutation(async ({ input, ctx }) => {
      return ctx.adapter.recordPipelineEvent({
        projectId: input.projectId,
        runId: input.runId,
        taskId: input.taskId,
        eventType: input.eventType,
        payload: input.payload,
      });
    }),

  /**
   * List events for a run.
   * GET /trpc/runs.listEvents
   */
  listEvents: t.procedure
    .input(
      z.object({
        runId: z.string().uuid(),
      })
    )
    .query(async ({ input, ctx }) => {
      return ctx.adapter.listPipelineEvents(input.runId);
    }),

  // ── Messages ──────────────────────────────────────────────────────────────

  /**
   * Append a message chunk to a run.
   * POST /trpc/runs.sendMessage
   */
  sendMessage: t.procedure
    .input(
      z.object({
        runId: z.string().uuid(),
        stepKey: z.string().optional(),
        stream: STREAM_SCHEMA,
        chunk: z.string(),
        lineNumber: z.number().int().min(0),
      })
    )
    .mutation(async ({ input, ctx }) => {
      return ctx.adapter.appendMessage({
        runId: input.runId,
        stepKey: input.stepKey,
        stream: input.stream,
        chunk: input.chunk,
        lineNumber: input.lineNumber,
      });
    }),

  /**
   * List messages for a run, optionally filtered by step.
   * GET /trpc/runs.listMessages
   */
  listMessages: t.procedure
    .input(
      z.object({
        runId: z.string().uuid(),
        stepKey: z.string().optional(),
      })
    )
    .query(async ({ input, ctx }) => {
      return ctx.adapter.listMessages(input.runId, input.stepKey);
    }),
});

const mailRouter = t.router({
  send: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        runId: z.string().uuid(),
        senderAgentType: z.string().min(1),
        recipientAgentType: z.string().min(1),
        subject: z.string().min(1),
        body: z.string(),
      })
    )
    .mutation(async ({ input, ctx }) => {
      return ctx.adapter.sendMessage(
        input.projectId,
        input.runId,
        input.senderAgentType,
        input.recipientAgentType,
        input.subject,
        input.body,
      );
    }),

  list: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        runId: z.string().uuid(),
        agentType: z.string().min(1).optional(),
        unreadOnly: z.boolean().optional(),
      })
    )
    .query(async ({ input, ctx }) => {
      if (input.agentType) {
        return ctx.adapter.getMessages(input.projectId, input.runId, input.agentType, input.unreadOnly ?? false);
      }
      return ctx.adapter.getAllMessages(input.runId);
    }),

  listGlobal: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
        limit: z.number().int().min(1).max(500).optional(),
      })
    )
    .query(async ({ input, ctx }) => {
      return ctx.adapter.getAllMessagesGlobal(input.projectId, input.limit ?? 200);
    }),

  markRead: t.procedure
    .input(z.object({ projectId: PROJECT_ID_SCHEMA, messageId: z.string().uuid() }))
    .mutation(async ({ input, ctx }) => {
      return ctx.adapter.markMessageRead(input.projectId, input.messageId);
    }),

  markAllRead: t.procedure
    .input(z.object({ projectId: PROJECT_ID_SCHEMA, runId: z.string().uuid(), agentType: z.string().min(1) }))
    .mutation(async ({ input, ctx }) => {
      await ctx.adapter.markAllMessagesRead(input.projectId, input.runId, input.agentType);
      return { updated: true };
    }),

  delete: t.procedure
    .input(z.object({ projectId: PROJECT_ID_SCHEMA, messageId: z.string().uuid() }))
    .mutation(async ({ input, ctx }) => {
      return ctx.adapter.deleteMessage(input.projectId, input.messageId);
    }),
});

// ---------------------------------------------------------------------------
// Projects router
// ---------------------------------------------------------------------------

const projectsRouter = t.router({
  /**
   * List all projects with health status.
   * GET /trpc/projects.list
   *
   * Returns projects from the daemon-backed registry source of truth, enriched
   * with health status.
   * Tasks counts (running, ready, needs human) come from the task store.
   */
  list: t.procedure
    .input(
      z.object({
        status: STATUS_FILTER_SCHEMA,
        search: z.string().optional(),
      }).optional()
    )
    .query(async ({ input, ctx }) => {
      const records = await ctx.registry.list();

      // Filter in memory after loading from the daemon-backed registry source
      // of truth.
      let filtered = records;
      if (input?.status) {
        filtered = filtered.filter((p) => p.status === input.status);
      }
      if (input?.search) {
        const term = input.search.toLowerCase();
        filtered = filtered.filter(
          (p) =>
            p.name.toLowerCase().includes(term) ||
            p.githubUrl?.toLowerCase().includes(term)
        );
      }

      // Enrich with health status in parallel
      const enriched = await Promise.all(
        filtered.map(async (p) => ({
          id: p.id,
          name: p.name,
          path: p.path,
          githubUrl: p.githubUrl,
          defaultBranch: p.defaultBranch,
          status: p.status,
          lastSyncAt: p.lastSyncAt,
          createdAt: p.createdAt,
          healthy: await ctx.registry.isHealthy(p.id).catch(() => false),
        }))
      );

      return enriched;
    }),

  /**
   * Get a single project by ID.
   * GET /trpc/projects.get
   */
  get: t.procedure
    .input(z.object({ id: PROJECT_ID_SCHEMA }))
    .query(async ({ input, ctx }) => {
      return ctx.registry.get(input.id);
    }),

  /**
   * Get aggregate task counts for a project.
   * GET /trpc/projects.stats
   */
  stats: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
      })
    )
    .query(async ({ input, ctx }) => {
      const [backlog, ready, inProgress, merged, closed] = await Promise.all([
        ctx.adapter.listTasks(input.projectId, { status: ["backlog"] }),
        ctx.adapter.listTasks(input.projectId, { status: ["ready"] }),
        ctx.adapter.listTasks(input.projectId, { status: ["in-progress"] }),
        ctx.adapter.listTasks(input.projectId, { status: ["merged"] }),
        ctx.adapter.listTasks(input.projectId, { status: ["closed"] }),
      ]);

      const activeRuns = await ctx.adapter.listPipelineRuns(input.projectId, { status: "running" });
      const pendingRuns = await ctx.adapter.listPipelineRuns(input.projectId, { status: "pending" });

      return {
        tasks: {
          backlog: backlog.length,
          ready: ready.length,
          inProgress: inProgress.length,
          approved: 0,
          merged: merged.length,
          closed: closed.length,
          total: backlog.length + ready.length + inProgress.length + merged.length + closed.length,
        },
        runs: {
          active: activeRuns.length,
          pending: pendingRuns.length,
        },
      };
    }),

  /**
   * List tasks needing human attention for a project.
   * GET /trpc/projects.listNeedsHuman
   */
  listNeedsHuman: t.procedure
    .input(
      z.object({
        projectId: PROJECT_ID_SCHEMA,
      })
    )
    .query(async ({ input, ctx }) => {
      const [conflict, failed, stuck] = await Promise.all([
        ctx.adapter.listTasks(input.projectId, { status: ["conflict"] }),
        ctx.adapter.listTasks(input.projectId, { status: ["failed"] }),
        ctx.adapter.listTasks(input.projectId, { status: ["stuck"] }),
      ]);
      return [...conflict, ...failed, ...stuck];
    }),

  /**
   * Add a project from a GitHub URL.
   * POST /trpc/projects.add
   *
   * Steps:
   * 1. Verify gh auth (throws if not authenticated)
   * 2. Fetch repo metadata (owner, repo, default branch, visibility)
   * 3. Generate stable project ID: <normalized-name>-<hex5>
   * 4. Create ~/.foreman/projects/ directory if absent
   * 5. Clone repo to ~/.foreman/projects/<project-id>/
   * 6. Write to Postgres (idempotent: fails if path already exists)
   *
   * @throws GhNotInstalledError if gh is not installed
   * @throws GhNotAuthenticatedError if gh is not logged in
   * @throws GhCloneError if clone fails
   * @throws GhApiError if repo metadata fetch fails
   */
  add: t.procedure
    .input(
      z.object({
        /** GitHub repository URL or owner/repo shorthand. */
        githubUrl: z.string().min(1),
        /** Override display name. Defaults to repo name from GitHub API. */
        name: PROJECT_NAME_SCHEMA.optional(),
        /** Override default branch. Defaults to repo default from GitHub API. */
        defaultBranch: z.string().optional(),
        /** Override project status. Defaults to "active". */
        status: z.enum(["active", "paused", "archived"]).optional(),
      })
    )
    .mutation(async ({ input, ctx }) => {
      const { gh, registry } = ctx;

      // Step 1: Verify gh auth
      try {
        await gh.checkAuth();
      } catch (err) {
        if (err instanceof GhNotInstalledError) {
          throw new TrpcProjectError(
            "GitHub CLI (gh) is required but not installed. Install it from https://cli.github.com"
          );
        }
        if (err instanceof GhNotAuthenticatedError) {
          throw new TrpcProjectError(
            `GitHub authentication required: ${err.message}. Run 'gh auth login' first.`
          );
        }
        throw err;
      }

      // Step 2: Parse GitHub URL to extract owner/repo
      const parsed = parseGitHubUrl(input.githubUrl);
      const repoKey = toRepoKey(parsed.owner, parsed.repo);

      // Step 3: Fetch repo metadata from GitHub API
      let defaultBranch = input.defaultBranch ?? "main";
      let displayName = input.name;
      try {
        const meta = await gh.getRepoMetadata(parsed.owner, parsed.repo);
        defaultBranch = meta.defaultBranch;
        displayName = displayName ?? parsed.repo;
      } catch (err) {
        if (err instanceof GhError) {
          throw new TrpcProjectError(
            `Failed to fetch repository metadata for '${input.githubUrl}': ${err.message}`
          );
        }
        throw err;
      }

      // Step 4: Generate a stable clone directory name
      const cloneDirName = registry.generateProjectId(displayName);
      const projectsDir = join(homedir(), ".foreman", "projects");
      const clonePath = join(projectsDir, cloneDirName);

      // Step 5: Ensure projects directory exists
      const { mkdir } = await import("node:fs/promises");
      await mkdir(projectsDir, { recursive: true });

      // Step 6: Clone the repository
      try {
        await gh.repoClone(input.githubUrl, clonePath);
      } catch (err) {
        if (err instanceof GhNotAuthenticatedError) {
          throw new TrpcProjectError(
            `GitHub authentication required to clone '${input.githubUrl}'. Run 'gh auth login' first.`
          );
        }
        if (err instanceof GhError) {
          throw new TrpcProjectError(
            `Failed to clone repository '${input.githubUrl}': ${err.message}`
          );
        }
        throw err;
      }

      // Step 7: Persist in the daemon-backed project registry source of truth.
      const record = await registry.add({
        name: displayName,
        path: clonePath,
        githubUrl: input.githubUrl,
        repoKey,
        defaultBranch,
        status: input.status ?? "active",
      });
      return {
        id: record.id,
        name: record.name,
        path: record.path,
        github_url: record.githubUrl,
        default_branch: record.defaultBranch,
        status: record.status,
        created_at: record.createdAt,
        updated_at: record.updatedAt,
        last_sync_at: record.lastSyncAt,
      };
    }),

  /**
   * Update a project.
   * POST /trpc/projects.update
   */
  update: t.procedure
    .input(
      z.object({
        id: PROJECT_ID_SCHEMA,
        updates: z.object({
          name: PROJECT_NAME_SCHEMA.optional(),
          path: PROJECT_PATH_SCHEMA.optional(),
          status: STATUS_FILTER_SCHEMA,
        }),
      })
    )
    .mutation(async ({ input, ctx }) => {
      return ctx.registry.update(input.id, {
        ...(input.updates.name !== undefined ? { name: input.updates.name } : {}),
        ...(input.updates.path !== undefined ? { path: input.updates.path } : {}),
        ...(input.updates.status !== undefined ? { status: input.updates.status } : {}),
      });
    }),

  /**
   * Remove (archive) a project.
   * POST /trpc/projects.remove
   *
   * Guards against removing a project with active (pending/running) tasks
   * unless force=true.
   */
  remove: t.procedure
    .input(
      z.object({
        id: PROJECT_ID_SCHEMA,
        force: z.boolean().optional(),
      })
    )
    .mutation(async ({ input, ctx }) => {
      // Active-run guard: prevent removal if project has pending/running tasks
      if (!input.force) {
        const hasActive = await hasActiveRuns(input.id, ctx);
        if (hasActive) {
          throw new TrpcProjectError(
            `Project '${input.id}' has active runs. ` +
              `Complete or cancel them before removing, or use --force to skip this check.`
          );
        }
      }
      await ctx.registry.remove(input.id);
      return { removed: true };
    }),

  /**
   * Sync a project: run git fetch and update lastSyncAt in both JSON and Postgres.
   * POST /trpc/projects.sync
   */
  sync: t.procedure
    .input(z.object({ id: PROJECT_ID_SCHEMA }))
    .mutation(async ({ input, ctx }) => {
      // registry.sync() runs git fetch and updates lastSyncAt in JSON + Postgres
      const record = await ctx.registry.sync(input.id);
      return record;
    }),
});

// ---------------------------------------------------------------------------
// App router
// ---------------------------------------------------------------------------

export const appRouter = t.router({
  projects: projectsRouter,
  tasks: tasksRouter,
  runs: runsRouter,
  mail: mailRouter,
});

export type AppRouter = typeof appRouter;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Parse a GitHub URL or shorthand into owner and repo.
 *
 * Accepts:
 * - `https://github.com/owner/repo`
 * - `https://github.com/owner/repo/tree/branch-name`
 * - `git@github.com:owner/repo.git`
 * - `owner/repo`
 *
 * @throws TrpcProjectError if the URL cannot be parsed.
 */
function parseGitHubUrl(url: string): { owner: string; repo: string } {
  // HTTPS URL: https://github.com/owner/repo[.git]
  const httpsMatch = url.match(
    /^https?:\/\/github\.com\/([^/]+)\/([^/.]+)/i
  );
  if (httpsMatch) {
    return {
      owner: httpsMatch[1]!,
      repo: httpsMatch[2]!.replace(/\.git$/, ""),
    };
  }

  // SSH URL: git@github.com:owner/repo.git
  const sshMatch = url.match(/^git@github\.com:([^/]+)\/(.+?)(?:\.git)?$/i);
  if (sshMatch) {
    return { owner: sshMatch[1]!, repo: sshMatch[2]! };
  }

  // Shortcut: owner/repo
  const shortcutMatch = url.match(/^([^/]+)\/(.+)$/);
  if (shortcutMatch) {
    return { owner: shortcutMatch[1]!, repo: shortcutMatch[2]! };
  }

  throw new TrpcProjectError(
    `Invalid GitHub URL '${url}'. Expected formats: ` +
      `"owner/repo", "https://github.com/owner/repo", or "git@github.com:owner/repo"`
  );
}

function toRepoKey(owner: string, repo: string): string {
  return `${owner}/${repo}`.toLowerCase();
}

// ---------------------------------------------------------------------------
// Active-run guard
// ---------------------------------------------------------------------------

/**
 * Check whether a project has any active pipeline runs.
 */
async function hasActiveRuns(
  projectId: string,
  ctx: Context
): Promise<boolean> {
  const [pendingRuns, activeRuns] = await Promise.all([
    ctx.adapter.listPipelineRuns(projectId, { status: "pending" }),
    ctx.adapter.listPipelineRuns(projectId, { status: "running" }),
  ]);
  return pendingRuns.length > 0 || activeRuns.length > 0;
}
