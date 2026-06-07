import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const mockCreateTaskClient = vi.hoisted(() => vi.fn());
const mockResolveRepoRootProjectPath = vi.hoisted(() => vi.fn());
const mockListRegisteredProjects = vi.hoisted(() => vi.fn());
const mockEnsureCliPostgresPool = vi.hoisted(() => vi.fn());
const mockForemanForProject = vi.hoisted(() => vi.fn());
const mockPostgresForProject = vi.hoisted(() => vi.fn());
const mockVcsCreate = vi.hoisted(() => vi.fn());
const mockMonitorCheckAll = vi.hoisted(() => vi.fn());
const mockMonitorClose = vi.hoisted(() => vi.fn());

vi.mock("../../lib/task-client-factory.js", () => ({
  createTaskClient: mockCreateTaskClient,
}));

vi.mock("../commands/project-task-support.js", () => ({
  ensureCliPostgresPool: mockEnsureCliPostgresPool,
  listRegisteredProjects: mockListRegisteredProjects,
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: mockForemanForProject,
  },
}));

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: {
    forProject: mockPostgresForProject,
  },
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockVcsCreate,
  },
}));

vi.mock("../../orchestrator/monitor.js", () => ({
  Monitor: vi.fn().mockImplementation(function MockMonitor(this: Record<string, unknown>) {
    this.checkAll = mockMonitorCheckAll;
    this.close = mockMonitorClose;
  }),
}));

import { monitorCommand } from "../commands/monitor.js";

describe("foreman monitor project targeting", () => {
  let tempDir: string;
  let originalCwd: string;
  let localStore: {
    getActiveRuns: ReturnType<typeof vi.fn>;
    updateRun: ReturnType<typeof vi.fn>;
    logEvent: ReturnType<typeof vi.fn>;
    getRunProgress: ReturnType<typeof vi.fn>;
    getRunEvents: ReturnType<typeof vi.fn>;
    close: ReturnType<typeof vi.fn>;
  };

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "foreman-monitor-context-"));
    originalCwd = process.cwd();
    vi.clearAllMocks();

    localStore = {
      getActiveRuns: vi.fn().mockResolvedValue([]),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      getRunProgress: vi.fn(),
      getRunEvents: vi.fn(),
      close: vi.fn(),
    };

    mockCreateTaskClient.mockResolvedValue({ taskClient: {} });
    mockMonitorCheckAll.mockResolvedValue({ active: [], completed: [], stuck: [], failed: [] });
    mockMonitorClose.mockResolvedValue?.(undefined);

    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(process, "exit").mockImplementation((code?: number | string | null | undefined) => {
      throw new Error(`process.exit(${code ?? ""}) called`);
    });

    mockForemanForProject.mockReturnValue(localStore);
    mockPostgresForProject.mockReturnValue({ close: vi.fn() });
    mockVcsCreate.mockResolvedValue({});
  });

  afterEach(() => {
    process.chdir(originalCwd);
    vi.restoreAllMocks();
    rmSync(tempDir, { recursive: true, force: true });
  });

  async function runMonitor(): Promise<void> {
    await monitorCommand.parseAsync([], { from: "user" });
  }

  it("resolves registered monitor runs from a non-canonical worktree to the registered project path", async () => {
    const canonicalPath = join(tempDir, "canonical-project");
    const worktreePath = join(tempDir, "worktree-clone");
    mkdirSync(canonicalPath, { recursive: true });
    mkdirSync(worktreePath, { recursive: true });
    process.chdir(worktreePath);

    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "foreman", path: canonicalPath }]);

    await runMonitor();

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockVcsCreate).toHaveBeenCalledWith({ backend: "auto" }, canonicalPath);
    expect(mockCreateTaskClient).toHaveBeenCalledWith(canonicalPath, { ensureBrInstalled: true });
    expect(mockEnsureCliPostgresPool).toHaveBeenCalledWith(canonicalPath);
    expect(mockPostgresForProject).toHaveBeenCalledWith("proj-1");
    expect(mockForemanForProject).not.toHaveBeenCalled();
    expect(mockMonitorCheckAll).toHaveBeenCalledWith({ stuckTimeoutMinutes: 15 });
  });

  it("keeps local unregistered behavior unchanged", async () => {
    mockResolveRepoRootProjectPath.mockResolvedValue(tempDir);
    mockListRegisteredProjects.mockResolvedValue([]);

    await runMonitor();

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockVcsCreate).toHaveBeenCalledWith({ backend: "auto" }, tempDir);
    expect(mockCreateTaskClient).toHaveBeenCalledWith(tempDir, { ensureBrInstalled: true });
    expect(mockForemanForProject).toHaveBeenCalledWith(tempDir);
    expect(mockPostgresForProject).not.toHaveBeenCalled();
    expect(mockEnsureCliPostgresPool).not.toHaveBeenCalled();
    expect(mockMonitorCheckAll).toHaveBeenCalledWith({ stuckTimeoutMinutes: 15 });
  });

  it("keeps outside-a-repo behavior unchanged", async () => {
    mockResolveRepoRootProjectPath.mockRejectedValue(new Error("not a repo"));

    await expect(runMonitor()).rejects.toThrow("process.exit(1) called");

    expect(mockVcsCreate).not.toHaveBeenCalled();
    expect(mockCreateTaskClient).not.toHaveBeenCalled();
    expect(mockForemanForProject).not.toHaveBeenCalled();
    expect(mockPostgresForProject).not.toHaveBeenCalled();
    expect(mockEnsureCliPostgresPool).not.toHaveBeenCalled();
  });
});
