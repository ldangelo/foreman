import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockResolveProjectPathFromOptions,
  mockFindRegisteredProjectByPath,
  mockCreateTrpcClient,
  mockEnsureRunning,
  mockListTasks,
  mockGetTask,
  mockListRuns,
  mockSendCommand,
  mockForemanBackendMode,
} = vi.hoisted(() => ({
  mockResolveProjectPathFromOptions: vi.fn(),
  mockFindRegisteredProjectByPath: vi.fn(),
  mockCreateTrpcClient: vi.fn(),
  mockEnsureRunning: vi.fn(),
  mockListTasks: vi.fn(),
  mockGetTask: vi.fn(),
  mockListRuns: vi.fn(),
  mockSendCommand: vi.fn(),
  mockForemanBackendMode: vi.fn(),
}));

vi.mock("../commands/project-task-support.js", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  resolveProjectPathFromOptions: mockResolveProjectPathFromOptions,
}));

vi.mock("../commands/project-context.js", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  findRegisteredProjectByPath: mockFindRegisteredProjectByPath,
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
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
      listTasks: mockListTasks,
      getTask: mockGetTask,
      listRuns: mockListRuns,
      sendCommand: mockSendCommand,
    };
  }),
}));

async function freshTaskCommand() {
  vi.resetModules();
  const { taskCommand } = await import("../commands/task.js");
  return taskCommand;
}

