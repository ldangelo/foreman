import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Command } from "commander";

const mockResolveRepoRootProjectPath = vi.hoisted(() => vi.fn());
const mockLoadDashboardConfig = vi.hoisted(() => vi.fn());
const mockPollWatchData = vi.hoisted(() => vi.fn());
const mockPollInboxData = vi.hoisted(() => vi.fn());
const mockPollPipelineEvents = vi.hoisted(() => vi.fn());
const mockRenderWatch = vi.hoisted(() => vi.fn());
const mockForemanForProject = vi.hoisted(() => vi.fn());
const mockPrintDeprecationNotice = vi.hoisted(() => vi.fn());

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
}));

vi.mock("../../lib/project-config.js", () => ({
  loadDashboardConfig: mockLoadDashboardConfig,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: mockForemanForProject,
  },
}));

vi.mock("../commands/watch/WatchState.js", () => ({
  initialWatchState: vi.fn().mockReturnValue({}),
  pollWatchData: mockPollWatchData,
  pollInboxData: mockPollInboxData,
  pollPipelineEvents: mockPollPipelineEvents,
  handleWatchKey: vi.fn().mockReturnValue({ render: false, wake: false, quit: false, none: true }),
  nextPanel: vi.fn(),
}));

vi.mock("../commands/watch/render.js", () => ({
  renderWatch: mockRenderWatch,
}));

vi.mock("../commands/cli-output.js", () => ({
  printDeprecationNotice: mockPrintDeprecationNotice,
}));

import { maybePrintDashboardAliasNotice, watchCommand } from "../commands/watch/index.js";

