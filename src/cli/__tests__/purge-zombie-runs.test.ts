import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockCreateTaskClient,
  mockResolveRepoRootProjectPath,
  mockFindRegisteredProjectByPath,
  mockWrapLocalRunStore,
  mockCloseStoreIfPossible,
  mockForemanStoreForProject,
  mockElixirStoreForProject,
} = vi.hoisted(() => ({
  mockCreateTaskClient: vi.fn(),
  mockResolveRepoRootProjectPath: vi.fn(),
  mockFindRegisteredProjectByPath: vi.fn(),
  mockWrapLocalRunStore: vi.fn(),
  mockCloseStoreIfPossible: vi.fn(),
  mockForemanStoreForProject: vi.fn(),
  mockElixirStoreForProject: vi.fn(),
}));

vi.mock("../../lib/task-client-factory.js", () => ({
  createTaskClient: (...args: unknown[]) => mockCreateTaskClient(...args),
}));

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: (...args: unknown[]) => mockResolveRepoRootProjectPath(...args),
}));

vi.mock("../commands/project-context.js", () => ({
  findRegisteredProjectByPath: (...args: unknown[]) => mockFindRegisteredProjectByPath(...args),
}));

vi.mock("../commands/local-store-adapter.js", () => ({
  wrapLocalRunStore: (...args: unknown[]) => mockWrapLocalRunStore(...args),
  closeStoreIfPossible: (...args: unknown[]) => mockCloseStoreIfPossible(...args),
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: (...args: unknown[]) => mockForemanStoreForProject(...args),
  },
}));

vi.mock("../commands/elixir-cli-store.js", () => ({
  ElixirCliStore: {
    forProject: (...args: unknown[]) => mockElixirStoreForProject(...args),
  },
}));

import { purgeZombieRunsAction, purgeZombieRunsCommandAction } from "../commands/purge-zombie-runs.js";

describe("purgeZombieRunsAction", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("fails when the project is not registered", async () => {
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue(null),
      getRunsByStatus: vi.fn(),
      deleteRun: vi.fn(),
    };

    await expect(purgeZombieRunsAction({}, { show: vi.fn() }, store, "/repo/project")).rejects.toThrow(
      "No project registered for this path. Run 'foreman init' first.",
    );
  });

  it("returns early when there are no failed runs", async () => {
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "proj-1", path: "/repo/project" }),
      getRunsByStatus: vi.fn().mockResolvedValue([]),
      deleteRun: vi.fn(),
    };

    const result = await purgeZombieRunsAction({}, { show: vi.fn() }, store, "/repo/project");

    expect(result).toEqual({ checked: 0, purged: 0, skipped: 0, errors: 0 });
    expect(store.getRunsByStatus).toHaveBeenCalledWith("failed", "proj-1");
  });

  it("dry-runs closed or missing tasks without deleting rows", async () => {
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "proj-1", path: "/repo/project" }),
      getRunsByStatus: vi.fn().mockResolvedValue([
        { id: "run-1", task_id: "bd-1", status: "failed" },
        { id: "run-2", task_id: "bd-2", status: "failed" },
      ]),
      deleteRun: vi.fn(),
    };
    const show = vi.fn()
      .mockResolvedValueOnce({ status: "closed" })
      .mockRejectedValueOnce(new Error("404 not found"));

    const result = await purgeZombieRunsAction({ dryRun: true }, { show }, store, "/repo/project");

    expect(result).toEqual({ checked: 2, purged: 2, skipped: 0, errors: 0 });
    expect(store.deleteRun).not.toHaveBeenCalled();
  });

  it("skips open tasks and counts unexpected lookup failures as errors", async () => {
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "proj-1", path: "/repo/project" }),
      getRunsByStatus: vi.fn().mockResolvedValue([
        { id: "run-1", task_id: "bd-open", status: "failed" },
        { id: "run-2", task_id: "bd-error", status: "failed" },
      ]),
      deleteRun: vi.fn(),
    };
    const show = vi.fn()
      .mockResolvedValueOnce({ status: "open" })
      .mockRejectedValueOnce(new Error("network timeout"));

    const result = await purgeZombieRunsAction({}, { show }, store, "/repo/project");

    expect(result).toEqual({ checked: 2, purged: 0, skipped: 1, errors: 1 });
    expect(store.deleteRun).not.toHaveBeenCalled();
    expect(vi.mocked(console.warn).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("network timeout");
  });

  it("deletes zombie runs during a live purge", async () => {
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "proj-1", path: "/repo/project" }),
      getRunsByStatus: vi.fn().mockResolvedValue([
        { id: "run-1", task_id: "bd-1", status: "failed" },
      ]),
      deleteRun: vi.fn().mockResolvedValue(true),
    };
    const show = vi.fn().mockResolvedValue({ status: "completed" });

    const result = await purgeZombieRunsAction({}, { show }, store, "/repo/project");

    expect(result).toEqual({ checked: 1, purged: 1, skipped: 0, errors: 0 });
    expect(store.deleteRun).toHaveBeenCalledWith("run-1");
  });
});

