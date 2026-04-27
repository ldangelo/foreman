import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockResolveRepoRootProjectPath,
  mockListRegisteredProjects,
  mockSelectTaskReadBackend,
  mockDispatcher,
  mockForProject,
  mockStoreClose,
} = vi.hoisted(() => {
  const mockResolveRepoRootProjectPath = vi.fn();
  const mockListRegisteredProjects = vi.fn();
  const mockSelectTaskReadBackend = vi.fn();
  const mockDispatcher = vi.fn(function MockDispatcherImpl(this: Record<string, unknown>) {
    this.dispatchPlanStep = vi.fn();
  });
  const mockStoreClose = vi.fn();
  const mockForProject = vi.fn(() => ({ close: mockStoreClose }));

  return {
    mockResolveRepoRootProjectPath,
    mockListRegisteredProjects,
    mockSelectTaskReadBackend,
    mockDispatcher,
    mockForProject,
    mockStoreClose,
  };
});

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../lib/task-client-factory.js", () => ({
  selectTaskReadBackend: mockSelectTaskReadBackend,
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

describe("foreman plan command context", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockSelectTaskReadBackend.mockReturnValue("native");
    mockResolveRepoRootProjectPath.mockReset();
    mockListRegisteredProjects.mockReset();
    mockStoreClose.mockReset();
    mockForProject.mockReturnValue({ close: mockStoreClose });
    process.exitCode = undefined;
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  async function runPlan(args: string[]): Promise<void> {
    await planCommand.parseAsync(args, { from: "user" });
  }

  it("resolves a registered plan run from a non-canonical clone/worktree to the registered project path", async () => {
    const canonicalPath = "/canonical/project";

    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "foreman", path: canonicalPath },
    ]);

    await runPlan([
      "Build a user auth system",
      "--project",
      "/worktrees/non-canonical-clone",
      "--dry-run",
    ]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({ project: "/worktrees/non-canonical-clone" });
    expect(mockForProject).toHaveBeenCalledWith(canonicalPath);
    expect(mockDispatcher).toHaveBeenCalledWith(
      expect.any(Object),
      expect.any(Object),
      canonicalPath,
      null,
      { externalProjectId: "proj-1" },
    );
    expect(mockStoreClose).toHaveBeenCalledOnce();
    expect(process.exitCode).toBeUndefined();
  });

  it("keeps local unregistered behavior unchanged", async () => {
    const localPath = "/local/project";

    mockResolveRepoRootProjectPath.mockResolvedValue(localPath);
    mockListRegisteredProjects.mockResolvedValue([]);

    await runPlan(["Build a user auth system", "--dry-run"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockForProject).not.toHaveBeenCalled();
    expect(mockDispatcher).not.toHaveBeenCalled();
    expect(process.exitCode).toBe(1);
  });
});
