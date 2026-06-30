import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { mockRegisterProjectInElixir, mockListRegisteredProjects } = vi.hoisted(() => ({
  mockRegisterProjectInElixir: vi.fn(),
  mockListRegisteredProjects: vi.fn(),
}));

const exitSentinel = new Error("process-exit");

vi.mock("../commands/project-task-support.js", async () => {
  const actual = await vi.importActual<typeof import("../commands/project-task-support.js")>("../commands/project-task-support.js");
  return {
    ...actual,
    registerProjectInElixir: mockRegisterProjectInElixir,
    listRegisteredProjects: mockListRegisteredProjects,
  };
});

describe("foreman project register", () => {
  let originalLog: typeof console.log;
  let originalError: typeof console.error;

  beforeEach(() => {
    vi.clearAllMocks();
    originalLog = console.log;
    originalError = console.error;
    console.log = vi.fn();
    console.error = vi.fn();
  });

  afterEach(() => {
    console.log = originalLog;
    console.error = originalError;
    vi.restoreAllMocks();
    delete process.env.FOREMAN_BACKEND;
    delete (exitSentinel as { code?: unknown }).code;
  });

  it("registers the current repository with Elixir projections", async () => {
    mockRegisterProjectInElixir.mockResolvedValue({
      id: "foreman-a1b2c",
      name: "foreman",
      path: "/repo/foreman",
      defaultBranch: "dev",
      status: "active",
    });

    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync(["register", "/repo/foreman"], { from: "user" });

    expect(mockRegisterProjectInElixir).toHaveBeenCalledWith("/repo/foreman", {
      name: undefined,
      defaultBranch: undefined,
      status: "active",
    });

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("registered with Elixir");
    expect(rendered).toContain("foreman-a1b2c");
  });

  it("lists projects through the Elixir helper instead of daemon tRPC", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    mockListRegisteredProjects.mockResolvedValue([
      { id: "foreman-a1b2c", name: "foreman", path: "/repo/foreman", defaultBranch: "dev", status: "active" },
    ]);

    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync(["list"], { from: "user" });

    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Projects (1)");
    expect(rendered).toContain("foreman-a1b2c");
  });

  it("filters Elixir projects and prints JSON output", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    mockListRegisteredProjects.mockResolvedValue([
      { id: "foreman-a1b2c", name: "foreman", path: "/repo/foreman", defaultBranch: "dev", status: "active" },
      { id: "other-b2c3d", name: "other", path: "/repo/other", defaultBranch: "main", status: "paused" },
    ]);

    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync(["list", "--status", "active", "--search", "fore", "--json"], { from: "user" });

    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(vi.mocked(console.log)).toHaveBeenCalledWith(JSON.stringify([
      { id: "foreman-a1b2c", name: "foreman", path: "/repo/foreman", status: "active" },
    ], null, 2));
  });

  it("exits with an error when Elixir registration fails", async () => {
    const exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: string | number | null) => {
      throw Object.assign(exitSentinel, { code });
    }) as never);
    mockRegisterProjectInElixir.mockRejectedValue(new Error("registration failed"));

    const { projectCommand } = await import("../commands/project.js");
    await expect(projectCommand.parseAsync(["register", "/repo/foreman"], { from: "user" })).rejects.toBe(exitSentinel);

    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("registration failed");
  });
});
