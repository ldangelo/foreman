import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const {
  mockResolveRepoRootProjectPath,
  mockListRegisteredProjects,
  mockCreateTrpcClient,
  mockDispatcher,
  mockForProject,
  mockStoreClose,
} = vi.hoisted(() => {
  const mockResolveRepoRootProjectPath = vi.fn();
  const mockListRegisteredProjects = vi.fn();
  const mockCreateTrpcClient = vi.fn();
  const mockDispatcher = vi.fn(function MockDispatcherImpl(this: Record<string, unknown>) {
    this.dispatchPlanStep = vi.fn();
  });
  const mockStoreClose = vi.fn();
  const mockForProject = vi.fn(() => ({ close: mockStoreClose }));

  return {
    mockResolveRepoRootProjectPath,
    mockListRegisteredProjects,
    mockCreateTrpcClient,
    mockDispatcher,
    mockForProject,
    mockStoreClose,
  };
});

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: () => "node",
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

vi.mock("../../lib/store.js", async () => {
  const actual = await vi.importActual<typeof import("../../lib/store.js")>("../../lib/store.js");
  return {
    ...actual,
    ForemanStore: {
      ...actual.ForemanStore,
      forProject: mockForProject,
    },
  };
});

vi.mock("../../orchestrator/dispatcher.js", () => ({
  Dispatcher: mockDispatcher,
}));

import { planCommand } from "../commands/plan.js";

