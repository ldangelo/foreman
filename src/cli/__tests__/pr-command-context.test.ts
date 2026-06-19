import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mockCreateTaskClient = vi.hoisted(() => vi.fn());
const mockListRegisteredProjects = vi.hoisted(() => vi.fn());
const mockResolveRepoRootProjectPath = vi.hoisted(() => vi.fn());
const mockGetProjectByPath = vi.hoisted(() => vi.fn());
const mockCreateVcsBackend = vi.hoisted(() => vi.fn());
const mockPostgresStoreForProject = vi.hoisted(() => vi.fn());
const mockCreatePRs = vi.hoisted(() => vi.fn());
const MockRefinery = vi.hoisted(() => vi.fn(function MockRefineryImpl(this: Record<string, unknown>) {
  return { createPRs: mockCreatePRs };
}));

vi.mock("../../lib/task-client-factory.js", () => ({
  createTaskClient: mockCreateTaskClient,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: vi.fn(() => ({
      getProjectByPath: mockGetProjectByPath,
      close: vi.fn(),
    })),
  },
}));

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: {
    forProject: mockPostgresStoreForProject,
  },
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockCreateVcsBackend,
  },
}));

vi.mock("../../orchestrator/refinery.js", () => ({
  Refinery: MockRefinery,
}));

vi.mock("../commands/project-task-support.js", () => ({
  listRegisteredProjects: mockListRegisteredProjects,
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
}));

import { prCommand } from "../commands/pr.js";

async function runCommand(args: string[] = []): Promise<void> {
  await prCommand.parseAsync(["node", "foreman", ...args]);
}

describe("pr command registered context", () => {
  let exitCalled = false;

  beforeEach(() => {
    vi.clearAllMocks();
    exitCalled = false;

    mockCreateVcsBackend.mockResolvedValue({
      getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
    });
    mockCreateTaskClient.mockResolvedValue({ taskClient: { kind: "task-client" } });
    mockListRegisteredProjects.mockResolvedValue([]);
    mockResolveRepoRootProjectPath.mockResolvedValue("/mock/project");
    mockPostgresStoreForProject.mockReturnValue({ kind: "run-lookup" });
    mockGetProjectByPath.mockReturnValue({ id: "proj-local", path: "/mock/project" });
    mockCreatePRs.mockResolvedValue({ created: [], failed: [] });
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      exitCalled = true;
      return code as never;
    }) as typeof process.exit);
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("resolves registered pr bootstrap to the canonical project path before lookup", async () => {
    mockResolveRepoRootProjectPath.mockResolvedValue("/canonical/project");
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "my-project", path: "/canonical/project" }]);
    mockGetProjectByPath.mockReturnValue(null);

    await runCommand();

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockCreateVcsBackend).toHaveBeenCalledWith({ backend: "auto" }, "/canonical/project");
    expect(mockCreateTaskClient).toHaveBeenCalledWith("/canonical/project", {
      registeredProjectId: "proj-1",
    });
    expect(mockPostgresStoreForProject).toHaveBeenCalledWith("proj-1");
    expect(MockRefinery).toHaveBeenCalledWith(
      expect.any(Object),
      expect.any(Object),
      "/canonical/project",
      expect.any(Object),
      { registeredProjectId: "proj-1", runLookup: { kind: "run-lookup" } },
    );
    expect(mockCreatePRs).toHaveBeenCalledWith({
      baseBranch: "main",
      draft: undefined,
      projectId: "proj-1",
    });
    expect(exitCalled).toBe(false);
  });

  it("keeps local/unregistered behavior unchanged", async () => {
    await runCommand(["--draft"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockCreateVcsBackend).toHaveBeenCalledWith({ backend: "auto" }, "/mock/project");
    expect(mockCreateTaskClient).toHaveBeenCalledWith("/mock/project", {
      registeredProjectId: undefined,
    });
    expect(mockPostgresStoreForProject).not.toHaveBeenCalled();
    expect(MockRefinery).toHaveBeenCalledWith(
      expect.any(Object),
      expect.any(Object),
      "/mock/project",
      expect.any(Object),
    );
    expect(mockCreatePRs).toHaveBeenCalledWith({
      baseBranch: "main",
      draft: true,
      projectId: "proj-local",
    });
    expect(exitCalled).toBe(false);
  });

  it("keeps outside-a-repo behavior unchanged", async () => {
    mockResolveRepoRootProjectPath.mockRejectedValue(new Error("not a repo"));

    await runCommand();

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockCreateVcsBackend).not.toHaveBeenCalled();
    expect(mockCreateTaskClient).not.toHaveBeenCalled();
    expect(mockPostgresStoreForProject).not.toHaveBeenCalled();
    expect(exitCalled).toBe(true);
  });
});
