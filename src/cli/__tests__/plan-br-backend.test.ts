import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockSelectTaskReadBackend,
  MockBeadsRustClient,
  mockListRegisteredProjects,
  mockTaskList,
  mockTaskCreate,
  mockTaskApprove,
  mockTaskAddDependency,
  mockTaskUpdate,
  mockTaskGet,
  mockTaskClose,
  mockForemanBackendMode,
  mockEnsureRunning,
  mockSendCommand,
  mockElixirListTasks,
  mockElixirGetTask,
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

  const mockListRegisteredProjects = vi.fn();
  const mockTaskList = vi.fn();
  const mockTaskCreate = vi.fn();
  const mockTaskApprove = vi.fn();
  const mockTaskAddDependency = vi.fn();
  const mockTaskUpdate = vi.fn();
  const mockTaskGet = vi.fn();
  const mockTaskClose = vi.fn();
  const mockForemanBackendMode = vi.fn();
  const mockEnsureRunning = vi.fn();
  const mockSendCommand = vi.fn();
  const mockElixirListTasks = vi.fn();
  const mockElixirGetTask = vi.fn();

  return {
    mockSelectTaskReadBackend,
    MockBeadsRustClient,
    mockListRegisteredProjects,
    mockTaskList,
    mockTaskCreate,
    mockTaskApprove,
    mockTaskAddDependency,
    mockTaskUpdate,
    mockTaskGet,
    mockTaskClose,
    mockForemanBackendMode,
    mockEnsureRunning,
    mockSendCommand,
    mockElixirListTasks,
    mockElixirGetTask,
  };
});

vi.mock("../../lib/task-client-factory.js", () => ({
  selectTaskReadBackend: mockSelectTaskReadBackend,
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../commands/project-task-support.js", () => ({
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: () => ({
    tasks: {
      list: mockTaskList,
      create: mockTaskCreate,
      approve: mockTaskApprove,
      addDependency: mockTaskAddDependency,
      update: mockTaskUpdate,
      get: mockTaskGet,
      close: mockTaskClose,
    },
  }),
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: mockForemanBackendMode,
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return { ensureRunning: mockEnsureRunning };
  }),
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn().mockImplementation(function MockElixirServerClient() {
    return {
      listTasks: mockElixirListTasks,
      getTask: mockElixirGetTask,
      sendCommand: mockSendCommand,
    };
  }),
}));

import { createPlanClient, inferPrdHintPath, readPlanningInput } from "../commands/plan.js";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PROJECT_PATH = "/mock/project";

