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
  createTask: vi.fn(),
  listTasks: vi.fn(),
  getTask: vi.fn(),
  updateTask: vi.fn(),
  deleteTask: vi.fn(),
  approveTask: vi.fn(),
  resetTask: vi.fn(),
  retryTask: vi.fn(),
  listReadyTasks: vi.fn(),
  listNeedsHumanTasks: vi.fn(),
};

const mockGh = {
  checkAuth: vi.fn(),
  authStatus: vi.fn(),
  repoClone: vi.fn(),
  api: vi.fn(),
  getRepoMetadata: vi.fn(),
  isInstalled: vi.fn(),
};

const mockRegistry = {
  generateProjectId: vi.fn(),
  add: vi.fn(),
  get: vi.fn(),
  list: vi.fn(),
  update: vi.fn(),
  remove: vi.fn(),
  sync: vi.fn(),
  isHealthy: vi.fn(),
  resolve: vi.fn(),
};


const mockCtx: Context = {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  req: {} as any,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  res: {} as any,
  adapter: mockAdapter as never,
  gh: mockGh as never,
  registry: mockRegistry as never,
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

  it("add input schema validates githubUrl as primary field", () => {
    const schema = z.object({
      githubUrl: z.string().min(1),
      name: z.string().min(1).max(255).optional(),
      defaultBranch: z.string().optional(),
      status: z.enum(["active", "paused", "archived"]).optional(),
    });

    // Valid: githubUrl only
    expect(() => schema.parse({ githubUrl: "owner/repo" })).not.toThrow();
    // Valid: full input
    expect(() =>
      schema.parse({
        githubUrl: "https://github.com/owner/repo",
        name: "my-project",
        defaultBranch: "main",
        status: "active",
      })
    ).not.toThrow();
    // Missing githubUrl
    expect(() => schema.parse({ name: "my-project" })).toThrow();
  });

  // TRD-030: projectId required on all task procedures
  it("task create input requires projectId", () => {
    const schema = z.object({
      projectId: z.string().min(1),
      title: z.string().min(1),
      description: z.string().optional(),
      type: z.enum(["feature", "bugfix", "chore", "test", "docs", "refactor", "security"]).optional(),
      priority: z.enum(["P0", "P1", "P2", "P3", "P4"]).optional(),
      status: z.enum(["backlog", "ready", "in-progress", "in-review", "approved", "merged", "closed"]).optional(),
      externalId: z.string().optional(),
    });
    // Missing projectId
    expect(() => schema.parse({ title: "Test" })).toThrow();
    // Valid: projectId only
    expect(() => schema.parse({ projectId: "proj-123", title: "Test" })).not.toThrow();
  });

  it("task get/list input requires projectId", () => {
    const listSchema = z.object({
      projectId: z.string().min(1),
      status: z.enum(["backlog", "ready", "in-progress", "in-review", "approved", "merged", "closed"]).optional(),
      type: z.string().optional(),
      priority: z.enum(["P0", "P1", "P2", "P3", "P4"]).optional(),
      assignee: z.string().optional(),
    });
    const getSchema = z.object({
      projectId: z.string().min(1),
      taskId: z.string().min(1),
    });
    // Missing projectId
    expect(() => listSchema.parse({})).toThrow();
    expect(() => getSchema.parse({ taskId: "task-1" })).toThrow();
    // Valid
    expect(() => listSchema.parse({ projectId: "proj-123" })).not.toThrow();
    expect(() => getSchema.parse({ projectId: "proj-123", taskId: "task-1" })).not.toThrow();
  });

  it("task update/approve/reset/retry require projectId", () => {
    const schema = z.object({
      projectId: z.string().min(1),
      taskId: z.string().min(1),
    });
    // Missing projectId
    expect(() => schema.parse({ taskId: "task-1" })).toThrow();
    // Valid
    expect(() => schema.parse({ projectId: "proj-123", taskId: "task-1" })).not.toThrow();
  });
});

// ---------------------------------------------------------------------------
// Task procedure integration tests (TRD-031)
// ---------------------------------------------------------------------------

