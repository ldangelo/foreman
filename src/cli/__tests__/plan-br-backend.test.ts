import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockSelectTaskReadBackend,
  MockBeadsRustClient,
  mockForemanStoreForProject,
  MockNativeTaskStore,
  mockTaskStoreCreate,
  mockTaskStoreApprove,
  mockTaskStoreAddDependency,
  mockTaskStoreUpdate,
  mockTaskStoreGet,
  mockTaskStoreReady,
  mockTaskStoreReevaluateBlockedTasks,
  mockStoreClose,
  mockStoreGetDb,
} = vi.hoisted(() => {
  const mockSelectTaskReadBackend = vi.fn();

  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.create = vi.fn();
    this.addDependency = vi.fn();
    this.ready = vi.fn();
    this.close = vi.fn();
    this.list = vi.fn();
    this.show = vi.fn();
    this.update = vi.fn();
  });

  const mockTaskStoreCreate = vi.fn();
  const mockTaskStoreApprove = vi.fn();
  const mockTaskStoreAddDependency = vi.fn();
  const mockTaskStoreUpdate = vi.fn();
  const mockTaskStoreGet = vi.fn();
  const mockTaskStoreReady = vi.fn();
  const mockTaskStoreReevaluateBlockedTasks = vi.fn();

  const MockNativeTaskStore = vi.fn(function MockNativeTaskStoreImpl(this: Record<string, unknown>) {
    this.create = mockTaskStoreCreate;
    this.approve = mockTaskStoreApprove;
    this.addDependency = mockTaskStoreAddDependency;
    this.update = mockTaskStoreUpdate;
    this.get = mockTaskStoreGet;
    this.ready = mockTaskStoreReady;
    this.reevaluateBlockedTasks = mockTaskStoreReevaluateBlockedTasks;
    this.list = vi.fn().mockReturnValue([]);
    this.close = vi.fn();
  });

  const mockStoreClose = vi.fn();
  const mockStoreGetDb = vi.fn().mockReturnValue({});
  const mockForemanStoreForProject = vi.fn().mockReturnValue({
    getDb: mockStoreGetDb,
    close: mockStoreClose,
  });

  return {
    mockSelectTaskReadBackend,
    MockBeadsRustClient,
    mockForemanStoreForProject,
    MockNativeTaskStore,
    mockTaskStoreCreate,
    mockTaskStoreApprove,
    mockTaskStoreAddDependency,
    mockTaskStoreUpdate,
    mockTaskStoreGet,
    mockTaskStoreReady,
    mockTaskStoreReevaluateBlockedTasks,
    mockStoreClose,
    mockStoreGetDb,
  };
});

vi.mock("../../lib/task-client-factory.js", () => ({
  selectTaskReadBackend: mockSelectTaskReadBackend,
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: mockForemanStoreForProject,
  },
}));

vi.mock("../../lib/task-store.js", () => ({
  NativeTaskStore: MockNativeTaskStore,
}));

import { createPlanClient, inferPrdHintPath } from "../commands/plan.js";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PROJECT_PATH = "/mock/project";

