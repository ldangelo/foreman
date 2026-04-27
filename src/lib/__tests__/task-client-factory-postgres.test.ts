import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockRegistryList,
  mockPgHasNativeTasks,
  mockLocalHasNativeTasks,
  mockEnsureBrInstalled,
  MockNativeTaskClient,
  MockBeadsRustClient,
  MockProjectRegistry,
  MockPostgresAdapter,
  MockForemanStore,
  mockResolveProjectDatabaseUrl,
} = vi.hoisted(() => {
  const mockRegistryList = vi.fn().mockResolvedValue([]);
  const mockPgHasNativeTasks = vi.fn().mockResolvedValue(false);
  const mockLocalHasNativeTasks = vi.fn().mockReturnValue(false);
  const mockEnsureBrInstalled = vi.fn().mockResolvedValue(undefined);

  const MockNativeTaskClient = vi.fn(function MockNativeTaskClientImpl(this: Record<string, unknown>) {
    this.kind = "native";
  });
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.kind = "beads";
    this.ensureBrInstalled = mockEnsureBrInstalled;
  });
  const MockProjectRegistry = vi.fn(function MockProjectRegistryImpl(this: Record<string, unknown>) {
    this.list = mockRegistryList;
  });
  const MockPostgresAdapter = vi.fn(function MockPostgresAdapterImpl(this: Record<string, unknown>) {
    this.hasNativeTasks = mockPgHasNativeTasks;
  });

  const localStore = {
    close: vi.fn(),
    hasNativeTasks: mockLocalHasNativeTasks,
  };
  const MockForemanStore = {
    forProject: vi.fn().mockReturnValue(localStore),
  };

  const mockResolveProjectDatabaseUrl = vi.fn().mockReturnValue("postgresql://foreman.test/foreman");

  return {
    mockRegistryList,
    mockPgHasNativeTasks,
    mockLocalHasNativeTasks,
    mockEnsureBrInstalled,
    MockNativeTaskClient,
    MockBeadsRustClient,
    MockProjectRegistry,
    MockPostgresAdapter,
    MockForemanStore,
    mockResolveProjectDatabaseUrl,
  };
});

vi.mock("../native-task-client.js", () => ({
  NativeTaskClient: MockNativeTaskClient,
}));

vi.mock("../beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../project-registry.js", () => ({
  ProjectRegistry: MockProjectRegistry,
}));

vi.mock("../db/postgres-adapter.js", () => ({
  PostgresAdapter: MockPostgresAdapter,
}));

vi.mock("../store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../project-mail-client.js", () => ({
  resolveProjectDatabaseUrl: mockResolveProjectDatabaseUrl,
}));

vi.mock("../db/pool-manager.js", () => ({
  initPool: vi.fn(),
  isPoolInitialised: vi.fn().mockReturnValue(true),
}));

import { createTaskClient } from "../task-client-factory.js";

describe("task-client-factory Postgres native selection", () => {
  const projectPath = "/mock/project";

  beforeEach(() => {
    vi.clearAllMocks();
    mockRegistryList.mockResolvedValue([]);
    mockPgHasNativeTasks.mockResolvedValue(false);
    mockLocalHasNativeTasks.mockReturnValue(false);
    mockEnsureBrInstalled.mockResolvedValue(undefined);
    mockResolveProjectDatabaseUrl.mockReturnValue("postgresql://foreman.test/foreman");
    MockForemanStore.forProject.mockReturnValue({
      close: vi.fn(),
      hasNativeTasks: mockLocalHasNativeTasks,
    });
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("selects native from Postgres for exact-path registered projects in auto mode", async () => {
    vi.stubEnv("FOREMAN_TASK_STORE", "auto");
    mockRegistryList.mockResolvedValue([{ id: "proj-1", name: "foreman", path: projectPath }]);
    mockPgHasNativeTasks.mockResolvedValue(true);
    mockLocalHasNativeTasks.mockReturnValue(false);

    const result = await createTaskClient(projectPath);

    expect(result.backendType).toBe("native");
    expect(MockNativeTaskClient).toHaveBeenCalledWith(projectPath, { registeredProjectId: "proj-1" });
    expect(mockPgHasNativeTasks).toHaveBeenCalledWith("proj-1");
    expect(MockForemanStore.forProject).not.toHaveBeenCalled();
  });

  it("keeps registered native selection pinned by project id even when the path no longer matches", async () => {
    vi.stubEnv("FOREMAN_TASK_STORE", "native");
    mockRegistryList.mockResolvedValue([{ id: "proj-1", name: "foreman", path: "/elsewhere/project" }]);

    const result = await createTaskClient(projectPath, { registeredProjectId: "proj-1" });

    expect(result.backendType).toBe("native");
    expect(MockNativeTaskClient).toHaveBeenCalledWith(projectPath, { registeredProjectId: "proj-1" });
    expect(mockPgHasNativeTasks).not.toHaveBeenCalled();
    expect(MockForemanStore.forProject).not.toHaveBeenCalled();
  });

  it("keeps local unregistered native selection unchanged", async () => {
    vi.stubEnv("FOREMAN_TASK_STORE", "auto");
    mockRegistryList.mockResolvedValue([]);
    mockLocalHasNativeTasks.mockReturnValue(true);

    const result = await createTaskClient(projectPath);

    expect(result.backendType).toBe("native");
    expect(MockNativeTaskClient).toHaveBeenCalledWith(projectPath, { registeredProjectId: undefined });
    expect(MockForemanStore.forProject).toHaveBeenCalledWith(projectPath);
    expect(mockPgHasNativeTasks).not.toHaveBeenCalled();
  });
});