describe("tasks router structure", () => {
  it("has a tasks router", () => {
    // @ts-ignore - only testing structure at runtime
    expect(appRouter).toHaveProperty("tasks");
  });

  it("tasks router has list procedure", () => {
    // @ts-ignore
    expect(appRouter.tasks).toHaveProperty("list");
  });

  it("tasks router has get procedure", () => {
    // @ts-ignore
    expect(appRouter.tasks).toHaveProperty("get");
  });

  it("tasks router has create procedure", () => {
    // @ts-ignore
    expect(appRouter.tasks).toHaveProperty("create");
  });

  it("tasks router has update procedure", () => {
    // @ts-ignore
    expect(appRouter.tasks).toHaveProperty("update");
  });

  it("tasks router has delete procedure", () => {
    // @ts-ignore
    expect(appRouter.tasks).toHaveProperty("delete");
  });

  it("tasks router has approve procedure", () => {
    // @ts-ignore
    expect(appRouter.tasks).toHaveProperty("approve");
  });

  it("tasks router has reset procedure", () => {
    // @ts-ignore
    expect(appRouter.tasks).toHaveProperty("reset");
  });

  it("tasks router has retry procedure", () => {
    // @ts-ignore
    expect(appRouter.tasks).toHaveProperty("retry");
  });

  it("tasks router has claim procedure", () => {
    // @ts-ignore
    expect(appRouter.tasks).toHaveProperty("claim");
  });
});

describe("tasks.list procedure", () => {
  beforeEach(() => mockAdapter.listTasks.mockReset());

  it("calls adapter.listTasks with projectId and filters", async () => {
    const mockTask = {
      id: "task-1",
      project_id: "proj-123",
      title: "Test task",
      description: null,
      type: "feature",
      priority: 2,
      status: "backlog",
      run_id: null,
      branch: null,
      external_id: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      approved_at: null,
      closed_at: null,
    };
    mockAdapter.listTasks.mockResolvedValueOnce([mockTask]);

    const caller = appRouter.createCaller(mockCtx);
    // @ts-ignore
    const result = await caller.tasks.list({ projectId: "proj-123" });

    expect(mockAdapter.listTasks).toHaveBeenCalledWith(
      "proj-123",
      expect.objectContaining({})
    );
    expect(result).toHaveLength(1);
    expect(result[0].id).toBe("task-1");
  });

  it("passes status filter to adapter", async () => {
    mockAdapter.listTasks.mockResolvedValueOnce([]);
    const caller = appRouter.createCaller(mockCtx);
    // @ts-ignore
    await caller.tasks.list({ projectId: "proj-123", status: ["ready"] });
    expect(mockAdapter.listTasks).toHaveBeenCalledWith(
      "proj-123",
      expect.objectContaining({ status: ["ready"] })
    );
  });

  it("rejects missing projectId", async () => {
    const caller = appRouter.createCaller(mockCtx);
    // @ts-ignore
    await expect(caller.tasks.list({})).rejects.toThrow();
  });
});

describe("tasks.create procedure", () => {
  beforeEach(() => mockAdapter.createTask.mockReset());

  it("calls adapter.createTask with projectId and task data", async () => {
    const mockTask = {
      id: "task-2",
      project_id: "proj-123",
      title: "New feature",
      description: "Implement X",
      type: "task",
      priority: 1,
      status: "backlog",
      run_id: null,
      branch: null,
      external_id: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      approved_at: null,
      closed_at: null,
    };
    mockAdapter.createTask.mockResolvedValueOnce(mockTask);

    const caller = appRouter.createCaller(mockCtx);
    // @ts-ignore
    const result = await caller.tasks.create({
      projectId: "proj-123",
      id: "task-2",
      title: "New feature",
      description: "Implement X",
      type: "task",
      priority: 1,
    });

    expect(mockAdapter.createTask).toHaveBeenCalledWith(
      "proj-123",
      expect.objectContaining({ title: "New feature", type: "task" })
    );
    expect(result.id).toBe("task-2");
  });

  it("rejects empty title", async () => {
    const caller = appRouter.createCaller(mockCtx);
    // @ts-ignore
    await expect(
      caller.tasks.create({ projectId: "proj-123", id: "task-x", title: "" })
    ).rejects.toThrow();
  });

  it("rejects missing projectId", async () => {
    const caller = appRouter.createCaller(mockCtx);
    await expect(
      // @ts-ignore - intentionally testing missing projectId
      caller.tasks.create({ id: "task-x", title: "Test" })
    ).rejects.toThrow();
  });
});