describe("createPlanClient", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockSelectTaskReadBackend.mockReturnValue("beads");

    mockForemanStoreForProject.mockReturnValue({
      getDb: mockStoreGetDb,
      close: mockStoreClose,
    });

    mockTaskStoreCreate.mockReturnValue({
      id: "native-001",
      title: "Plan epic",
      type: "epic",
      priority: 1,
      status: "backlog",
      run_id: null,
      branch: null,
      external_id: null,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
      approved_at: null,
      closed_at: null,
      description: "desc",
    });
    mockTaskStoreGet.mockReturnValue({
      id: "native-001",
      title: "Plan epic",
      type: "epic",
      priority: 1,
      status: "ready",
      run_id: null,
      branch: null,
      external_id: null,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
      approved_at: "2026-01-01T00:00:00Z",
      closed_at: null,
      description: "desc",
    });
    mockTaskStoreReady.mockResolvedValue([]);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("uses the beads client when the shared helper selects beads", () => {
    mockSelectTaskReadBackend.mockReturnValue("beads");

    const client = createPlanClient(PROJECT_PATH);

    expect(mockSelectTaskReadBackend).toHaveBeenCalledWith(PROJECT_PATH);
    expect(client).toBeDefined();
  });

  it("instantiates the beads client lazily when a delegated method is used", async () => {
    mockSelectTaskReadBackend.mockReturnValue("beads");
    const beadsReady = vi.fn().mockResolvedValue([]);
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.create = vi.fn();
      this.addDependency = vi.fn();
      this.ready = beadsReady;
      this.close = vi.fn();
      this.list = vi.fn();
      this.show = vi.fn();
      this.update = vi.fn();
    });

    const client = createPlanClient(PROJECT_PATH);
    await client.ready();

    expect(MockBeadsRustClient).toHaveBeenCalledWith(PROJECT_PATH);
    expect(beadsReady).toHaveBeenCalledOnce();
  });

  it("returns a native-backed planning client when the shared helper selects native", async () => {
    mockSelectTaskReadBackend.mockReturnValue("native");

    const client = createPlanClient(PROJECT_PATH);
    const created = await client.create("Plan epic", {
      type: "epic",
      priority: "P1",
      parent: "parent-123",
      description: "desc",
    });

    expect(MockBeadsRustClient).not.toHaveBeenCalled();
    expect(mockForemanStoreForProject).toHaveBeenCalledWith(PROJECT_PATH);
    expect(MockNativeTaskStore).toHaveBeenCalled();
    expect(mockTaskStoreCreate).toHaveBeenCalledWith({
      title: "Plan epic",
      description: "desc",
      type: "epic",
      priority: 1,
    });
    expect(mockTaskStoreApprove).toHaveBeenCalledWith("native-001");
    expect(mockTaskStoreAddDependency).toHaveBeenCalledWith(
      "native-001",
      "parent-123",
      "parent-child",
    );
    expect(created.id).toBe("native-001");
    expect(created.priority).toBe("P1");
  });

  it("marks dependents blocked on native backends until their blocker closes", async () => {
    mockSelectTaskReadBackend.mockReturnValue("native");
    mockTaskStoreGet.mockImplementation((id: string) =>
      id === "blocker-1"
        ? {
            id,
            title: "Blocker",
            type: "task",
            priority: 1,
            status: "ready",
            run_id: null,
            branch: null,
            external_id: null,
            created_at: "2026-01-01T00:00:00Z",
            updated_at: "2026-01-01T00:00:00Z",
            approved_at: null,
            closed_at: null,
            description: null,
          }
        : null,
    );

    const client = createPlanClient(PROJECT_PATH);
    await client.addDependency("child-1", "blocker-1");

    expect(mockTaskStoreAddDependency).toHaveBeenCalledWith("child-1", "blocker-1", "blocks");
    expect(mockTaskStoreUpdate).toHaveBeenCalledWith("child-1", {
      status: "blocked",
      force: true,
    });
    expect(mockTaskStoreReevaluateBlockedTasks).not.toHaveBeenCalled();
  });

  it("re-evaluates blocked tasks when a native planning task closes", async () => {
    mockSelectTaskReadBackend.mockReturnValue("native");
    const client = createPlanClient(PROJECT_PATH);

    await client.close("native-001", "Completed");

    expect(MockNativeTaskStore).toHaveBeenCalled();
    expect(mockTaskStoreReevaluateBlockedTasks).toHaveBeenCalled();
    expect(mockStoreClose).toHaveBeenCalled();
  });
});

describe("inferPrdHintPath", () => {
  it("prefers an explicit --from-prd path", () => {
    expect(inferPrdHintPath("/tmp/out", "/tmp/custom/PRD.md")).toBe("/tmp/custom/PRD.md");
  });

  it("falls back to the latest PRD markdown file in the output directory", () => {
    const dir = mkdtempSync(join(tmpdir(), "foreman-plan-hint-"));
    try {
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "PRD-2026-001-old.md"), "# old");
      writeFileSync(join(dir, "PRD-2026-002-new.md"), "# new");

      expect(inferPrdHintPath(dir)).toBe(join(dir, "PRD-2026-002-new.md"));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
