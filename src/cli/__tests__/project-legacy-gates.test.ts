import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { mockForemanBackendMode, mockAdd, mockArchiveProjectInElixir, mockRemove, mockUpdate, mockUpdateProjectInElixir } = vi.hoisted(() => ({
  mockForemanBackendMode: vi.fn(),
  mockAdd: vi.fn(),
  mockArchiveProjectInElixir: vi.fn(),
  mockRemove: vi.fn(),
  mockUpdate: vi.fn(),
  mockUpdateProjectInElixir: vi.fn(),
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: mockForemanBackendMode,
}));

vi.mock("../commands/project-task-support.js", () => ({
  archiveProjectInElixir: mockArchiveProjectInElixir,
  listRegisteredProjects: vi.fn(),
  registerProjectInElixir: vi.fn(),
  updateProjectInElixir: mockUpdateProjectInElixir,
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: () => ({
    projects: {
      add: mockAdd,
      list: vi.fn(),
      get: vi.fn(),
      update: mockUpdate,
      remove: mockRemove,
      sync: vi.fn(),
    },
  }),
}));

describe("foreman project legacy gates", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockForemanBackendMode.mockReturnValue("elixir");
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("removes project add in Elixir mode without Node fallback guidance", async () => {
    const { projectCommand } = await import("../commands/project.js");
    await expect(projectCommand.parseAsync(["add", "owner/repo"], { from: "user" })).rejects.toThrow("process.exit(1)");
    expect(mockAdd).not.toHaveBeenCalled();
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("removed after the Elixir backend cutover");
    expect(rendered).toContain("project register");
    expect(rendered).not.toContain("FOREMAN_BACKEND=node");
  });

  it("archives projects through Elixir in Elixir mode", async () => {
    mockArchiveProjectInElixir.mockResolvedValue(undefined);
    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync(["remove", "proj-1"], { from: "user" });
    expect(mockArchiveProjectInElixir).toHaveBeenCalledWith("proj-1", { force: false });
    expect(mockRemove).not.toHaveBeenCalled();
  });

  it("edits project metadata through Elixir in Elixir mode", async () => {
    mockUpdateProjectInElixir.mockResolvedValue(undefined);
    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync(["edit", "proj-1", "--name", "new-name"], { from: "user" });
    expect(mockUpdateProjectInElixir).toHaveBeenCalledWith("proj-1", {
      name: "new-name",
      status: undefined,
      defaultBranch: undefined,
    });
    expect(mockUpdate).not.toHaveBeenCalled();
  });
});
