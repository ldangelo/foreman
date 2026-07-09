import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const {
  mockResolveRepoRootProjectPath,
  mockListRegisteredProjects,
  mockCreateTrpcClient,
  mockEnsureRunning,
  mockSendCommand,
  mockListInbox,
  mockListRuns,
  mockListEvents,
} = vi.hoisted(() => ({
  mockResolveRepoRootProjectPath: vi.fn(),
  mockListRegisteredProjects: vi.fn(),
  mockCreateTrpcClient: vi.fn(),
  mockEnsureRunning: vi.fn(),
  mockSendCommand: vi.fn(),
  mockListInbox: vi.fn(),
  mockListRuns: vi.fn(),
  mockListEvents: vi.fn(),
}));

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
  listRegisteredProjects: mockListRegisteredProjects,
  requireProjectOrAllInMultiMode: vi.fn().mockResolvedValue(undefined),
  ensureCliPostgresPool: vi.fn(),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return { ensureRunning: mockEnsureRunning };
  }),
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn().mockImplementation(function MockElixirServerClient() {
    return {
      sendCommand: mockSendCommand,
      listInbox: mockListInbox,
      listRuns: mockListRuns,
      listEvents: mockListEvents,
    };
  }),
}));

import { inboxCommand, resolveDaemonInboxContext } from "../commands/inbox.js";

