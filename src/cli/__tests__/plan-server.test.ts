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
  const originalBackend = process.env.FOREMAN_BACKEND;

  beforeEach(() => {
    delete process.env.FOREMAN_BACKEND;
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
    if (originalBackend === undefined) delete process.env.FOREMAN_BACKEND;
    else process.env.FOREMAN_BACKEND = originalBackend;
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

  it("dispatches bare foreman plan through Elixir PRD and TRD planning", async () => {
    await planCommand.parseAsync([
      "Build a planning system",
      "--project",
      "foreman",
      "--output-dir",
      "docs/plans",
    ], { from: "user" });

    expect(mockSendCommand).toHaveBeenCalledTimes(2);
    expect(mockSendCommand).toHaveBeenNthCalledWith(1, expect.objectContaining({
      command_type: "plan.prd",
      payload: expect.objectContaining({
        kind: "prd",
        project_id: "proj-1",
        description: "Build a planning system",
        output_dir: "/repo/docs/plans",
      }),
    }));
    expect(mockSendCommand).toHaveBeenNthCalledWith(2, expect.objectContaining({
      command_type: "plan.trd",
      payload: expect.objectContaining({
        kind: "trd",
        project_id: "proj-1",
        description: "/repo/docs/plans/PRD.md",
        output_dir: "/repo/docs/plans",
      }),
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
});
