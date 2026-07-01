import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync, utimesSync, writeFileSync, existsSync } from "node:fs";
import { promises as nodeFs } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const {
  mockResolveProjectContext,
  mockForemanStoreForProject,
  mockPostgresStoreForProject,
  mockCloseStoreIfPossible,
} = vi.hoisted(() => ({
  mockResolveProjectContext: vi.fn(),
  mockForemanStoreForProject: vi.fn(),
  mockPostgresStoreForProject: vi.fn(),
  mockCloseStoreIfPossible: vi.fn(),
}));

vi.mock("../commands/project-context.js", () => ({
  resolveProjectContext: (...args: unknown[]) => mockResolveProjectContext(...args),
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: { forProject: (...args: unknown[]) => mockForemanStoreForProject(...args) },
}));

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: { forProject: (...args: unknown[]) => mockPostgresStoreForProject(...args) },
}));

vi.mock("../commands/local-store-adapter.js", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  closeStoreIfPossible: (...args: unknown[]) => mockCloseStoreIfPossible(...args),
}));

import type { Run } from "../../lib/store.js";
import { purgeLogsAction, purgeLogsCommandAction } from "../commands/purge-logs.js";

describe("purge-logs", () => {
  function makeRun(id: string, status: Run["status"]): Run {
    return {
      id,
      project_id: "proj-1",
      task_id: "task-1",
      agent_type: "developer",
      session_key: null,
      worktree_path: null,
      status,
      started_at: null,
      completed_at: null,
      created_at: new Date(0).toISOString(),
      progress: null,
      base_branch: null,
      merge_strategy: null,
    };
  }

  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-purge-logs-"));
    tempDirs.push(dir);
    return dir;
  }

  function writeLogGroup(dir: string, runId: string, ageDays: number, suffixes = ["log", "err", "out"]): string[] {
    const now = Date.now();
    return suffixes.map((suffix) => {
      const file = join(dir, `${runId}.${suffix}`);
      writeFileSync(file, `${runId}-${suffix}`);
      const when = new Date(now - ageDays * 24 * 60 * 60 * 1000);
      utimesSync(file, when, when);
      return file;
    });
  }

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
    tempDirs.length = 0;
    vi.restoreAllMocks();
  });

  it("returns cleanly when the logs directory does not exist", async () => {
    const dir = join(makeTempDir(), "missing");
    const store = { getRun: vi.fn() };

    const result = await purgeLogsAction({ days: 7 }, store, dir);

    expect(result).toEqual({ checked: 0, deleted: 0, skipped: 0, errors: 0, freedBytes: 0 });
    expect(store.getRun).not.toHaveBeenCalled();
  });

  it("dry-run counts terminal and orphaned old groups without deleting files", async () => {
    const dir = makeTempDir();
    const terminalRun = "11111111-1111-1111-1111-111111111111";
    const orphanRun = "22222222-2222-2222-2222-222222222222";
    writeLogGroup(dir, terminalRun, 10);
    writeLogGroup(dir, orphanRun, 8, ["log"]);

    const store = {
      getRun: vi.fn(async (id: string) => (id === terminalRun ? makeRun(id, "completed") : null)),
    };

    const result = await purgeLogsAction({ days: 7, dryRun: true }, store, dir);

    expect(result.checked).toBe(2);
    expect(result.deleted).toBe(2);
    expect(result.skipped).toBe(0);
    expect(result.errors).toBe(0);
    expect(result.freedBytes).toBeGreaterThan(0);
    expect(existsSync(join(dir, `${terminalRun}.log`))).toBe(true);
    expect(existsSync(join(dir, `${orphanRun}.log`))).toBe(true);
  });

  it("skips recent and active run groups for safety", async () => {
    const dir = makeTempDir();
    const recentRun = "33333333-3333-3333-3333-333333333333";
    const activeRun = "44444444-4444-4444-4444-444444444444";
    writeLogGroup(dir, recentRun, 1);
    writeLogGroup(dir, activeRun, 10);

    const store = {
      getRun: vi.fn(async (id: string) => (id === activeRun ? makeRun(id, "running") : null)),
    };

    const result = await purgeLogsAction({ days: 7 }, store, dir);

    expect(result.checked).toBe(2);
    expect(result.deleted).toBe(0);
    expect(result.skipped).toBe(2);
    expect(existsSync(join(dir, `${recentRun}.log`))).toBe(true);
    expect(existsSync(join(dir, `${activeRun}.log`))).toBe(true);
  });

  it("deletes eligible files in non-dry-run mode", async () => {
    const dir = makeTempDir();
    const runId = "55555555-5555-5555-5555-555555555555";
    const files = writeLogGroup(dir, runId, 10);

    const store = {
      getRun: vi.fn(async () => makeRun(runId, "failed")),
    };

    const result = await purgeLogsAction({ days: 7 }, store, dir);

    expect(result).toMatchObject({ checked: 1, deleted: 1, skipped: 0, errors: 0 });
    for (const file of files) expect(existsSync(file)).toBe(false);
  });

  it("purgeLogsCommandAction exits 0 and closes stores after success", async () => {
    const localStore = { close: vi.fn() };
    const postgresStore = { getRun: vi.fn(), close: vi.fn() };
    const enoent = Object.assign(new Error("missing"), { code: "ENOENT" });
    const exitSpy = vi.spyOn(process, "exit").mockImplementation((() => undefined) as never);
    mockResolveProjectContext.mockResolvedValue({
      projectPath: "/tmp/project",
      registered: { id: "proj-1", name: "Foreman", path: "/tmp/project" },
    });
    mockForemanStoreForProject.mockReturnValue(localStore);
    mockPostgresStoreForProject.mockReturnValue(postgresStore);
    vi.spyOn(nodeFs, "readdir").mockRejectedValue(enoent);

    await purgeLogsCommandAction({ days: 7 });

    expect(exitSpy).toHaveBeenCalledWith(0);
    expect(localStore.close).toHaveBeenCalled();
    expect(mockCloseStoreIfPossible).toHaveBeenCalledWith(postgresStore);
  });

  it("purgeLogsCommandAction exits 1 when project context cannot be resolved", async () => {
    mockResolveProjectContext.mockRejectedValue(new Error("no repo"));

    await expect(purgeLogsCommandAction({ days: 7 })).rejects.toThrow("process.exit(1)");

    const output = vi.mocked(console.error).mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(output).toContain("Not in a git repository");
  });
});