describe("createPlanClient", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockSelectTaskReadBackend.mockReturnValue("beads");
    mockForemanBackendMode.mockReturnValue("node");
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766" });
    mockSendCommand.mockResolvedValue({ ok: true, events: ["evt-1"], projection_version: 1, correlation_id: "corr-1" });
    mockElixirListTasks.mockResolvedValue([]);
    mockElixirGetTask.mockResolvedValue({
      task_id: "native-001",
      project_id: "proj-1",
      title: "Plan epic",
      type: "epic",
      priority: 1,
      status: "ready",
      description: "desc",
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
    });

    mockListRegisteredProjects.mockResolvedValue([{ id: 'proj-1', name: 'test-project', path: PROJECT_PATH }]);

    mockTaskCreate.mockResolvedValue({
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
    mockTaskGet.mockResolvedValue({
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
    mockTaskList.mockResolvedValue([]);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("creates a native-backed planning client without backend selection", () => {
    const client = createPlanClient(PROJECT_PATH);

    expect(mockSelectTaskReadBackend).not.toHaveBeenCalled();
    expect(MockBeadsRustClient).not.toHaveBeenCalled();
    expect(client).toBeDefined();
  });

  it("uses the native planning API when a delegated method is used", async () => {
    const client = createPlanClient(PROJECT_PATH);
    await client.ready();

    expect(MockBeadsRustClient).not.toHaveBeenCalled();
    expect(mockTaskList).toHaveBeenCalled();
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
    expect(mockTaskCreate).toHaveBeenCalledWith(expect.objectContaining({
      title: "Plan epic",
      description: "desc",
      type: "epic",
      priority: 1,
    }));
    expect(mockTaskApprove).toHaveBeenCalledWith({ projectId: 'proj-1', taskId: 'native-001' });
    expect(mockTaskAddDependency).toHaveBeenCalledWith({ projectId: 'proj-1', fromTaskId: 'native-001', toTaskId: 'parent-123', type: 'parent-child' });
    expect(created.id).toBe("native-001");
    expect(created.priority).toBe("P1");
  });

  it("uses Elixir planning task APIs in default Elixir mode", async () => {
    mockForemanBackendMode.mockReturnValue("elixir");
    mockElixirGetTask.mockResolvedValue({
      task_id: "native-001",
      project_id: "proj-1",
      title: "Plan epic",
      task_type: "epic",
      priority: 1,
      status: "ready",
      description: "desc",
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
    });

    const client = createPlanClient(PROJECT_PATH);
    const created = await client.create("Plan epic", {
      type: "epic",
      priority: "P1",
      parent: "parent-123",
      description: "desc",
    });

    expect(mockTaskCreate).not.toHaveBeenCalled();
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({ command_type: "task.create" }));
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({ command_type: "task.approve" }));
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({ command_type: "task.add_dependency" }));
    expect(created.id).toBe("native-001");
    expect(created.priority).toBe("P1");
  });

  it("marks dependents blocked on native backends until their blocker closes", async () => {
    mockSelectTaskReadBackend.mockReturnValue("native");
    mockTaskGet.mockImplementation(async (id: string) =>
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

    expect(mockTaskAddDependency).toHaveBeenCalledWith({ projectId: 'proj-1', fromTaskId: 'child-1', toTaskId: 'blocker-1', type: 'blocks' });
    expect(mockTaskUpdate).not.toHaveBeenCalled();
  });

  it("re-evaluates blocked tasks when a native planning task closes", async () => {
    mockSelectTaskReadBackend.mockReturnValue("native");
    const client = createPlanClient(PROJECT_PATH);

    await client.close("native-001", "Completed");

    expect(mockTaskClose).toHaveBeenCalledWith({ projectId: 'proj-1', taskId: 'native-001' });
  });
});

describe("readPlanningInput", () => {
  it("returns literal description text when the input path does not exist", () => {
    const input = "Build a user auth system";

    expect(readPlanningInput(input, PROJECT_PATH)).toBe(input);
  });

  it("reads file contents when the input path exists", () => {
    const dir = mkdtempSync(join(tmpdir(), "foreman-plan-read-"));
    try {
      mkdirSync(dir, { recursive: true });
      const file = join(dir, "description.md");
      writeFileSync(file, "# PRD\n\nReal contents\n");
      const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

      const result = readPlanningInput(file, PROJECT_PATH);

      expect(result).toContain("Real contents");
      expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("Reading description from:"));
      logSpy.mockRestore();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("reads absolute existing files and keeps missing absolute paths literal", () => {
    const dir = mkdtempSync(join(tmpdir(), "foreman-plan-read-abs-"));
    try {
      mkdirSync(dir, { recursive: true });
      const file = join(dir, "absolute.md");
      writeFileSync(file, "Absolute contents\n");

      expect(readPlanningInput(file, PROJECT_PATH)).toContain("Absolute contents");
      expect(readPlanningInput(join(dir, "missing.md"), PROJECT_PATH)).toBe(join(dir, "missing.md"));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
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

  it("falls back to PRD.md when no PRD markdown files exist", () => {
    const dir = mkdtempSync(join(tmpdir(), "foreman-plan-hint-empty-"));
    try {
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "notes.md"), "ignore");

      expect(inferPrdHintPath(dir)).toBe(join(dir, "PRD.md"));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
