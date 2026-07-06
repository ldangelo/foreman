import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockCreateTrpcClient,
  mockEnsureRunning,
  mockListProjects,
  mockRegistryList,
  mockSendCommand,
} = vi.hoisted(() => ({
  mockCreateTrpcClient: vi.fn(),
  mockEnsureRunning: vi.fn(),
  mockListProjects: vi.fn(),
  mockRegistryList: vi.fn(),
  mockSendCommand: vi.fn(),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return { ensureRunning: mockEnsureRunning };
  }),
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn().mockImplementation(function MockElixirServerClient() {
    return {
      listProjects: mockListProjects,
      sendCommand: mockSendCommand,
    };
  }),
}));

vi.mock("../../lib/project-registry.js", () => ({
  ProjectRegistry: vi.fn().mockImplementation(function MockProjectRegistry() {
    return { list: mockRegistryList };
  }),
}));

describe("project-task-support Elixir mode", () => {
  const originalBackend = process.env.FOREMAN_BACKEND;

  beforeEach(() => {
    vi.clearAllMocks();
    process.env.FOREMAN_BACKEND = "elixir";
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 123 });
  });

  afterEach(() => {
    process.env.FOREMAN_BACKEND = originalBackend;
  });

  it("lists registered projects from Elixir projections before any daemon/tRPC lookup", async () => {
    mockListProjects.mockResolvedValue([
      {
        project_id: "foreman-a1b2c",
        path: "/repo/foreman",
        status: "active",
        default_branch: "dev",
        config: { name: "foreman" },
      },
    ]);

    const { listRegisteredProjects } = await import("../commands/project-task-support.js");
    const projects = await listRegisteredProjects();

    expect(projects).toEqual([
      {
        id: "foreman-a1b2c",
        name: "foreman",
        path: "/repo/foreman",
        githubUrl: undefined,
        defaultBranch: "dev",
        status: "active",
      },
    ]);
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockRegistryList).not.toHaveBeenCalled();
  });

  it("registers a project with Elixir using the existing local registry identity when available", async () => {
    mockRegistryList.mockResolvedValue([
      {
        id: "foreman-a1b2c",
        name: "foreman",
        path: "/repo/foreman",
        defaultBranch: "dev",
        status: "active",
      },
    ]);
    mockSendCommand.mockResolvedValue({
      ok: true,
      events: ["evt-1"],
      projection_version: 1,
      correlation_id: "corr-1",
    });

    const { registerProjectInElixir } = await import("../commands/project-task-support.js");
    const project = await registerProjectInElixir("/repo/foreman");

    expect(project).toEqual({
      id: "foreman-a1b2c",
      name: "foreman",
      path: "/repo/foreman",
      defaultBranch: "dev",
      status: "active",
    });
    expect(mockSendCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        command_type: "project.register",
        payload: expect.objectContaining({
          project_id: "foreman-a1b2c",
          path: "/repo/foreman",
          status: "active",
          default_branch: "dev",
        }),
      }),
    );
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
  });
});
