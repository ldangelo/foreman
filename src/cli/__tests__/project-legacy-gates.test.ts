import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { mockForemanBackendMode, mockAdd, mockRemove, mockUpdate } = vi.hoisted(() => ({
  mockForemanBackendMode: vi.fn(),
  mockAdd: vi.fn(),
  mockRemove: vi.fn(),
  mockUpdate: vi.fn(),
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: mockForemanBackendMode,
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

  it("gates project add in Elixir mode", async () => {
    const { projectCommand } = await import("../commands/project.js");
    await expect(projectCommand.parseAsync(["add", "owner/repo"], { from: "user" })).rejects.toThrow("process.exit(1)");
    expect(mockAdd).not.toHaveBeenCalled();
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("legacy Node-backed only");
    expect(rendered).toContain("FOREMAN_BACKEND=node");
  });

  it("gates project remove in Elixir mode", async () => {
    const { projectCommand } = await import("../commands/project.js");
    await expect(projectCommand.parseAsync(["remove", "proj-1"], { from: "user" })).rejects.toThrow("process.exit(1)");
    expect(mockRemove).not.toHaveBeenCalled();
  });

  it("gates project edit in Elixir mode", async () => {
    const { projectCommand } = await import("../commands/project.js");
    await expect(projectCommand.parseAsync(["edit", "proj-1", "--name", "new-name"], { from: "user" })).rejects.toThrow("process.exit(1)");
    expect(mockUpdate).not.toHaveBeenCalled();
  });
});
