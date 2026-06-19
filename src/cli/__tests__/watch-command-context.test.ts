import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const mockResolveRepoRootProjectPath = vi.hoisted(() => vi.fn());
const mockLoadDashboardConfig = vi.hoisted(() => vi.fn());
const mockPollWatchData = vi.hoisted(() => vi.fn());
const mockPollInboxData = vi.hoisted(() => vi.fn());
const mockPollPipelineEvents = vi.hoisted(() => vi.fn());
const mockRenderWatch = vi.hoisted(() => vi.fn());
const mockForemanForProject = vi.hoisted(() => vi.fn());

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

import { watchCommand } from "../commands/watch/index.js";

describe("watch command bootstrap", () => {
  let tempDir: string;
  let originalCwd: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "foreman-watch-command-"));
    originalCwd = process.cwd();
    vi.clearAllMocks();

    mockLoadDashboardConfig.mockReturnValue({ refreshInterval: 5000 });
    mockPollWatchData.mockResolvedValue({
      dashboard: null,
      agents: [],
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
});