describe("foreman plan main flow", () => {
  const tempDirs: string[] = [];

  function makeProject(): { projectPath: string; docsDir: string; prdPath: string } {
    const projectPath = mkdtempSync(join(tmpdir(), "foreman-plan-main-"));
    tempDirs.push(projectPath);
    const docsDir = join(projectPath, "docs");
    mkdirSync(docsDir, { recursive: true });
    const prdPath = join(docsDir, "PRD.md");
    writeFileSync(prdPath, "# PRD\n");
    return { projectPath, docsDir, prdPath };
  }

  beforeEach(() => {
    vi.clearAllMocks();
    mockResolveRepoRootProjectPath.mockResolvedValue("/canonical/project");
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "foreman", path: "/canonical/project" },
    ]);
    mockForProject.mockReturnValue({ close: mockStoreClose });
    mockStoreClose.mockReset();
    process.exitCode = undefined;
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  async function runPlan(args: string[]): Promise<void> {
    await planCommand.parseAsync(args, { from: "user" });
  }

  it("creates and closes only an epic when the pipeline has no steps", async () => {
    const { projectPath, prdPath } = makeProject();
    mockResolveRepoRootProjectPath.mockResolvedValue(projectPath);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "foreman", path: projectPath },
    ]);

    const list = vi.fn().mockResolvedValue([]);
    const create = vi.fn().mockResolvedValue({
      id: "foreman-epic",
      title: "Plan: Build auth",
      type: "epic",
      priority: 1,
      status: "ready",
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      description: "Planning pipeline",
    });
    const approve = vi.fn().mockResolvedValue(undefined);
    const addDependency = vi.fn().mockResolvedValue(undefined);
    const get = vi.fn().mockResolvedValue({
      id: "foreman-epic",
      title: "Plan: Build auth",
      type: "epic",
      priority: 1,
      status: "ready",
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      description: "Planning pipeline",
    });
    const close = vi.fn().mockResolvedValue(undefined);

    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, create, approve, addDependency, get, close, update: vi.fn() },
    });

    await runPlan([
      "Build auth",
      "--from-prd",
      prdPath,
      "--prd-only",
    ]);

    expect(create).toHaveBeenCalledTimes(1);
    expect(create).toHaveBeenCalledWith(expect.objectContaining({
      projectId: "proj-1",
      title: expect.stringContaining("Plan: Build auth"),
      type: "epic",
    }));
    expect(mockDispatcher).toHaveBeenCalled();
    expect(mockDispatcher.mock.results[0]?.value.dispatchPlanStep).not.toHaveBeenCalled();
    expect(close).toHaveBeenCalledWith({ projectId: "proj-1", taskId: "foreman-epic" });
    expect(vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("Planning pipeline complete");
    expect(mockStoreClose).toHaveBeenCalledOnce();
  });

  it("creates child planning tasks, dispatches them, and closes the epic on success", async () => {
    const { projectPath, docsDir } = makeProject();
    mockResolveRepoRootProjectPath.mockResolvedValue(projectPath);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "foreman", path: projectPath },
    ]);

    const issueRows = new Map<string, Record<string, unknown>>();
    let createCount = 0;
    const list = vi.fn().mockImplementation(async () => {
      return [...issueRows.values()];
    });
    const create = vi.fn().mockImplementation(async ({ title, type, description }: Record<string, unknown>) => {
      createCount += 1;
      const id = createCount === 1 ? "foreman-epic" : `foreman-step-${createCount - 1}`;
      const row = {
        id,
        title,
        type,
        priority: 1,
        status: createCount === 1 ? "ready" : "ready",
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        description,
      };
      issueRows.set(id, row);
      return row;
    });
    const approve = vi.fn().mockResolvedValue(undefined);
    const addDependency = vi.fn().mockResolvedValue(undefined);
    const get = vi.fn().mockImplementation(async ({ taskId }: { taskId: string }) => issueRows.get(taskId));
    const close = vi.fn().mockResolvedValue(undefined);

    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, create, approve, addDependency, get, close, update: vi.fn() },
    });
    mockDispatcher.mockImplementationOnce(function MockDispatcherImpl(this: Record<string, unknown>) {
      this.dispatchPlanStep = vi.fn()
        .mockResolvedValueOnce({ runId: "run-prd-1" })
        .mockResolvedValueOnce({ runId: "run-prd-2" });
    });

    await runPlan([
      "Build auth",
      "--prd-only",
    ]);

    const dispatch = mockDispatcher.mock.results[0]?.value.dispatchPlanStep;
    expect(create).toHaveBeenCalledTimes(3);
    expect(addDependency).toHaveBeenCalledWith({
      projectId: "proj-1",
      fromTaskId: "foreman-step-2",
      toTaskId: "foreman-step-1",
      type: "blocks",
    });
    expect(dispatch).toHaveBeenCalledTimes(2);
    expect(dispatch).toHaveBeenNthCalledWith(1,
      "proj-1",
      expect.objectContaining({ id: "foreman-step-1", title: "Create PRD" }),
      "/ensemble:create-prd",
      "Build auth",
      docsDir,
    );
    expect(dispatch).toHaveBeenNthCalledWith(2,
      "proj-1",
      expect.objectContaining({ id: "foreman-step-2", title: "Refine PRD" }),
      "/ensemble:refine-prd",
      `Review and refine the PRD in ${docsDir}`,
      docsDir,
    );
    expect(close).toHaveBeenCalledWith({ projectId: "proj-1", taskId: "foreman-step-1" });
    expect(close).toHaveBeenCalledWith({ projectId: "proj-1", taskId: "foreman-step-2" });
    expect(close).toHaveBeenCalledWith({ projectId: "proj-1", taskId: "foreman-epic" });
    expect(mockStoreClose).toHaveBeenCalledOnce();
  });

  it("reports dispatch failures, sets exitCode, and leaves the epic open", async () => {
    const { projectPath, prdPath } = makeProject();
    mockResolveRepoRootProjectPath.mockResolvedValue(projectPath);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "foreman", path: projectPath },
    ]);

    const issueRows = new Map<string, Record<string, unknown>>();
    let createCount = 0;
    const list = vi.fn().mockImplementation(async () => {
      return [...issueRows.values()];
    });
    const create = vi.fn().mockImplementation(async ({ title, type, description }: Record<string, unknown>) => {
      createCount += 1;
      const id = createCount === 1 ? "foreman-epic" : `foreman-step-${createCount - 1}`;
      const row = {
        id,
        title,
        type,
        priority: 1,
        status: "ready",
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        description,
      };
      issueRows.set(id, row);
      return row;
    });
    const approve = vi.fn().mockResolvedValue(undefined);
    const addDependency = vi.fn().mockResolvedValue(undefined);
    const get = vi.fn().mockImplementation(async ({ taskId }: { taskId: string }) => issueRows.get(taskId));
    const close = vi.fn().mockResolvedValue(undefined);

    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, create, approve, addDependency, get, close, update: vi.fn() },
    });
    mockDispatcher.mockImplementationOnce(function MockDispatcherImpl(this: Record<string, unknown>) {
      this.dispatchPlanStep = vi.fn().mockRejectedValue(new Error("planner exploded"));
    });

    await runPlan([
      "Build auth",
      "--from-prd",
      prdPath,
    ]);

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    const errors = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(process.exitCode).toBe(1);
    expect(errors).toContain("planner exploded");
    expect(rendered).toContain("Pipeline paused. Fix the issue");
    expect(close).not.toHaveBeenCalledWith({ projectId: "proj-1", taskId: "foreman-epic" });
    expect(mockStoreClose).toHaveBeenCalledOnce();
  });
});
