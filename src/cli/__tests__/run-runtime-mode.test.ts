/**
 * Tests for runtime mode resolution.
 *
 * Verifies:
 * - resolveRuntimeMode correctly resolves explicit values and env var
 * - createTaskClients always uses native backend (beads fallback removed)
 *
 * Note: The FOREMAN_TASK_STORE env var is not read by createTaskClients.
 * The native task store is the only supported backend — this is intentional
 * and verified by the tests below (no env stubs needed).
 */
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
  }) as ReturnType<typeof vi.fn>& { forProject: ReturnType<typeof vi.fn> };
  MockForemanStore.forProject = vi.fn((...args: unknown[]) => new MockForemanStore(...args));

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
    MockForemanStore.forProject = vi.fn((...args: unknown[]) => new MockForemanStore(...args));
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

  it("uses native backend in test runtime", async () => {
    mockHasNativeTasks.mockReturnValue(true);
    mockRegistryList.mockResolvedValue([{ id: "proj-1", name: "foreman", path: projectPath }]);

    const result = await createTaskClients(projectPath, "test", "proj-1");

    expect(result.backendType).toBe("native");
    expect(result.bvClient).toBeNull();
    expect(MockBeadsRustClient).not.toHaveBeenCalled();
    expect(result.taskClient).toBeDefined();
    expect(MockForemanStore.forProject).not.toHaveBeenCalled();
  });

  it("uses native backend in normal runtime", async () => {
    const result = await createTaskClients(projectPath, "normal");

    expect(result.backendType).toBe("native");
    expect(MockBeadsRustClient).not.toHaveBeenCalled();
    expect(mockEnsureBrInstalled).not.toHaveBeenCalled();
    expect(MockBvClient).not.toHaveBeenCalled();
    expect(result.bvClient).toBeNull();
  });
});
