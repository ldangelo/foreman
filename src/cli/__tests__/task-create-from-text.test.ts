/**
 * `foreman bead` is folded into `foreman task create --from-text`.
 *
 * Both spellings delegate to the shared createTasksFromText() implementation
 * (extracted from bead.ts into create-from-text.ts). `foreman bead` stays as
 * a hidden, deprecated command that prints a one-line notice.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

const { mockCreateTasksFromText, mockForemanBackendMode } = vi.hoisted(() => ({
  mockCreateTasksFromText: vi.fn(),
  mockForemanBackendMode: vi.fn(),
}));

vi.mock("../commands/create-from-text.js", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  createTasksFromText: mockCreateTasksFromText,
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: mockForemanBackendMode,
}));

async function freshTaskCommand() {
  vi.resetModules();
  const { taskCommand } = await import("../commands/task.js");
  return taskCommand;
}

async function freshBeadCommand() {
  vi.resetModules();
  const { beadCommand } = await import("../commands/bead.js");
  return beadCommand;
}

describe("foreman task create --from-text", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;
  let errSpy: ReturnType<typeof vi.spyOn>;
  let logSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    mockCreateTasksFromText.mockResolvedValue(undefined);
    mockForemanBackendMode.mockReturnValue("node");
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
    errSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
  });

  afterEach(() => {
    exitSpy.mockRestore();
    errSpy.mockRestore();
    logSpy.mockRestore();
  });

  it("exposes the --from-text option and bead's flags on task create", async () => {
    const taskCommand = await freshTaskCommand();
    const create = taskCommand.commands.find((cmd) => cmd.name() === "create");
    const flags = create?.options.map((option) => option.long) ?? [];
    expect(flags).toContain("--from-text");
    expect(flags).toContain("--parent");
    expect(flags).toContain("--dry-run");
    expect(flags).toContain("--no-llm");
    expect(flags).toContain("--model");
    // Existing structured flags must remain
    expect(flags).toContain("--title");
    expect(flags).toContain("--type");
    expect(flags).toContain("--priority");
  });

  it("delegates --from-text to the shared createTasksFromText implementation", async () => {
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(
      [
        "create",
        "--from-text", "Add OAuth login and fix session bug",
        "--type", "bug",
        "--priority", "P1",
        "--parent", "task-abc12",
        "--dry-run",
        "--model", "claude-test-model",
      ],
      { from: "user" },
    );

    expect(mockCreateTasksFromText).toHaveBeenCalledTimes(1);
    const [description, opts] = mockCreateTasksFromText.mock.calls[0];
    expect(description).toBe("Add OAuth login and fix session bug");
    expect(opts).toEqual(
      expect.objectContaining({
        type: "bug",
        priority: "P1",
        parent: "task-abc12",
        dryRun: true,
        llm: true,
        model: "claude-test-model",
      }),
    );
  });

  it("passes llm:false when --no-llm is given with --from-text", async () => {
    const taskCommand = await freshTaskCommand();

    await taskCommand.parseAsync(
      ["create", "--from-text", "single task", "--no-llm"],
      { from: "user" },
    );

    expect(mockCreateTasksFromText).toHaveBeenCalledWith(
      "single task",
      expect.objectContaining({ llm: false }),
      undefined,
    );
  });

  it("errors clearly when --from-text is combined with --title", async () => {
    const taskCommand = await freshTaskCommand();

    await expect(
      taskCommand.parseAsync(
        ["create", "--from-text", "desc", "--title", "explicit title"],
        { from: "user" },
      ),
    ).rejects.toThrow("process.exit(1)");

    const messages = errSpy.mock.calls.map((call: unknown[]) => String(call[0]));
    expect(messages.some((line: string) => line.includes("--from-text") && line.includes("--title"))).toBe(true);
    expect(mockCreateTasksFromText).not.toHaveBeenCalled();
  });

  it("still requires --title for structured creation (no --from-text)", async () => {
    const taskCommand = await freshTaskCommand();

    await expect(
      taskCommand.parseAsync(["create", "--type", "task"], { from: "user" }),
    ).rejects.toThrow("process.exit(1)");

    const messages = errSpy.mock.calls.map((call: unknown[]) => String(call[0]));
    expect(messages.some((line: string) => line.includes("--title"))).toBe(true);
  });

  it("rejects bead-only flags without --from-text", async () => {
    const taskCommand = await freshTaskCommand();

    await expect(
      taskCommand.parseAsync(["create", "--title", "t", "--dry-run"], { from: "user" }),
    ).rejects.toThrow("process.exit(1)");

    const messages = errSpy.mock.calls.map((call: unknown[]) => String(call[0]));
    expect(messages.some((line: string) => line.includes("--from-text"))).toBe(true);
    expect(mockCreateTasksFromText).not.toHaveBeenCalled();
  });
});

describe("foreman bead (deprecated)", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;
  let errSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    mockCreateTasksFromText.mockResolvedValue(undefined);
    mockForemanBackendMode.mockReturnValue("node");
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
    errSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    exitSpy.mockRestore();
    errSpy.mockRestore();
  });

  it("prints a deprecation notice pointing at task create --from-text and delegates", async () => {
    const beadCommand = await freshBeadCommand();

    await beadCommand.parseAsync(
      ["Fix the login timeout bug", "--type", "bug", "--priority", "P0", "--no-llm", "--dry-run"],
      { from: "user" },
    );

    const notices = errSpy.mock.calls.map((call: unknown[]) => String(call[0]));
    expect(
      notices.some((line: string) => line.includes("deprecated") && line.includes("task create --from-text")),
    ).toBe(true);

    expect(mockCreateTasksFromText).toHaveBeenCalledTimes(1);
    const [description, opts] = mockCreateTasksFromText.mock.calls[0];
    expect(description).toBe("Fix the login timeout bug");
    expect(opts).toEqual(
      expect.objectContaining({
        type: "bug",
        priority: "P0",
        llm: false,
        dryRun: true,
      }),
    );
  });

  it("rejects default Elixir mode and requires explicit Node legacy mode", async () => {
    mockForemanBackendMode.mockReturnValue("elixir");
    const beadCommand = await freshBeadCommand();

    await expect(
      beadCommand.parseAsync(["Fix the login timeout bug", "--no-llm"], { from: "user" }),
    ).rejects.toThrow("process.exit(1)");

    const messages = errSpy.mock.calls.map((call: unknown[]) => String(call[0]));
    expect(messages.some((line: string) => line.includes("FOREMAN_BACKEND=node"))).toBe(true);
    expect(mockCreateTasksFromText).not.toHaveBeenCalled();
  });

  it("keeps all existing bead flags registered", async () => {
    const beadCommand = await freshBeadCommand();
    const flags = beadCommand.options.map((option) => option.long);
    expect(flags).toContain("--type");
    expect(flags).toContain("--priority");
    expect(flags).toContain("--parent");
    expect(flags).toContain("--dry-run");
    expect(flags).toContain("--no-llm");
    expect(flags).toContain("--model");
  });
});
