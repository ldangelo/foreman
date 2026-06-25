import { beforeEach, describe, expect, it, vi } from "vitest";

const mockSendCommand = vi.fn();
const mockListEvents = vi.fn();
const mockCreateTrpcClient = vi.fn(() => {
  throw new Error("legacy tRPC should not be used in Elixir mode");
});

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: () => "elixir",
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: class {
    url = "http://127.0.0.1:4000";
    authToken = "secret";
  },
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: class {
    sendCommand = mockSendCommand;
    listEvents = mockListEvents;
  },
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

vi.mock("../../lib/encryption.js", () => ({
  encrypt: async (value: string) => `enc:${value}`,
}));

vi.mock("../../daemon/jira-api-client.js", () => ({
  JiraApiClient: class {
    async authenticate() {}
    async listProjects() {
      return [{ key: "FORE", name: "Foreman" }];
    }
  },
}));

async function runJira(args: string[]): Promise<{ stdout: string; stderr: string; exitCode?: number }> {
  const { jiraCommand } = await import("../commands/jira.js");
  const command = jiraCommand;
  let stdout = "";
  let stderr = "";
  let exitCode: number | undefined;
  command.exitOverride((err) => {
    exitCode = err.exitCode;
    throw err;
  });
  command.configureOutput({
    writeOut: (chunk) => { stdout += chunk; },
    writeErr: (chunk) => { stderr += chunk; },
  });
  const originalLog = console.log;
  const originalError = console.error;
  console.log = (...parts: unknown[]) => { stdout += `${parts.join(" ")}\n`; };
  console.error = (...parts: unknown[]) => { stderr += `${parts.join(" ")}\n`; };
  try {
    await command.parseAsync(args, { from: "user" });
  } catch {
    // commander/process.exit path captured by exitOverride or mocked process.exit in tests.
  } finally {
    console.log = originalLog;
    console.error = originalError;
  }
  return { stdout, stderr, exitCode };
}

describe("foreman jira Elixir backend parity", () => {
  beforeEach(() => {
    vi.resetModules();
    mockSendCommand.mockReset();
    mockListEvents.mockReset();
    mockCreateTrpcClient.mockClear();
    mockSendCommand.mockResolvedValue({ ok: true, events: ["evt-1"], projection_version: 1, correlation_id: "corr" });
    mockListEvents.mockResolvedValue([]);
  });

  it("routes configure through Elixir command API", async () => {
    const result = await runJira([
      "configure",
      "--api-url", "https://jira.example.com",
      "--email", "ops@example.com",
      "--api-token", "token",
      "--project", "fore",
      "--start-status", "Ready",
      "--issue-type-workflow", "task=default",
    ]);

    expect(result.stderr).toBe("");
    expect(result.stdout).toContain("Jira monitoring configured successfully");
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "jira.configure",
      payload: expect.objectContaining({
        apiUrl: "https://jira.example.com",
        email: "ops@example.com",
        apiToken: "enc:token",
      }),
    }));
  });

  it("renders status from Elixir events", async () => {
    mockListEvents.mockResolvedValue([
      {
        event_type: "CommandAccepted",
        payload: {
          command_type: "jira.configure",
          input: {
            projects: [{ key: "FORE" }, { key: "OPS" }],
            webhookEnabled: true,
          },
        },
        occurred_at: "2026-06-25T12:00:00Z",
      },
    ]);

    const result = await runJira(["status"]);

    expect(result.stdout).toContain("✓ Configured");
    expect(result.stdout).toContain("Projects monitored: 2");
    expect(result.stdout).toContain("Webhooks: enabled");
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
  });

  it("tests Jira connection directly without daemon tRPC in Elixir mode", async () => {
    const result = await runJira([
      "test",
      "--api-url", "https://jira.example.com",
      "--email", "ops@example.com",
      "--api-token", "token",
    ]);

    expect(result.stdout).toContain("✓ Connected to Jira");
    expect(result.stdout).toContain("FORE");
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
  });
});
