import { beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockRegistryList,
  MockNativeTaskClient,
  MockProjectRegistry,
  MockForemanStore,
  mockResolveProjectDatabaseUrl,
} = vi.hoisted(() => {
  const mockRegistryList = vi.fn().mockResolvedValue([]);

  const MockNativeTaskClient = vi.fn(function MockNativeTaskClientImpl(this: Record<string, unknown>) {
    this.kind = "native";
  });
  const MockProjectRegistry = vi.fn(function MockProjectRegistryImpl(this: Record<string, unknown>) {
    this.list = mockRegistryList;
  });

  const MockForemanStore = {
    forProject: vi.fn().mockReturnValue({ close: vi.fn() }),
  };

  const mockResolveProjectDatabaseUrl = vi.fn().mockReturnValue("postgresql://foreman.test/foreman");

  return {
    mockRegistryList,
    MockNativeTaskClient,
    MockProjectRegistry,
    MockForemanStore,
    mockResolveProjectDatabaseUrl,
  };
});

vi.mock("../native-task-client.js", () => ({
  NativeTaskClient: MockNativeTaskClient,
}));

vi.mock("../project-registry.js", () => ({
  ProjectRegistry: MockProjectRegistry,
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
    mockResolveProjectDatabaseUrl.mockReturnValue("postgresql://foreman.test/foreman");
    MockForemanStore.forProject.mockReturnValue({ close: vi.fn() });
  });

  it("selects native for exact-path registered projects", async () => {
    mockRegistryList.mockResolvedValue([{ id: "proj-1", name: "foreman", path: projectPath }]);

    const result = await createTaskClient(projectPath);

    expect(result.backendType).toBe("native");
    expect(MockNativeTaskClient).toHaveBeenCalledWith(projectPath, { registeredProjectId: "proj-1" });
    expect(MockForemanStore.forProject).not.toHaveBeenCalled();
  });

  it("keeps registered native selection pinned by project id even when the path no longer matches", async () => {
    mockRegistryList.mockResolvedValue([{ id: "proj-1", name: "foreman", path: "/elsewhere/project" }]);

    const result = await createTaskClient(projectPath, { registeredProjectId: "proj-1" });

    expect(result.backendType).toBe("native");
    expect(MockNativeTaskClient).toHaveBeenCalledWith(projectPath, { registeredProjectId: "proj-1" });
    expect(MockForemanStore.forProject).not.toHaveBeenCalled();
  });

  it("keeps local unregistered native selection unchanged", async () => {
    mockRegistryList.mockResolvedValue([]);

    const result = await createTaskClient(projectPath);

    expect(result.backendType).toBe("native");
    expect(MockNativeTaskClient).toHaveBeenCalledWith(projectPath, { registeredProjectId: undefined });
    expect(MockForemanStore.forProject).not.toHaveBeenCalled();
  });
});