import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockResolveProjectPath,
  mockCreateTrpcClient,
  mockRegistryList,
  mockCreateVcsBackend,
} = vi.hoisted(() => ({
  mockResolveProjectPath: vi.fn(),
  mockCreateTrpcClient: vi.fn(),
  mockRegistryList: vi.fn(),
  mockCreateVcsBackend: vi.fn(),
}));

vi.mock("../../lib/project-path.js", () => ({
  resolveProjectPath: mockResolveProjectPath,
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: () => "node",
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

vi.mock("../../lib/project-registry.js", () => ({
  ProjectRegistry: vi.fn().mockImplementation(function MockProjectRegistry() {
    return { list: mockRegistryList };
  }),
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockCreateVcsBackend,
  },
}));

vi.mock("../../lib/db/pool-manager.js", () => ({
  initPool: vi.fn(),
  isPoolInitialised: vi.fn(() => false),
}));

describe("project-task-support node mode", () => {
  const originalCwd = process.cwd;

  beforeEach(() => {
    vi.clearAllMocks();
    mockResolveProjectPath.mockResolvedValue("/resolved/local");
    mockRegistryList.mockResolvedValue([]);
    mockCreateVcsBackend.mockResolvedValue({
      getRepoRoot: vi.fn().mockResolvedValue("/repo/root"),
      getRemoteUrl: vi.fn().mockResolvedValue(undefined),
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    process.cwd = originalCwd;
  });

  it("lists registered projects through node tRPC when available", async () => {
    const list = vi.fn().mockResolvedValue([
      {
        id: "proj-1",
        name: "alpha",
        path: "/projects/alpha",
        githubUrl: "https://github.com/acme/alpha",
        defaultBranch: "main",
        status: "active",
      },
    ]);
    mockCreateTrpcClient.mockReturnValue({ projects: { list } });

    const { listRegisteredProjects } = await import("../commands/project-task-support.js");
    const projects = await listRegisteredProjects();

    expect(projects).toEqual([
      {
        id: "proj-1",
        name: "alpha",
        path: "/projects/alpha",
        githubUrl: "https://github.com/acme/alpha",
        defaultBranch: "main",
        status: "active",
      },
    ]);
    expect(mockRegistryList).not.toHaveBeenCalled();
  });

  it("falls back to the local registry when node tRPC listing fails", async () => {
    mockCreateTrpcClient.mockReturnValue({
      projects: { list: vi.fn().mockRejectedValue(new Error("daemon down")) },
    });
    mockRegistryList.mockResolvedValue([
      {
        id: "proj-2",
        name: "beta",
        path: "/projects/beta",
        githubUrl: "https://github.com/acme/beta",
        defaultBranch: "dev",
        status: "paused",
      },
    ]);

    const { listRegisteredProjects } = await import("../commands/project-task-support.js");
    const projects = await listRegisteredProjects();

    expect(projects).toEqual([
      {
        id: "proj-2",
        name: "beta",
        path: "/projects/beta",
        githubUrl: "https://github.com/acme/beta",
        defaultBranch: "dev",
        status: "paused",
      },
    ]);
  });

  it("resolves project paths by registered id or name before local fallback", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "proj-1", name: "alpha", path: "/projects/alpha" },
    ]);
    mockCreateTrpcClient.mockReturnValue({ projects: { list } });

    const { resolveProjectPathFromOptions } = await import("../commands/project-task-support.js");

    await expect(resolveProjectPathFromOptions({ project: "proj-1" })).resolves.toBe("/projects/alpha");
    await expect(resolveProjectPathFromOptions({ project: "alpha" })).resolves.toBe("/projects/alpha");
    expect(mockResolveProjectPath).not.toHaveBeenCalled();
  });

  it("falls back to the local project-path resolver when no registered project matches", async () => {
    const list = vi.fn().mockResolvedValue([
      { id: "proj-1", name: "alpha", path: "/projects/alpha" },
    ]);
    mockCreateTrpcClient.mockReturnValue({ projects: { list } });

    const { resolveProjectPathFromOptions } = await import("../commands/project-task-support.js");
    const result = await resolveProjectPathFromOptions({ project: "missing" });

    expect(result).toBe("/resolved/local");
    expect(mockResolveProjectPath).toHaveBeenCalledWith({ project: "missing" });
  });

  it("maps git origin remotes back to a registered project path", async () => {
    const getRepoRoot = vi.fn().mockResolvedValue("/repo/root");
    const getRemoteUrl = vi.fn().mockResolvedValue("git@github.com:acme/alpha.git");
    mockCreateVcsBackend.mockResolvedValue({ getRepoRoot, getRemoteUrl });
    mockCreateTrpcClient.mockReturnValue({
      projects: {
        list: vi.fn().mockResolvedValue([
          {
            id: "proj-1",
            name: "alpha",
            path: "/projects/alpha",
            githubUrl: "https://github.com/acme/alpha.git",
          },
        ]),
      },
    });
    process.cwd = vi.fn(() => "/repo/root") as typeof process.cwd;

    const { resolveRepoRootProjectPath } = await import("../commands/project-task-support.js");
    const result = await resolveRepoRootProjectPath({});

    expect(result).toBe("/projects/alpha");
    expect(getRepoRoot).toHaveBeenCalledWith("/repo/root");
    expect(getRemoteUrl).toHaveBeenCalledWith("/repo/root", "origin");
  });

  it("falls back to the repo root when remote lookup fails or no project matches", async () => {
    const getRepoRoot = vi.fn().mockResolvedValue("/repo/root");
    const getRemoteUrl = vi.fn().mockRejectedValue(new Error("no remote"));
    mockCreateVcsBackend.mockResolvedValue({ getRepoRoot, getRemoteUrl });
    mockCreateTrpcClient.mockReturnValue({
      projects: { list: vi.fn().mockResolvedValue([]) },
    });
    process.cwd = vi.fn(() => "/repo/root") as typeof process.cwd;

    const { resolveRepoRootProjectPath } = await import("../commands/project-task-support.js");
    const result = await resolveRepoRootProjectPath({});

    expect(result).toBe("/repo/root");
  });
});