describe("watch command bootstrap", () => {
  it("prints a deprecation notice only for the dashboard alias token", () => {
    maybePrintDashboardAliasNotice(["node", "foreman", "dashboard"]);
    expect(mockPrintDeprecationNotice).toHaveBeenCalledWith("foreman dashboard", "foreman watch");

    mockPrintDeprecationNotice.mockClear();
    maybePrintDashboardAliasNotice(["node", "foreman", "watch"]);
    maybePrintDashboardAliasNotice(["node", "foreman", "watch", "--project", "dashboard"]);
    expect(mockPrintDeprecationNotice).not.toHaveBeenCalled();
  });

  let tempDir: string;
  let originalCwd: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "foreman-watch-command-"));
    originalCwd = process.cwd();
    vi.clearAllMocks();

    mockLoadDashboardConfig.mockReturnValue({ refreshInterval: 5000 });
    mockPollWatchData.mockResolvedValue({
      dashboard: null,
      agents: [{ run: { id: "run-1" } }],
      board: null,
      taskCounts: { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 },
    });
    mockPollInboxData.mockResolvedValue({ messages: [], totalCount: 0, newestId: null });
    mockPollPipelineEvents.mockResolvedValue({ events: [], totalCount: 0, newestId: null });
    mockRenderWatch.mockReturnValue("watch output");

    vi.spyOn(process.stdout, "write").mockImplementation(() => true);
    vi.spyOn(console, "log").mockImplementation(() => undefined);
  });

  afterEach(() => {
    process.chdir(originalCwd);
    rmSync(tempDir, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  it("resolves a registered watch run from a non-canonical worktree before daemon lookup", async () => {
    const canonicalPath = join(tempDir, "canonical-project");
    const worktreePath = join(tempDir, "worktree-clone");
    mkdirSync(canonicalPath, { recursive: true });
    mkdirSync(worktreePath, { recursive: true });
    process.chdir(worktreePath);

    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);

    await watchCommand.parseAsync(["--no-watch", "--no-board", "--no-inbox", "--project", "registered-project"], { from: "user" });

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({ project: "registered-project" });
    expect(mockLoadDashboardConfig).toHaveBeenCalledWith(canonicalPath);
    expect(mockPollWatchData).toHaveBeenCalledWith(canonicalPath, "registered-project");
    expect(mockForemanForProject).not.toHaveBeenCalled();
  });

  it("resolves the monitor alias through the watch command action", async () => {
    const projectPath = join(tempDir, "monitor-project");
    mkdirSync(projectPath, { recursive: true });
    mockResolveRepoRootProjectPath.mockResolvedValue(projectPath);

    const program = new Command("foreman").exitOverride();
    program.addCommand(watchCommand);

    await program.parseAsync([
      "node",
      "foreman",
      "monitor",
      "--no-watch",
      "--no-inbox",
      "--no-events",
      "--project",
      "proj-monitor",
    ]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({ project: "proj-monitor" });
    expect(mockPollWatchData).toHaveBeenCalledWith(projectPath, "proj-monitor");
    expect(mockRenderWatch).toHaveBeenCalledOnce();
    expect(mockPrintDeprecationNotice).not.toHaveBeenCalled();
  });

  it("skips inbox and pipeline event polling when those panels are disabled", async () => {
    const projectPath = join(tempDir, "project");
    mkdirSync(projectPath, { recursive: true });
    mockResolveRepoRootProjectPath.mockResolvedValue(projectPath);

    await watchCommand.parseAsync(["--no-watch", "--no-inbox", "--no-events"], { from: "user" });

    expect(mockLoadDashboardConfig).toHaveBeenCalledWith(projectPath);
    expect(mockPollWatchData).toHaveBeenCalledWith(projectPath, undefined);
    expect(mockForemanForProject).not.toHaveBeenCalled();
    expect(mockPollInboxData).not.toHaveBeenCalled();
    expect(mockPollPipelineEvents).not.toHaveBeenCalled();
    expect(mockRenderWatch).toHaveBeenCalledOnce();
    expect(vi.mocked(console.log)).toHaveBeenCalledWith("watch output");
  });

  it("falls back to default one-shot inbox and event limits for zero values", async () => {
    const projectPath = join(tempDir, "project-limits");
    mkdirSync(projectPath, { recursive: true });
    mockResolveRepoRootProjectPath.mockResolvedValue(projectPath);
    const store = { close: vi.fn() };
    mockForemanForProject.mockReturnValue(store);

    await watchCommand.parseAsync([
      "--no-watch",
      "--inbox-limit", "0",
      "--events-limit", "0",
      "--project", "proj-1",
    ], { from: "user" });

    expect(mockPollWatchData).toHaveBeenCalledWith(projectPath, "proj-1");
    expect(mockForemanForProject).toHaveBeenCalledWith(projectPath);
    expect(mockPollInboxData).toHaveBeenCalled();
    expect(mockPollPipelineEvents).toHaveBeenCalled();
    expect(mockPollInboxData.mock.calls[0]?.slice(1)).toEqual([null, 5, ["run-1"], projectPath, "proj-1"]);
    expect(mockPollPipelineEvents.mock.calls[0]?.slice(1)).toEqual([null, 5, ["run-1"], projectPath, "proj-1"]);
    expect(store.close).toHaveBeenCalled();
  });

  it("renders one-shot events without creating a store when inbox is disabled", async () => {
    const projectPath = join(tempDir, "project-events-only");
    mkdirSync(projectPath, { recursive: true });
    mockResolveRepoRootProjectPath.mockResolvedValue(projectPath);
    mockPollPipelineEvents.mockResolvedValue({
      events: [
        { id: "evt-2", createdAt: "2026-01-02T00:00:00.000Z" },
        { id: "evt-1", createdAt: "2026-01-01T00:00:00.000Z" },
      ],
      totalCount: 2,
      newestId: "evt-2",
    });

    await watchCommand.parseAsync(["--no-watch", "--no-inbox", "--project", "proj-2"], { from: "user" });

    expect(mockForemanForProject).not.toHaveBeenCalled();
    expect(mockPollInboxData).not.toHaveBeenCalled();
    expect(mockPollPipelineEvents).toHaveBeenCalledWith(null, null, 5, ["run-1"], projectPath, "proj-2");
    const renderedState = mockRenderWatch.mock.calls[0]?.[0];
    expect(renderedState.events).toEqual(expect.objectContaining({
      totalCount: 2,
      newestTimestamp: "2026-01-02T00:00:00.000Z",
      oldestTimestamp: "2026-01-01T00:00:00.000Z",
    }));
  });

  it("propagates one-shot inbox timestamps into rendered state", async () => {
    const projectPath = join(tempDir, "project-inbox-timestamps");
    mkdirSync(projectPath, { recursive: true });
    mockResolveRepoRootProjectPath.mockResolvedValue(projectPath);
    const store = { close: vi.fn() };
    mockForemanForProject.mockReturnValue(store);
    mockPollInboxData.mockResolvedValue({
      messages: [
        { message: { id: "msg-2", created_at: "2026-01-02T00:00:00.000Z" } },
        { message: { id: "msg-1", created_at: "2026-01-01T00:00:00.000Z" } },
      ],
      totalCount: 2,
      newestId: "msg-2",
    });
    mockPollPipelineEvents.mockResolvedValue({ events: [], totalCount: 0, newestId: null });

    await watchCommand.parseAsync(["--no-watch", "--project", "proj-3"], { from: "user" });

    const renderedState = mockRenderWatch.mock.calls[0]?.[0];
    expect(renderedState.inbox).toEqual(expect.objectContaining({
      totalCount: 2,
      newestTimestamp: "2026-01-02T00:00:00.000Z",
      oldestTimestamp: "2026-01-01T00:00:00.000Z",
    }));
    expect(store.close).toHaveBeenCalled();
  });
});
