import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockResolveRepoRootProjectPath,
  mockListRegisteredProjects,
  mockEnsureRunning,
  mockStatus,
  mockSendCommand,
} = vi.hoisted(() => ({
  mockResolveRepoRootProjectPath: vi.fn(),
  mockListRegisteredProjects: vi.fn(),
  mockEnsureRunning: vi.fn(),
  mockStatus: vi.fn(),
  mockSendCommand: vi.fn(),
}));

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return {
      ensureRunning: mockEnsureRunning,
      status: mockStatus,
    };
  }),
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn().mockImplementation(function MockElixirServerClient() {
    return {
      sendCommand: mockSendCommand,
    };
  }),
}));

import { planCommand } from "../commands/plan.js";

describe("foreman plan server subcommands", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    process.exitCode = undefined;
    mockResolveRepoRootProjectPath.mockResolvedValue("/repo");
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "foreman", path: "/repo" }]);
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766" });
    mockStatus.mockReturnValue({ running: true, url: "http://127.0.0.1:4766" });
    mockSendCommand.mockResolvedValue({ ok: true, events: ["event-1"], projection_version: 1, correlation_id: "corr-1" });
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("dispatches foreman plan prd to the Elixir plan.prd command with trailing options", async () => {
    await planCommand.parseAsync([
      "prd",
      "Build a planning system",
      "--project",
      "foreman",
      "--output-dir",
      "docs/PRD",
      "--command-id",
      "cmd-prd",
      "--run-id",
      "run-prd",
    ], { from: "user" });

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({ project: "foreman" });
    expect(mockEnsureRunning).toHaveBeenCalledOnce();
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_id: "cmd-prd",
      command_type: "plan.prd",
      payload: expect.objectContaining({
        kind: "prd",
        project_id: "proj-1",
        description: "Build a planning system",
        output_dir: "/repo/docs/PRD",
        provider: "pi_sdk",
        run_id: "run-prd",
      }),
      metadata: { correlation_id: "cmd-prd", source: "foreman-cli-plan" },
    }));
    expect(process.exitCode).toBeUndefined();
  });

  it("dispatches foreman plan trd to the Elixir plan.trd command with trailing options", async () => {
    await planCommand.parseAsync([
      "trd",
      "Build the technical plan",
      "--project",
      "foreman",
      "--output-dir",
      "docs/TRD",
      "--command-id",
      "cmd-trd",
      "--provider",
      "pi_sdk",
    ], { from: "user" });

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({ project: "foreman" });
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_id: "cmd-trd",
      command_type: "plan.trd",
      payload: expect.objectContaining({
        kind: "trd",
        project_id: "proj-1",
        description: "Build the technical plan",
        output_dir: "/repo/docs/TRD",
        provider: "pi_sdk",
      }),
    }));
    expect(process.exitCode).toBeUndefined();
  });

  it("includes from_prd for trd when the description points to an existing project file", async () => {
    const cwd = process.cwd();
    mockResolveRepoRootProjectPath.mockResolvedValue(cwd);
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "foreman", path: cwd }]);

    await planCommand.parseAsync([
      "trd",
      "src/cli/commands/plan.ts",
      "--project",
      "foreman",
    ], { from: "user" });

    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "plan.trd",
      payload: expect.objectContaining({
        description: expect.any(String),
        from_prd: `${cwd}/src/cli/commands/plan.ts`,
      }),
    }));
  });

  it("inherits parent output-dir for server subcommands", async () => {
    await planCommand.parseAsync([
      "--output-dir",
      "docs/shared",
      "prd",
      "Build a planning system",
      "--project",
      "foreman",
    ], { from: "user" });

    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "plan.prd",
      payload: expect.objectContaining({
        output_dir: "/repo/docs/shared",
      }),
    }));
  });

  it("fails closed when no registered project matches the resolved directory", async () => {
    mockListRegisteredProjects.mockResolvedValue([]);

    await planCommand.parseAsync(["prd", "Build a planning system"], { from: "user" });

    expect(mockEnsureRunning).not.toHaveBeenCalled();
    expect(process.exitCode).toBe(1);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("Run 'foreman init' first");
  });

  it("fails closed when --no-auto-start is used and the Elixir server is not running", async () => {
    mockStatus.mockReturnValue({ running: false, url: "http://127.0.0.1:4766" });

    await planCommand.parseAsync(["prd", "Build a planning system", "--no-auto-start"], { from: "user" });

    expect(mockEnsureRunning).not.toHaveBeenCalled();
    expect(process.exitCode).toBe(1);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("Elixir server is not running");
  });

  it("reports planning command failures without throwing", async () => {
    mockSendCommand.mockResolvedValue({ ok: false, error: { message: "plan failed" } });

    await planCommand.parseAsync(["prd", "Build a planning system"], { from: "user" });

    expect(process.exitCode).toBe(1);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("Planning command failed: plan failed");
  });
});
