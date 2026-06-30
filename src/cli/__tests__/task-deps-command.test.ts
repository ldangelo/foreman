import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockResolveProjectPathFromOptions,
  mockFindRegisteredProjectByPath,
  mockCreateTrpcClient,
} = vi.hoisted(() => ({
  mockResolveProjectPathFromOptions: vi.fn(),
  mockFindRegisteredProjectByPath: vi.fn(),
  mockCreateTrpcClient: vi.fn(),
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

async function freshTaskCommand() {
  vi.resetModules();
  const { taskCommand } = await import("../commands/task.js");
  return taskCommand;
}

describe("foreman task dependency commands", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;
  let logSpy: ReturnType<typeof vi.spyOn>;
  let errSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    mockResolveProjectPathFromOptions.mockResolvedValue("/canonical/project");
    mockFindRegisteredProjectByPath.mockResolvedValue({ id: "proj-1", name: "proj", path: "/canonical/project" });
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

  it("adds a dependency through tRPC using resolved task prefixes", async () => {
    const addDependency = vi.fn().mockResolvedValue(undefined);
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "backlog", priority: 2, type: "task" },
      { id: "task-22222", title: "B", status: "ready", priority: 1, type: "task" },
    ]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, addDependency, listDependencies: vi.fn(), removeDependency: vi.fn() },
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync([
      "dep",
      "add",
      "task-111",
      "task-222",
      "--project-path",
      "/canonical/project",
    ], { from: "user" });

    expect(addDependency).toHaveBeenCalledWith({
      projectId: "proj-1",
      fromTaskId: "task-11111",
      toTaskId: "task-22222",
      type: "blocks",
    });
    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("Dependency added"));
  });

  it("rejects invalid dependency types before issuing RPCs", async () => {
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list: vi.fn(), addDependency: vi.fn(), listDependencies: vi.fn(), removeDependency: vi.fn() },
    });
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "dep",
      "add",
      "task-1",
      "task-2",
      "--type",
      "invalid",
      "--project-path",
      "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Invalid type 'invalid'");
  });

  it("surfaces circular dependency errors with a specific message", async () => {
    const addDependency = vi.fn().mockRejectedValue(new Error("circular dependency detected"));
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "backlog", priority: 2, type: "task" },
      { id: "task-22222", title: "B", status: "ready", priority: 1, type: "task" },
    ]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, addDependency, listDependencies: vi.fn(), removeDependency: vi.fn() },
    });
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "dep",
      "add",
      "task-11111",
      "task-22222",
      "--project-path",
      "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("would create a circular dependency");
  });

  it("prints a no-dependencies message when dep list is empty", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "backlog", priority: 2, type: "task" },
    ]);
    const listDependencies = vi.fn().mockResolvedValue([]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, addDependency: vi.fn(), listDependencies, removeDependency: vi.fn() },
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync([
      "dep",
      "list",
      "task-111",
      "--project-path",
      "/canonical/project",
    ], { from: "user" });

    expect(listDependencies).toHaveBeenNthCalledWith(1, {
      projectId: "proj-1",
      taskId: "task-11111",
      direction: "incoming",
    });
    expect(listDependencies).toHaveBeenNthCalledWith(2, {
      projectId: "proj-1",
      taskId: "task-11111",
      direction: "outgoing",
    });
    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("has no dependencies"));
  });

  it("prints incoming and outgoing dependencies", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "backlog", priority: 2, type: "task" },
    ]);
    const listDependencies = vi.fn()
      .mockResolvedValueOnce([{ from_task_id: "task-parent", to_task_id: "task-11111", type: "blocks" }])
      .mockResolvedValueOnce([{ from_task_id: "task-11111", to_task_id: "task-child", type: "parent-child" }]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, addDependency: vi.fn(), listDependencies, removeDependency: vi.fn() },
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync([
      "dep",
      "list",
      "task-11111",
      "--project-path",
      "/canonical/project",
    ], { from: "user" });

    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Blocked by:");
    expect(rendered).toContain("task-parent");
    expect(rendered).toContain("Blocking:");
    expect(rendered).toContain("task-child");
  });

  it("removes a dependency through tRPC using resolved task ids", async () => {
    const removeDependency = vi.fn().mockResolvedValue(undefined);
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "backlog", priority: 2, type: "task" },
      { id: "task-22222", title: "B", status: "ready", priority: 1, type: "task" },
    ]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, addDependency: vi.fn(), listDependencies: vi.fn(), removeDependency },
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync([
      "dep",
      "remove",
      "task-111",
      "task-222",
      "--type",
      "parent-child",
      "--project-path",
      "/canonical/project",
    ], { from: "user" });

    expect(removeDependency).toHaveBeenCalledWith({
      projectId: "proj-1",
      fromTaskId: "task-11111",
      toTaskId: "task-22222",
      type: "parent-child",
    });
    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("Dependency removed"));
  });

  it("surfaces ambiguous task prefixes before issuing dependency RPCs", async () => {
    const addDependency = vi.fn().mockResolvedValue(undefined);
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "backlog", priority: 2, type: "task" },
      { id: "task-11112", title: "B", status: "ready", priority: 1, type: "task" },
      { id: "task-22222", title: "C", status: "ready", priority: 1, type: "task" },
    ]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, addDependency, listDependencies: vi.fn(), removeDependency: vi.fn() },
    });
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "dep",
      "add",
      "task-111",
      "task-22222",
      "--project-path",
      "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(addDependency).not.toHaveBeenCalled();
    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Ambiguous task ID prefix 'task-111'");
  });

  it("surfaces missing tasks during dependency removal", async () => {
    const removeDependency = vi.fn().mockResolvedValue(undefined);
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "backlog", priority: 2, type: "task" },
    ]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, addDependency: vi.fn(), listDependencies: vi.fn(), removeDependency },
    });
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "dep",
      "remove",
      "task-11111",
      "task-missing",
      "--project-path",
      "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(removeDependency).not.toHaveBeenCalled();
    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Task 'task-missing' not found");
  });
});
