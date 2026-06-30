import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const {
  mockResolveRepoRootProjectPath,
  mockListRegisteredProjects,
  mockCreateTrpcClient,
  mockParseTrd,
  mockAnalyzeParallel,
  mockExecute,
  mockForemanBackendMode,
  mockEnsureRunning,
  mockListTasks,
  mockGetTask,
  mockSendCommand,
  mockRunWithPiSdk,
} = vi.hoisted(() => {
  const mockResolveRepoRootProjectPath = vi.fn();
  const mockListRegisteredProjects = vi.fn();
  const mockCreateTrpcClient = vi.fn();
  const mockParseTrd = vi.fn();
  const mockAnalyzeParallel = vi.fn();
  const mockExecute = vi.fn();
  const mockForemanBackendMode = vi.fn();
  const mockEnsureRunning = vi.fn();
  const mockListTasks = vi.fn();
  const mockGetTask = vi.fn();
  const mockSendCommand = vi.fn();
  const mockRunWithPiSdk = vi.fn();

  return {
    mockResolveRepoRootProjectPath,
    mockListRegisteredProjects,
    mockCreateTrpcClient,
    mockParseTrd,
    mockAnalyzeParallel,
    mockExecute,
    mockForemanBackendMode,
    mockEnsureRunning,
    mockListTasks,
    mockGetTask,
    mockSendCommand,
    mockRunWithPiSdk,
  };
});

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: mockForemanBackendMode,
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return { ensureRunning: mockEnsureRunning };
  }),
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn().mockImplementation(function MockElixirServerClient() {
    return {
      listTasks: mockListTasks,
      getTask: mockGetTask,
      sendCommand: mockSendCommand,
    };
  }),
}));

vi.mock("../../orchestrator/trd-parser.js", () => ({
  parseTrd: mockParseTrd,
}));

vi.mock("../../orchestrator/sprint-parallel.js", () => ({
  analyzeParallel: mockAnalyzeParallel,
}));

vi.mock("../../orchestrator/sling-executor.js", () => ({
  execute: mockExecute,
}));

vi.mock("../../orchestrator/pi-sdk-runner.js", () => ({
  runWithPiSdk: mockRunWithPiSdk,
}));

import { parsePrdReadinessScore, slingCommand } from "../commands/sling.js";