describe("foreman task command Elixir context", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;
  let logSpy: ReturnType<typeof vi.spyOn>;
  let errSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    mockForemanBackendMode.mockReturnValue("elixir");
    mockResolveProjectPathFromOptions.mockResolvedValue("/canonical/project");
    mockFindRegisteredProjectByPath.mockResolvedValue({ id: "proj-1", name: "proj", path: "/canonical/project" });
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", title: "One", status: "backlog", priority: 2, task_type: "task" },
    ]);
    mockGetTask.mockResolvedValue({ task_id: "task-1", project_id: "proj-1", title: "One", status: "ready", priority: 2, task_type: "task" });
    mockSendCommand.mockResolvedValue({ ok: true, events: ["evt-1"], projection_version: 1, correlation_id: "corr-1" });
    mockListRuns.mockResolvedValue([]);
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
    logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    errSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    exitSpy.mockRestore();
    logSpy.mockRestore();
    errSpy.mockRestore();
  });

  it("routes task create through Elixir commands without creating a tRPC client", async () => {
    mockGetTask.mockResolvedValue({
      task_id: "proj-abcde",
      project_id: "proj-1",
      title: "Created task",
      description: "Created description",
      status: "backlog",
      priority: 1,
      task_type: "bug",
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync([
      "create",
      "--title", "Created task",
      "--description", "Created description",
      "--type", "bug",
      "--priority", "high",
      "--project-path", "/canonical/project",
    ], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockListTasks).toHaveBeenCalledOnce();
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.create",
      payload: expect.objectContaining({
        project_id: "proj-1",
        title: "Created task",
        description: "Created description",
        task_type: "bug",
        priority: 1,
        status: "backlog",
      }),
    }));
    expect(mockGetTask).toHaveBeenCalled();
  });

  it("routes task list through Elixir reads without creating a tRPC client", async () => {
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["list", "--project-path", "/canonical/project"], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockListTasks).toHaveBeenCalledOnce();
  });

  it("routes task show through Elixir reads without creating a tRPC client", async () => {
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", title: "One", status: "backlog", priority: 2, task_type: "task", dependencies: ["task-2"] },
      { task_id: "task-2", project_id: "proj-1", title: "Two", status: "ready", priority: 1, task_type: "task" },
    ]);
    mockGetTask.mockResolvedValue({
      task_id: "task-1",
      project_id: "proj-1",
      title: "One",
      status: "backlog",
      priority: 2,
      task_type: "task",
      annotations: [{ body: "note body", author: "user", created_at: "2026-06-01T00:00:00.000Z" }],
      dependencies: ["task-2"],
      run_id: "run-1",
    });
    mockListRuns.mockResolvedValue([{ run_id: "run-1", task_id: "task-1", status: "completed" }]);
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["show", "task-1", "--project-path", "/canonical/project"], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockGetTask).toHaveBeenCalledWith("task-1");
    expect(mockListRuns).toHaveBeenCalledWith({ projectId: "proj-1" });
  });

  it("routes task approve through Elixir commands without creating a tRPC client", async () => {
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["approve", "task-1", "--project-path", "/canonical/project"], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockListTasks).toHaveBeenCalledOnce();
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.approve",
      payload: expect.objectContaining({ project_id: "proj-1", task_id: "task-1" }),
    }));
    expect(mockGetTask).toHaveBeenCalledWith("task-1");
  });

  it("routes task update through Elixir commands without creating a tRPC client", async () => {
    mockGetTask.mockResolvedValue({
      task_id: "task-1",
      project_id: "proj-1",
      title: "Renamed",
      description: "Updated description",
      status: "ready",
      priority: 1,
      task_type: "bug",
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync([
      "update",
      "task-1",
      "--title", "Renamed",
      "--description", "Updated description",
      "--priority", "high",
      "--status", "ready",
      "--project-path", "/canonical/project",
    ], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.update",
      payload: expect.objectContaining({
        project_id: "proj-1",
        task_id: "task-1",
        title: "Renamed",
        description: "Updated description",
        priority: 1,
        status: "ready",
      }),
    }));
    expect(mockGetTask).toHaveBeenCalledWith("task-1");
  });

  it("clears description for Elixir task update with --no-description", async () => {
    mockGetTask.mockResolvedValue({
      task_id: "task-1",
      project_id: "proj-1",
      title: "Renamed",
      description: null,
      status: "ready",
      priority: 2,
      task_type: "task",
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync([
      "update",
      "task-1",
      "--no-description",
      "--project-path", "/canonical/project",
    ], { from: "user" });

    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.update",
      payload: expect.objectContaining({
        project_id: "proj-1",
        task_id: "task-1",
      }),
    }));
    const payload = mockSendCommand.mock.calls.at(-1)?.[0]?.payload;
    expect(payload?.description).toBeUndefined();
    expect(payload?.title).toBeUndefined();
  });

  it("prints a filtered empty-state message for Elixir task list", async () => {
    mockListTasks.mockResolvedValue([]);
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["list", "--status", "ready", "--type", "bug", "--project-path", "/canonical/project"], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("No tasks with status 'ready' and type 'bug'."));
  });

  it("prints a run-status empty-state message for Elixir task list", async () => {
    mockListTasks.mockResolvedValue([]);
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["list", "--run-status", "failed", "--project-path", "/canonical/project"], { from: "user" });

    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("No tasks with run status 'failed'.");
  });

  it("prints a stuck empty-state message for Elixir task list", async () => {
    mockListTasks.mockResolvedValue([]);
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["list", "--stuck", "--project-path", "/canonical/project"], { from: "user" });

    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("No stuck or stale tasks found.");
  });

  it("filters Elixir task list by run status without creating a tRPC client", async () => {
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", title: "One", status: "backlog", priority: 2, task_type: "task", run_id: "run-1", created_at: "2026-01-01T00:00:00.000Z" },
      { task_id: "task-2", project_id: "proj-1", title: "Two", status: "backlog", priority: 1, task_type: "task", run_id: "run-2", created_at: "2026-01-02T00:00:00.000Z" },
    ]);
    mockListRuns.mockResolvedValue([
      { run_id: "run-1", project_id: "proj-1", task_id: "task-1", status: "completed", updated_at: "2026-01-02T00:00:00.000Z" },
      { run_id: "run-2", project_id: "proj-1", task_id: "task-2", status: "in_progress", updated_at: "2026-01-02T00:00:00.000Z" },
    ]);
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["list", "--run-status", "completed", "--project-path", "/canonical/project"], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Tasks (1)");
    expect(rendered).toContain("task-1");
    expect(rendered).not.toContain("task-2");
  });

  it("shows stuck-task summary in Elixir task list", async () => {
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", title: "One", status: "backlog", priority: 2, task_type: "task", run_id: "run-1", created_at: "2026-01-01T00:00:00.000Z" },
    ]);
    mockListRuns.mockResolvedValue([
      { run_id: "run-1", project_id: "proj-1", task_id: "task-1", status: "in_progress", updated_at: "2025-01-01T00:00:00.000Z" },
    ]);
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["list", "--stuck", "--project-path", "/canonical/project"], { from: "user" });

    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("task-1");
    expect(rendered).toContain("stuck");
  });

  it("prints a cleaned-up run message for verbose Elixir task show when run activity is unavailable", async () => {
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", title: "One", status: "backlog", priority: 2, task_type: "task", run_id: "run-404" },
    ]);
    mockGetTask.mockResolvedValue({
      task_id: "task-1",
      project_id: "proj-1",
      title: "One",
      status: "backlog",
      priority: 2,
      task_type: "task",
      run_id: "run-404",
      annotations: [],
      dependencies: [],
    });
    mockListRuns.mockResolvedValue([]);
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["show", "task-1", "--verbose", "--project-path", "/canonical/project"], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Run Activity: run run-404 not found");
  });

  it("prints the current phase for verbose Elixir task show when run activity exists", async () => {
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", title: "One", status: "backlog", priority: 2, task_type: "task", run_id: "run-1" },
    ]);
    mockGetTask.mockResolvedValue({
      task_id: "task-1",
      project_id: "proj-1",
      title: "One",
      status: "backlog",
      priority: 2,
      task_type: "task",
      run_id: "run-1",
      annotations: [],
      dependencies: [],
    });
    mockListRuns.mockResolvedValue([{ run_id: "run-1", project_id: "proj-1", task_id: "task-1", status: "in_progress", current_phase: "developer", updated_at: new Date().toISOString() }]);
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["show", "task-1", "--verbose", "--project-path", "/canonical/project"], { from: "user" });

    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Current phase: developer");
  });

  it("prints non-ready approval output when Elixir approval does not yield ready status", async () => {
    mockGetTask.mockResolvedValue({
      task_id: "task-1",
      project_id: "proj-1",
      title: "One",
      status: "review",
      priority: 2,
      task_type: "task",
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["approve", "task-1", "--project-path", "/canonical/project"], { from: "user" });

    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("approved.");
    expect(rendered).toContain("Status: review");
  });

  it("prints ready-for-dispatch approval output when Elixir approval yields ready status", async () => {
    mockGetTask.mockResolvedValue({
      task_id: "task-1",
      project_id: "proj-1",
      title: "One",
      status: "ready",
      priority: 2,
      task_type: "task",
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["approve", "task-1", "--project-path", "/canonical/project"], { from: "user" });

    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("approved and ready for dispatch");
  });

  it("rejects backward Elixir status transitions unless --force is used", async () => {
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", title: "One", status: "merged", priority: 2, task_type: "task" },
    ]);
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "update",
      "task-1",
      "--status", "backlog",
      "--project-path", "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(mockSendCommand).not.toHaveBeenCalled();
    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("cannot transition from 'merged' to 'backlog'");
    expect(rendered).toContain("Use --force to override this check.");
  });

  it("allows backward Elixir status transitions when --force is used", async () => {
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", title: "One", status: "merged", priority: 2, task_type: "task" },
    ]);
    mockGetTask.mockResolvedValue({
      task_id: "task-1",
      project_id: "proj-1",
      title: "One",
      status: "backlog",
      priority: 2,
      task_type: "task",
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync([
      "update",
      "task-1",
      "--status", "backlog",
      "--force",
      "--project-path", "/canonical/project",
    ], { from: "user" });

    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.update",
      payload: expect.objectContaining({
        project_id: "proj-1",
        task_id: "task-1",
        status: "backlog",
      }),
    }));
  });

  it("routes task close through Elixir commands without creating a tRPC client", async () => {
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["close", "task-1", "--project-path", "/canonical/project"], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockListTasks).toHaveBeenCalledOnce();
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.close",
      payload: expect.objectContaining({ project_id: "proj-1", task_id: "task-1" }),
    }));
  });

  it("rejects invalid Elixir task types before issuing commands", async () => {
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "create",
      "--title", "Created task",
      "--type", "urgent",
      "--project-path", "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(mockSendCommand).not.toHaveBeenCalled();
    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Invalid type 'urgent'");
  });

  it("rejects invalid Elixir task priorities before issuing commands", async () => {
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "create",
      "--title", "Created task",
      "--priority", "urgent",
      "--project-path", "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(mockSendCommand).not.toHaveBeenCalled();
    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Invalid priority 'urgent'");
  });

  it("fails closed when the Elixir project is not registered", async () => {
    mockFindRegisteredProjectByPath.mockResolvedValue(null);
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "list",
      "--project-path", "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("not registered with the daemon");
  });

  it("renders Elixir task notes, incoming dependencies, and outgoing dependencies", async () => {
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", title: "One", status: "backlog", priority: 2, task_type: "task", dependencies: ["task-2"] },
      { task_id: "task-parent", project_id: "proj-1", title: "Parent", status: "ready", priority: 1, task_type: "task", dependencies: ["task-1"] },
      { task_id: "task-2", project_id: "proj-1", title: "Child", status: "ready", priority: 1, task_type: "task" },
    ]);
    mockGetTask.mockResolvedValue({
      task_id: "task-1",
      project_id: "proj-1",
      title: "One",
      status: "backlog",
      priority: 2,
      task_type: "task",
      annotations: [{ body: "first line\nsecond line", author: "user", created_at: "2026-06-01T00:00:00.000Z" }],
      dependencies: ["task-2"],
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["show", "task-1", "--project-path", "/canonical/project"], { from: "user" });

    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Notes:");
    expect(rendered).toContain("first line");
    expect(rendered).toContain("second line");
    expect(rendered).toContain("Blocked by:");
    expect(rendered).toContain("task-parent");
    expect(rendered).toContain("Blocking:");
    expect(rendered).toContain("task-2");
  });

  it("renders the empty Elixir notes placeholder when there are no annotations", async () => {
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", title: "One", status: "backlog", priority: 2, task_type: "task" },
    ]);
    mockGetTask.mockResolvedValue({
      task_id: "task-1",
      project_id: "proj-1",
      title: "One",
      status: "backlog",
      priority: 2,
      task_type: "task",
      annotations: [],
      dependencies: [],
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(["show", "task-1", "--project-path", "/canonical/project"], { from: "user" });

    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Notes:");
    expect(rendered).toContain("(none yet)");
  });

  it("prints a not-found error for missing Elixir tasks", async () => {
    mockGetTask.mockResolvedValue(null);
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "show",
      "task-404",
      "--project-path", "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Task 'task-404' not found");
  });
});
