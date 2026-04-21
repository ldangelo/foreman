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
import { existsSync } from "node:fs";
import Database from "better-sqlite3";

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
  return {
    req,
    res,
    adapter: new PostgresAdapter(),
    // Singleton instances shared across all requests in the daemon process
    gh: new GhCli(),
    registry: new ProjectRegistry(),
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
const TASK_TYPE_SCHEMA = z.enum(["task", "bug", "story", "epic", "chore"]).optional();

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
        externalId: z.string().optional(),
        branch: z.string().optional(),
      })
    )
    .mutation(async ({ input, ctx }) => {
      return ctx.adapter.createTask(input.projectId, {
        id: input.id,
        title: input.title ?? input.id,
        description: input.description,
        type: input.type ?? "task",
        priority: input.priority ?? 2,
        external_id: input.externalId,
        branch: input.branch,
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
});

// ---------------------------------------------------------------------------
// Projects router
// ---------------------------------------------------------------------------

const projectsRouter = t.router({
  /**
   * List all projects with health status.
   * GET /trpc/projects.list
   *
   * Returns projects from the registry (source of truth), enriched with health status.
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

      // Filter in memory (source of truth is JSON, Postgres is query mirror)
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
      return ctx.adapter.getProject(input.id);
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
      const { gh, registry, adapter } = ctx;

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

      // Step 4: Generate stable project ID and derive clone path
      const projectId = registry.generateProjectId(displayName);
      const projectsDir = join(homedir(), ".foreman", "projects");
      const clonePath = join(projectsDir, projectId);

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

      // Step 7: Write to Postgres (idempotent — throws on duplicate path)
      try {
        const row = await adapter.createProject({
          id: projectId,
          name: displayName,
          path: clonePath,
          githubUrl: input.githubUrl,
          defaultBranch,
          status: input.status ?? "active",
        });
        return row;
      } catch (err) {
        // Postgres write failed — best effort cleanup of cloned repo
        // (Leave the clone on disk; user can remove manually)
        throw err;
      }
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
      return ctx.adapter.updateProject(input.id, input.updates);
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
      return ctx.adapter.removeProject(input.id, {
        force: input.force ?? false,
      });
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

// ---------------------------------------------------------------------------
// Active-run guard
// ---------------------------------------------------------------------------

/**
 * Check whether a project has any active (pending or running) tasks.
 * Queries the per-project SQLite task store at `<project-path>/.beads/beads.db`.
 * Returns false if the store file does not exist (no tasks have been created yet).
 */
async function hasActiveRuns(
  projectId: string,
  ctx: Context
): Promise<boolean> {
  const record = await ctx.registry.get(projectId);
  if (!record) return false; // project doesn't exist — guard won't prevent removal

  const dbPath = join(record.path, ".beads", "beads.db");
  if (!existsSync(dbPath)) return false;

  try {
    const db = new Database(dbPath, { readonly: true });
    try {
      const rows = db
        .prepare(
          `SELECT COUNT(*) as cnt FROM tasks WHERE status IN ('pending', 'running') LIMIT 1`
        )
        .get() as { cnt: number } | undefined;
      return (rows?.cnt ?? 0) > 0;
    } finally {
      db.close();
    }
  } catch {
    // If the database is locked or schema is wrong, fail open — don't block removal
    return false;
  }
}
