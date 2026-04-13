import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

const {
  mockEnsureBrInstalled,
  MockBeadsRustClient,
  MockBvClient,
  mockHasNativeTasks,
  MockForemanStore,
} = vi.hoisted(() => {
  const mockEnsureBrInstalled = vi.fn().mockResolvedValue(undefined);
  const MockBeadsRustClient = vi.fn(function (this: Record<string, unknown>) {
    this.ensureBrInstalled = mockEnsureBrInstalled;
  });
  const MockBvClient = vi.fn(function () { /* noop */ });
  const mockHasNativeTasks = vi.fn().mockReturnValue(true);
  const MockForemanStore = vi.fn(function (this: Record<string, unknown>) {
    this.hasNativeTasks = mockHasNativeTasks;
    this.close = vi.fn();
  });
  (MockForemanStore as any).forProject = vi.fn(
    (...args: unknown[]) => new (MockForemanStore as any)(...args),
  );

  return {
    mockEnsureBrInstalled,
    MockBeadsRustClient,
    MockBvClient,
    mockHasNativeTasks,
    MockForemanStore,
  };
});

vi.mock("../../lib/beads-rust.js", () => ({ BeadsRustClient: MockBeadsRustClient }));
vi.mock("../../lib/bv.js", () => ({ BvClient: MockBvClient }));
vi.mock("../../lib/store.js", () => ({ ForemanStore: MockForemanStore }));

import { createTaskClients, resolveRuntimeMode } from "../commands/run.js";

describe("run runtime mode", () => {
  const projectPath = "/mock/project";

  beforeEach(() => {
    vi.clearAllMocks();
    mockEnsureBrInstalled.mockResolvedValue(undefined);
    mockHasNativeTasks.mockReturnValue(true);
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

  it("uses the native task client in test runtime when native tasks exist", async () => {
    const result = await createTaskClients(projectPath, "test");

    expect(result.backendType).toBe("native");
    expect(result.bvClient).toBeNull();
    expect(MockBeadsRustClient).not.toHaveBeenCalled();
    expect(result.taskClient.constructor.name).toBe("NativeTaskClient");
  });

  it("falls back to br in normal runtime", async () => {
    const result = await createTaskClients(projectPath, "normal");

    expect(result.backendType).toBe("beads");
    expect(MockBeadsRustClient).toHaveBeenCalledWith(projectPath);
    expect(mockEnsureBrInstalled).toHaveBeenCalledTimes(1);
    expect(MockBvClient).toHaveBeenCalledWith(projectPath);
    expect(result.bvClient).not.toBeNull();
  });
});