describe("inbox Elixir context", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-inbox-elixir-context-"));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    process.env.FOREMAN_BACKEND = "elixir";
    vi.clearAllMocks();
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockListInbox.mockResolvedValue([]);
    mockListRuns.mockResolvedValue([]);
    mockListEvents.mockResolvedValue([]);
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => undefined) as typeof process.exit);
  });

  afterEach(() => {
    delete process.env.FOREMAN_BACKEND;
    vi.restoreAllMocks();
    for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
    tempDirs.length = 0;
  });

  it("resolves inbox context through Elixir without creating a tRPC client", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);

    const daemon = await resolveDaemonInboxContext(projectDir);

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(daemon).toEqual({
      backend: "elixir",
      client: expect.any(Object),
      projectId: "proj-1",
    });
  });

  it("sends inbox mail through Elixir command routing in default Elixir mode", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockSendCommand.mockResolvedValue({ ok: true, events: ["evt-1"], projection_version: 1, correlation_id: "corr-1" });

    await inboxCommand.parseAsync([
      "send",
      "--run-id",
      "run-1",
      "--from",
      "developer",
      "--to",
      "foreman",
      "--subject",
      "phase-complete",
      "--body",
      "{}",
    ], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "inbox.send",
      payload: expect.objectContaining({
        project_id: "proj-1",
        run_id: "run-1",
        sender_agent_type: "developer",
        recipient_agent_type: "foreman",
        subject: "phase-complete",
        body: "{}",
      }),
    }));
  });

  it("falls back to FOREMAN_RUN_ID for inbox send", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    process.env.FOREMAN_RUN_ID = "run-from-env";
    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockSendCommand.mockResolvedValue({ ok: true, events: ["evt-1"], projection_version: 1, correlation_id: "corr-1" });

    await inboxCommand.parseAsync([
      "send",
      "--from",
      "developer",
      "--to",
      "foreman",
      "--subject",
      "phase-complete",
      "--body",
      "{\"ok\":true}",
    ], { from: "user" });

    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      payload: expect.objectContaining({ run_id: "run-from-env", body: '{"ok":true}' }),
    }));
    delete process.env.FOREMAN_RUN_ID;
  });

  it("rejects inbox send when no run id is available", async () => {
    await inboxCommand.parseAsync([
      "send",
      "--from",
      "developer",
      "--to",
      "foreman",
      "--subject",
      "phase-complete",
    ], { from: "user" });

    expect(mockSendCommand).not.toHaveBeenCalled();
    expect(vi.mocked(process.stderr.write)).toHaveBeenCalledWith(
      "inbox send error: --run-id is required (or set FOREMAN_RUN_ID)\n",
    );
    expect(process.exit).toHaveBeenCalledWith(1);
  });

  it("rejects inbox send when the body is not valid JSON", async () => {
    await inboxCommand.parseAsync([
      "send",
      "--run-id",
      "run-1",
      "--from",
      "developer",
      "--to",
      "foreman",
      "--subject",
      "phase-complete",
      "--body",
      "{broken",
    ], { from: "user" });

    expect(mockSendCommand).not.toHaveBeenCalled();
    const rendered = vi.mocked(process.stderr.write).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("--body must be valid JSON");
  });

  it("surfaces inbox send errors when the project is not registered", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([]);

    await inboxCommand.parseAsync([
      "send",
      "--run-id",
      "run-1",
      "--from",
      "developer",
      "--to",
      "foreman",
      "--subject",
      "phase-complete",
    ], { from: "user" });

    expect(mockSendCommand).not.toHaveBeenCalled();
    const rendered = vi.mocked(process.stderr.write).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("not registered with the daemon");
  });

  it("surfaces Elixir inbox send command failures", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockSendCommand.mockResolvedValue({ ok: false, error: { message: "send failed" } });

    await inboxCommand.parseAsync([
      "send",
      "--run-id",
      "run-1",
      "--from",
      "developer",
      "--to",
      "foreman",
      "--subject",
      "phase-complete",
    ], { from: "user" });

    const rendered = vi.mocked(process.stderr.write).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("inbox send error: send failed");
  });

  it("renders one-shot Elixir inbox output for a run without creating a tRPC client", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListRuns.mockResolvedValue([
      { id: "run-1", run_id: "run-1", project_id: "proj-1", task_id: "task-1", status: "running", created_at: "2026-01-01T00:00:00.000Z" },
    ]);
    mockListInbox.mockResolvedValue([
      {
        message_id: "msg-1",
        run_id: "run-1",
        sender_agent_type: "developer",
        recipient_agent_type: "foreman",
        subject: "phase-complete",
        body: { kind: "tool", tool: "bash", argsPreview: "npm test", taskId: "task-1" },
        unread: true,
        created_at: "2026-01-01T00:00:00.000Z",
      },
    ]);

    await inboxCommand.parseAsync(["--run", "run-1", "--project-path", projectDir], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockListInbox).toHaveBeenCalledWith({ projectId: "proj-1", runId: "run-1", unread: undefined, limit: 50 });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Inbox — run: run-1");
    expect(rendered).toContain("task-1");
    expect(rendered).toContain("bash");
  });

  it("renders Elixir pipeline events in one-shot mode", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListRuns.mockResolvedValue([
      { id: "run-1", run_id: "run-1", project_id: "proj-1", task_id: "task-1", status: "completed", created_at: "2026-01-01T00:00:00.000Z" },
    ]);
    mockListInbox.mockResolvedValue([]);
    mockListEvents.mockResolvedValue([
      {
        event_id: "evt-1",
        run_id: "run-1",
        event_type: "phase-complete",
        payload: { phase: "developer" },
        occurred_at: "2026-01-01T00:00:00.000Z",
      },
    ]);

    await inboxCommand.parseAsync(["--run", "run-1", "--events", "--project-path", projectDir], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockListEvents).toHaveBeenCalledWith({ projectId: "proj-1", runId: "run-1", limit: 1000 });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("No messages for run run-1");
    expect(rendered).toContain("Pipeline Events — run: ");
    expect(rendered).toContain("COMPLETED");
    expect(rendered).toContain("developer");
  });

  it("renders Elixir all-run pipeline events sorted and limited", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListRuns.mockResolvedValue([
      { id: "run-1", run_id: "run-1", project_id: "proj-1", task_id: "task-1", status: "completed", created_at: "2026-01-01T00:00:00.000Z" },
      { id: "run-2", run_id: "run-2", project_id: "proj-1", task_id: "task-2", status: "failed", created_at: "2026-01-01T00:01:00.000Z" },
    ]);
    mockListInbox.mockResolvedValue([]);
    mockListEvents.mockResolvedValue([
      {
        event_id: "evt-1",
        run_id: "run-1",
        event_type: "dispatch",
        payload: { task_id: "task-1" },
        occurred_at: "2026-01-01T00:00:00.000Z",
      },
      {
        event_id: "evt-2",
        run_id: "run-2",
        event_type: "fail",
        payload: { taskId: "task-2" },
        occurred_at: "2026-01-01T00:02:00.000Z",
      },
    ]);

    await inboxCommand.parseAsync(["--all", "--events", "--events-limit", "1", "--project-path", projectDir], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockListEvents).toHaveBeenCalledWith({ projectId: "proj-1", runId: undefined, limit: 1000 });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Pipeline Events — all runs");
  });

  it("resolves Elixir runs by --task and prints the no-events branch", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListRuns.mockResolvedValue([
      { id: "run-1", run_id: "run-1", project_id: "proj-1", task_id: "task-1", status: "completed", created_at: "2026-01-01T00:00:00.000Z" },
      { id: "run-2", run_id: "run-2", project_id: "proj-1", task_id: "task-2", status: "failed", created_at: "2026-01-01T00:01:00.000Z" },
    ]);
    mockListInbox.mockResolvedValue([]);
    mockListEvents.mockResolvedValue([]);

    await inboxCommand.parseAsync(["--task", "task-2", "--events", "--project-path", projectDir], { from: "user" });

    expect(mockListInbox).toHaveBeenCalledWith({ projectId: "proj-1", runId: "run-2", unread: undefined, limit: 50 });
    expect(mockListEvents).toHaveBeenCalledWith({ projectId: "proj-1", runId: "run-2", limit: 1000 });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("FAILED");
    expect(rendered).toContain("task-2");
  });

  it("resolves Elixir runs by --task alias", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListRuns.mockResolvedValue([
      { id: "run-2", run_id: "run-2", project_id: "proj-1", task_id: "task-2", status: "failed", created_at: "2026-01-01T00:01:00.000Z" },
    ]);
    mockListInbox.mockResolvedValue([]);

    await inboxCommand.parseAsync(["--task", "task-2", "--project-path", projectDir], { from: "user" });

    expect(mockListInbox).toHaveBeenCalledWith({ projectId: "proj-1", runId: "run-2", unread: undefined, limit: 50 });
  });

  it("prints the Elixir all-run unread empty state for agent filters", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListInbox.mockResolvedValue([]);

    await inboxCommand.parseAsync(["--all", "--unread", "--agent", "qa", "--project-path", projectDir], { from: "user" });

    expect(mockListInbox).toHaveBeenCalledWith({ projectId: "proj-1", runId: undefined, unread: true, limit: 50 });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("No unread messages found across all runs (agent: qa).");
  });

  it("defaults to the latest Elixir run when no selector is provided", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListRuns.mockResolvedValue([
      { id: "run-9", run_id: "run-9", project_id: "proj-1", task_id: "task-9", status: "running", created_at: "2026-01-02T00:00:00.000Z" },
      { id: "run-8", run_id: "run-8", project_id: "proj-1", task_id: "task-8", status: "completed", created_at: "2026-01-01T00:00:00.000Z" },
    ]);
    mockListInbox.mockResolvedValue([]);

    await inboxCommand.parseAsync(["--project-path", projectDir], { from: "user" });

    expect(mockListInbox).toHaveBeenCalledWith({ projectId: "proj-1", runId: "run-9", unread: undefined, limit: 50 });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("RUNNING");
    expect(rendered).toContain("task-9");
  });

  it("marks shown Elixir all-run messages as read and prints the analyzed summary", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListRuns.mockResolvedValue([
      { id: "run-1", run_id: "run-1", project_id: "proj-1", task_id: "task-1", status: "completed", created_at: "2026-01-01T00:00:00.000Z" },
    ]);
    mockListInbox.mockResolvedValue([
      {
        message_id: "msg-1",
        run_id: "run-1",
        sender_agent_type: "developer",
        recipient_agent_type: "foreman",
        subject: "phase-complete",
        body: { phase: "developer", taskId: "task-1" },
        unread: true,
        created_at: "2026-01-01T00:00:00.000Z",
      },
    ]);

    await inboxCommand.parseAsync(["--all", "--ack", "--project-path", projectDir], { from: "user" });

    expect(mockListInbox).toHaveBeenCalledWith({ projectId: "proj-1", runId: undefined, unread: undefined, limit: 50 });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("1 message(s) analyzed. Use --full for complete raw payloads.");
    expect(rendered).toContain("Marked 1 message(s) as read.");
  });

  it("shows active in_progress runs in the all-scope summary even when the inbox is empty", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListRuns.mockResolvedValue([
      {
        id: "run-active-123456",
        run_id: "run-active-123456",
        project_id: "proj-1",
        task_id: "task-active",
        status: "in_progress",
        created_at: "2026-01-01T00:05:00.000Z",
      },
    ]);
    mockListInbox.mockResolvedValue([]);

    await inboxCommand.parseAsync(["--all", "--project-path", projectDir], { from: "user" });

    expect(mockListInbox).toHaveBeenCalledWith({ projectId: "proj-1", runId: undefined, unread: undefined, limit: 50 });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("task-active");
    expect(rendered).toContain("run-active");
    expect(rendered).toContain("in_progress");
    expect(rendered).not.toContain("No messages found across all runs");
  });

  it("keeps active in_progress tasks visible beside historical all-scope messages", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListRuns.mockResolvedValue([
      {
        id: "run-historical-123456",
        run_id: "run-historical-123456",
        project_id: "proj-1",
        task_id: "task-historical",
        status: "completed",
        created_at: "2026-01-01T00:00:00.000Z",
      },
      {
        id: "run-active-654321",
        run_id: "run-active-654321",
        project_id: "proj-1",
        task_id: "task-active",
        status: "in_progress",
        created_at: "2026-01-01T00:10:00.000Z",
      },
    ]);
    mockListInbox.mockResolvedValue([
      {
        message_id: "msg-historical",
        run_id: "run-historical-123456",
        sender_agent_type: "qa",
        recipient_agent_type: "foreman",
        subject: "phase-complete",
        body: { taskId: "task-historical", phase: "qa", kind: "verdict", status: "completed", message: "historical done" },
        unread: false,
        created_at: "2026-01-01T00:01:00.000Z",
      },
    ]);

    await inboxCommand.parseAsync(["--all", "--project-path", projectDir], { from: "user" });

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("task-historical");
    expect(rendered).toContain("historical done");
    expect(rendered).toContain("task-active");
    expect(rendered).toContain("in_progress");
  });

  it("renders a scriptable all-scope summary with task, phase, run, date/time, activity, and status text", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListRuns.mockResolvedValue([
      {
        id: "run-summary-123456",
        run_id: "run-summary-123456",
        project_id: "proj-1",
        task_id: "task-summary",
        status: "running",
        created_at: "2026-01-01T00:00:00.000Z",
      },
      {
        id: "run-newer-123456",
        run_id: "run-newer-123456",
        project_id: "proj-1",
        task_id: "task-newer",
        status: "running",
        created_at: "2026-01-01T00:04:00",
      },
    ]);
    mockListInbox.mockResolvedValue([
      {
        message_id: "msg-summary",
        run_id: "run-summary-123456",
        sender_agent_type: "developer",
        recipient_agent_type: "qa",
        subject: "status",
        body: {
          taskId: "task-summary",
          phase: "qa",
          kind: "progress",
          status: "needs-review",
          message: "waiting on qa",
          argsPreview: "vitest run src/cli/__tests__/inbox-elixir-context.test.ts",
        },
        unread: true,
        created_at: "2026-01-01T00:02:00.000Z",
      },
      {
        message_id: "msg-newer",
        run_id: "run-newer-123456",
        sender_agent_type: "developer",
        recipient_agent_type: "qa",
        subject: "status",
        body: {
          taskId: "task-newer",
          phase: "reviewer",
          kind: "progress",
          status: "newer-run",
          message: "newer run first",
        },
        unread: true,
        created_at: "2026-01-01T00:05:00",
      },
    ]);

    await inboxCommand.parseAsync(["--all", "--project-path", projectDir], { from: "user" });

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Run Summary");
    expect(rendered).toContain("Recent Activity");
    expect(rendered).toContain("task-summary");
    expect(rendered).toContain("run=run-summ");
    expect(rendered).toContain("status=running");
    expect(rendered).toContain("phase=qa");
    expect(rendered).toContain("status=needs-review");
    expect(rendered).toContain("waiting on qa");
    expect(rendered).toContain("args: vitest run src/cli/__tests__/inbox-elixir-context.test.ts");
    expect(rendered).toContain("LAST");
    expect(rendered).toContain("2026-01-01 00:05:00");
    const table = rendered.slice(rendered.indexOf("FOREMAN INBOX"));
    expect(table.indexOf("task-newer")).toBeGreaterThanOrEqual(0);
    expect(table.indexOf("task-summary")).toBeGreaterThanOrEqual(0);
    expect(table.indexOf("task-newer")).toBeLessThan(table.indexOf("task-summary"));
  });

  it("keeps legacy --task with --events on the task drilldown path", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListRuns.mockResolvedValue([
      { id: "run-other", run_id: "run-other", project_id: "proj-1", task_id: "task-other", status: "completed", created_at: "2026-01-01T00:00:00.000Z" },
      { id: "run-task-42", run_id: "run-task-42", project_id: "proj-1", task_id: "task-42", status: "running", created_at: "2026-01-01T00:01:00.000Z" },
    ]);
    mockListInbox.mockResolvedValue([
      {
        message_id: "msg-task-42",
        run_id: "run-task-42",
        sender_agent_type: "developer",
        recipient_agent_type: "qa",
        subject: "phase-status",
        body: { taskId: "task-42", phase: "qa", kind: "progress", status: "running", message: "qa is reviewing" },
        unread: true,
        created_at: "2026-01-01T00:02:00.000Z",
      },
    ]);
    mockListEvents.mockResolvedValue([
      {
        event_id: "evt-task-42",
        run_id: "run-task-42",
        event_type: "PhaseStarted",
        payload: { task_id: "task-42", phase_id: "qa", run_id: "run-task-42" },
        occurred_at: "2026-01-01T00:03:00.000Z",
      },
    ]);

    await inboxCommand.parseAsync(["--task", "task-42", "--events", "--project-path", projectDir], { from: "user" });

    expect(mockListInbox).toHaveBeenCalledWith({ projectId: "proj-1", runId: "run-task-42", unread: undefined, limit: 50 });
    expect(mockListEvents).toHaveBeenCalledWith({ projectId: "proj-1", runId: "run-task-42", limit: 1000 });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Inbox Messages — run: ");
    expect(rendered).toContain("run-task-42");
    expect(rendered).toContain("task-42");
    expect(rendered).toContain("qa is reviewing");
    expect(rendered).toContain("Pipeline Events — run: ");
    expect(rendered).not.toContain("Pipeline Events — all runs");
  });

  it("honors task drilldown --limit and --events-limit in rendered detail", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListRuns.mockResolvedValue([
      {
        id: "run-task-limit",
        run_id: "run-task-limit",
        project_id: "proj-1",
        task_id: "task-limit",
        status: "running",
        created_at: "2026-01-01T00:00:00.000Z",
      },
    ]);
    mockListInbox.mockResolvedValue([
      {
        message_id: "msg-stale",
        run_id: "run-task-limit",
        sender_agent_type: "developer",
        recipient_agent_type: "qa",
        subject: "stale-message",
        body: { taskId: "task-limit", phase: "qa", message: "stale message hidden" },
        unread: false,
        created_at: "2026-01-01T00:01:00.000Z",
      },
      {
        message_id: "msg-latest",
        run_id: "run-task-limit",
        sender_agent_type: "qa",
        recipient_agent_type: "foreman",
        subject: "latest-message",
        body: { taskId: "task-limit", phase: "qa", message: "latest message visible" },
        unread: true,
        created_at: "2026-01-01T00:03:00.000Z",
      },
    ]);
    mockListEvents.mockResolvedValue([
      {
        event_id: "evt-stale",
        run_id: "run-task-limit",
        event_type: "PhaseStarted",
        payload: { task_id: "task-limit", phase_id: "stale-phase", run_id: "run-task-limit" },
        occurred_at: "2026-01-01T00:02:00.000Z",
      },
      {
        event_id: "evt-latest",
        run_id: "run-task-limit",
        event_type: "PhaseCompleted",
        payload: { task_id: "task-limit", phase_id: "latest-phase", status: "completed", run_id: "run-task-limit" },
        occurred_at: "2026-01-01T00:04:00.000Z",
      },
    ]);

    await inboxCommand.parseAsync(["task", "task-limit", "--limit", "1", "--events-limit", "1", "--project-path", projectDir], { from: "user" });

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("latest message visible");
    expect(rendered).not.toContain("stale message hidden");
    expect(rendered).toContain("latest-phase");
    expect(rendered).not.toContain("stale-phase");
  });

  it("exposes follow and optional detail section flags in task and run help", () => {
    for (const commandName of ["task", "run"]) {
      const detailCommand = inboxCommand.commands.find((command) => command.name() === commandName);

      expect(detailCommand, `${commandName} command should be registered`).toBeDefined();
      const help = detailCommand?.helpInformation() ?? "";
      expect(help).toContain("--follow");
      expect(help).toContain("--logs");
      expect(help).toContain("--reports");
      expect(help).toContain("--files");
    }
  });

  it("renders absent optional artifact sections for run detail without crashing", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockListRuns.mockResolvedValue([
      {
        id: "run-without-artifacts",
        run_id: "run-without-artifacts",
        project_id: "proj-1",
        task_id: "task-without-artifacts",
        status: "running",
        created_at: "2026-01-01T00:00:00.000Z",
      },
    ]);
    mockListInbox.mockResolvedValue([]);
    mockListEvents.mockResolvedValue([]);

    await inboxCommand.parseAsync(["run", "run-without-artifacts", "--logs", "--reports", "--files", "--project-path", projectDir], { from: "user" });

    expect(process.exit).not.toHaveBeenCalled();
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Logs");
    expect(rendered).toContain("No logs found");
    expect(rendered).toContain("Reports");
    expect(rendered).toContain("No reports found");
    expect(rendered).toContain("Files");
    expect(rendered).toContain("No files found");
  });
});
