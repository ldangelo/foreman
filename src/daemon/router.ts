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

import { initTRPC } from "@trpc/server";
import type { inferRouterContext } from "@trpc/server";
import { z } from "zod";
import type { FastifyRequest, FastifyReply } from "fastify";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

export interface Context {
  /** Fastify request object for access to headers, socket, etc. */
  req: FastifyRequest;
  res: FastifyReply;
  /** PostgresAdapter instance scoped to this request. */
  adapter: PostgresAdapter;
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
const GITHUB_URL_SCHEMA = z.string().url().optional();
const STATUS_FILTER_SCHEMA = z
  .enum(["active", "paused", "archived"])
  .optional();

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

const t = initTRPC.context<Context>().create();

// ---------------------------------------------------------------------------
// Projects router
// ---------------------------------------------------------------------------

const projectsRouter = t.router({
  /**
   * List all projects.
   * GET /trpc/projects.list
   */
  list: t.procedure
    .input(
      z.object({
        status: STATUS_FILTER_SCHEMA,
        search: z.string().optional(),
      }).optional()
    )
    .query(async ({ input, ctx }) => {
      return ctx.adapter.listProjects({
        status: input?.status,
        search: input?.search,
      });
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
   * Create a new project.
   * POST /trpc/projects.add
   */
  add: t.procedure
    .input(
      z.object({
        name: PROJECT_NAME_SCHEMA,
        path: PROJECT_PATH_SCHEMA,
        githubUrl: GITHUB_URL_SCHEMA,
        defaultBranch: z.string().optional(),
      })
    )
    .mutation(async ({ input, ctx }) => {
      return ctx.adapter.createProject({
        name: input.name,
        path: input.path,
        githubUrl: input.githubUrl,
        defaultBranch: input.defaultBranch,
        status: "active",
      });
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
   */
  remove: t.procedure
    .input(
      z.object({
        id: PROJECT_ID_SCHEMA,
        force: z.boolean().optional(),
      })
    )
    .mutation(async ({ input, ctx }) => {
      return ctx.adapter.removeProject(input.id, { force: input.force });
    }),

  /**
   * Sync a project (git fetch + update timestamp).
   * POST /trpc/projects.sync
   */
  sync: t.procedure
    .input(z.object({ id: PROJECT_ID_SCHEMA }))
    .mutation(async ({ input, ctx }) => {
      return ctx.adapter.syncProject(input.id);
    }),
});

// ---------------------------------------------------------------------------
// App router
// ---------------------------------------------------------------------------

export const appRouter = t.router({
  projects: projectsRouter,
});

export type AppRouter = typeof appRouter;