describe("foreman sling command context", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-sling-command-context-"));
    tempDirs.push(dir);
    return dir;
  }

  function createProject(baseDir: string, name: string): string {
    const projectPath = join(baseDir, name);
    mkdirSync(join(projectPath, "docs", "TRD"), { recursive: true });
    writeFileSync(join(projectPath, "docs", "TRD", "sling-trd.md"), "# Sling TRD\n");
    return projectPath;
  }

  async function run(args: string[]): Promise<void> {
    await slingCommand.parseAsync(args, { from: "user" });
  }

  beforeEach(() => {
    vi.clearAllMocks();
    mockResolveRepoRootProjectPath.mockReset();
    mockListRegisteredProjects.mockReset();
    mockCreateTrpcClient.mockReset();
    mockForemanBackendMode.mockReturnValue("node");
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockListTasks.mockResolvedValue([]);
    mockGetTask.mockResolvedValue({ task_id: "foreman-abc12", project_id: "proj-1", title: "Task", status: "backlog" });
    mockSendCommand.mockResolvedValue({ ok: true, events: ["evt-1"], projection_version: 1, correlation_id: "corr-1" });
    mockRunWithPiSdk.mockReset();
    mockRunWithPiSdk.mockResolvedValue({ success: true });
    mockParseTrd.mockReset();
    mockAnalyzeParallel.mockReset();
    mockExecute.mockReset();
    process.exitCode = undefined;

    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);

    mockCreateTrpcClient.mockReturnValue({
      tasks: {
        list: vi.fn(),
        create: vi.fn(),
        update: vi.fn(),
        close: vi.fn(),
        addDependency: vi.fn(),
        get: vi.fn(),
      },
    });
    mockParseTrd.mockReturnValue({
      epic: { title: "Sling Epic" },
      sprints: [],
      acceptanceCriteria: new Map(),
      riskMap: new Map(),
    });
    mockAnalyzeParallel.mockReturnValue({ groups: [], warnings: [] });
    mockExecute.mockResolvedValue({
      native: { created: 0, skipped: 0, failed: 0, errors: [] },
      depErrors: [],
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("resolves a registered sling run from a non-canonical clone/worktree to the registered project path", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");

    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "my-project", path: canonicalPath },
    ]);

    await run([
      "trd",
      "docs/TRD/sling-trd.md",
      "--project",
      "/worktrees/non-canonical-clone",
      "--auto",
    ]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({ project: "/worktrees/non-canonical-clone" });
    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockExecute).toHaveBeenCalledOnce();
    expect(process.exitCode).toBeUndefined();
  });

  it("uses Elixir task writer in default Elixir mode without creating a tRPC client", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");
    mockForemanBackendMode.mockReturnValue("elixir");
    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "my-project", path: canonicalPath },
    ]);
    mockListTasks.mockResolvedValue([{ task_id: "foreman-existing", project_id: "proj-1", external_id: "trd:T0" }]);
    mockExecute.mockImplementation(async (_plan, _parallel, _opts, writer) => {
      await writer.getByExternalId("trd:T0");
      await writer.create({ title: "Task", description: "desc", type: "task", priority: 2, externalId: "trd:T1" });
      await writer.update("foreman-abc12", { title: "Updated", description: "next", priority: 1, force: true });
      await writer.close("foreman-abc12");
      await writer.addDependency("foreman-abc12", "foreman-dep");
      return {
        native: { created: 1, skipped: 0, failed: 0, errors: [] },
        depErrors: [],
      };
    });

    await run([
      "trd",
      "docs/TRD/sling-trd.md",
      "--project",
      "/worktrees/non-canonical-clone",
      "--auto",
    ]);

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockListTasks).toHaveBeenCalled();
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({ command_type: "task.create" }));
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({ command_type: "task.update" }));
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({ command_type: "task.close" }));
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({ command_type: "task.add_dependency" }));
  });

  it("uses the node daemon task writer in node mode", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");
    const list = vi.fn().mockResolvedValue([]);
    const create = vi.fn().mockResolvedValue({ id: "foreman-abc12", external_id: "trd:T1" });
    const update = vi.fn().mockResolvedValue(undefined);
    const close = vi.fn().mockResolvedValue(undefined);
    const addDependency = vi.fn().mockResolvedValue(undefined);
    const get = vi.fn().mockResolvedValue({ id: "foreman-abc12", title: "Updated task" });

    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "my-project", path: canonicalPath },
    ]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list, create, update, close, addDependency, get },
    });
    mockExecute.mockImplementation(async (_plan, _parallel, _opts, writer) => {
      await writer.getByExternalId("trd:T0");
      await writer.create({ title: "Task", description: "desc", type: "task", priority: 2, externalId: "trd:T1" });
      await writer.update("foreman-abc12", { title: "Updated", description: "next", priority: 1, force: true });
      await writer.close("foreman-abc12");
      await writer.addDependency("foreman-abc12", "foreman-dep", "blocks");
      return {
        native: { created: 1, skipped: 0, failed: 0, errors: [] },
        depErrors: [],
      };
    });

    await run([
      "trd",
      "docs/TRD/sling-trd.md",
      "--project",
      "/worktrees/non-canonical-clone",
      "--auto",
    ]);

    expect(mockCreateTrpcClient).toHaveBeenCalledOnce();
    expect(list).toHaveBeenCalledWith({ projectId: "proj-1", limit: 1000 });
    expect(create).toHaveBeenCalledWith(expect.objectContaining({ projectId: "proj-1", title: "Task", externalId: "trd:T1" }));
    expect(update).toHaveBeenCalledWith(expect.objectContaining({ projectId: "proj-1", taskId: "foreman-abc12" }));
    expect(get).toHaveBeenCalledWith({ projectId: "proj-1", taskId: "foreman-abc12" });
    expect(close).toHaveBeenCalledWith({ projectId: "proj-1", taskId: "foreman-abc12" });
    expect(addDependency).toHaveBeenCalledWith({ projectId: "proj-1", fromTaskId: "foreman-abc12", toTaskId: "foreman-dep", type: "blocks" });
  });

  it("keeps local unregistered behavior unchanged", async () => {
    const tmpBase = makeTempDir();
    const localPath = createProject(tmpBase, "local-project");

    mockResolveRepoRootProjectPath.mockResolvedValue(localPath);
    mockListRegisteredProjects.mockResolvedValue([]);

    await expect(
      run([
        "trd",
        "docs/TRD/sling-trd.md",
        "--auto",
      ]),
    ).rejects.toThrow(`Project at '${localPath}' is not registered with the daemon.`);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockExecute).not.toHaveBeenCalled();
  });

  it("sets exitCode when the requested TRD file does not exist", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");

    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);

    await run([
      "trd",
      "docs/TRD/missing-trd.md",
      "--auto",
    ]);

    expect(process.exitCode).toBe(1);
    expect(mockExecute).not.toHaveBeenCalled();
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("SLING-001: TRD file not found");
  });

  it("renders JSON TRD preview without executing writes", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");
    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);

    await run([
      "trd",
      "docs/TRD/sling-trd.md",
      "--json",
    ]);

    expect(mockExecute).not.toHaveBeenCalled();
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain('"sourceTrdPath"');
    expect(rendered).toContain('"epic"');
  });

  it("prints dry-run native preview messaging and skips task creation", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");
    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "my-project", path: canonicalPath },
    ]);

    await run([
      "trd",
      "docs/TRD/sling-trd.md",
      "--dry-run",
      "--auto",
    ]);

    expect(mockExecute).not.toHaveBeenCalled();
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Dry run — native task store preview only; no tasks created.");
    expect(rendered).toContain("Sling now writes native backlog tasks that require explicit approval before dispatch.");
  });

  it("sets exitCode when TRD parsing fails", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");
    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);
    mockParseTrd.mockImplementation(() => {
      throw new Error("bad trd");
    });

    await run([
      "trd",
      "docs/TRD/sling-trd.md",
      "--auto",
    ]);

    expect(process.exitCode).toBe(1);
    expect(mockExecute).not.toHaveBeenCalled();
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("bad trd");
  });

  it("sets exitCode when both --project and --project-path are provided", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");

    await run([
      "trd",
      "docs/TRD/sling-trd.md",
      "--project",
      "my-project",
      "--project-path",
      canonicalPath,
      "--auto",
    ]);

    expect(process.exitCode).toBe(1);
    expect(mockResolveRepoRootProjectPath).not.toHaveBeenCalled();
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("SLING-006");
  });

  it("sets exitCode when --project-path is relative", async () => {
    await run([
      "trd",
      "docs/TRD/sling-trd.md",
      "--project-path",
      "relative/path",
      "--auto",
    ]);

    expect(process.exitCode).toBe(1);
    expect(mockResolveRepoRootProjectPath).not.toHaveBeenCalled();
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("SLING-007");
  });

  it("sets exitCode when the PRD file does not exist", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");
    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);

    await run([
      "prd",
      "docs/missing-PRD.md",
      "--auto",
    ]);

    expect(process.exitCode).toBe(1);
    expect(mockRunWithPiSdk).not.toHaveBeenCalled();
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("SLING-008");
  });

  it("rejects PRDs whose readiness score is below the minimum", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");
    const prdPath = join(canonicalPath, "docs", "PRD.md");
    writeFileSync(prdPath, "# PRD\n\nReadiness Score: 3.5\n");
    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);

    await run([
      "prd",
      "docs/PRD.md",
      "--auto",
    ]);

    expect(process.exitCode).toBe(1);
    expect(mockRunWithPiSdk).not.toHaveBeenCalled();
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("SLING-009");
  });

  it("sets exitCode when PRD generation produces no TRD file", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");
    const prdPath = join(canonicalPath, "docs", "PRD.md");
    writeFileSync(prdPath, "# PRD\n\nReadiness Score: 4.5\n");
    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);

    await run([
      "prd",
      "docs/PRD.md",
      "--auto",
    ]);

    expect(mockRunWithPiSdk).toHaveBeenCalledOnce();
    expect(process.exitCode).toBe(1);
    expect(mockExecute).not.toHaveBeenCalled();
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("SLING-011");
  });

  it("sets exitCode when PRD generation fails", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");
    const prdPath = join(canonicalPath, "docs", "PRD.md");
    writeFileSync(prdPath, "# PRD\n\nReadiness Score: 4.5\n");
    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);
    mockRunWithPiSdk.mockResolvedValue({ success: false, errorMessage: "generator exploded" });

    await run([
      "prd",
      "docs/PRD.md",
      "--auto",
    ]);

    expect(process.exitCode).toBe(1);
    expect(mockExecute).not.toHaveBeenCalled();
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("SLING-010");
  });

  it("surfaces Elixir task writer command failures", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");
    mockForemanBackendMode.mockReturnValue("elixir");
    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "my-project", path: canonicalPath },
    ]);
    mockSendCommand.mockResolvedValueOnce({ ok: false, error: { message: "create failed" } });
    mockExecute.mockImplementation(async (_plan, _parallel, _opts, writer) => {
      await writer.create({ title: "Task", description: "desc", type: "task", priority: 2, externalId: "trd:T1" });
      return {
        native: { created: 0, skipped: 0, failed: 1, errors: [] },
        depErrors: [],
      };
    });

    await expect(run([
      "trd",
      "docs/TRD/sling-trd.md",
      "--project",
      "/worktrees/non-canonical-clone",
      "--auto",
    ])).rejects.toThrow("create failed");
  });

  it("parses readiness scores across supported formats", () => {
    expect(parsePrdReadinessScore("Readiness Score: 4.5")).toBe(4.5);
    expect(parsePrdReadinessScore("readiness_score | 3")).toBe(3);
    expect(parsePrdReadinessScore("**readiness:** 5")).toBe(5);
    expect(parsePrdReadinessScore("No score here")).toBeNull();
  });
});