describe("purgeZombieRunsCommandAction", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const localStore = { close: vi.fn() };
    mockForemanStoreForProject.mockReturnValue(localStore);
    mockWrapLocalRunStore.mockReturnValue({
      getProjectByPath: vi.fn(),
      getRunsByStatus: vi.fn(),
      deleteRun: vi.fn(),
    });
    mockCreateTaskClient.mockResolvedValue({ taskClient: { show: vi.fn() } });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("returns 1 when not run inside a git repository", async () => {
    mockResolveRepoRootProjectPath.mockRejectedValue(new Error("not git"));

    await expect(purgeZombieRunsCommandAction({})).resolves.toBe(1);

    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("Not in a git repository");
  });

  it("uses the Elixir store for registered projects and returns 0 on clean success", async () => {
    const localStore = { close: vi.fn() };
    const elixirStore = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "proj-1", path: "/repo/project" }),
      getRunsByStatus: vi.fn().mockResolvedValue([]),
      deleteRun: vi.fn(),
      close: vi.fn(),
    };
    mockResolveRepoRootProjectPath.mockResolvedValue("/repo/project");
    mockForemanStoreForProject.mockReturnValue(localStore);
    mockFindRegisteredProjectByPath.mockResolvedValue({ id: "proj-1", path: "/repo/project" });
    mockElixirStoreForProject.mockReturnValue(elixirStore);
    mockCreateTaskClient.mockResolvedValue({ taskClient: { show: vi.fn() } });

    await expect(purgeZombieRunsCommandAction({})).resolves.toBe(0);

    expect(mockElixirStoreForProject).toHaveBeenCalledWith({ id: "proj-1", path: "/repo/project" });
    expect(localStore.close).toHaveBeenCalledOnce();
    expect(mockCloseStoreIfPossible).toHaveBeenCalledWith(elixirStore);
  });

  it("returns 1 when purgeZombieRunsAction throws", async () => {
    const localStore = { close: vi.fn() };
    const wrappedStore = {
      getProjectByPath: vi.fn().mockResolvedValue(null),
      getRunsByStatus: vi.fn(),
      deleteRun: vi.fn(),
    };
    mockResolveRepoRootProjectPath.mockResolvedValue("/repo/project");
    mockForemanStoreForProject.mockReturnValue(localStore);
    mockFindRegisteredProjectByPath.mockResolvedValue(null);
    mockWrapLocalRunStore.mockReturnValue(wrappedStore);
    mockCreateTaskClient.mockResolvedValue({ taskClient: { show: vi.fn() } });

    await expect(purgeZombieRunsCommandAction({})).resolves.toBe(1);

    expect(localStore.close).toHaveBeenCalledOnce();
    expect(mockCloseStoreIfPossible).toHaveBeenCalledWith(wrappedStore);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("No project registered for this path");
  });
});
