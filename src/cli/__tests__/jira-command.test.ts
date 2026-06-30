import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { mockCreateTrpcClient } = vi.hoisted(() => ({
  mockCreateTrpcClient: vi.fn(() => {
    throw new Error("createTrpcClient should not be used by removed Jira commands");
  }),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

async function freshJiraCommand() {
  vi.resetModules();
  const { jiraCommand } = await import("../commands/jira.js");
  return jiraCommand;
}

describe("jira command removal", () => {
  let errSpy: ReturnType<typeof vi.spyOn>;
  let exitSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    errSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  for (const args of [
    ["configure", "--api-url", "https://example.atlassian.net", "--email", "user@example.com", "--api-token", "token", "--project", "eng", "--start-status", "Selected", "--issue-type-workflow", "bug=default"],
    ["status"],
    ["status", "--json"],
    ["test", "--api-url", "https://example.atlassian.net", "--email", "user@example.com", "--api-token", "token"],
    ["enable-webhook", "--secret-env", "CUSTOM_SECRET"],
    ["disable-webhook"],
  ]) {
    it(`reports removed Jira management for: ${args.join(" ")}`, async () => {
      const jiraCommand = await freshJiraCommand();

      await expect(jiraCommand.parseAsync(args, { from: "user" })).rejects.toThrow("process.exit(1)");

      expect(exitSpy).toHaveBeenCalledWith(1);
      expect(mockCreateTrpcClient).not.toHaveBeenCalled();
      const rendered = errSpy.mock.calls.map((call: unknown[]) => String(call[0] ?? "")).join("\n");
      expect(rendered).toContain("Jira management commands were removed");
      expect(rendered).toContain("ExternalTriggerCommand");
      expect(rendered).not.toContain("FOREMAN_BACKEND=node");
    });
  }
});
