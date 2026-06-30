import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { mockArchiveProjectInElixir, mockRegisterProjectInElixir, mockListRegisteredProjects, mockUpdateProjectInElixir } = vi.hoisted(() => ({
  mockArchiveProjectInElixir: vi.fn(),
  mockRegisterProjectInElixir: vi.fn(),
  mockListRegisteredProjects: vi.fn(),
  mockUpdateProjectInElixir: vi.fn(),
}));

const exitSentinel = new Error("process-exit");

vi.mock("../commands/project-task-support.js", async () => {
  const actual = await vi.importActual<typeof import("../commands/project-task-support.js")>("../commands/project-task-support.js");
  return {
    ...actual,
    archiveProjectInElixir: mockArchiveProjectInElixir,
    registerProjectInElixir: mockRegisterProjectInElixir,
    listRegisteredProjects: mockListRegisteredProjects,
    updateProjectInElixir: mockUpdateProjectInElixir,
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

    expect(mockListRegisteredProjects).toHaveBeenCalledWith({ includeArchived: false });
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

    expect(mockListRegisteredProjects).toHaveBeenCalledWith({ includeArchived: true });
    expect(vi.mocked(console.log)).toHaveBeenCalledWith(JSON.stringify([
      { id: "foreman-a1b2c", name: "foreman", path: "/repo/foreman", status: "active" },
    ], null, 2));
  });

  it("archives projects through Elixir instead of requiring Node mode", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    mockArchiveProjectInElixir.mockResolvedValue(undefined);

    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync(["remove", "proj-1", "--force"], { from: "user" });

    expect(mockArchiveProjectInElixir).toHaveBeenCalledWith("proj-1", { force: true });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("archived");
  });

  it("updates project metadata through Elixir", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    mockUpdateProjectInElixir.mockResolvedValue(undefined);

    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync(["edit", "proj-1", "--name", "Renamed", "--status", "paused", "--default-branch", "dev"], { from: "user" });

    expect(mockUpdateProjectInElixir).toHaveBeenCalledWith("proj-1", {
      name: "Renamed",
      status: "paused",
      defaultBranch: "dev",
    });
  });

  it("rejects removed project add without Node fallback guidance", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: string | number | null) => {
      throw Object.assign(exitSentinel, { code });
    }) as never);

    const { projectCommand } = await import("../commands/project.js");
    await expect(projectCommand.parseAsync(["add", "owner/repo"], { from: "user" })).rejects.toBe(exitSentinel);

    expect(exitSpy).toHaveBeenCalledWith(1);
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("removed after the Elixir backend cutover");
    expect(rendered).toContain("project register");
    expect(rendered).not.toContain("FOREMAN_BACKEND=node");
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
