import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockForemanBackendMode,
  mockList,
  mockAdd,
  mockUpdate,
  mockEncrypt,
} = vi.hoisted(() => ({
  mockForemanBackendMode: vi.fn(),
  mockList: vi.fn(),
  mockAdd: vi.fn(),
  mockUpdate: vi.fn(),
  mockEncrypt: vi.fn(),
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: mockForemanBackendMode,
}));

vi.mock("../../lib/encryption.js", () => ({
  encrypt: (...args: unknown[]) => mockEncrypt(...args),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: () => ({
    projects: {
      list: mockList,
      add: mockAdd,
      update: mockUpdate,
      remove: vi.fn(),
      get: vi.fn(),
      sync: vi.fn(),
    },
  }),
}));

describe("foreman project node-mode commands", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockForemanBackendMode.mockReturnValue("node");
    mockEncrypt.mockResolvedValue("enc-token");
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("lists daemon projects in node mode as JSON", async () => {
    mockList.mockResolvedValue([
      { id: "proj-1", name: "foreman", path: "/repo/foreman", status: "active" },
    ]);

    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync(["list", "--status", "active", "--search", "fore", "--json"], { from: "user" });

    expect(mockList).toHaveBeenCalledWith({ status: "active", search: "fore" });
    expect(vi.mocked(console.log)).toHaveBeenCalledWith(JSON.stringify([
      { id: "proj-1", name: "foreman", path: "/repo/foreman", status: "active" },
    ], null, 2));
  });

  it("prints a friendly empty message when node-mode list returns no projects", async () => {
    mockList.mockResolvedValue([]);

    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync(["list"], { from: "user" });

    expect(mockList).toHaveBeenCalledWith({ status: undefined, search: undefined });
    expect(vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("No projects found.");
  });

  it("does not call update when project edit is invoked with no changes", async () => {
    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync(["edit", "proj-1"], { from: "user" });

    expect(mockUpdate).not.toHaveBeenCalled();
    expect(vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("No updates provided");
  });

  it("builds Jira updates and encrypts tokens during project edit", async () => {
    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync([
      "edit",
      "proj-1",
      "--name",
      "Renamed",
      "--status",
      "paused",
      "--jira-url",
      "https://jira.example.com",
      "--jira-email",
      "dev@example.com",
      "--jira-token",
      "plain-token",
      "--jira-project",
      "abc",
      "--jira-start-status",
      "Todo,In Progress",
      "--jira-end-status",
      "Done",
      "--jira-issue-type",
      "bug=workflow-a",
      "--jira-poll-interval",
      "30",
      "--jira-webhook-enabled",
      "--jira-webhook-secret-env",
      "JIRA_SECRET",
    ], { from: "user" });

    expect(mockEncrypt).toHaveBeenCalledWith("plain-token");
    expect(mockUpdate).toHaveBeenCalledWith({
      id: "proj-1",
      updates: {
        name: "Renamed",
        status: "paused",
        jira: {
          apiUrl: "https://jira.example.com",
          email: "dev@example.com",
          apiToken: "enc-token",
          pollIntervalSeconds: 30,
          webhookEnabled: true,
          webhookSecretEnvVar: "JIRA_SECRET",
          projects: [
            {
              key: "ABC",
              startStatus: ["Todo", "In Progress"],
              endStatus: ["Done"],
              issueTypeWorkflowMap: { bug: "workflow-a" },
            },
          ],
        },
      },
    });
  });

  it("applies Jira configuration after project add when Jira flags are provided", async () => {
    mockAdd.mockResolvedValue({
      id: "proj-1",
      name: "foreman",
      path: "/repo/foreman",
      default_branch: "main",
    });

    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync([
      "add",
      "owner/repo",
      "--jira-token",
      "plain-token",
      "--jira-project",
      "xyz",
    ], { from: "user" });

    expect(mockAdd).toHaveBeenCalledWith({
      githubUrl: "owner/repo",
      name: undefined,
      defaultBranch: undefined,
      status: "active",
    });
    expect(mockUpdate).toHaveBeenCalledWith({
      id: "proj-1",
      updates: {
        jira: {
          apiToken: "enc-token",
          projects: [
            {
              key: "XYZ",
              startStatus: [],
              endStatus: [],
              issueTypeWorkflowMap: {},
            },
          ],
        },
      },
    });
  });
});
