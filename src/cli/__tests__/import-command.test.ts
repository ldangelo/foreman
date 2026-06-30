import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockPerformBeadsImport,
  mockResolveProjectPathFromOptions,
  mockListRegisteredProjects,
  mockEnsureCliPostgresPool,
  mockListTasks,
  mockEnsureRunning,
  mockStatus,
  mockSendCommand,
} = vi.hoisted(() => ({
  mockPerformBeadsImport: vi.fn(),
  mockResolveProjectPathFromOptions: vi.fn(),
  mockListRegisteredProjects: vi.fn(),
  mockEnsureCliPostgresPool: vi.fn(),
  mockListTasks: vi.fn(),
  mockEnsureRunning: vi.fn(),
  mockStatus: vi.fn(),
  mockSendCommand: vi.fn(),
}));

vi.mock("../commands/task.js", () => ({
  performBeadsImport: (...args: unknown[]) => mockPerformBeadsImport(...args),
}));

vi.mock("../commands/project-task-support.js", () => ({
  resolveProjectPathFromOptions: (...args: unknown[]) => mockResolveProjectPathFromOptions(...args),
  listRegisteredProjects: (...args: unknown[]) => mockListRegisteredProjects(...args),
  ensureCliPostgresPool: (...args: unknown[]) => mockEnsureCliPostgresPool(...args),
}));

vi.mock("../../lib/db/postgres-adapter.js", () => ({
  PostgresAdapter: vi.fn().mockImplementation(function MockPostgresAdapter() {
    return {
      listTasks: mockListTasks,
    };
  }),
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return {
      ensureRunning: mockEnsureRunning,
      status: mockStatus,
    };
  }),
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn().mockImplementation(function MockElixirServerClient() {
    return {
      sendCommand: mockSendCommand,
    };
  }),
}));

import { importCommand } from "../commands/import.js";

describe("import command", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    mockResolveProjectPathFromOptions.mockResolvedValue("/repo/project");
    mockPerformBeadsImport.mockResolvedValue({
      imported: 2,
      duplicateSkips: 1,
      unsupportedStatusSkips: 0,
      jsonlPath: "/repo/project/.beads/issues.jsonl",
      preview: [
        { bead: { id: "bd-1", title: "One" }, nativeId: "task-11111111", status: "backlog" },
        { bead: { id: "bd-2", title: "Two" }, nativeId: "task-22222222", status: "ready" },
      ],
    });
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766" });
    mockStatus.mockReturnValue({ running: true, url: "http://127.0.0.1:4766" });
    mockSendCommand.mockResolvedValue({ ok: true, events: ["event-1"], projection_version: 1, correlation_id: "corr-1" });
    mockListRegisteredProjects.mockResolvedValue([]);
    mockListTasks.mockResolvedValue([]);
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("renders dry-run preview for beads import", async () => {
    await importCommand.parseAsync(["--dry-run"], { from: "user" });

    expect(mockResolveProjectPathFromOptions).toHaveBeenCalledWith(expect.objectContaining({ dryRun: true }));
    expect(mockPerformBeadsImport).toHaveBeenCalledWith("/repo/project", { dryRun: true });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Dry-run preview");
    expect(rendered).toContain("bd-1");
    expect(rendered).toContain("Would import 2 tasks");
  });

  it("renders successful beads import summary and source path", async () => {
    await importCommand.parseAsync([], { from: "user" });

    expect(mockPerformBeadsImport).toHaveBeenCalledWith("/repo/project", { dryRun: undefined });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Imported 2 tasks");
    expect(rendered).toContain("/repo/project/.beads/issues.jsonl");
  });

  it("fails when --to-elixir is missing both --file and --from-node", async () => {
    await expect(importCommand.parseAsync(["--to-elixir"], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(exitSpy).toHaveBeenCalledWith(1);
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("--to-elixir requires --file <migration.json> or --from-node");
  });

  it("fails closed when --no-auto-start is used and the Elixir server is not already running", async () => {
    mockStatus.mockReturnValue({ running: false, url: "http://127.0.0.1:4766" });
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "foreman", path: "/repo/project", defaultBranch: "main" },
    ]);
    mockListTasks.mockResolvedValue([]);

    await expect(importCommand.parseAsync(["--to-elixir", "--from-node", "--project-path", "/repo/project", "--no-auto-start"], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(mockEnsureRunning).not.toHaveBeenCalled();
    expect(exitSpy).toHaveBeenCalledWith(1);
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Elixir server is not running");
  });

  it("builds a migration payload from the current Node/Postgres project", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "foreman", path: "/repo/project", defaultBranch: undefined },
    ]);
    mockListTasks.mockResolvedValue([
      {
        id: "task-1",
        title: "Imported task",
        description: "Desc",
        status: "ready",
        type: "task",
        priority: 2,
        external_id: "bd-1",
      },
    ]);

    await importCommand.parseAsync(["--to-elixir", "--from-node", "--project-path", "/repo/project"], { from: "user" });

    expect(mockEnsureCliPostgresPool).toHaveBeenCalledWith("/repo/project");
    expect(mockListTasks).toHaveBeenCalledWith("proj-1", { limit: 10000 });
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "migration.import",
      payload: expect.objectContaining({
        migration_id: "node-project-proj-1",
        source: "node-postgres",
        projects: [expect.objectContaining({ id: "proj-1", default_branch: "main" })],
        tasks: [expect.objectContaining({ id: "task-1", project_id: "proj-1", external_id: "bd-1" })],
      }),
    }));
  });

  it("fails when --from-node targets an unregistered project", async () => {
    mockListRegisteredProjects.mockResolvedValue([]);

    await expect(importCommand.parseAsync(["--to-elixir", "--from-node", "--project-path", "/repo/project"], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(exitSpy).toHaveBeenCalledWith(1);
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("is not registered; run 'foreman init' or pass --file");
  });
});