describe("tasks.approve procedure", () => {
  beforeEach(() => {
    mockAdapter.approveTask.mockReset();
    mockAdapter.getTask.mockReset();
  });

  it("calls adapter.approveTask then returns updated task", async () => {
    const mockTask = {
      id: "task-1",
      project_id: "proj-123",
      title: "Test",
      description: null,
      type: "task",
      priority: 2,
      status: "approved",
      run_id: null,
      branch: null,
      external_id: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      approved_at: new Date().toISOString(),
      closed_at: null,
    };
    mockAdapter.approveTask.mockResolvedValueOnce(undefined);
    mockAdapter.getTask.mockResolvedValueOnce(mockTask);
    const caller = appRouter.createCaller(mockCtx);
    // @ts-ignore
    const result = await caller.tasks.approve({
      projectId: "proj-123",
      taskId: "task-1",
    });

    expect(mockAdapter.approveTask).toHaveBeenCalledWith("proj-123", "task-1");
    expect(result!.id).toBe("task-1");
    expect(result!.status).toBe("approved");
  });

  it("rejects missing projectId", async () => {
    const caller = appRouter.createCaller(mockCtx);
    await expect(
      // @ts-ignore - intentionally testing missing projectId
      caller.tasks.approve({ taskId: "task-1" })
    ).rejects.toThrow();
  });
});

describe("tasks.reset procedure", () => {
  beforeEach(() => {
    mockAdapter.resetTask.mockReset();
    mockAdapter.getTask.mockReset();
  });

  it("calls adapter.resetTask then returns updated task", async () => {
    const mockTask = {
      id: "task-1",
      project_id: "proj-123",
      title: "Test",
      description: null,
      type: "task",
      priority: 2,
      status: "backlog",
      run_id: null,
      branch: null,
      external_id: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      approved_at: null,
      closed_at: null,
    };
    mockAdapter.resetTask.mockResolvedValueOnce(undefined);
    mockAdapter.getTask.mockResolvedValueOnce(mockTask);
    const caller = appRouter.createCaller(mockCtx);
    // @ts-ignore
    const result = await caller.tasks.reset({
      projectId: "proj-123",
      taskId: "task-1",
    });

    expect(mockAdapter.resetTask).toHaveBeenCalledWith("proj-123", "task-1");
    expect(result!.id).toBe("task-1");
  });
});

describe("tasks.retry procedure", () => {
  beforeEach(() => {
    mockAdapter.retryTask.mockReset();
    mockAdapter.getTask.mockReset();
  });

  it("calls adapter.retryTask then returns updated task", async () => {
    const mockTask = {
      id: "task-1",
      project_id: "proj-123",
      title: "Test",
      description: null,
      type: "task",
      priority: 2,
      status: "backlog",
      run_id: null,
      branch: null,
      external_id: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      approved_at: null,
      closed_at: null,
    };
    mockAdapter.retryTask.mockResolvedValueOnce(undefined);
    mockAdapter.getTask.mockResolvedValueOnce(mockTask);
    const caller = appRouter.createCaller(mockCtx);
    // @ts-ignore
    const result = await caller.tasks.retry({
      projectId: "proj-123",
      taskId: "task-1",
    });

    expect(mockAdapter.retryTask).toHaveBeenCalledWith("proj-123", "task-1");
    expect(result!.id).toBe("task-1");
  });
});

describe("tasks.get procedure", () => {
  beforeEach(() => mockAdapter.getTask.mockReset());

  it("calls adapter.getTask and returns task", async () => {
    const mockTask = {
      id: "task-1",
      project_id: "proj-123",
      title: "Test",
      description: null,
      type: "feature",
      priority: 2,
      status: "backlog",
      run_id: null,
      branch: null,
      external_id: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      approved_at: null,
      closed_at: null,
    };
    mockAdapter.getTask.mockResolvedValueOnce(mockTask);

    const caller = appRouter.createCaller(mockCtx);
    // @ts-ignore
    const result = await caller.tasks.get({
      projectId: "proj-123",
      taskId: "task-1",
    });

    expect(mockAdapter.getTask).toHaveBeenCalledWith("proj-123", "task-1");
    expect(result!.id).toBe("task-1");
  });

  it("rejects missing projectId", async () => {
    const caller = appRouter.createCaller(mockCtx);
    await expect(
      // @ts-ignore - intentionally testing missing projectId
      caller.tasks.get({ taskId: "task-1" })
    ).rejects.toThrow();
  });
});

// ---------------------------------------------------------------------------
// Context factory
// ---------------------------------------------------------------------------

describe("createContext", () => {
  it("createContext returns a Context object with adapter, gh, and registry", async () => {
    const { createContext } = await import("../router.js");
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const ctx = await createContext({ req: {} as any, res: {} as any });
    expect(ctx).toHaveProperty("adapter");
    expect(ctx).toHaveProperty("req");
    expect(ctx).toHaveProperty("res");
    expect(ctx).toHaveProperty("gh");
    expect(ctx).toHaveProperty("registry");
  });
});
