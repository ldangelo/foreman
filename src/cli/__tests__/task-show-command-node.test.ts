import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockResolveProjectPathFromOptions,
  mockFindRegisteredProjectByPath,
  mockCreateTrpcClient,
  mockStoreGetRun,
  mockStoreGetRunProgress,
  mockStoreClose,
} = vi.hoisted(() => ({
  mockResolveProjectPathFromOptions: vi.fn(),
  mockFindRegisteredProjectByPath: vi.fn(),
  mockCreateTrpcClient: vi.fn(),
  mockStoreGetRun: vi.fn(),
  mockStoreGetRunProgress: vi.fn(),
  mockStoreClose: vi.fn(),
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

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: vi.fn(() => ({
      getRun: mockStoreGetRun,
      getRunProgress: mockStoreGetRunProgress,
      close: mockStoreClose,
    })),
  },
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: () => "node",
}));

async function freshTaskCommand() {
  vi.resetModules();
  const { taskCommand } = await import("../commands/task.js");
  return taskCommand;
}

describe("foreman task show command (node mode)", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;
  let logSpy: ReturnType<typeof vi.spyOn>;
  let errSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    mockResolveProjectPathFromOptions.mockResolvedValue("/canonical/project");
    mockFindRegisteredProjectByPath.mockResolvedValue({ id: "proj-1", name: "proj", path: "/canonical/project" });
    mockStoreGetRun.mockReset();
    mockStoreGetRunProgress.mockReset();
    mockStoreClose.mockReset();
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

  it("renders verbose run activity, PR details, notes fallback, and dependencies", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "ready", priority: 2, type: "task" },
      { id: "task-parent", title: "Parent", status: "ready", priority: 1, type: "task" },
    ]);
    const get = vi.fn().mockResolvedValue({
      id: "task-11111",
      title: "A",
      status: "ready",
      priority: 2,
      type: "task",
      description: "Important work",
      run_id: "run-1",
      branch: "foreman/task-11111",
      external_id: "github:owner/repo#42",
      created_at: "2026-01-01T00:00:00.000Z",
      updated_at: "2026-01-02T00:00:00.000Z",
      approved_at: "2026-01-01T01:00:00.000Z",
      closed_at: null,
    });
    const getPrState = vi.fn().mockResolvedValue({
      status: "merged",
      url: "https://example.test/pr/42",
      number: 42,
      headSha: "1234567890abcdef1234",
      currentHeadSha: "fedcba09876543211234",
      isStale: true,
      error: "merge metadata drift",
    });
    const listNotes = vi.fn().mockRejectedValue(new Error("notes offline"));
    const listDependencies = vi.fn()
      .mockResolvedValueOnce([{ from_task_id: "task-11111", to_task_id: "task-child", type: "parent-child" }])
      .mockResolvedValueOnce([{ from_task_id: "task-parent", to_task_id: "task-11111", type: "blocks" }]);
    mockStoreGetRun.mockReturnValue({
      id: "run-1",
      status: "completed",
      started_at: "2026-01-02T00:00:00.000Z",
      completed_at: "2026-01-02T00:05:00.000Z",
    });
    mockStoreGetRunProgress.mockReturnValue({
      currentPhase: "reviewer",
      lastActivity: "2026-01-02T00:04:00.000Z",
      toolCalls: 3,
      costUsd: 1.25,
      turns: 7,
    });

    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, get, getPrState, listNotes, listDependencies },
    });

    const taskCommand = await freshTaskCommand();
    await taskCommand.parseAsync([
      "show",
      "task-111",
      "--verbose",
      "--project-path",
      "/canonical/project",
    ], { from: "user" });

    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Run Activity:");
    expect(rendered).toContain("Current phase: reviewer");
    expect(rendered).toContain("Tools used:");
    expect(rendered).toContain("Turns:");
    expect(rendered).toContain("Cost:");
    expect(rendered).toContain("Last activity:");
    expect(rendered).toContain("Started:");
    expect(rendered).toContain("Completed:");
    expect(rendered).toContain("Run completed successfully");
    expect(rendered).toContain("Pull Request:");
    expect(rendered).toContain("URL:");
    expect(rendered).toContain("Number:     #42");
    expect(rendered).toContain("PR Head:");
    expect(rendered).toContain("Branch Head:");
    expect(rendered).toContain("Stale:");
    expect(rendered).toContain("Error:      merge metadata drift");
    expect(rendered).toContain("Notes:");
    expect(rendered).toContain("unavailable: notes offline");
    expect(rendered).toContain("Blocked by:");
    expect(rendered).toContain("task-parent");
    expect(rendered).toContain("Blocking:");
    expect(rendered).toContain("task-child");
  });

  it("renders failed-run guidance and missing-task errors", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "task-11111", title: "A", status: "ready", priority: 2, type: "task" },
    ]);
    const get = vi.fn()
      .mockResolvedValueOnce({
        id: "task-11111",
        title: "A",
        status: "ready",
        priority: 2,
        type: "task",
        run_id: "run-2",
        created_at: "2026-01-01T00:00:00.000Z",
        updated_at: "2026-01-02T00:00:00.000Z",
      })
      .mockResolvedValueOnce(null);
    const getPrState = vi.fn().mockRejectedValue(new Error("pr unavailable"));
    const listNotes = vi.fn().mockResolvedValue([]);
    const listDependencies = vi.fn().mockResolvedValue([]);
    mockStoreGetRun.mockReturnValue({
      id: "run-2",
      status: "failed",
      started_at: "2026-01-02T00:00:00.000Z",
      completed_at: "2026-01-02T00:05:00.000Z",
    });
    mockStoreGetRunProgress.mockReturnValue({
      currentPhase: "developer",
      lastActivity: "2026-01-02T00:04:00.000Z",
      toolCalls: 0,
      costUsd: 0,
      turns: 0,
    });

    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, get, getPrState, listNotes, listDependencies },
    });

    const taskCommand = await freshTaskCommand();
    await taskCommand.parseAsync([
      "show",
      "task-11111",
      "--verbose",
      "--project-path",
      "/canonical/project",
    ], { from: "user" });

    let rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("This run FAILED");
    expect(rendered).toContain("To retry: foreman task retry task-11111");
    expect(rendered).toContain("Notes:");
    expect(rendered).toContain("(none yet)");
    expect(rendered).not.toContain("Pull Request:");

    logSpy.mockClear();
    errSpy.mockClear();

    await expect(taskCommand.parseAsync([
      "show",
      "task-missing",
      "--project-path",
      "/canonical/project",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Task 'task-missing' not found");
  });
});
