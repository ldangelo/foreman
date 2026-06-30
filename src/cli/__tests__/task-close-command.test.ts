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

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: () => "node",
}));

async function freshTaskCommand() {
  vi.resetModules();
  const { taskCommand } = await import("../commands/task.js");
  return taskCommand;
}

describe("foreman task close command", () => {
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

  it("closes a task through tRPC using a resolved task prefix", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "ready", priority: 2, type: "task" },
    ]);
    const close = vi.fn().mockResolvedValue(undefined);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, close },
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync([
      "close",
      "task-111",
      "--project-path",
      "/canonical/project",
    ], { from: "user" });

    expect(close).toHaveBeenCalledWith({
      projectId: "proj-1",
      taskId: "task-11111",
    });
    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("closed"));
  });

  it("surfaces missing tasks when closing", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "ready", priority: 2, type: "task" },
    ]);
    const close = vi.fn().mockResolvedValue(undefined);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, close },
    });
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "close",
      "task-missing",
      "--project-path",
      "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(close).not.toHaveBeenCalled();
    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Task 'task-missing' not found");
  });

  it("surfaces ambiguous task prefixes when closing", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "ready", priority: 2, type: "task" },
      { id: "task-11112", title: "B", status: "ready", priority: 1, type: "task" },
    ]);
    const close = vi.fn().mockResolvedValue(undefined);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, close },
    });
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "close",
      "task-111",
      "--project-path",
      "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(close).not.toHaveBeenCalled();
    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Ambiguous task ID prefix 'task-111'");
  });

  it("surfaces close failures", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "ready", priority: 2, type: "task" },
    ]);
    const close = vi.fn().mockRejectedValue(new Error("close failed"));
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, close },
    });
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "close",
      "task-11111",
      "--project-path",
      "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("close failed");
  });
});
