import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { mockAdd } = vi.hoisted(() => ({
  mockAdd: vi.fn(),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: () => ({
    projects: {
      add: mockAdd,
      list: vi.fn(),
      get: vi.fn(),
      update: vi.fn(),
      remove: vi.fn(),
      sync: vi.fn(),
    },
  }),
}));

describe("foreman project daemon error handling", () => {
  let originalExit: typeof process.exit;
  let originalError: typeof console.error;

  beforeEach(() => {
    mockAdd.mockReset();
    originalExit = process.exit;
    originalError = console.error;
    console.error = vi.fn();
    vi.stubGlobal("process", {
      ...process,
      exit: vi.fn((code?: number) => {
        throw new Error(`process.exit called with code: ${code}`);
      }) as typeof process.exit,
    });
  });

  afterEach(() => {
    process.exit = originalExit;
    console.error = originalError;
    vi.restoreAllMocks();
  });

  it("surfaces a helpful daemon connectivity message for nested empty TRPC errors", async () => {
    mockAdd.mockRejectedValue(
      Object.assign(new Error(""), {
        name: "TRPCClientError",
        cause: new AggregateError([
          Object.assign(new Error("connect ENOENT /Users/test/.foreman/daemon.sock"), {
            code: "ENOENT",
          }),
        ]),
      }),
    );

    const { projectCommand } = await import("../commands/project.js");

    await expect(
      projectCommand.parseAsync(["add", "https://github.com/FortiumPartners/ensemble"], { from: "user" }),
    ).rejects.toThrow("process.exit called with code: 1");

    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Error: Cannot connect to the Foreman daemon.");
    expect(rendered).toContain("foreman daemon start");
    expect(rendered).toContain("Underlying error: connect ENOENT");
  });
});
