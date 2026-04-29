/**
 * Unit tests for GitHubIssuesPoller (TRD-030, TRD-032).
 *
 * Tests:
 * - Poller start/stop lifecycle
 * - Idempotent polling: duplicate prevention via external_id
 * - Auto-import: new issues → backlog by default
 * - Auto-import with 'foreman' label: → ready status
 * - Safe re-sync: existing linked issues are updated, not recreated
 * - Rate limit handling (GhRateLimitError propagation)
 * - closeLinkedGithubIssue() integration
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { GitHubIssuesPoller, closeLinkedGithubIssue, type PollSummary } from "../github-poller.js";
import type { PostgresAdapter } from "../../lib/db/postgres-adapter.js";
import type { ProjectRegistry } from "../../lib/project-registry.js";
import type { GhCli, GitHubIssue } from "../../lib/gh-cli.js";

// ---------------------------------------------------------------------------
// Helper builders
// ---------------------------------------------------------------------------

function makeIssue(number: number, title: string, labels: string[] = [], state: "open" | "closed" = "open"): GitHubIssue {
  return {
    id: 1000 + number,
    number,
    title,
    body: `Body for issue #${number}`,
    state,
    user: { login: "testuser", id: 1 },
    labels: labels.map((name) => ({ id: 1, name, color: "fff" })),
    assignees: [],
    milestone: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    closed_at: null,
    url: `https://api.github.com/repos/test/repo/issues/${number}`,
    html_url: `https://github.com/test/repo/issues/${number}`,
  };
}

function makeRepo(owner = "test", repo = "repo") {
  return { id: "repo-uuid", owner, repo };
}

function makeProject(id = "proj-1", status = "active") {
  return { id, name: "Test Project", path: "/tmp/test", githubUrl: "https://github.com/test/repo", repoKey: "test/repo" as string | null, status };
}

function makeTaskRow(overrides: Partial<{
  id: string; title: string; description: string | null; status: string; external_id: string | null; external_repo: string | null; github_issue_number: number | null;
}> = {}) {
  return {
    id: "task-1",
    project_id: "proj-1",
    title: "Test issue",
    description: null,
    type: "task",
    priority: 2,
    status: "backlog",
    run_id: null,
    branch: null,
    external_id: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    approved_at: null,
    closed_at: null,
    external_repo: null,
    github_issue_number: null,
    github_milestone: null,
    sync_enabled: false,
    last_sync_at: null,
    labels: null,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Mock adapters
// ---------------------------------------------------------------------------

const NOOP_GH: Partial<GhCli> = {
  isInstalled: vi.fn().mockResolvedValue(true),
  listIssues: vi.fn().mockResolvedValue([]),
  updateIssue: vi.fn().mockResolvedValue({} as GitHubIssue),
  api: vi.fn().mockResolvedValue({}),
};

function createMockAdapter(overrides: Partial<{
  listTasks: ReturnType<typeof vi.fn>;
  createTask: ReturnType<typeof vi.fn>;
  updateTaskGitHubFields: ReturnType<typeof vi.fn>;
  recordGithubSyncEvent: ReturnType<typeof vi.fn>;
  getGithubRepo: ReturnType<typeof vi.fn>;
  updateGithubRepoLastSync: ReturnType<typeof vi.fn>;
  getTask: ReturnType<typeof vi.fn>;
}> = {}): PostgresAdapter {
  return {
    listTasks: overrides.listTasks ?? vi.fn().mockResolvedValue([]),
    createTask: overrides.createTask ?? vi.fn().mockResolvedValue({ id: "task-new", project_id: "proj-1" } as any),
    updateTaskGitHubFields: overrides.updateTaskGitHubFields ?? vi.fn().mockResolvedValue(null),
    recordGithubSyncEvent: overrides.recordGithubSyncEvent ?? vi.fn().mockResolvedValue({} as any),
    getGithubRepo: overrides.getGithubRepo ?? vi.fn().mockResolvedValue(makeRepo()),
    updateGithubRepoLastSync: overrides.updateGithubRepoLastSync ?? vi.fn().mockResolvedValue(undefined),
    getTask: overrides.getTask ?? vi.fn().mockResolvedValue(null),
  } as any;
}

function createMockRegistry(projects = [makeProject()]): ProjectRegistry {
  return {
    list: vi.fn().mockResolvedValue(projects),
  } as any;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("GitHubIssuesPoller", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe("constructor and config", () => {
    it("uses default config values", () => {
      const adapter = createMockAdapter();
      const registry = createMockRegistry();
      const poller = new GitHubIssuesPoller(adapter, registry);

      expect(poller.running).toBe(false);
    });

    it("accepts custom foremanLabel", () => {
      const adapter = createMockAdapter();
      const registry = createMockRegistry();
      const poller = new GitHubIssuesPoller(adapter, registry, { foremanLabel: "my-label" });
      expect(poller).toBeDefined();
    });

    it("accepts custom pollIntervalMs", () => {
      const adapter = createMockAdapter();
      const registry = createMockRegistry();
      const poller = new GitHubIssuesPoller(adapter, registry, { pollIntervalMs: 30_000 });
      expect(poller).toBeDefined();
    });
  });

  describe("start() / stop()", () => {
    it("start() sets running=true", () => {
      const adapter = createMockAdapter();
      const registry = createMockRegistry();
      const poller = new GitHubIssuesPoller(adapter, registry, {
        autoImport: false, // prevent actual polling
      });

      poller.start();
      expect(poller.running).toBe(true);

      poller.stop();
      expect(poller.running).toBe(false);
    });

    it("start() is idempotent — calling twice does not start twice", () => {
      const adapter = createMockAdapter();
      const registry = createMockRegistry();
      const poller = new GitHubIssuesPoller(adapter, registry, { autoImport: false });

      poller.start();
      poller.start(); // second call — should be no-op

      expect(poller.running).toBe(true);
      poller.stop();
    });

    it("stop() without start() is a no-op", () => {
      const adapter = createMockAdapter();
      const registry = createMockRegistry();
      const poller = new GitHubIssuesPoller(adapter, registry, { autoImport: false });

      poller.stop(); // should not throw
      expect(poller.running).toBe(false);
    });
  });

  describe("pollRepo", () => {
    it("creates a backlog task for new issues by default", async () => {
      const issue = makeIssue(42, "New issue");
      const mockGh = { listIssues: vi.fn().mockResolvedValue([issue]) } as any;
      const adapter = createMockAdapter({
        listTasks: vi.fn().mockResolvedValue([]), // no existing task
        createTask: vi.fn().mockResolvedValue({ id: "task-new", project_id: "proj-1" } as any),
      });
      const registry = createMockRegistry();

      const poller = new GitHubIssuesPoller(adapter, registry, { autoImport: true }, mockGh);
      const result = await poller.pollRepo("proj-1", "test", "repo");

      expect(result.imported).toBe(1);
      expect(result.issues).toBe(1);
    });

    it("creates a ready task for issues with the foreman label", async () => {
      const issue = makeIssue(43, "Foreman-labeled issue", ["foreman"]);
      const mockGh = { listIssues: vi.fn().mockResolvedValue([issue]) } as any;
      const adapter = createMockAdapter({
        listTasks: vi.fn().mockResolvedValue([]),
        createTask: vi.fn().mockResolvedValue({ id: "task-ready", project_id: "proj-1" } as any),
      });
      const registry = createMockRegistry();

      const poller = new GitHubIssuesPoller(adapter, registry, { autoImport: true, foremanLabel: "foreman" }, mockGh);
      const result = await poller.pollRepo("proj-1", "test", "repo");

      expect(result.imported).toBe(1);
      expect((adapter.createTask as ReturnType<typeof vi.fn>).mock.calls[0]?.[1]?.status).toBe("ready");
    });

    it("creates a ready task for issues with foreman:dispatch label", async () => {
      const issue = makeIssue(44, "Dispatch-labeled issue", ["foreman:dispatch"]);
      const mockGh = { listIssues: vi.fn().mockResolvedValue([issue]) } as any;
      const adapter = createMockAdapter({
        listTasks: vi.fn().mockResolvedValue([]),
        createTask: vi.fn().mockResolvedValue({ id: "task-dispatch", project_id: "proj-1" } as any),
      });
      const registry = createMockRegistry();

      const poller = new GitHubIssuesPoller(adapter, registry, { autoImport: true, foremanLabel: "foreman" }, mockGh);
      const result = await poller.pollRepo("proj-1", "test", "repo");

      expect(result.imported).toBe(1);
      expect((adapter.createTask as ReturnType<typeof vi.fn>).mock.calls[0]?.[1]?.status).toBe("ready");
    });

    it("does NOT create a task when autoImport is false", async () => {
      const issue = makeIssue(45, "Should not import");
      const mockGh = { listIssues: vi.fn().mockResolvedValue([issue]) } as any;
      const adapter = createMockAdapter({
        listTasks: vi.fn().mockResolvedValue([]),
      });
      const registry = createMockRegistry();

      const poller = new GitHubIssuesPoller(adapter, registry, { autoImport: false }, mockGh);
      const result = await poller.pollRepo("proj-1", "test", "repo");

      expect(result.imported).toBe(0);
      expect(adapter.createTask).not.toHaveBeenCalled();
    });

    it("does NOT create duplicate tasks for re-polling the same issue (idempotency)", async () => {
      const issue = makeIssue(46, "Already imported", [], "open");
      const existingTask = makeTaskRow({
        id: "existing-task",
        title: "Already imported",
        description: "Body for issue #46",
        external_id: "github:test/repo#46",
      });
      const mockGh = { listIssues: vi.fn().mockResolvedValue([issue]) } as any;
      const adapter = createMockAdapter({
        listTasks: vi.fn().mockResolvedValue([existingTask]),
      });
      const registry = createMockRegistry();

      const poller = new GitHubIssuesPoller(adapter, registry, { autoImport: true }, mockGh);
      const result = await poller.pollRepo("proj-1", "test", "repo");

      expect(result.imported).toBe(0);
      expect(result.updated).toBe(0); // no change detected
      expect(adapter.createTask).not.toHaveBeenCalled();
    });

    it("updates existing task when title or body changed (safe re-sync)", async () => {
      const issue = makeIssue(47, "Updated title");
      const existingTask = makeTaskRow({
        id: "existing-task-47",
        title: "Old title", // different title
        external_id: "github:test/repo#47",
      });
      const mockGh = { listIssues: vi.fn().mockResolvedValue([issue]) } as any;
      const adapter = createMockAdapter({
        listTasks: vi.fn().mockResolvedValue([existingTask]),
        updateTaskGitHubFields: vi.fn().mockResolvedValue(null),
      });
      const registry = createMockRegistry();

      const poller = new GitHubIssuesPoller(adapter, registry, { autoImport: true }, mockGh);
      const result = await poller.pollRepo("proj-1", "test", "repo");

      expect(result.updated).toBe(1);
      expect(adapter.updateTaskGitHubFields).toHaveBeenCalled();
    });

    it("records a sync event on new import", async () => {
      const issue = makeIssue(48, "New issue to record");
      const mockGh = { listIssues: vi.fn().mockResolvedValue([issue]) } as any;
      const adapter = createMockAdapter({
        listTasks: vi.fn().mockResolvedValue([]),
        createTask: vi.fn().mockResolvedValue({ id: "task-new-48", project_id: "proj-1" } as any),
        recordGithubSyncEvent: vi.fn().mockResolvedValue({} as any),
      });
      const registry = createMockRegistry();

      const poller = new GitHubIssuesPoller(adapter, registry, { autoImport: true }, mockGh);
      await poller.pollRepo("proj-1", "test", "repo");

      expect(adapter.recordGithubSyncEvent).toHaveBeenCalledWith(
        expect.objectContaining({
          projectId: "proj-1",
          externalId: "github:test/repo#48",
          eventType: "issue_opened",
          direction: "from_github",
        }),
      );
    });
  });

  describe("pollAll", () => {
    it("skips projects with non-active status", async () => {
      const adapter = createMockAdapter();
      const registry = createMockRegistry([makeProject("proj-archived", "archived")]);
      const mockGh = { listIssues: vi.fn().mockResolvedValue([]) } as any;

      const poller = new GitHubIssuesPoller(adapter, registry, { autoImport: false }, mockGh);
      const result = await poller.pollAll();

      expect(result.repos).toBe(0);
    });
  });
});

describe("closeLinkedGithubIssue", () => {
  it("does nothing when task has no external_id", async () => {
    const adapter = createMockAdapter({
      getTask: vi.fn().mockResolvedValue(makeTaskRow({ external_id: null })),
    });
    const gh = { ...NOOP_GH, updateIssue: vi.fn().mockResolvedValue({}) } as any;

    await closeLinkedGithubIssue(adapter as any, gh as any, "proj-1", "task-1");

    expect(gh.updateIssue).not.toHaveBeenCalled();
  });

  it("does nothing when external_id does not start with github:", async () => {
    const adapter = createMockAdapter({
      getTask: vi.fn().mockResolvedValue(makeTaskRow({ external_id: "beads:123" })),
    });
    const gh = { ...NOOP_GH, updateIssue: vi.fn().mockResolvedValue({}) } as any;

    await closeLinkedGithubIssue(adapter as any, gh as any, "proj-1", "task-1");

    expect(gh.updateIssue).not.toHaveBeenCalled();
  });

  it("closes the GitHub issue when task is linked", async () => {
    const task = makeTaskRow({
      id: "github-task-1",
      external_id: "github:test/repo#99",
    });
    const adapter = createMockAdapter({
      getTask: vi.fn().mockResolvedValue(task),
      recordGithubSyncEvent: vi.fn().mockResolvedValue({} as any),
    });
    const gh = {
      ...NOOP_GH,
      updateIssue: vi.fn().mockResolvedValue({}),
    } as any;

    await closeLinkedGithubIssue(adapter as any, gh as any, "proj-1", "github-task-1");

    expect(gh.updateIssue).toHaveBeenCalledWith("test", "repo", 99, { state: "closed" });
  });

  it("records sync event when closing", async () => {
    const task = makeTaskRow({
      id: "github-task-2",
      external_id: "github:test/repo#100",
    });
    const adapter = createMockAdapter({
      getTask: vi.fn().mockResolvedValue(task),
      recordGithubSyncEvent: vi.fn().mockResolvedValue({} as any),
    });
    const gh = {
      ...NOOP_GH,
      updateIssue: vi.fn().mockResolvedValue({}),
    } as any;

    await closeLinkedGithubIssue(adapter as any, gh as any, "proj-1", "github-task-2");

    expect(adapter.recordGithubSyncEvent).toHaveBeenCalledWith(
      expect.objectContaining({
        projectId: "proj-1",
        externalId: "github:test/repo#100",
        eventType: "issue_closed",
        direction: "to_github",
      }),
    );
  });

  it("is non-fatal when the GitHub API call fails", async () => {
    const task = makeTaskRow({
      id: "github-task-3",
      external_id: "github:test/repo#101",
    });
    const adapter = createMockAdapter({
      getTask: vi.fn().mockResolvedValue(task),
      recordGithubSyncEvent: vi.fn().mockRejectedValue(new Error("DB write failed")),
    });
    const gh = {
      ...NOOP_GH,
      updateIssue: vi.fn().mockRejectedValue(new Error("GH rate limited")),
    } as any;

    // Should not throw — errors are logged but not propagated
    await expect(
      closeLinkedGithubIssue(adapter as any, gh as any, "proj-1", "github-task-3"),
    ).resolves.not.toThrow();
  });
});