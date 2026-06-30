import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockEncrypt,
  mockConfigure,
  mockGetStatus,
  mockTestConnection,
  mockEnableWebhook,
  mockDisableWebhook,
} = vi.hoisted(() => ({
  mockEncrypt: vi.fn(),
  mockConfigure: vi.fn(),
  mockGetStatus: vi.fn(),
  mockTestConnection: vi.fn(),
  mockEnableWebhook: vi.fn(),
  mockDisableWebhook: vi.fn(),
}));

vi.mock("../../lib/encryption.js", () => ({
  encrypt: mockEncrypt,
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: vi.fn(() => ({
    jira: {
      configure: mockConfigure,
      getStatus: mockGetStatus,
      testConnection: mockTestConnection,
      enableWebhook: mockEnableWebhook,
      disableWebhook: mockDisableWebhook,
    },
  })),
}));

async function freshJiraCommand() {
  vi.resetModules();
  const { jiraCommand } = await import("../commands/jira.js");
  return jiraCommand;
}

describe("jira command wrappers", () => {
  let logSpy: ReturnType<typeof vi.spyOn>;
  let errSpy: ReturnType<typeof vi.spyOn>;
  let exitSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    mockEncrypt.mockResolvedValue("encrypted-token");
    mockConfigure.mockResolvedValue(undefined);
    mockGetStatus.mockResolvedValue({ configured: true, projects: 2, lastPoll: "2026-01-02T00:00:00.000Z", webhookEnabled: true });
    mockTestConnection.mockResolvedValue({ connected: true, projects: [{ key: "ENG", name: "Engineering" }] });
    mockEnableWebhook.mockResolvedValue({ webhookUrl: "https://foreman.test/webhook" });
    mockDisableWebhook.mockResolvedValue(undefined);
    logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    errSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("configures Jira with encrypted token and workflow mappings", async () => {
    const jiraCommand = await freshJiraCommand();

    await jiraCommand.parseAsync([
      "configure",
      "--api-url", "https://example.atlassian.net",
      "--email", "user@example.com",
      "--api-token", "plain-token",
      "--project", "eng",
      "--start-status", "Selected for Development",
      "--end-status", "Done",
      "--issue-type-workflow", "bug=bug",
      "--issue-type-workflow", "story=default",
      "--webhook-enabled",
    ], { from: "user" });

    expect(mockEncrypt).toHaveBeenCalledWith("plain-token");
    expect(mockConfigure).toHaveBeenCalledWith({
      apiUrl: "https://example.atlassian.net",
      email: "user@example.com",
      apiToken: "encrypted-token",
      projects: [
        {
          key: "ENG",
          startStatus: ["Selected for Development"],
          endStatus: ["Done"],
          issueTypeWorkflowMap: { bug: "bug", story: "default" },
          debounceWindowSeconds: undefined,
        },
      ],
      webhookEnabled: true,
      webhookSecretEnvVar: undefined,
      pollIntervalSeconds: undefined,
    });
    const renderedLines = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? ""));
    expect(renderedLines.some((line: string) => line.includes("configured successfully"))).toBe(true);
    expect(renderedLines.some((line: string) => line.includes("Projects:") && line.includes("ENG"))).toBe(true);
  });

  it("rejects configure without issue-type workflow mapping", async () => {
    const jiraCommand = await freshJiraCommand();

    await expect(jiraCommand.parseAsync([
      "configure",
      "--api-url", "https://example.atlassian.net",
      "--email", "user@example.com",
      "--api-token", "plain-token",
      "--project", "eng",
      "--start-status", "Selected for Development",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(mockConfigure).not.toHaveBeenCalled();
    expect(errSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n")).toContain("At least one --issue-type-workflow is required");
  });

  it("renders Jira status as JSON when requested", async () => {
    const jiraCommand = await freshJiraCommand();

    await jiraCommand.parseAsync(["status", "--json"], { from: "user" });

    expect(mockGetStatus).toHaveBeenCalledWith({});
    expect(logSpy).toHaveBeenCalledWith(JSON.stringify({ configured: true, projects: 2, lastPoll: "2026-01-02T00:00:00.000Z", webhookEnabled: true }, null, 2));
  });

  it("renders unconfigured Jira status guidance", async () => {
    mockGetStatus.mockResolvedValue({ configured: false, projects: 0, webhookEnabled: false });
    const jiraCommand = await freshJiraCommand();

    await jiraCommand.parseAsync(["status"], { from: "user" });

    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Jira Monitor Status");
    expect(rendered).toContain("Not configured");
    expect(rendered).toContain("foreman jira configure");
  });

  it("tests Jira connection with encrypted token", async () => {
    const jiraCommand = await freshJiraCommand();

    await jiraCommand.parseAsync([
      "test",
      "--api-url", "https://example.atlassian.net",
      "--email", "user@example.com",
      "--api-token", "plain-token",
    ], { from: "user" });

    expect(mockEncrypt).toHaveBeenCalledWith("plain-token");
    expect(mockTestConnection).toHaveBeenCalledWith({
      apiUrl: "https://example.atlassian.net",
      email: "user@example.com",
      apiToken: "encrypted-token",
    });
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Connected to Jira");
    expect(rendered).toContain("ENG");
  });

  it("emits JSON failure for test --json when connection throws", async () => {
    mockTestConnection.mockRejectedValue(new Error("bad credentials"));
    const jiraCommand = await freshJiraCommand();

    await expect(jiraCommand.parseAsync([
      "test",
      "--api-url", "https://example.atlassian.net",
      "--email", "user@example.com",
      "--api-token", "plain-token",
      "--json",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(logSpy).toHaveBeenCalledWith(JSON.stringify({ connected: false, error: "bad credentials" }, null, 2));
  });

  it("enables Jira webhook and prints setup instructions", async () => {
    const jiraCommand = await freshJiraCommand();

    await jiraCommand.parseAsync(["enable-webhook", "--secret-env", "CUSTOM_SECRET_ENV"], { from: "user" });

    expect(mockEnableWebhook).toHaveBeenCalledOnce();
    const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Webhook enabled");
    expect(rendered).toContain("CUSTOM_SECRET_ENV");
  });

  it("disables Jira webhook", async () => {
    const jiraCommand = await freshJiraCommand();

    await jiraCommand.parseAsync(["disable-webhook"], { from: "user" });

    expect(mockDisableWebhook).toHaveBeenCalledWith({});
    expect(logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n")).toContain("Webhook disabled");
  });
});
