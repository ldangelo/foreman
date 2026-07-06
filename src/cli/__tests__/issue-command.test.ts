import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockResolveProjectPathFromOptions,
  mockEnsureCliPostgresPool,
  mockGetIssue,
  mockListIssues,
  mockListLabels,
  mockListMilestones,
  mockCheckAuth,
  mockEnsureLabels,
  mockCreateWebhook,
  mockListWebhooks,
  mockDeleteWebhook,
  mockLinkIssueToPullRequest,
  mockUnlinkIssueFromPullRequest,
  mockListProjects,
  mockGetGithubRepo,
  mockUpsertGithubRepo,
  mockListTasks,
  mockCreateTask,
  mockListGithubSyncEvents,
} = vi.hoisted(() => ({
  mockResolveProjectPathFromOptions: vi.fn(),
  mockEnsureCliPostgresPool: vi.fn(),
  mockGetIssue: vi.fn(),
  mockListIssues: vi.fn(),
  mockListLabels: vi.fn(),
  mockListMilestones: vi.fn(),
  mockCheckAuth: vi.fn(),
  mockEnsureLabels: vi.fn(),
  mockCreateWebhook: vi.fn(),
  mockListWebhooks: vi.fn(),
  mockDeleteWebhook: vi.fn(),
  mockLinkIssueToPullRequest: vi.fn(),
  mockUnlinkIssueFromPullRequest: vi.fn(),
  mockListProjects: vi.fn(),
  mockGetGithubRepo: vi.fn(),
  mockUpsertGithubRepo: vi.fn(),
  mockListTasks: vi.fn(),
  mockCreateTask: vi.fn(),
  mockListGithubSyncEvents: vi.fn(),
}));

vi.mock("../commands/project-task-support.js", () => ({
  resolveProjectPathFromOptions: mockResolveProjectPathFromOptions,
  ensureCliPostgresPool: mockEnsureCliPostgresPool,
}));

vi.mock("../../lib/gh-cli.js", () => {
  class GhNotFoundError extends Error {}
  class GhRateLimitError extends Error {
    retryAfter = 60;
  }
  return {
    GhCli: vi.fn().mockImplementation(function MockGhCli() {
      return {
        getIssue: mockGetIssue,
        listIssues: mockListIssues,
        listLabels: mockListLabels,
        listMilestones: mockListMilestones,
        checkAuth: mockCheckAuth,
        ensureLabels: mockEnsureLabels,
        createWebhook: mockCreateWebhook,
        listWebhooks: mockListWebhooks,
        deleteWebhook: mockDeleteWebhook,
        linkIssueToPullRequest: mockLinkIssueToPullRequest,
        unlinkIssueFromPullRequest: mockUnlinkIssueFromPullRequest,
      };
    }),
    GhNotFoundError,
    GhRateLimitError,
  };
});

vi.mock("../../daemon/webhook-handler.js", () => ({
  generateWebhookSecret: () => "generated-secret",
}));

vi.mock("../../lib/db/postgres-adapter.js", () => ({
  PostgresAdapter: vi.fn().mockImplementation(function MockPostgresAdapter() {
    return {
      listProjects: mockListProjects,
      getGithubRepo: mockGetGithubRepo,
      upsertGithubRepo: mockUpsertGithubRepo,
      listTasks: mockListTasks,
      createTask: mockCreateTask,
      listGithubSyncEvents: mockListGithubSyncEvents,
    };
  }),
}));

async function freshIssueCommand() {
  vi.resetModules();
  const { issueCommand } = await import("../commands/issue.js");
  return issueCommand;
}

