/**
 * Natural-language task creation (`foreman task create --from-text` and the
 * hidden `foreman bead` alias) was removed after the Elixir backend cutover.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

const { mockForemanBackendMode } = vi.hoisted(() => ({
  mockForemanBackendMode: vi.fn(),
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

  it("rejects --from-text without delegating to the legacy generator", async () => {
    const taskCommand = await freshTaskCommand();

    await expect(taskCommand.parseAsync(
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
    )).rejects.toThrow("process.exit(1)");

    const messages = errSpy.mock.calls.map((call: unknown[]) => String(call[0]));
    expect(messages.some((line: string) => line.includes("removed after the Elixir backend cutover"))).toBe(true);
    expect(messages.some((line: string) => line.includes("FOREMAN_BACKEND=node"))).toBe(false);
  });

  it("reports removal even when --from-text is combined with --title", async () => {
    const taskCommand = await freshTaskCommand();

    await expect(
      taskCommand.parseAsync(
        ["create", "--from-text", "desc", "--title", "explicit title"],
        { from: "user" },
      ),
    ).rejects.toThrow("process.exit(1)");

    const messages = errSpy.mock.calls.map((call: unknown[]) => String(call[0]));
    expect(messages.some((line: string) => line.includes("removed after the Elixir backend cutover"))).toBe(true);
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
  });
});

describe("foreman bead (deprecated)", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;
  let errSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
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

  it("reports removal and does not delegate", async () => {
    const beadCommand = await freshBeadCommand();

    await expect(beadCommand.parseAsync(
      ["Fix the login timeout bug", "--type", "bug", "--priority", "P0", "--no-llm", "--dry-run"],
      { from: "user" },
    )).rejects.toThrow("process.exit(1)");

    const notices = errSpy.mock.calls.map((call: unknown[]) => String(call[0]));
    expect(notices.some((line: string) => line.includes("removed after the Elixir backend cutover"))).toBe(true);
    expect(notices.some((line: string) => line.includes("FOREMAN_BACKEND=node"))).toBe(false);
  });

  it("reports the same removal in default Elixir mode", async () => {
    mockForemanBackendMode.mockReturnValue("elixir");
    const beadCommand = await freshBeadCommand();

    await expect(
      beadCommand.parseAsync(["Fix the login timeout bug", "--no-llm"], { from: "user" }),
    ).rejects.toThrow("process.exit(1)");

    const messages = errSpy.mock.calls.map((call: unknown[]) => String(call[0]));
    expect(messages.some((line: string) => line.includes("removed after the Elixir backend cutover"))).toBe(true);
    expect(messages.some((line: string) => line.includes("FOREMAN_BACKEND=node"))).toBe(false);
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
