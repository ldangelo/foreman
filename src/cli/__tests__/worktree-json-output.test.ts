import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

let exitSpy: ReturnType<typeof vi.spyOn>;

const {
  mockCreateVcs,
  mockGetRepoRoot,
  mockListWorkspaces,
  mockStoreClose,
  mockGetRunsForSeed,
  MockForemanStore,
} = vi.hoisted(() => {
  const mockGetRepoRoot = vi.fn().mockResolvedValue("/mock/project");
  const mockListWorkspaces = vi.fn().mockResolvedValue([]);
  const mockCreateVcs = vi.fn().mockResolvedValue({
    getRepoRoot: mockGetRepoRoot,
    listWorkspaces: mockListWorkspaces,
  });

  const mockStoreClose = vi.fn();
  const mockGetRunsForSeed = vi.fn().mockReturnValue([]);
  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.getRunsForSeed = mockGetRunsForSeed;
    this.close = mockStoreClose;
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (MockForemanStore as any).forProject = vi.fn(() => new (MockForemanStore as any)());

  return {
    mockCreateVcs,
    mockGetRepoRoot,
    mockListWorkspaces,
    mockStoreClose,
    mockGetRunsForSeed,
    MockForemanStore,
  };
});

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockCreateVcs,
  },
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../../lib/archive-reports.js", () => ({
  archiveWorktreeReports: vi.fn(),
}));

import { worktreeCommand } from "../commands/worktree.js";

async function runCommand(args: string[]): Promise<{ stdout: string; stderr: string; error?: Error }> {
  const stdoutLines: string[] = [];
  const stderrLines: string[] = [];
  const origLog = console.log;
  const origWarn = console.warn;
  const origError = console.error;
  let error: Error | undefined;

  console.log = (...a: unknown[]) => stdoutLines.push(a.join(" "));
  console.warn = (...a: unknown[]) => stderrLines.push(a.join(" "));
  console.error = (...a: unknown[]) => stderrLines.push(a.join(" "));

  try {
    await worktreeCommand.parseAsync(["node", "foreman", ...args]);
  } catch (caught) {
    error = caught as Error;
  } finally {
    console.log = origLog;
    console.warn = origWarn;
    console.error = origError;
  }

  return { stdout: stdoutLines.join("\n"), stderr: stderrLines.join("\n"), error };
}

describe("worktree list --json", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    exitSpy = vi.spyOn(process, "exit").mockImplementation((code?: number | string | null | undefined) => {
      throw new Error(`process.exit unexpectedly called with ${JSON.stringify(code ?? "")}`);
    });

    mockGetRepoRoot.mockResolvedValue("/mock/project");
    mockCreateVcs.mockResolvedValue({
      getRepoRoot: mockGetRepoRoot,
      listWorkspaces: mockListWorkspaces,
    });
    mockListWorkspaces.mockResolvedValue([]);
    mockGetRunsForSeed.mockReturnValue([]);
  });

  afterEach(() => {
    exitSpy.mockRestore();
  });

  it("outputs valid JSON for successful worktree listing", async () => {
    mockListWorkspaces.mockResolvedValue([
      {
        path: "/mock/project/.foreman-worktrees/bd-123",
        branch: "foreman/bd-123",
        head: "abc123",
        bare: false,
      },
    ]);
    mockGetRunsForSeed.mockReturnValue([
      {
        id: "run-1",
        project_id: "proj-1",
        seed_id: "bd-123",
        agent_type: "claude-code",
        session_key: null,
        worktree_path: "/mock/project/.foreman-worktrees/bd-123",
        status: "completed",
        started_at: "2026-04-09T10:00:00Z",
        completed_at: "2026-04-09T10:05:00Z",
        created_at: "2026-04-09T09:55:00Z",
        progress: null,
      },
    ]);

    const { stdout, stderr } = await runCommand(["list", "--json"]);
    const data = JSON.parse(stdout);

    expect(stderr).toBe("");
    expect(data).toHaveLength(1);
    expect(data[0].seedId).toBe("bd-123");
    expect(data[0].runStatus).toBe("completed");
  });

  it("emits a machine-readable error when repo root resolution fails", async () => {
    mockGetRepoRoot.mockRejectedValue(new Error("not in a git repository"));

    const { stderr, error } = await runCommand(["list", "--json"]);

    expect(error?.message).toMatch(/process\.exit/);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(JSON.parse(stderr.split("\n")[0] ?? "")).toEqual({ error: "not in a git repository" });
  });

  it("emits a machine-readable error when worktree listing fails", async () => {
    mockListWorkspaces.mockRejectedValue(new Error("failed to list workspaces"));

    const { stderr, error } = await runCommand(["list", "--json"]);

    expect(error?.message).toMatch(/process\.exit/);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(JSON.parse(stderr.split("\n")[0] ?? "")).toEqual({ error: "failed to list workspaces" });
  });
});
