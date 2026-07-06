import { beforeEach, describe, expect, it, vi } from "vitest";

const { mockListProjects, MockElixirTaskClient, MockElixirServerClient } = vi.hoisted(() => {
  const mockListProjects = vi.fn();
  const MockElixirServerClient = vi.fn(function MockElixirServerClientImpl(this: Record<string, unknown>) {
    this.listProjects = mockListProjects;
  });
  const MockElixirTaskClient = vi.fn(function MockElixirTaskClientImpl(this: Record<string, unknown>, projectPath: string, projectId: string) {
    this.projectPath = projectPath;
    this.projectId = projectId;
  });
  return { mockListProjects, MockElixirTaskClient, MockElixirServerClient };
});

vi.mock("../elixir-server-client.js", () => ({
  ElixirServerClient: MockElixirServerClient,
}));

vi.mock("../elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn(function MockElixirServerManager(this: Record<string, unknown>) {
    this.ensureRunning = vi.fn().mockResolvedValue({ url: "http://server.test" });
  }),
}));

vi.mock("../elixir-task-client.js", () => ({
  ElixirTaskClient: MockElixirTaskClient,
}));

import { createTaskClient } from "../task-client-factory.js";

describe("task-client-factory Elixir selection", () => {
  const projectPath = "/mock/project";

  beforeEach(() => {
    vi.clearAllMocks();
    mockListProjects.mockResolvedValue([]);
    vi.stubEnv("FOREMAN_SERVER_URL", "http://server.test");
  });

  it("creates an Elixir task client for a registered project path", async () => {
    mockListProjects.mockResolvedValue([{ id: "proj-1", name: "foreman", path: projectPath }]);

    const result = await createTaskClient(projectPath);

    expect(result.backendType).toBe("native");
    expect(MockElixirServerClient).toHaveBeenCalledWith("http://server.test", undefined);
    expect(MockElixirTaskClient).toHaveBeenCalledWith(projectPath, "proj-1");
  });

  it("keeps selection pinned by provided project id without projection lookup", async () => {
    const result = await createTaskClient(projectPath, { registeredProjectId: "proj-1" });

    expect(result.backendType).toBe("native");
    expect(mockListProjects).not.toHaveBeenCalled();
    expect(MockElixirTaskClient).toHaveBeenCalledWith(projectPath, "proj-1");
  });

  it("fails fast when no registered Elixir project is available", async () => {
    await expect(createTaskClient(projectPath)).rejects.toThrow("not registered in Elixir projections");
  });
});
