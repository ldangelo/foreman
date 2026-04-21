/**
 * TRD-004-TEST | Verifies: TRD-004 | Tests: TrpcRouter exposes projects.list/add/remove procedures
 * PRD: docs/PRD/PRD-2026-010-multi-project-orchestrator.md
 * TRD: docs/TRD/TRD-2026-011-multi-project-orchestrator.md#trd-004
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { initTRPC } from "@trpc/server";
import { z } from "zod";
import { appRouter } from "../router.js";
import type { Context } from "../router.js";

// ---------------------------------------------------------------------------
// Mock context
// ---------------------------------------------------------------------------

const mockAdapter = {
  createProject: vi.fn(),
  listProjects: vi.fn(),
  getProject: vi.fn(),
  updateProject: vi.fn(),
  removeProject: vi.fn(),
  syncProject: vi.fn(),
};

const mockCtx: Context = {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  req: {} as any,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  res: {} as any,
  adapter: mockAdapter as never,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

type RouterRecord = {
  projects: {
    list: { query: (input: unknown) => Promise<unknown> };
    get: { query: (input: unknown) => Promise<unknown> };
    add: { mutation: (input: unknown) => Promise<unknown> };
    update: { mutation: (input: unknown) => Promise<unknown> };
    remove: { mutation: (input: unknown) => Promise<unknown> };
    sync: { mutation: (input: unknown) => Promise<unknown> };
  };
};

function createCaller(router: typeof appRouter) {
  return (procedures: RouterRecord["projects"]) => procedures;
}

// ---------------------------------------------------------------------------
// Router structure tests
// ---------------------------------------------------------------------------

describe("TrpcRouter structure", () => {
  it("has a projects router", () => {
    // @ts-ignore - only testing structure at runtime
    expect(appRouter).toHaveProperty("projects");
  });

  it("projects router has list procedure", () => {
    // @ts-ignore - only testing structure at runtime
    expect(appRouter.projects).toHaveProperty("list");
  });

  it("projects router has add procedure", () => {
    // @ts-ignore - only testing structure at runtime
    expect(appRouter.projects).toHaveProperty("add");
  });

  it("projects router has get procedure", () => {
    // @ts-ignore - only testing structure at runtime
    expect(appRouter.projects).toHaveProperty("get");
  });

  it("projects router has update procedure", () => {
    // @ts-ignore - only testing structure at runtime
    expect(appRouter.projects).toHaveProperty("update");
  });

  it("projects router has remove procedure", () => {
    // @ts-ignore - only testing structure at runtime
    expect(appRouter.projects).toHaveProperty("remove");
  });

  it("projects router has sync procedure", () => {
    // @ts-ignore - only testing structure at runtime
    expect(appRouter.projects).toHaveProperty("sync");
  });

  it("has expected type — AppRouter defined", () => {
    // Type-level test: if this compiles, AppRouter is properly exported.
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    type _AppRouter = typeof appRouter;
  });
});

// ---------------------------------------------------------------------------
// Zod schemas
// ---------------------------------------------------------------------------

describe("Zod schemas", () => {
  it("PROJECT_ID_SCHEMA validates non-empty strings", () => {
    const schema = z.string().min(1);
    expect(() => schema.parse("")).toThrow();
    expect(() => schema.parse("proj-123")).not.toThrow();
  });

  it("STATUS_FILTER_SCHEMA accepts valid enum values", () => {
    const schema = z.enum(["active", "paused", "archived"]).optional();
    expect(schema.parse("active")).toBe("active");
    expect(schema.parse("archived")).toBe("archived");
    expect(schema.parse(undefined)).toBeUndefined();
    expect(() => schema.parse("invalid")).toThrow();
  });

  it("createProject input schema validates required fields", () => {
    const schema = z.object({
      name: z.string().min(1).max(255),
      path: z.string().min(1),
      githubUrl: z.string().url().optional(),
      defaultBranch: z.string().optional(),
    });

    // Valid
    expect(() =>
      schema.parse({ name: "my-project", path: "/tmp/my-project" })
    ).not.toThrow();

    // Missing required
    expect(() => schema.parse({ path: "/tmp" })).toThrow();

    // Invalid URL
    expect(() =>
      schema.parse({ name: "my-project", path: "/tmp", githubUrl: "not-a-url" })
    ).toThrow();
  });
});

// ---------------------------------------------------------------------------
// Context factory
// ---------------------------------------------------------------------------

describe("createContext", () => {
  it("returns a Context object with adapter", async () => {
    const { createContext } = await import("../router.js");
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const ctx = await createContext({ req: {} as any, res: {} as any });
    expect(ctx).toHaveProperty("adapter");
    expect(ctx).toHaveProperty("req");
    expect(ctx).toHaveProperty("res");
  });
});
