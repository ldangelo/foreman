import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { ensureRunningMock, createTrpcClientMock } = vi.hoisted(() => ({
  ensureRunningMock: vi.fn(),
  createTrpcClientMock: vi.fn(),
}));

vi.mock("../../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: class {
    authToken = undefined;
    ensureRunning = ensureRunningMock;
  },
}));

vi.mock("../../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: class {
    listProjects = vi.fn(async () => []);
  },
}));

vi.mock("../../../lib/trpc-client.js", () => ({
  createTrpcClient: createTrpcClientMock,
}));

describe("project-task-support Elixir fallback policy", () => {
  const originalBackend = process.env.FOREMAN_BACKEND;
  const originalFallback = process.env.FOREMAN_PROJECT_LEGACY_FALLBACK;

  beforeEach(() => {
    process.env.FOREMAN_BACKEND = "elixir";
    delete process.env.FOREMAN_PROJECT_LEGACY_FALLBACK;
    ensureRunningMock.mockReset();
    createTrpcClientMock.mockReset();
  });

  afterEach(() => {
    if (originalBackend === undefined) delete process.env.FOREMAN_BACKEND;
    else process.env.FOREMAN_BACKEND = originalBackend;
    if (originalFallback === undefined) delete process.env.FOREMAN_PROJECT_LEGACY_FALLBACK;
    else process.env.FOREMAN_PROJECT_LEGACY_FALLBACK = originalFallback;
  });

  it("does not fall back to tRPC/local registry when Elixir registry is unavailable", async () => {
    ensureRunningMock.mockRejectedValue(new Error("boom"));
    const { listRegisteredProjects } = await import("../project-task-support.js");

    await expect(listRegisteredProjects()).rejects.toThrow("refusing legacy daemon/local fallback");
    expect(createTrpcClientMock).not.toHaveBeenCalled();
  });

  it("refuses local path fallback when --project is missing from Elixir registry", async () => {
    ensureRunningMock.mockResolvedValue({ running: true, url: "http://127.0.0.1:4000" });
    const { resolveProjectPathFromOptions } = await import("../project-task-support.js");

    await expect(resolveProjectPathFromOptions({ project: "missing" })).rejects.toThrow("not found in Elixir project registry");
    expect(createTrpcClientMock).not.toHaveBeenCalled();
  });

  it("allows explicit mixed-cutover fallback", async () => {
    process.env.FOREMAN_PROJECT_LEGACY_FALLBACK = "true";
    ensureRunningMock.mockRejectedValue(new Error("boom"));
    createTrpcClientMock.mockReturnValue({ projects: { list: vi.fn(async () => []) } });
    const { listRegisteredProjects } = await import("../project-task-support.js");

    await expect(listRegisteredProjects()).resolves.toEqual([]);
    expect(createTrpcClientMock).toHaveBeenCalled();
  });
});
