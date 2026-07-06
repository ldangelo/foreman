import { afterEach, describe, expect, it, vi } from "vitest";

const exitSentinel = new Error("process-exit");

function mockProcessExit() {
  return vi.spyOn(process, "exit").mockImplementation(((code?: string | number | null) => {
    throw Object.assign(exitSentinel, { code });
  }) as never);
}

afterEach(() => {
  vi.restoreAllMocks();
  vi.resetModules();
  delete (exitSentinel as { code?: unknown }).code;
});

describe("doctor command action", () => {
  it("emits JSON and exits 1 when not inside a git repository", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const exitSpy = mockProcessExit();

    vi.doMock("../commands/project-task-support.js", () => ({
      resolveRepoRootProjectPath: vi.fn().mockRejectedValue(new Error("not a repo")),
      ensureCliPostgresPool: vi.fn(),
    }));

    const { doctorCommand } = await import("../commands/doctor.js");

    await expect(doctorCommand.parseAsync(["node", "doctor", "--json"], { from: "node" })).rejects.toBe(exitSentinel);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(logSpy).toHaveBeenCalledWith(JSON.stringify({
      checks: [],
      summary: { pass: 0, warn: 0, fail: 1, fixed: 0, skip: 0 },
      error: "Not inside a git repository",
    }, null, 2));
  });

  it("prints non-JSON git-repo failure guidance", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const exitSpy = mockProcessExit();

    vi.doMock("../commands/project-task-support.js", () => ({
      resolveRepoRootProjectPath: vi.fn().mockRejectedValue(new Error("not a repo")),
      ensureCliPostgresPool: vi.fn(),
    }));

    const { doctorCommand } = await import("../commands/doctor.js");

    await expect(doctorCommand.parseAsync(["node", "doctor", "--fix", "--dry-run"], { from: "node" })).rejects.toBe(exitSentinel);
    expect(exitSpy).toHaveBeenCalledWith(1);
    const rendered = logSpy.mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("foreman doctor");
    expect(rendered).toContain("Both --fix and --dry-run specified");
    expect(rendered).toContain("Not inside a git repository");
  });

  it("runs clean-logs against the local store when the report succeeds", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const closeSpy = vi.fn();
    const localPurgeCloseSpy = vi.fn();
    const purgeLogsAction = vi.fn().mockResolvedValue(undefined);
    const runAll = vi.fn().mockResolvedValue({
      system: [{ name: "system", status: "pass", message: "ok" }],
      repository: [],
      dataIntegrity: [],
      summary: { pass: 1, warn: 0, fail: 0, fixed: 0, skip: 0 },
    });

    vi.doMock("../../lib/store.js", () => ({
      ForemanStore: {
        forProject: vi
          .fn()
          .mockReturnValueOnce({ getDb: vi.fn().mockReturnValue({}), close: closeSpy })
          .mockReturnValueOnce({ close: localPurgeCloseSpy }),
      },
    }));
    vi.doMock("../../lib/postgres-store.js", () => ({ PostgresStore: { forProject: vi.fn() } }));
    vi.doMock("../../lib/db/pool-manager.js", () => ({ destroyPool: vi.fn(), isPoolInitialised: vi.fn().mockReturnValue(true) }));
    vi.doMock("../../lib/task-client-factory.js", () => ({ createTaskClient: vi.fn().mockResolvedValue({ taskClient: {}, backendType: "native" }) }));
    vi.doMock("../../orchestrator/doctor.js", () => ({
      Doctor: class Doctor {
        runAll = runAll;
      },
    }));
    vi.doMock("../../orchestrator/merge-queue.js", () => ({ MergeQueue: class MergeQueue {} }));
    vi.doMock("../../orchestrator/postgres-merge-queue.js", () => ({ PostgresMergeQueue: class PostgresMergeQueue {} }));
    vi.doMock("../commands/project-task-support.js", () => ({
      resolveRepoRootProjectPath: vi.fn().mockResolvedValue("/tmp/project"),
      ensureCliPostgresPool: vi.fn(),
    }));
    vi.doMock("../commands/project-context.js", () => ({ findRegisteredProjectByPath: vi.fn().mockResolvedValue(null) }));
    vi.doMock("../commands/local-store-adapter.js", () => ({ wrapLocalRunStore: vi.fn((value) => value) }));
    vi.doMock("../commands/purge-logs.js", () => ({ purgeLogsAction }));

    const { doctorCommand } = await import("../commands/doctor.js");

    await doctorCommand.parseAsync(["node", "doctor", "--clean-logs", "--log-days", "3"], { from: "node" });
    expect(runAll).toHaveBeenCalledWith({ fix: false, dryRun: false, projectPath: "/tmp/project" });
    expect(purgeLogsAction).toHaveBeenCalledWith({ days: 3, dryRun: false }, { close: localPurgeCloseSpy });
    expect(closeSpy).toHaveBeenCalled();
    expect(localPurgeCloseSpy).toHaveBeenCalled();
    expect(logSpy.mock.calls.some((args) => String(args[0] ?? "").includes("Log cleanup:"))).toBe(true);
  });

  it("emits JSON error output when doctor execution throws", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const exitSpy = mockProcessExit();
    const runAll = vi.fn().mockRejectedValue(new Error("doctor exploded"));

    vi.doMock("../../lib/store.js", () => ({
      ForemanStore: {
        forProject: vi.fn().mockReturnValue({ getDb: vi.fn().mockReturnValue({}), close: vi.fn() }),
      },
    }));
    vi.doMock("../../lib/postgres-store.js", () => ({ PostgresStore: { forProject: vi.fn() } }));
    vi.doMock("../../lib/db/pool-manager.js", () => ({ destroyPool: vi.fn(), isPoolInitialised: vi.fn().mockReturnValue(true) }));
    vi.doMock("../../lib/task-client-factory.js", () => ({ createTaskClient: vi.fn().mockResolvedValue({ taskClient: {}, backendType: "native" }) }));
    vi.doMock("../../orchestrator/doctor.js", () => ({ Doctor: class Doctor { runAll = runAll; } }));
    vi.doMock("../../orchestrator/merge-queue.js", () => ({ MergeQueue: class MergeQueue {} }));
    vi.doMock("../../orchestrator/postgres-merge-queue.js", () => ({ PostgresMergeQueue: class PostgresMergeQueue {} }));
    vi.doMock("../commands/project-task-support.js", () => ({ resolveRepoRootProjectPath: vi.fn().mockResolvedValue("/tmp/project"), ensureCliPostgresPool: vi.fn() }));
    vi.doMock("../commands/project-context.js", () => ({ findRegisteredProjectByPath: vi.fn().mockResolvedValue(null) }));
    vi.doMock("../commands/local-store-adapter.js", () => ({ wrapLocalRunStore: vi.fn((value) => value) }));
    vi.doMock("../commands/purge-logs.js", () => ({ purgeLogsAction: vi.fn() }));

    const { doctorCommand } = await import("../commands/doctor.js");

    await expect(doctorCommand.parseAsync(["node", "doctor", "--json"], { from: "node" })).rejects.toBe(exitSentinel);

    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(logSpy).toHaveBeenCalledWith(JSON.stringify({ error: "doctor exploded" }, null, 2));
  });

  it("runs clean-logs against the registered Postgres store when a project is registered", async () => {
    const ensureCliPostgresPool = vi.fn();
    const closeSpy = vi.fn();
    const postgresCloseSpy = vi.fn();
    const purgeLogsAction = vi.fn().mockResolvedValue(undefined);
    const runAll = vi.fn().mockResolvedValue({
      system: [{ name: "system", status: "pass", message: "ok" }],
      repository: [],
      dataIntegrity: [],
      summary: { pass: 1, warn: 0, fail: 0, fixed: 0, skip: 0 },
    });
    const PostgresStoreForProject = vi.fn().mockReturnValue({ close: postgresCloseSpy });

    vi.doMock("../../lib/store.js", () => ({
      ForemanStore: {
        forProject: vi.fn().mockReturnValue({ getDb: vi.fn().mockReturnValue({}), close: closeSpy }),
      },
    }));
    vi.doMock("../../lib/postgres-store.js", () => ({ PostgresStore: { forProject: PostgresStoreForProject } }));
    vi.doMock("../../lib/db/pool-manager.js", () => ({ destroyPool: vi.fn(), isPoolInitialised: vi.fn().mockReturnValue(false) }));
    vi.doMock("../../lib/task-client-factory.js", () => ({ createTaskClient: vi.fn().mockResolvedValue({ taskClient: {}, backendType: "native" }) }));
    vi.doMock("../../orchestrator/doctor.js", () => ({ Doctor: class Doctor { runAll = runAll; } }));
    vi.doMock("../../orchestrator/merge-queue.js", () => ({ MergeQueue: class MergeQueue {} }));
    vi.doMock("../../orchestrator/postgres-merge-queue.js", () => ({ PostgresMergeQueue: class PostgresMergeQueue {} }));
    vi.doMock("../commands/project-task-support.js", () => ({ resolveRepoRootProjectPath: vi.fn().mockResolvedValue("/tmp/project"), ensureCliPostgresPool }));
    vi.doMock("../commands/project-context.js", () => ({ findRegisteredProjectByPath: vi.fn().mockResolvedValue({ id: "proj-1" }) }));
    vi.doMock("../commands/local-store-adapter.js", () => ({ wrapLocalRunStore: vi.fn((value) => value) }));
    vi.doMock("../commands/purge-logs.js", () => ({ purgeLogsAction }));

    const { doctorCommand } = await import("../commands/doctor.js");

    await doctorCommand.parseAsync(["node", "doctor", "--clean-logs"], { from: "node" });

    expect(ensureCliPostgresPool).toHaveBeenCalledWith("/tmp/project");
    expect(PostgresStoreForProject).toHaveBeenCalledWith("proj-1");
    expect(purgeLogsAction).toHaveBeenCalledWith({ days: 7, dryRun: false }, { close: postgresCloseSpy });
    expect(closeSpy).toHaveBeenCalled();
    expect(postgresCloseSpy).toHaveBeenCalled();
  });
});
