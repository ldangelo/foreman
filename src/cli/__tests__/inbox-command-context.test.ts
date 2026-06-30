import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";

const { mockListRegisteredProjects, mockCreateTrpcClient } = vi.hoisted(() => {
  const mockListRegisteredProjects = vi.fn();
  const mockCreateTrpcClient = vi.fn();
  return { mockListRegisteredProjects, mockCreateTrpcClient };
});

vi.mock("../commands/project-task-support.js", () => ({
  listRegisteredProjects: mockListRegisteredProjects,
  resolveRepoRootProjectPath: vi.fn(async ({ projectPath }: { projectPath?: string }) => resolve(projectPath ?? process.cwd())),
  requireProjectOrAllInMultiMode: vi.fn(),
  ensureCliPostgresPool: vi.fn(),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

import { inboxCommand, resolveDaemonInboxContext } from "../commands/inbox.js";

describe("inbox command context", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-inbox-command-context-"));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    process.env.FOREMAN_BACKEND = "node";
    vi.clearAllMocks();
    mockListRegisteredProjects.mockReset();
    mockCreateTrpcClient.mockReset();
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit called with code: ${code}`);
    }) as typeof process.exit);
  });

  afterEach(() => {
    delete process.env.FOREMAN_BACKEND;
    vi.restoreAllMocks();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("resolves a registered inbox project when projectPath is a non-canonical equivalent path", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    const client = { inbox: true };
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockCreateTrpcClient.mockReturnValue(client);

    const equivalentPath = `${projectDir}/.`;
    const daemon = await resolveDaemonInboxContext(equivalentPath);

    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockCreateTrpcClient).toHaveBeenCalledOnce();
    expect(daemon).toEqual({ backend: "node", client, projectId: "proj-1" });
  });

  it("keeps explicit project selection by id or name unchanged", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: "/elsewhere/registered-project" },
    ]);
    const client = { inbox: true };
    mockCreateTrpcClient.mockReturnValue(client);

    await expect(resolveDaemonInboxContext("/totally/different", "proj-1")).resolves.toEqual({
      backend: "node",
      client,
      projectId: "proj-1",
    });
    await expect(resolveDaemonInboxContext("/totally/different", "registered-project")).resolves.toEqual({
      backend: "node",
      client,
      projectId: "proj-1",
    });
  });

  it("keeps local fallback behavior unchanged when no project matches", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "local-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([]);

    const localStore = {
      getAllMessagesGlobal: vi.fn().mockReturnValue([]),
      close: vi.fn(),
    };
    const forProjectSpy = vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore as unknown as ForemanStore);

    await inboxCommand.parseAsync(["--all", "--project-path", `${projectDir}/.`], { from: "user" });

    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(forProjectSpy).toHaveBeenCalledWith(resolve(projectDir));
    expect(localStore.getAllMessagesGlobal).toHaveBeenCalledWith(50);
  });

  it("returns null daemon context when registered-project lookup throws", async () => {
    mockListRegisteredProjects.mockRejectedValue(new Error("registry unavailable"));

    await expect(resolveDaemonInboxContext("/tmp/project")).resolves.toBeNull();
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
  });

  it("supports local global inbox ack plus pipeline events when daemon/project resolution is unavailable", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "local-events-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([]);

    const localStore = {
      getAllMessagesGlobal: vi.fn().mockReturnValue([
        {
          id: "msg-1",
          run_id: "run-1",
          sender_agent_type: "developer",
          recipient_agent_type: "foreman",
          subject: "phase-complete",
          body: JSON.stringify({ kind: "tool", tool: "bash", argsPreview: "npm test", seedId: "task-1" }),
          read: 0,
          created_at: "2026-01-01T00:00:00.000Z",
          deleted_at: null,
        },
      ]),
      getRunsByStatuses: vi.fn().mockReturnValue([
        {
          id: "run-1",
          seed_id: "task-1",
          status: "completed",
          created_at: "2026-01-01T00:00:00.000Z",
          started_at: "2026-01-01T00:00:00.000Z",
          completed_at: "2026-01-01T00:01:00.000Z",
          branch: "foreman/task-1",
        },
      ]),
      getRunEvents: vi.fn().mockReturnValue([
        {
          id: "evt-1",
          run_id: "run-1",
          event_type: "phase-complete",
          details: JSON.stringify({ phase: "developer" }),
          created_at: "2026-01-01T00:01:00.000Z",
        },
      ]),
      markMessageRead: vi.fn(),
      close: vi.fn(),
    };
    const forProjectSpy = vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore as unknown as ForemanStore);

    await inboxCommand.parseAsync(["--all", "--events", "--ack", "--project-path", projectDir], { from: "user" });

    expect(forProjectSpy).toHaveBeenCalledWith(resolve(projectDir));
    expect(localStore.getAllMessagesGlobal).toHaveBeenCalledWith(50);
    expect(localStore.markMessageRead).toHaveBeenCalledWith("msg-1");
    expect(localStore.getRunEvents).toHaveBeenCalledWith("run-1");
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Pipeline Events — all runs");
    expect(rendered).toContain("phase-complete");
    expect(rendered).toContain("Marked 1 message(s) as read.");
  });

  it("resolves the most recent local run by task id and renders run-specific events", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "local-run-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([]);

    const runs = [
      {
        id: "run-new",
        seed_id: "task-1",
        status: "completed",
        created_at: "2026-01-01T00:02:00.000Z",
        started_at: "2026-01-01T00:02:00.000Z",
        completed_at: "2026-01-01T00:03:00.000Z",
        branch: "foreman/task-1",
      },
      {
        id: "run-old",
        seed_id: "task-1",
        status: "failed",
        created_at: "2026-01-01T00:00:00.000Z",
        started_at: "2026-01-01T00:00:00.000Z",
        completed_at: "2026-01-01T00:01:00.000Z",
        branch: "foreman/task-1-old",
      },
    ];
    const localStore = {
      getRunsByStatuses: vi.fn().mockReturnValue(runs),
      getAllMessages: vi.fn().mockImplementation((runId: string) => runId === "run-new" ? [{
        id: "msg-2",
        run_id: "run-new",
        sender_agent_type: "qa",
        recipient_agent_type: "foreman",
        subject: "agent-error",
        body: JSON.stringify({ error: "bad test", seedId: "task-1" }),
        read: 0,
        created_at: "2026-01-01T00:02:30.000Z",
        deleted_at: null,
      }] : []),
      getRunEvents: vi.fn().mockImplementation((runId: string) => runId === "run-new" ? [{
        id: "evt-2",
        run_id: "run-new",
        event_type: "fail",
        details: JSON.stringify({ seedId: "task-1" }),
        created_at: "2026-01-01T00:03:00.000Z",
      }] : []),
      close: vi.fn(),
    };
    const forProjectSpy = vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore as unknown as ForemanStore);

    await inboxCommand.parseAsync(["--task", "task-1", "--events", "--project-path", projectDir], { from: "user" });

    expect(forProjectSpy).toHaveBeenCalledWith(resolve(projectDir));
    expect(localStore.getAllMessages).toHaveBeenCalledWith("run-new");
    expect(localStore.getRunEvents).toHaveBeenCalledWith("run-new");
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Inbox — run: run-new");
    expect(rendered).toContain("Pipeline Events — run: run-new");
    expect(rendered).toContain("task-1");
  });

  it("prints the all-run unread empty state for a filtered local inbox", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "local-empty-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([]);

    const localStore = {
      getAllMessagesGlobal: vi.fn().mockReturnValue([]),
      getRunsByStatuses: vi.fn().mockReturnValue([]),
      close: vi.fn(),
    };
    vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore as unknown as ForemanStore);

    await inboxCommand.parseAsync(["--all", "--unread", "--agent", "qa", "--project-path", projectDir], { from: "user" });

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("No unread messages found across all runs (agent: qa).");
  });

  it("prints run empty-state and no pipeline events for a local run", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "local-run-empty-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([]);

    const runs = [{
      id: "run-1",
      seed_id: "task-1",
      status: "completed",
      created_at: "2026-01-01T00:00:00.000Z",
      started_at: "2026-01-01T00:00:00.000Z",
      completed_at: "2026-01-01T00:01:00.000Z",
      branch: "foreman/task-1",
    }];
    const localStore = {
      getRunsByStatuses: vi.fn().mockReturnValue(runs),
      getAllMessages: vi.fn().mockReturnValue([]),
      getRunEvents: vi.fn().mockReturnValue([]),
      close: vi.fn(),
    };
    vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore as unknown as ForemanStore);

    await inboxCommand.parseAsync(["--run", "run-1", "--events", "--project-path", projectDir], { from: "user" });

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("No messages for run run-1  bead: task-1.");
    expect(rendered).toContain("No pipeline events found.");
  });

  it("fails clearly when no local runs exist", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "local-no-runs-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([]);

    const localStore = {
      getRunsByStatuses: vi.fn().mockReturnValue([]),
      close: vi.fn(),
    };
    vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore as unknown as ForemanStore);

    await expect(inboxCommand.parseAsync(["--project-path", projectDir], { from: "user" })).rejects.toThrow("process.exit called with code: 1");

    expect(vi.mocked(console.error)).toHaveBeenCalledWith("No runs found. Start a pipeline first with `foreman run`.");
  });

  it("supports daemon all-run ack plus pipeline events in node mode", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);

    const markRead = vi.fn().mockResolvedValue(undefined);
    const listGlobal = vi.fn().mockResolvedValue([
      {
        id: "msg-1",
        run_id: "run-1",
        sender_agent_type: "developer",
        recipient_agent_type: "foreman",
        subject: "phase-complete",
        body: JSON.stringify({ kind: "tool", tool: "bash", argsPreview: "npm test", seedId: "task-1" }),
        read: 0,
        created_at: "2026-01-01T00:00:00.000Z",
        deleted_at: null,
      },
    ]);
    const listRuns = vi.fn().mockResolvedValue([
      {
        id: "run-1",
        project_id: "proj-1",
        bead_id: "task-1",
        status: "success",
        branch: "foreman/task-1",
        agent_type: "developer",
        session_key: null,
        worktree_path: null,
        progress: null,
        base_branch: null,
        merge_strategy: null,
        queued_at: "2026-01-01T00:00:00.000Z",
        started_at: "2026-01-01T00:00:00.000Z",
        finished_at: "2026-01-01T00:01:00.000Z",
        created_at: "2026-01-01T00:00:00.000Z",
      },
    ]);
    const listEvents = vi.fn().mockResolvedValue([
      {
        id: "evt-1",
        run_id: "run-1",
        event_type: "phase-complete",
        details: JSON.stringify({ phase: "developer" }),
        created_at: "2026-01-01T00:01:00.000Z",
      },
    ]);
    mockCreateTrpcClient.mockReturnValue({
      mail: { listGlobal, markRead },
      runs: { list: listRuns, listEvents },
    });

    await inboxCommand.parseAsync(["--all", "--events", "--ack", "--project-path", projectDir], { from: "user" });

    expect(listGlobal).toHaveBeenCalledWith({ projectId: "proj-1", limit: 50 });
    expect(listRuns).toHaveBeenCalledWith({ projectId: "proj-1", limit: 100 });
    expect(listEvents).toHaveBeenCalledWith({ runId: "run-1" });
    expect(markRead).toHaveBeenCalledWith({ projectId: "proj-1", messageId: "msg-1" });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Pipeline Events — all runs");
    expect(rendered).toContain("phase-complete");
    expect(rendered).toContain("Marked 1 message(s) as read.");
  });

  it("resolves daemon runs by --task and prints the no-events branch", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);

    const listRuns = vi.fn().mockResolvedValue([
      {
        id: "run-2",
        project_id: "proj-1",
        bead_id: "task-2",
        status: "failed",
        branch: "foreman/task-2",
        agent_type: "developer",
        session_key: null,
        worktree_path: null,
        progress: null,
        base_branch: null,
        merge_strategy: null,
        queued_at: "2026-01-01T00:00:00.000Z",
        started_at: "2026-01-01T00:00:00.000Z",
        finished_at: "2026-01-01T00:01:00.000Z",
        created_at: "2026-01-01T00:00:00.000Z",
      },
    ]);
    const listMessages = vi.fn().mockResolvedValue([]);
    const listEvents = vi.fn().mockResolvedValue([]);
    mockCreateTrpcClient.mockReturnValue({
      mail: { list: listMessages },
      runs: { list: listRuns, listEvents },
    });

    await inboxCommand.parseAsync(["--task", "task-2", "--events", "--project-path", projectDir], { from: "user" });

    expect(listMessages).toHaveBeenCalledWith({ projectId: "proj-1", runId: "run-2", agentType: undefined, unreadOnly: undefined });
    expect(listEvents).toHaveBeenCalledWith({ runId: "run-2" });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("No messages for run run-2  bead: task-2.");
    expect(rendered).toContain("No pipeline events found.");
  });

  it("resolves daemon runs by --bead alias", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);

    const listRuns = vi.fn().mockResolvedValue([
      {
        id: "run-2",
        project_id: "proj-1",
        bead_id: "task-2",
        status: "failed",
        branch: "foreman/task-2",
        agent_type: "developer",
        session_key: null,
        worktree_path: null,
        progress: null,
        base_branch: null,
        merge_strategy: null,
        queued_at: "2026-01-01T00:00:00.000Z",
        started_at: "2026-01-01T00:00:00.000Z",
        finished_at: "2026-01-01T00:01:00.000Z",
        created_at: "2026-01-01T00:00:00.000Z",
      },
    ]);
    const listMessages = vi.fn().mockResolvedValue([]);
    mockCreateTrpcClient.mockReturnValue({
      mail: { list: listMessages },
      runs: { list: listRuns },
    });

    await inboxCommand.parseAsync(["--bead", "task-2", "--project-path", projectDir], { from: "user" });

    expect(listMessages).toHaveBeenCalledWith({ projectId: "proj-1", runId: "run-2", agentType: undefined, unreadOnly: undefined });
  });
});
