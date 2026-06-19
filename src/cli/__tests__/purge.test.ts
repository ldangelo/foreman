/**
 * `foreman purge` groups the log/run cleanup commands:
 *   foreman purge logs   (formerly: foreman purge-logs)
 *   foreman purge runs   (formerly: foreman purge-zombie-runs)
 *
 * The old top-level spellings stay registered as hidden, deprecated commands
 * that print a one-line notice and delegate to the same handlers.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

const { mockPurgeLogsCommandAction, mockPurgeZombieRunsCommandAction } = vi.hoisted(() => ({
  mockPurgeLogsCommandAction: vi.fn(),
  mockPurgeZombieRunsCommandAction: vi.fn(),
}));

vi.mock("../commands/purge-logs.js", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  purgeLogsCommandAction: mockPurgeLogsCommandAction,
}));

vi.mock("../commands/purge-zombie-runs.js", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  purgeZombieRunsCommandAction: mockPurgeZombieRunsCommandAction,
}));

type PurgeModule = typeof import("../commands/purge.js");

async function freshPurgeModule(): Promise<PurgeModule> {
  vi.resetModules();
  return await import("../commands/purge.js");
}

describe("foreman purge", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;
  let errSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    mockPurgeLogsCommandAction.mockResolvedValue(undefined);
    mockPurgeZombieRunsCommandAction.mockResolvedValue(0);
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
    errSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    exitSpy.mockRestore();
    errSpy.mockRestore();
  });

  it("exposes a 'purge' group with 'logs' and 'runs' subcommands", async () => {
    const { purgeCommand } = await freshPurgeModule();
    expect(purgeCommand.name()).toBe("purge");
    const subNames = purgeCommand.commands.map((cmd) => cmd.name());
    expect(subNames).toContain("logs");
    expect(subNames).toContain("runs");
  });

  it("'purge logs' supports the same flags as the old purge-logs command", async () => {
    const { purgeCommand } = await freshPurgeModule();
    const logs = purgeCommand.commands.find((cmd) => cmd.name() === "logs");
    const flags = logs?.options.map((option) => option.long) ?? [];
    expect(flags).toContain("--days");
    expect(flags).toContain("--dry-run");
    expect(flags).toContain("--all");
  });

  it("'purge runs' supports the same flags as the old purge-zombie-runs command", async () => {
    const { purgeCommand } = await freshPurgeModule();
    const runs = purgeCommand.commands.find((cmd) => cmd.name() === "runs");
    const flags = runs?.options.map((option) => option.long) ?? [];
    expect(flags).toContain("--dry-run");
  });

  it("'purge logs' delegates to purgeLogsCommandAction with parsed options", async () => {
    const { purgeCommand } = await freshPurgeModule();

    await purgeCommand.parseAsync(["logs", "--days", "3", "--dry-run", "--all"], { from: "user" });

    expect(mockPurgeLogsCommandAction).toHaveBeenCalledTimes(1);
    expect(mockPurgeLogsCommandAction).toHaveBeenCalledWith(
      expect.objectContaining({ days: 3, dryRun: true, all: true }),
    );
    // No deprecation notice on the new spelling
    expect(errSpy).not.toHaveBeenCalled();
  });

  it("'purge runs' delegates to purgeZombieRunsCommandAction and exits with its code", async () => {
    mockPurgeZombieRunsCommandAction.mockResolvedValue(1);
    const { purgeCommand } = await freshPurgeModule();

    await expect(
      purgeCommand.parseAsync(["runs", "--dry-run"], { from: "user" }),
    ).rejects.toThrow("process.exit(1)");

    expect(mockPurgeZombieRunsCommandAction).toHaveBeenCalledTimes(1);
    expect(mockPurgeZombieRunsCommandAction).toHaveBeenCalledWith(
      expect.objectContaining({ dryRun: true }),
    );
  });

  it("'purge logs' rejects non-integer --days values instead of truncating them", async () => {
    const { purgeCommand } = await freshPurgeModule();

    await expect(
      purgeCommand.parseAsync(["logs", "--days", "1.5"], { from: "user" }),
    ).rejects.toThrow("process.exit(1)");

    expect(mockPurgeLogsCommandAction).not.toHaveBeenCalled();
  });

  it("'purge logs' rejects trailing-garbage --days values like '7abc'", async () => {
    const { purgeCommand } = await freshPurgeModule();

    await expect(
      purgeCommand.parseAsync(["logs", "--days", "7abc"], { from: "user" }),
    ).rejects.toThrow("process.exit(1)");

    expect(mockPurgeLogsCommandAction).not.toHaveBeenCalled();
  });

  it("deprecated 'purge-logs' prints a notice and runs the same handler", async () => {
    const { purgeLogsCommand } = await freshPurgeModule();

    await purgeLogsCommand.parseAsync(["--days", "5", "--dry-run"], { from: "user" });

    const notices = errSpy.mock.calls.map((call: unknown[]) => String(call[0]));
    expect(notices.some((line: string) => line.includes("deprecated") && line.includes("foreman purge logs"))).toBe(true);
    expect(mockPurgeLogsCommandAction).toHaveBeenCalledWith(
      expect.objectContaining({ days: 5, dryRun: true }),
    );
  });

  it("deprecated 'purge-zombie-runs' prints a notice and runs the same handler", async () => {
    const { purgeZombieRunsCommand } = await freshPurgeModule();

    await expect(
      purgeZombieRunsCommand.parseAsync(["--dry-run"], { from: "user" }),
    ).rejects.toThrow("process.exit(0)");

    const notices = errSpy.mock.calls.map((call: unknown[]) => String(call[0]));
    expect(notices.some((line: string) => line.includes("deprecated") && line.includes("foreman purge runs"))).toBe(true);
    expect(mockPurgeZombieRunsCommandAction).toHaveBeenCalledWith(
      expect.objectContaining({ dryRun: true }),
    );
  });
});