describe("issue command wrappers", () => {
  let logSpy: ReturnType<typeof vi.spyOn>;
  let errSpy: ReturnType<typeof vi.spyOn>;
  let exitSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    mockResolveProjectPathFromOptions.mockResolvedValue("/tmp/project");
    mockListProjects.mockResolvedValue([{ id: "proj-1", path: "/tmp/project" }]);
    mockGetGithubRepo.mockResolvedValue(null);
    mockUpsertGithubRepo.mockResolvedValue({
      id: "repo-1",
      sync_strategy: "github-wins",
      auto_import: false,
      default_labels: [],
    });
    mockCheckAuth.mockResolvedValue(undefined);
    mockEnsureLabels.mockResolvedValue({ created: [], updated: [], unchanged: [] });
    mockCreateWebhook.mockResolvedValue({ id: 99 });
    mockListWebhooks.mockResolvedValue([]);
    mockDeleteWebhook.mockResolvedValue(undefined);
    mockListTasks.mockResolvedValue([]);
    mockCreateTask.mockResolvedValue({ id: "task-1" });
    mockListGithubSyncEvents.mockResolvedValue([]);
    logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    errSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("views a GitHub issue through GhCli", async () => {
    mockGetIssue.mockResolvedValue({
      number: 142,
      title: "Fix login bug",
      state: "open",
      user: { login: "leo" },
      created_at: "2026-01-01T00:00:00.000Z",
      updated_at: "2026-01-02T00:00:00.000Z",
      milestone: null,
      assignees: [],
      labels: [{ name: "bug" }],
      body: "Detailed description",
      html_url: "https://github.com/owner/repo/issues/142",
    });
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["view", "--repo", "owner/repo", "--issue", "142"], { from: "user" });

    expect(mockResolveProjectPathFromOptions).toHaveBeenCalled();
    expect(mockGetIssue).toHaveBeenCalledWith("owner", "repo", 142);
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("#142: Fix login bug");
    expect(rendered).toContain("Detailed description");
  });

  it("lists GitHub issues with limit messaging", async () => {
    mockListIssues.mockResolvedValue([
      { number: 1, title: "One", state: "open", labels: [], user: { login: "a" }, created_at: "", updated_at: "", assignees: [], milestone: null, body: null, html_url: "" },
      { number: 2, title: "Two", state: "open", labels: [{ name: "bug" }], user: { login: "a" }, created_at: "", updated_at: "", assignees: [], milestone: null, body: null, html_url: "" },
    ]);
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["list", "--repo", "owner/repo", "--limit", "1", "--label", "bug"], { from: "user" });

    expect(mockListIssues).toHaveBeenCalledWith("owner", "repo", { labels: "bug", state: "open" });
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("owner/repo — 1 issue");
    expect(rendered).toContain("Showing 1 of 2 issues");
  });

  it("configures a repo and optionally creates required labels", async () => {
    mockGetGithubRepo.mockResolvedValue({
      id: "repo-1",
      auth_type: "app",
      auth_config: { installationId: 123 },
      default_labels: ["github:docs"],
      auto_import: true,
      webhook_secret: "secret",
      webhook_enabled: true,
      sync_strategy: "manual",
      last_sync_at: "2026-01-01T00:00:00.000Z",
    });
    mockEnsureLabels.mockResolvedValue({ created: ["foreman"], updated: ["foreman:dispatch"], unchanged: ["foreman:skip"] });
    mockUpsertGithubRepo.mockResolvedValue({
      id: "repo-1",
      sync_strategy: "manual",
      auto_import: false,
      default_labels: ["github:docs"],
    });
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["configure", "--repo", "owner/repo", "--disable-auto-import", "--create-labels"], { from: "user" });

    expect(mockCheckAuth).toHaveBeenCalledOnce();
    expect(mockEnsureLabels).toHaveBeenCalled();
    expect(mockUpsertGithubRepo).toHaveBeenCalled();
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Configured owner/repo for project proj-1");
    expect(rendered).toContain("Labels created:");
  });

  it("lists labels for a repository", async () => {
    mockListLabels.mockResolvedValue([
      { name: "bug", color: "ff0000", description: "Bug label" },
      { name: "foreman:dispatch", color: "00ff00", description: null },
    ]);
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["labels", "--repo", "owner/repo"], { from: "user" });

    expect(mockListLabels).toHaveBeenCalledWith("owner", "repo");
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("owner/repo — 2 labels");
    expect(rendered).toContain("bug");
    expect(rendered).toContain("foreman:dispatch");
  });

  it("lists filtered milestones for a repository", async () => {
    mockListMilestones.mockResolvedValue([
      { number: 1, title: "v1", state: "open", open_issues: 2, closed_issues: 1 },
      { number: 2, title: "v0", state: "closed", open_issues: 0, closed_issues: 3 },
    ]);
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["milestones", "--repo", "owner/repo", "--state", "closed"], { from: "user" });

    expect(mockListMilestones).toHaveBeenCalledWith("owner", "repo");
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("owner/repo — 1 milestones");
    expect(rendered).toContain("v0");
    expect(rendered).not.toContain("v1");
  });

  it("fails fast on invalid repo keys", async () => {
    const issueCommand = await freshIssueCommand();

    await expect(issueCommand.parseAsync(["view", "--repo", "invalid-repo", "--issue", "1"], { from: "user" })).rejects.toThrow("Invalid repo key");
    expect(mockGetIssue).not.toHaveBeenCalled();
  });

  it("bulk import dry-run previews issues without creating tasks", async () => {
    mockListIssues.mockResolvedValue([
      { number: 1, title: "One", state: "open", labels: [], user: { login: "a" }, created_at: "", updated_at: "", assignees: [], milestone: null, body: null, html_url: "" },
      { number: 2, title: "Two", state: "open", labels: [], user: { login: "a" }, created_at: "", updated_at: "", assignees: [], milestone: null, body: null, html_url: "" },
    ]);
    mockUpsertGithubRepo.mockResolvedValue({ id: "repo-1", default_labels: [], auto_import: false, sync_strategy: "github-wins" });
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["import", "--repo", "owner/repo", "--label", "bug", "--dry-run"], { from: "user" });

    expect(mockListIssues).toHaveBeenCalledWith("owner", "repo", { labels: "bug", milestone: undefined, assignee: undefined, state: "open" });
    expect(mockCreateTask).not.toHaveBeenCalled();
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("2 issues to import");
    expect(rendered).toContain("Dry-run mode");
  });

  it("bulk import creates new tasks and skips already-imported ones", async () => {
    mockListIssues.mockResolvedValue([
      { number: 1, title: "One", state: "open", labels: [{ name: "bug" }], user: { login: "a" }, created_at: "", updated_at: "", assignees: [], milestone: { title: "v1" }, body: "Issue one", html_url: "" },
      { number: 2, title: "Two", state: "open", labels: [], user: { login: "a" }, created_at: "", updated_at: "", assignees: [], milestone: null, body: null, html_url: "" },
    ]);
    mockUpsertGithubRepo.mockResolvedValue({ id: "repo-1", default_labels: ["github:docs"], auto_import: false, sync_strategy: "github-wins" });
    mockListTasks
      .mockResolvedValueOnce([{ id: "task-existing" }])
      .mockResolvedValueOnce([]);
    mockCreateTask.mockResolvedValue({ id: "task-created" });
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["import", "--repo", "owner/repo", "--label", "bug", "--sync"], { from: "user" });

    expect(mockCreateTask).toHaveBeenCalledTimes(1);
    expect(mockCreateTask).toHaveBeenCalledWith("proj-1", expect.objectContaining({
      title: "Two",
      externalId: "github:owner/repo#2",
      labels: ["github:docs"],
      external_repo: "owner/repo",
      github_issue_number: 2,
      sync_enabled: true,
    }));
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Imported 1 task");
    expect(rendered).toContain("1 skipped: already exist");
  });

  it("imports a single issue as a Foreman task", async () => {
    mockGetIssue.mockResolvedValue({
      number: 7,
      title: "Import me",
      state: "open",
      labels: [{ name: "bug" }],
      user: { login: "a" },
      created_at: "",
      updated_at: "",
      assignees: [],
      milestone: { title: "v1" },
      body: "Issue body",
      html_url: "",
    });
    mockListTasks.mockResolvedValue([]);
    mockCreateTask.mockResolvedValue({ id: "task-7" });
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["import", "--repo", "owner/repo", "--issue", "7", "--sync"], { from: "user" });

    expect(mockGetIssue).toHaveBeenCalledWith("owner", "repo", 7);
    expect(mockCreateTask).toHaveBeenCalledWith("proj-1", expect.objectContaining({
      title: "Import me",
      externalId: "github:owner/repo#7",
      labels: ["github:bug"],
      milestone: "v1",
      github_issue_number: 7,
      sync_enabled: true,
    }));
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Imported #7 as task task-7");
  });

  it("import requires either --issue or a bulk filter", async () => {
    const issueCommand = await freshIssueCommand();

    await expect(issueCommand.parseAsync(["import", "--repo", "owner/repo"], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Specify --issue");
  });

  it("shows sync status for a configured repository", async () => {
    mockGetGithubRepo.mockResolvedValue({
      id: "repo-1",
      sync_strategy: "github-wins",
      auto_import: true,
      webhook_enabled: true,
      last_sync_at: "2026-01-01T00:00:00.000Z",
    });
    mockListGithubSyncEvents.mockResolvedValue([
      { direction: "from_github", event_type: "issue.imported", processed_at: "2026-01-02T00:00:00.000Z" },
      { direction: "to_github", event_type: "task.synced", processed_at: "2026-01-03T00:00:00.000Z" },
    ]);
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["status", "--repo", "owner/repo"], { from: "user" });

    expect(mockListGithubSyncEvents).toHaveBeenCalledWith("proj-1", undefined, 10);
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("GitHub sync status: owner/repo");
    expect(rendered).toContain("issue.imported");
    expect(rendered).toContain("task.synced");
  });

  it("shows sync status with no recent events and no last sync", async () => {
    mockGetGithubRepo.mockResolvedValue({
      id: "repo-1",
      sync_strategy: "github-wins",
      auto_import: false,
      webhook_enabled: false,
      last_sync_at: null,
    });
    mockListGithubSyncEvents.mockResolvedValue([]);
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["status", "--repo", "owner/repo"], { from: "user" });

    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Last sync:");
    expect(rendered).toContain("never");
    expect(rendered).not.toContain("Recent sync events:");
  });

  it("reports when a repository is not configured for sync status", async () => {
    mockGetGithubRepo.mockResolvedValue(null);
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["status", "--repo", "owner/repo"], { from: "user" });

    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("is not configured for Foreman");
    expect(rendered).toContain("foreman issue configure --repo owner/repo");
  });

  it("links and unlinks PRs through GhCli", async () => {
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["link", "--repo", "owner/repo", "--issue", "12", "--pr", "34"], { from: "user" });
    await issueCommand.parseAsync(["link", "--repo", "owner/repo", "--issue", "12", "--pr", "34", "--unlink"], { from: "user" });

    expect(mockLinkIssueToPullRequest).toHaveBeenCalledWith("owner", "repo", 12, 34);
    expect(mockUnlinkIssueFromPullRequest).toHaveBeenCalledWith("owner", "repo", 12, "34");
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Linked PR #34 to issue #12");
    expect(rendered).toContain("Unlinked PR #34 from issue #12");
  });

  it("surfaces GitHub 404 errors with the friendly not-found message", async () => {
    const issueCommand = await freshIssueCommand();
    const { GhNotFoundError } = await import("../../lib/gh-cli.js");
    mockGetIssue.mockRejectedValue(new GhNotFoundError("missing"));

    await expect(issueCommand.parseAsync(["view", "--repo", "owner/repo", "--issue", "404"], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("GitHub resource not found (404)");
  });

  it("surfaces GitHub rate limit errors with retry guidance", async () => {
    const issueCommand = await freshIssueCommand();
    const { GhRateLimitError } = await import("../../lib/gh-cli.js");
    mockListIssues.mockRejectedValue(new GhRateLimitError("slow down", 60));

    await expect(issueCommand.parseAsync(["list", "--repo", "owner/repo"], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("GitHub API rate limit exceeded");
    expect(rendered).toContain("60 seconds");
  });

  it("requires --enable or --disable for webhook management", async () => {
    const issueCommand = await freshIssueCommand();

    await expect(issueCommand.parseAsync(["webhook", "--repo", "owner/repo"], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("specify --enable or --disable");
  });

  it("enables webhook configuration for a repository", async () => {
    mockGetGithubRepo.mockResolvedValue({
      id: "repo-1",
      auth_type: "app",
      auth_config: { installationId: 123 },
      default_labels: ["github:docs"],
      auto_import: true,
      webhook_secret: null,
      webhook_enabled: false,
      sync_strategy: "manual",
      last_sync_at: "2026-01-01T00:00:00.000Z",
    });
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["webhook", "--repo", "owner/repo", "--enable", "--url", "https://example.com/webhook"], { from: "user" });

    expect(mockCreateWebhook).toHaveBeenCalledWith("owner", "repo", "https://example.com/webhook", "generated-secret");
    expect(mockUpsertGithubRepo).toHaveBeenCalledWith(expect.objectContaining({
      projectId: "proj-1",
      owner: "owner",
      repo: "repo",
      webhookEnabled: true,
      webhookSecret: "generated-secret",
    }));
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Enabled webhook for owner/repo");
    expect(rendered).toContain("Webhook URL:");
    expect(rendered).toContain("Webhook ID:");
    expect(rendered).toContain("Save this secret");
  });

  it("reuses an existing webhook secret when enabling webhooks", async () => {
    mockGetGithubRepo.mockResolvedValue({
      id: "repo-1",
      auth_type: "app",
      auth_config: { installationId: 123 },
      default_labels: ["github:docs"],
      auto_import: true,
      webhook_secret: "existing-secret",
      webhook_enabled: false,
      sync_strategy: "manual",
      last_sync_at: "2026-01-01T00:00:00.000Z",
    });
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["webhook", "--repo", "owner/repo", "--enable"], { from: "user" });

    expect(mockCreateWebhook).toHaveBeenCalledWith("owner", "repo", "http://localhost:3847/webhook", "existing-secret");
    expect(mockUpsertGithubRepo).toHaveBeenCalledWith(expect.objectContaining({ webhookSecret: "existing-secret", webhookEnabled: true }));
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Enabled webhook for owner/repo");
    expect(rendered).not.toContain("Save this secret");
  });

  it("disables webhook configuration for a repository", async () => {
    mockGetGithubRepo.mockResolvedValue({
      id: "repo-1",
      auth_type: "app",
      auth_config: { installationId: 123 },
      default_labels: ["github:docs"],
      auto_import: true,
      webhook_secret: "secret",
      webhook_enabled: true,
      sync_strategy: "manual",
      last_sync_at: "2026-01-01T00:00:00.000Z",
    });
    const issueCommand = await freshIssueCommand();

    await issueCommand.parseAsync(["webhook", "--repo", "owner/repo", "--disable"], { from: "user" });

    expect(mockListWebhooks).toHaveBeenCalledWith("owner", "repo");
    expect(mockUpsertGithubRepo).toHaveBeenCalledWith(expect.objectContaining({
      projectId: "proj-1",
      owner: "owner",
      repo: "repo",
      webhookEnabled: false,
      webhookSecret: null,
    }));
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Disabled 0 webhook(s) for owner/repo");
  });

  it("surfaces repository not found/admin access errors for webhook enable", async () => {
    const issueCommand = await freshIssueCommand();
    const { GhNotFoundError } = await import("../../lib/gh-cli.js");
    mockCreateWebhook.mockRejectedValue(new GhNotFoundError("missing"));

    await expect(issueCommand.parseAsync(["webhook", "--repo", "owner/repo", "--enable"], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("not found or no admin access");
  });

  it("surfaces generic GitHub errors through handleGhError", async () => {
    const issueCommand = await freshIssueCommand();
    mockListIssues.mockRejectedValue(new Error("boom"));

    await expect(issueCommand.parseAsync(["list", "--repo", "owner/repo"], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Error listing issues: boom");
  });
});
