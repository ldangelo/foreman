import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockResolveRepoRootProjectPath,
  mockListRegisteredProjects,
  mockCreateTrpcClient,
  mockForProject,
  mockSpawn,
} = vi.hoisted(() => ({
  mockResolveRepoRootProjectPath: vi.fn(),
  mockListRegisteredProjects: vi.fn(),
  mockCreateTrpcClient: vi.fn(),
  mockForProject: vi.fn(),
  mockSpawn: vi.fn(),
}));

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: (...args: unknown[]) => mockResolveRepoRootProjectPath(...args),
  listRegisteredProjects: (...args: unknown[]) => mockListRegisteredProjects(...args),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: (...args: unknown[]) => mockCreateTrpcClient(...args),
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: (...args: unknown[]) => mockForProject(...args),
  },
}));

vi.mock("node:child_process", async () => {
  const actual = await vi.importActual<typeof import("node:child_process")>("node:child_process");
  return { ...actual, spawn: (...args: unknown[]) => mockSpawn(...args) };
});

function makeChild() {
  const handlers = new Map<string, (value?: unknown) => void>();
  const child = {
    on: vi.fn((event: string, handler: (value?: unknown) => void) => {
      handlers.set(event, handler);
      return child;
    }),
    emit(event: string, value?: unknown) {
      handlers.get(event)?.(value);
    },
  };
  return child as any;
}

describe("attach command context", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockResolveRepoRootProjectPath.mockResolvedValue("/tmp/project");
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "project", path: "/tmp/project" },
    ]);
    mockForProject.mockReturnValue({
      close: vi.fn(),
      getRun: vi.fn().mockReturnValue(null),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1", path: "/tmp/project" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunProgress: vi.fn().mockReturnValue(null),
      getAllMessages: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
    });
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  async function freshCommand() {
    vi.resetModules();
    return (await import("../commands/attach.js")).attachCommand;
  }

  it("prefers daemon session listing when a registered project is available", async () => {
    mockCreateTrpcClient.mockReturnValue({
      runs: {
        list: vi.fn().mockResolvedValue([
          {
            id: "run-1",
            project_id: "proj-1",
            task_id: "task-1",
            status: "running",
            branch: "foreman/task-1",
            agent_type: "developer",
            session_key: null,
            worktree_path: "/tmp/wt",
            progress: null,
            base_branch: null,
            merge_strategy: null,
            queued_at: "2026-01-01T00:00:00.000Z",
            started_at: "2026-01-01T00:00:00.000Z",
            finished_at: null,
            created_at: "2026-01-01T00:00:00.000Z",
          },
        ]),
      },
    });

    const attachCommand = await freshCommand();
    await attachCommand.parseAsync(["--list"], { from: "user" });

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Attachable sessions:");
    expect(rendered).toContain("task-1");
  });

  it("prints usage and exits when no id is provided", async () => {
    const attachCommand = await freshCommand();

    await expect(attachCommand.parseAsync([], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Usage: foreman attach <run-id|task-id>");
    expect(rendered).toContain("foreman attach --list");
  });

});
