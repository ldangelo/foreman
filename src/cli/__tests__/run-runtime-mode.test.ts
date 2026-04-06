import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import Database from "better-sqlite3";

const {
  mockEnsureBrInstalled,
  MockBeadsRustClient,
  MockBvClient,
} = vi.hoisted(() => {
  const mockEnsureBrInstalled = vi.fn().mockResolvedValue(undefined);
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.ensureBrInstalled = mockEnsureBrInstalled;
  });
  const MockBvClient = vi.fn(function MockBvClientImpl() { /* noop */ });
  return { mockEnsureBrInstalled, MockBeadsRustClient, MockBvClient };
});

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../../lib/bv.js", () => ({
  BvClient: MockBvClient,
}));

import { createTaskClients, resolveRunRuntimeMode } from "../commands/run.js";

describe("run runtime mode", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.ensureBrInstalled = mockEnsureBrInstalled;
    });
    MockBvClient.mockImplementation(function MockBvClientImpl() { /* noop */ });
    mockEnsureBrInstalled.mockResolvedValue(undefined);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("resolves runtime mode from CLI value or env", () => {
    expect(resolveRunRuntimeMode("test")).toBe("test");
    expect(resolveRunRuntimeMode(undefined, { FOREMAN_RUNTIME_MODE: "test" } as NodeJS.ProcessEnv)).toBe("test");
    expect(resolveRunRuntimeMode(undefined, {} as NodeJS.ProcessEnv)).toBe("default");
  });

  it("throws on invalid runtime mode", () => {
    expect(() => resolveRunRuntimeMode("weird")).toThrow(/Invalid runtime mode/);
  });

  it("uses NativeTaskClient in test runtime when native tasks exist", async () => {
    const db = new Database(":memory:");
    db.exec(`
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT,
        type TEXT NOT NULL DEFAULT 'task',
        priority INTEGER NOT NULL DEFAULT 2,
        status TEXT NOT NULL DEFAULT 'backlog',
        run_id TEXT DEFAULT NULL,
        branch TEXT DEFAULT NULL,
        external_id TEXT DEFAULT NULL,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        approved_at TEXT DEFAULT NULL,
        closed_at TEXT DEFAULT NULL
      );
    `);
    db.prepare("INSERT INTO tasks (id, title, type, priority, status) VALUES ('task-1', 'native', 'task', 2, 'ready')").run();
    const store = {
      hasNativeTasks: () => true,
      getDb: () => db,
    };

    const result = await createTaskClients("/mock/project", {
      runtimeMode: "test",
      store,
    });

    expect(MockBeadsRustClient).not.toHaveBeenCalled();
    expect(MockBvClient).not.toHaveBeenCalled();
    expect(await result.taskClient.ready()).toEqual([
      expect.objectContaining({ id: "task-1", title: "native", status: "ready" }),
    ]);

    db.close();
  });

  it("falls back to beads_rust in default runtime", async () => {
    const result = await createTaskClients("/mock/project", {
      runtimeMode: "default",
    });

    expect(MockBeadsRustClient).toHaveBeenCalledWith("/mock/project");
    expect(mockEnsureBrInstalled).toHaveBeenCalledTimes(1);
    expect(MockBvClient).toHaveBeenCalledWith("/mock/project");
    expect(result.bvClient).not.toBeNull();
  });
});
