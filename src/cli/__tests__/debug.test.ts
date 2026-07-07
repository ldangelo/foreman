import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const {
  mockResolveRepoRootProjectPath,
  mockListRegisteredProjects,
  mockCreateTrpcClient,
  mockForemanBackendMode,
  mockEnsureRunning,
  mockElixirListRuns,
  mockElixirListInbox,
  mockRunWithPiSdk,
  mockGetHighspeedModel,
  mockStoreGetRunsForTask,
  mockStoreGetRunProgress,
  mockStoreGetAllMessages,
  mockStoreClose,
  mockForemanStoreForProject,
} = vi.hoisted(() => ({
  mockResolveRepoRootProjectPath: vi.fn(),
  mockListRegisteredProjects: vi.fn(),
  mockCreateTrpcClient: vi.fn(),
  mockForemanBackendMode: vi.fn(),
  mockEnsureRunning: vi.fn(),
  mockElixirListRuns: vi.fn(),
  mockElixirListInbox: vi.fn(),
  mockRunWithPiSdk: vi.fn(),
  mockGetHighspeedModel: vi.fn(),
  mockStoreGetRunsForTask: vi.fn(),
  mockStoreGetRunProgress: vi.fn(),
  mockStoreGetAllMessages: vi.fn(),
  mockStoreClose: vi.fn(),
  mockForemanStoreForProject: vi.fn(),
}));

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: (...args: unknown[]) => mockResolveRepoRootProjectPath(...args),
  listRegisteredProjects: (...args: unknown[]) => mockListRegisteredProjects(...args),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: (...args: unknown[]) => mockCreateTrpcClient(...args),
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: (...args: unknown[]) => mockForemanBackendMode(...args),
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return { ensureRunning: mockEnsureRunning };
  }),
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn().mockImplementation(function MockElixirServerClient() {
    return {
      listRuns: mockElixirListRuns,
      listInbox: mockElixirListInbox,
    };
  }),
}));

vi.mock("../../orchestrator/pi-sdk-runner.js", () => ({
  runWithPiSdk: (...args: unknown[]) => mockRunWithPiSdk(...args),
}));

vi.mock("../../lib/config.js", () => ({
  getHighspeedModel: (...args: unknown[]) => mockGetHighspeedModel(...args),
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: (...args: unknown[]) => mockForemanStoreForProject(...args),
  },
}));

