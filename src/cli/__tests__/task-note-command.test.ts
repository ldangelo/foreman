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

describe("foreman task note command", () => {
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

  it("adds a note through tRPC using a resolved task prefix", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "backlog", priority: 2, type: "task" },
    ]);
    const addNote = vi.fn().mockResolvedValue(undefined);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, addNote },
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync([
      "note",
      "task-111",
      "--body",
      "Need to revisit edge case",
      "--kind",
      "review",
      "--author",
      "alice",
      "--project-path",
      "/canonical/project",
    ], { from: "user" });

    expect(addNote).toHaveBeenCalledWith({
      projectId: "proj-1",
      taskId: "task-11111",
      author: "alice",
      kind: "review",
      body: "Need to revisit edge case",
    });
    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("Note added"));
  });

  it("surfaces missing tasks when adding a note", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "backlog", priority: 2, type: "task" },
    ]);
    const addNote = vi.fn().mockResolvedValue(undefined);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, addNote },
    });
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "note",
      "task-missing",
      "--body",
      "Need to revisit edge case",
      "--project-path",
      "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(addNote).not.toHaveBeenCalled();
    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Task 'task-missing' not found");
  });

  it("surfaces addNote failures", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "backlog", priority: 2, type: "task" },
    ]);
    const addNote = vi.fn().mockRejectedValue(new Error("write failed"));
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, addNote },
    });
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "note",
      "task-11111",
      "--body",
      "Need to revisit edge case",
      "--project-path",
      "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("write failed");
  });

  it("uses default kind and author when optional note flags are omitted", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "backlog", priority: 2, type: "task" },
    ]);
    const addNote = vi.fn().mockResolvedValue(undefined);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, addNote },
    });
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync([
      "note",
      "task-11111",
      "--body",
      "Default note",
      "--project-path",
      "/canonical/project",
    ], { from: "user" });

    expect(addNote).toHaveBeenCalledWith({
      projectId: "proj-1",
      taskId: "task-11111",
      author: "user",
      kind: "manual",
      body: "Default note",
    });
  });

  it("surfaces ambiguous task prefixes when adding a note", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "backlog", priority: 2, type: "task" },
      { id: "task-11112", title: "B", status: "ready", priority: 1, type: "task" },
    ]);
    const addNote = vi.fn().mockResolvedValue(undefined);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, addNote },
    });
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync([
      "note",
      "task-111",
      "--body",
      "Ambiguous note",
      "--project-path",
      "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(addNote).not.toHaveBeenCalled();
    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Ambiguous task ID prefix 'task-111'");
  });
});
