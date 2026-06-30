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
        body: { kind: "tool", tool: "bash", argsPreview: "npm test", seedId: "task-1" },
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
    expect(rendered).toContain("phase-complete");
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
        payload: { bead_id: "task-1" },
        occurred_at: "2026-01-01T00:00:00.000Z",
      },
      {
        event_id: "evt-2",
        run_id: "run-2",
        event_type: "fail",
        payload: { seedId: "task-2" },
        occurred_at: "2026-01-01T00:02:00.000Z",
      },
    ]);

    await inboxCommand.parseAsync(["--all", "--events", "--events-limit", "1", "--project-path", projectDir], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockListEvents).toHaveBeenCalledWith({ projectId: "proj-1", runId: undefined, limit: 1000 });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("No messages found across all runs.");
    expect(rendered).toContain("Pipeline Events — all runs");
    expect(rendered).toContain("fail — Failed: task-2");
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
    expect(rendered).toContain("No messages for run run-2  bead: task-2.");
    expect(rendered).toContain("No pipeline events found.");
  });

  it("resolves Elixir runs by --bead alias", async () => {
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

    await inboxCommand.parseAsync(["--bead", "task-2", "--project-path", projectDir], { from: "user" });

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
    expect(rendered).toContain("No messages for run run-9  bead: task-9.");
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
        body: { phase: "developer", seedId: "task-1" },
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
});
