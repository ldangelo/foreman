import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

const {
  mockEnsureBrInstalled,
  MockBeadsRustClient,
  MockBvClient,
  mockHasNativeTasks,
  mockPostgresHasNativeTasks,
  mockRegistryList,
  MockForemanStore,
  MockPostgresAdapter,
  MockProjectRegistry,
} = vi.hoisted(() => {
  const mockEnsureBrInstalled = vi.fn().mockResolvedValue(undefined);
  const MockBeadsRustClient = vi.fn(function (this: Record<string, unknown>) {
    this.ensureBrInstalled = mockEnsureBrInstalled;
  });
  const MockBvClient = vi.fn(function () { /* noop */ });
  const mockHasNativeTasks = vi.fn().mockReturnValue(true);
  const mockPostgresHasNativeTasks = vi.fn().mockResolvedValue(true);
  const mockRegistryList = vi.fn().mockResolvedValue([]);
  const MockForemanStore = vi.fn(function (this: Record<string, unknown>) {
    this.hasNativeTasks = mockHasNativeTasks;
    this.close = vi.fn();
  });
  (MockForemanStore as any).forProject = vi.fn(
    (...args: unknown[]) => new (MockForemanStore as any)(...args),
  );

  const MockPostgresAdapter = vi.fn(function (this: Record<string, unknown>) {
    this.hasNativeTasks = mockPostgresHasNativeTasks;
  });

  const MockProjectRegistry = vi.fn(function (this: Record<string, unknown>) {
    this.list = mockRegistryList;
  });

  return {
    mockEnsureBrInstalled,
    MockBeadsRustClient,
    MockBvClient,
    mockHasNativeTasks,
    mockPostgresHasNativeTasks,
    mockRegistryList,
    MockForemanStore,
    MockPostgresAdapter,
    MockProjectRegistry,
  };
});

vi.mock("../../lib/beads-rust.js", () => ({ BeadsRustClient: MockBeadsRustClient }));
vi.mock("../../lib/bv.js", () => ({ BvClient: MockBvClient }));
vi.mock("../../lib/store.js", () => ({ ForemanStore: MockForemanStore }));
vi.mock("../../lib/db/postgres-adapter.js", () => ({ PostgresAdapter: MockPostgresAdapter }));
vi.mock("../../lib/project-registry.js", () => ({ ProjectRegistry: MockProjectRegistry }));
vi.mock("../../lib/project-mail-client.js", () => ({
  resolveProjectDatabaseUrl: vi.fn().mockReturnValue("postgresql://foreman.test/foreman"),
}));
vi.mock("../../lib/db/pool-manager.js", () => ({
  initPool: vi.fn(),
  isPoolInitialised: vi.fn().mockReturnValue(true),
}));

import { createTaskClient } from "../../lib/task-client-factory.js";
import { createTaskClients, resolveRuntimeMode } from "../commands/run.js";

describe("run runtime mode", () => {
  const projectPath = "/mock/project";

  beforeEach(() => {
    vi.clearAllMocks();
    mockEnsureBrInstalled.mockResolvedValue(undefined);
    mockHasNativeTasks.mockReturnValue(true);
    mockPostgresHasNativeTasks.mockResolvedValue(true);
    mockRegistryList.mockResolvedValue([]);
    MockBeadsRustClient.mockImplementation(function (this: Record<string, unknown>) {
      this.ensureBrInstalled = mockEnsureBrInstalled;
    });
    MockBvClient.mockImplementation(function () { /* noop */ });
    MockForemanStore.mockImplementation(function (this: Record<string, unknown>) {
      this.hasNativeTasks = mockHasNativeTasks;
      this.close = vi.fn();
    });
    (MockForemanStore as any).forProject = vi.fn(
      (...args: unknown[]) => new (MockForemanStore as any)(...args),
    );
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("resolves runtime mode from explicit values or env", () => {
    expect(resolveRuntimeMode("test")).toBe("test");
    expect(resolveRuntimeMode("normal")).toBe("normal");
    vi.stubEnv("FOREMAN_RUNTIME_MODE", "test");
    expect(resolveRuntimeMode()).toBe("test");
  });

  it("forces the beads backend in test runtime even when task store is native", async () => {
    mockHasNativeTasks.mockReturnValue(false);
    mockRegistryList.mockResolvedValue([{ id: "proj-1", name: "foreman", path: projectPath }]);

    vi.stubEnv("FOREMAN_TASK_STORE", "native");
    const result = await createTaskClients(projectPath, "test", "proj-1");

    expect(result.backendType).toBe("beads");
    expect(result.bvClient).not.toBeNull();
    expect(MockBeadsRustClient).toHaveBeenCalledWith(projectPath);
    expect(result.taskClient).toBeDefined();
    expect(mockPostgresHasNativeTasks).not.toHaveBeenCalled();
  });

  it("preserves the legacy autoSelectNativeWhenAvailable alias", async () => {
    vi.stubEnv("FOREMAN_TASK_STORE", "auto");

    const result = await createTaskClient(projectPath, {
      autoSelectNativeWhenAvailable: true,
    });

    expect(result.backendType).toBe("beads");
    expect(MockBeadsRustClient).toHaveBeenCalledWith(projectPath);
  });

  it("falls back to br in normal runtime", async () => {
    // Stub TASK_STORE to 'beads' so auto-detect is bypassed
    vi.stubEnv("FOREMAN_TASK_STORE", "beads");
    const result = await createTaskClients(projectPath, "normal");

    expect(result.backendType).toBe("beads");
    expect(MockBeadsRustClient).toHaveBeenCalledWith(projectPath);
    expect(mockEnsureBrInstalled).toHaveBeenCalledTimes(1);
    expect(MockBvClient).toHaveBeenCalledWith(projectPath);
    expect(result.bvClient).not.toBeNull();
  });
});
