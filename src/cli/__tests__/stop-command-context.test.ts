import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockResolveRepoRootProjectPath,
  mockFindRegisteredProjectByPath,
  mockForemanStoreForProject,
  mockPostgresStoreForProject,
  mockWrapLocalRunStore,
  mockCloseStoreIfPossible,
} = vi.hoisted(() => ({
  mockResolveRepoRootProjectPath: vi.fn(),
  mockFindRegisteredProjectByPath: vi.fn(),
  mockForemanStoreForProject: vi.fn(),
  mockPostgresStoreForProject: vi.fn(),
  mockWrapLocalRunStore: vi.fn(),
  mockCloseStoreIfPossible: vi.fn(),
}));

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: (...args: unknown[]) => mockResolveRepoRootProjectPath(...args),
}));

vi.mock("../commands/project-context.js", () => ({
  findRegisteredProjectByPath: (...args: unknown[]) => mockFindRegisteredProjectByPath(...args),
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: { forProject: (...args: unknown[]) => mockForemanStoreForProject(...args) },
}));

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: { forProject: (...args: unknown[]) => mockPostgresStoreForProject(...args) },
}));

vi.mock("../commands/local-store-adapter.js", () => ({
  wrapLocalRunStore: (...args: unknown[]) => mockWrapLocalRunStore(...args),
  closeStoreIfPossible: (...args: unknown[]) => mockCloseStoreIfPossible(...args),
}));

import { stopCommandAction } from "../commands/stop.js";

describe("stop command context", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("returns 1 outside a git repo for non-list commands and closes local stores", async () => {
    const localStore = { close: vi.fn() };
    const wrappedStore = {
      getProjectByPath: vi.fn(),
      getActiveRuns: vi.fn(),
      getRun: vi.fn(),
      getRunsForSeed: vi.fn(),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
    };
    mockResolveRepoRootProjectPath.mockRejectedValue(new Error("no repo"));
    mockFindRegisteredProjectByPath.mockResolvedValue(null);
    mockForemanStoreForProject.mockReturnValue(localStore);
    mockWrapLocalRunStore.mockReturnValue(wrappedStore);

    const exitCode = await stopCommandAction(undefined, {});

    expect(exitCode).toBe(1);
    expect(mockWrapLocalRunStore).toHaveBeenCalledWith(localStore);
    expect(localStore.close).toHaveBeenCalled();
    expect(mockCloseStoreIfPossible).toHaveBeenCalledWith(wrappedStore);
  });

  it("allows --list outside a git repo using the local wrapped store", async () => {
    const localStore = { close: vi.fn() };
    const wrappedStore = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: process.cwd() }),
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRun: vi.fn(),
      getRunsForSeed: vi.fn(),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
    };
    mockResolveRepoRootProjectPath.mockRejectedValue(new Error("no repo"));
    mockFindRegisteredProjectByPath.mockResolvedValue(null);
    mockForemanStoreForProject.mockReturnValue(localStore);
    mockWrapLocalRunStore.mockReturnValue(wrappedStore);

    const exitCode = await stopCommandAction(undefined, { list: true });

    expect(exitCode).toBe(0);
    expect(wrappedStore.getActiveRuns).toHaveBeenCalled();
    expect(localStore.close).toHaveBeenCalled();
    expect(mockCloseStoreIfPossible).toHaveBeenCalledWith(wrappedStore);
  });

  it("uses the Postgres store for registered projects", async () => {
    const localStore = { close: vi.fn() };
    const postgresStore = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRun: vi.fn().mockResolvedValue(null),
      getRunsForSeed: vi.fn().mockResolvedValue([]),
      updateRun: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
      close: vi.fn(),
    };
    mockResolveRepoRootProjectPath.mockResolvedValue("/repo");
    mockFindRegisteredProjectByPath.mockResolvedValue({ id: "project-1", path: "/repo", name: "Foreman" });
    mockForemanStoreForProject.mockReturnValue(localStore);
    mockPostgresStoreForProject.mockReturnValue(postgresStore);

    const exitCode = await stopCommandAction(undefined, { dryRun: true });

    expect(exitCode).toBe(0);
    expect(mockPostgresStoreForProject).toHaveBeenCalledWith("project-1");
    expect(mockWrapLocalRunStore).not.toHaveBeenCalled();
    expect(localStore.close).toHaveBeenCalled();
    expect(mockCloseStoreIfPossible).toHaveBeenCalledWith(postgresStore);
  });
});