describe("foreman debug", () => {
  let tmpDir: string;

  beforeEach(() => {
    vi.clearAllMocks();
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-debug-test-"));
    mkdirSync(join(tmpDir, ".foreman"), { recursive: true });
    process.chdir(tmpDir);

    mockResolveRepoRootProjectPath.mockResolvedValue(tmpDir);
    mockListRegisteredProjects.mockResolvedValue([]);
    mockForemanBackendMode.mockReturnValue("node");
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockElixirListRuns.mockResolvedValue([]);
    mockElixirListInbox.mockResolvedValue([]);
    mockRunWithPiSdk.mockResolvedValue({ success: true, costUsd: 0.12, outputText: "analysis summary" });
    mockGetHighspeedModel.mockReturnValue("mock-model");
    mockStoreGetRunsForTask.mockReturnValue([]);
    mockStoreGetRunProgress.mockReturnValue({ currentPhase: "developer" });
    mockStoreGetAllMessages.mockReturnValue([]);
    mockStoreClose.mockReset();
    mockForemanStoreForProject.mockReturnValue({
      getRunsForTask: mockStoreGetRunsForTask,
      getRunProgress: mockStoreGetRunProgress,
      getAllMessages: mockStoreGetAllMessages,
      close: mockStoreClose,
    });

    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  async function freshCommand() {
    vi.resetModules();
    return (await import("../commands/debug.js")).debugCommand;
  }

  it("uses daemon-backed runs and mail in raw mode", async () => {
    mockForemanBackendMode.mockReturnValue("node");
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "foreman", path: tmpDir },
    ]);
    mockCreateTrpcClient.mockReturnValue({
      runs: {
        list: vi.fn().mockResolvedValue([
          {
            id: "run-12345678",
            project_id: "proj-1",
            task_id: "foreman-a01cf",
            status: "running",
            branch: "foreman/foreman-a01cf",
            queued_at: "2026-04-25T00:00:00.000Z",
            started_at: "2026-04-25T00:01:00.000Z",
            finished_at: null,
            created_at: "2026-04-25T00:00:00.000Z",
            agent_type: null,
            session_key: null,
            worktree_path: null,
            progress: null,
            base_branch: null,
            merge_strategy: null,
          },
        ]),
      },
      mail: {
        list: vi.fn().mockResolvedValue([
          {
            id: "msg-1",
            run_id: "run-12345678",
            sender_agent_type: "foreman",
            recipient_agent_type: "developer",
            subject: "task-claimed",
            body: '{"taskId":"foreman-a01cf"}',
            read: 0,
            created_at: "2026-04-25T00:02:00.000Z",
            deleted_at: null,
          },
        ]),
      },
    });

    const debugCommand = await freshCommand();
    await debugCommand.parseAsync(["foreman-a01cf", "--raw"], { from: "user" });

    const output = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(output).toContain("Analyzing foreman-a01cf");
    expect(output).toContain("run run-123");
    expect(output).toContain("task-claimed");
  });

  it("fails clearly when no runs exist for the task", async () => {
    const debugCommand = await freshCommand();

    await expect(debugCommand.parseAsync(["missing-task"], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("No runs found for task missing-task");
  });

  it("fails clearly when the requested run selector does not match", async () => {
    mockStoreGetRunsForTask.mockReturnValue([
      {
        id: "run-12345678",
        project_id: "proj-1",
        task_id: "task-1",
        agent_type: "developer",
        session_key: null,
        worktree_path: null,
        status: "completed",
        started_at: "2026-01-01T00:00:00.000Z",
        completed_at: "2026-01-01T00:01:00.000Z",
        created_at: "2026-01-01T00:00:00.000Z",
        progress: null,
        base_branch: null,
        merge_strategy: null,
      },
    ]);

    const debugCommand = await freshCommand();
    await expect(debugCommand.parseAsync(["task-1", "--run", "run-missing"], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Run run-missing not found for task task-1");
    expect(rendered).toContain("Available runs:");
  });

  it("uses Elixir-backed runs and inbox when FOREMAN_BACKEND=elixir", async () => {
    mockForemanBackendMode.mockReturnValue("elixir");
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "foreman", path: tmpDir }]);
    mockElixirListRuns.mockResolvedValue([
      {
        run_id: "run-2222",
        id: "run-2222",
        project_id: "proj-1",
        task_id: "task-1",
        status: "failed",
        created_at: "2026-01-01T00:00:00.000Z",
      },
    ]);
    mockElixirListInbox.mockResolvedValue([
      {
        message_id: "msg-2",
        run_id: "run-2222",
        sender_agent_type: "developer",
        recipient_agent_type: "foreman",
        subject: "agent-error",
        body: { error: "boom" },
        unread: true,
        created_at: "2026-01-01T00:02:00.000Z",
      },
    ]);

    const debugCommand = await freshCommand();
    await debugCommand.parseAsync(["task-1", "--raw"], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockElixirListRuns).toHaveBeenCalled();
    expect(mockElixirListInbox).toHaveBeenCalledWith({ projectId: "proj-1", runId: "run-2222", limit: 100 });
  });

  it("reports AI analysis failure when runWithPiSdk fails", async () => {
    mockStoreGetRunsForTask.mockReturnValue([
      {
        id: "run-12345678",
        project_id: "proj-1",
        task_id: "task-1",
        agent_type: "developer",
        session_key: null,
        worktree_path: null,
        status: "completed",
        started_at: "2026-01-01T00:00:00.000Z",
        completed_at: "2026-01-01T00:01:00.000Z",
        created_at: "2026-01-01T00:00:00.000Z",
        progress: null,
        base_branch: null,
        merge_strategy: null,
      },
    ]);
    mockRunWithPiSdk.mockResolvedValue({ success: false, errorMessage: "analysis exploded" });

    const debugCommand = await freshCommand();
    await expect(debugCommand.parseAsync(["task-1"], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("Analysis failed: analysis exploded");
  });
});
