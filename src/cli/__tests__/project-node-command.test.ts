import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { mockListRegisteredProjects, mockUpdateProjectInElixir } = vi.hoisted(() => ({
  mockListRegisteredProjects: vi.fn(),
  mockUpdateProjectInElixir: vi.fn(),
}));

vi.mock("../commands/project-task-support.js", async () => {
  const actual = await vi.importActual<typeof import("../commands/project-task-support.js")>("../commands/project-task-support.js");
  return {
    ...actual,
    listRegisteredProjects: mockListRegisteredProjects,
    updateProjectInElixir: mockUpdateProjectInElixir,
  };
});

describe("foreman project post-legacy commands", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("lists projects through the Elixir registry regardless of backend env", async () => {
    process.env.FOREMAN_BACKEND = "node";
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "foreman", path: "/repo/foreman", status: "active" },
    ]);

    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync(["list", "--json"], { from: "user" });

    expect(mockListRegisteredProjects).toHaveBeenCalledWith({ includeArchived: false });
    expect(vi.mocked(console.log)).toHaveBeenCalledWith(JSON.stringify([
      { id: "proj-1", name: "foreman", path: "/repo/foreman", status: "active" },
    ], null, 2));
  });

  it("rejects removed project add without legacy backend guidance", async () => {
    const { projectCommand } = await import("../commands/project.js");

    await expect(projectCommand.parseAsync(["add", "owner/repo"], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(exitSpy).toHaveBeenCalledWith(1);
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("removed after the Elixir backend cutover");
    expect(rendered).not.toContain("FOREMAN_BACKEND=node");
  });

  it("rejects Jira project edit flags without legacy backend guidance", async () => {
    const { projectCommand } = await import("../commands/project.js");

    await expect(projectCommand.parseAsync(["edit", "proj-1", "--jira-url", "https://example.atlassian.net"], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(mockUpdateProjectInElixir).not.toHaveBeenCalled();
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Jira project settings are not part of the Elixir project edit surface");
    expect(rendered).not.toContain("FOREMAN_BACKEND=node");
  });
});
