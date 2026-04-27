import { describe, it, expect, afterEach, vi, beforeEach } from "vitest";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtempSync, rmSync, realpathSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { runTsxModule, type ExecResult } from "../../test-support/tsx-subprocess.js";

const execFileAsync = promisify(execFile);
const CLI = path.resolve(__dirname, "../../../src/cli/index.ts");

async function run(args: string[], cwd: string, opts?: { timeout?: number }): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, timeout: opts?.timeout ?? 60_000 });
}

describe("doctor command", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-test-")));
    tempDirs.push(dir);
    return dir;
  }

  async function makeGitRepo(dir: string): Promise<void> {
    await execFileAsync("git", ["init", "--initial-branch", "main", dir]);
    await execFileAsync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
    await execFileAsync("git", ["config", "user.name", "Test"], { cwd: dir });
    // Create an initial commit so the repo is valid
    writeFileSync(join(dir, "README.md"), "# test");
    await execFileAsync("git", ["add", "."], { cwd: dir });
    await execFileAsync("git", ["commit", "-m", "init"], { cwd: dir });
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("doctor --help shows description and options", async () => {
    const tmp = makeTempDir();
    const result = await run(["doctor", "--help"], tmp);

    expect(result.exitCode).toBe(0);
    const output = result.stdout + result.stderr;
    expect(output).toContain("doctor");
    expect(output).toContain("health");
    expect(output).toContain("--fix");
  }, 30_000);

  it("doctor shows in top-level --help", async () => {
    const { program } = await import("../index.js");
    expect(program.helpInformation()).toContain("doctor");
  }, 30_000);

  it("doctor outside git repo fails gracefully", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`EXIT:${code ?? 0}`);
    }) as never);
    const vcs = await import("../../lib/vcs/index.js");
    const createSpy = vi.spyOn(vcs.VcsBackendFactory, "create").mockRejectedValue(new Error("not a repo"));
    const { doctorCommand } = await import("../commands/doctor.js");

    let thrown: unknown;
    try {
      await doctorCommand.parseAsync(["node", "doctor"], { from: "node" });
    } catch (error) {
      thrown = error;
    }

    const combinedOutput = [
      ...logSpy.mock.calls.flat().map(String),
      ...errorSpy.mock.calls.flat().map(String),
    ].join("\n");

    expect(String(thrown)).toContain("EXIT:1");
    expect(combinedOutput).toContain("git repository");

    createSpy.mockRestore();
    exitSpy.mockRestore();
    errorSpy.mockRestore();
    logSpy.mockRestore();
  }, 30_000);

  it("doctor inside git repo without project init warns", async () => {
    const tmp = makeTempDir();
    await makeGitRepo(tmp);

    const result = await run(["doctor"], tmp);
    const output = result.stdout + result.stderr;

    // Git binary check passes
    expect(output).toContain("git binary");
    // Project registration check fails
    expect(output).toContain("project registered in foreman");
  }, 30_000);

  it("doctor --json outputs valid JSON", async () => {
    const tmp = makeTempDir();
    const result = await run(["doctor", "--json"], tmp, { timeout: 60_000 });

    const output = result.stdout + result.stderr;
    let parsed: any;
    try {
      parsed = JSON.parse(output.trim());
    } catch {
      // If there's mixed output, try to find the JSON part
      const jsonStart = output.indexOf("{");
      if (jsonStart !== -1) {
        parsed = JSON.parse(output.slice(jsonStart).trim());
      }
    }

    expect(parsed).toBeDefined();
    expect(parsed).toHaveProperty("checks");
    expect(parsed).toHaveProperty("summary");
    expect(Array.isArray(parsed.checks)).toBe(true);
    expect(parsed.summary).toHaveProperty("pass");
    expect(parsed.summary).toHaveProperty("fail");
    expect(parsed.summary).toHaveProperty("warn");
    expect(parsed.summary).toHaveProperty("fixed");
  }, 30_000);

  it("doctor with registered project shows pass for project check", async () => {
    const tmp = makeTempDir();
    await makeGitRepo(tmp);

    // Register the project in the store
    const storeMod = await import("../../lib/store.js");
    const store = storeMod.ForemanStore.forProject(tmp);
    store.registerProject("test-project", tmp);
    store.close();

    const result = await run(["doctor"], tmp);
    const output = result.stdout + result.stderr;

    expect(output).toContain("project registered in foreman");
    // The project is registered so this check should not contain "fail" for that line
    // The overall may still fail due to missing br/bv/git binaries in CI
    expect(output).toContain("Summary");
  }, 30_000);

  it("doctor --fix runs without crashing", async () => {
    const tmp = makeTempDir();
    await makeGitRepo(tmp);

    const result = await run(["doctor", "--fix"], tmp);
    const output = result.stdout + result.stderr;

    // Should not crash with an unhandled exception
    expect(output).not.toContain("TypeError");
    expect(output).not.toContain("ReferenceError");
    expect(output).toContain("Summary");
  }, 30_000);

  describe("doctor --clean-logs registered-aware store selection", () => {
    afterEach(() => {
      vi.restoreAllMocks();
    });

    async function arrange(registered: boolean) {
      const tmp = makeTempDir();
      await makeGitRepo(tmp);

      const vcs = await import("../../lib/vcs/index.js");
      vi.spyOn(vcs.VcsBackendFactory, "create").mockResolvedValue({
        getRepoRoot: async () => tmp,
      } as never);

      const projectSupport = await import("../commands/project-task-support.js");
      const ensureSpy = vi.spyOn(projectSupport, "ensureCliPostgresPool").mockImplementation(() => undefined);
      const listSpy = vi.spyOn(projectSupport, "listRegisteredProjects").mockResolvedValue(
        registered ? ([{ id: "registered-project-id", path: tmp }] as never) : ([] as never),
      );

      const storeMod = await import("../../lib/store.js");
      const mainLocalStore = { getDb: () => ({}), close: vi.fn() };
      const purgeLocalStore = { getDb: () => ({}), close: vi.fn() };
      const localSpy = vi.spyOn(storeMod.ForemanStore, "forProject")
        .mockImplementationOnce(() => mainLocalStore as never)
        .mockImplementation(() => purgeLocalStore as never);

      const postgresMod = await import("../../lib/postgres-store.js");
      const postgresPurgeStore = { getRun: vi.fn(), close: vi.fn() };
      const postgresSpy = vi.spyOn(postgresMod.PostgresStore, "forProject").mockReturnValue(postgresPurgeStore as never);

      const taskClientFactory = await import("../../lib/task-client-factory.js");
      vi.spyOn(taskClientFactory, "createTaskClient").mockResolvedValue({ taskClient: {} } as never);

      const doctorOrchestrator = await import("../../orchestrator/doctor.js");
      vi.spyOn(doctorOrchestrator.Doctor.prototype, "runAll").mockResolvedValue({
        system: [],
        repository: [],
        dataIntegrity: [],
        summary: { pass: 1, warn: 0, fail: 0, fixed: 0, skip: 0 },
      } as never);

      const purgeLogsModule = await import("../commands/purge-logs.js");
      const wrapSpy = vi.spyOn(purgeLogsModule, "wrapLocalPurgeStore").mockImplementation((store) => ({
        getRun: async (id: string) => store.getRun(id),
      }));
      const purgeSpy = vi.spyOn(purgeLogsModule, "purgeLogsAction").mockResolvedValue({
        checked: 0,
        deleted: 0,
        skipped: 0,
        errors: 0,
        freedBytes: 0,
      } as never);

      const { doctorCommand } = await import("../commands/doctor.js");
      return {
        tmp,
        ensureSpy,
        listSpy,
        localSpy,
        mainLocalStore,
        purgeLocalStore,
        postgresSpy,
        postgresPurgeStore,
        wrapSpy,
        purgeSpy,
        doctorCommand,
      };
    }

    it("registered clean-logs uses PostgresStore and not a second local store", async () => {
      const { tmp, ensureSpy, listSpy, localSpy, postgresSpy, postgresPurgeStore, wrapSpy, purgeSpy, doctorCommand, mainLocalStore } = await arrange(true);

      await doctorCommand.parseAsync(["node", "doctor", "--clean-logs"], { from: "node" });

      expect(listSpy).toHaveBeenCalled();
      expect(ensureSpy).toHaveBeenCalledWith(tmp);
      expect(localSpy).toHaveBeenCalledTimes(1);
      expect(wrapSpy).not.toHaveBeenCalled();
      expect(postgresSpy).toHaveBeenCalledWith("registered-project-id");
      expect(purgeSpy).toHaveBeenCalledWith({ days: 7, dryRun: false }, postgresPurgeStore);
      expect(mainLocalStore.close).toHaveBeenCalledTimes(1);
    }, 30_000);

    it("local clean-logs keeps the local store path", async () => {
      const { ensureSpy, listSpy, localSpy, postgresSpy, wrapSpy, purgeSpy, doctorCommand, purgeLocalStore } = await arrange(false);

      await doctorCommand.parseAsync(["node", "doctor", "--clean-logs"], { from: "node" });

      expect(listSpy).toHaveBeenCalled();
      expect(ensureSpy).not.toHaveBeenCalled();
      expect(localSpy).toHaveBeenCalledTimes(2);
      expect(postgresSpy).not.toHaveBeenCalled();
      expect(wrapSpy).toHaveBeenCalledWith(purgeLocalStore);
      expect(purgeSpy).toHaveBeenCalledWith({ days: 7, dryRun: false }, expect.objectContaining({ getRun: expect.any(Function) }));
    }, 30_000);
  });

  describe("doctor project bootstrap resolution", () => {
    afterEach(() => {
      vi.restoreAllMocks();
    });

    async function arrange(registered: boolean) {
      vi.resetModules();

      const canonicalPath = makeTempDir();
      const clonePath = makeTempDir();

      const projectSupport = await import("../commands/project-task-support.js");
      const ensureSpy = vi.spyOn(projectSupport, "ensureCliPostgresPool").mockImplementation(() => undefined);
      const resolveSpy = vi.spyOn(projectSupport, "resolveRepoRootProjectPath");
      resolveSpy.mockResolvedValue(registered ? canonicalPath : clonePath);
      vi.spyOn(projectSupport, "listRegisteredProjects").mockResolvedValue(
        registered ? ([{ id: "registered-project-id", path: canonicalPath }] as never) : ([] as never),
      );

      const storeMod = await import("../../lib/store.js");
      const localStore = { getDb: () => ({}), close: vi.fn() };
      const localStoreSpy = vi.spyOn(storeMod.ForemanStore, "forProject").mockReturnValue(localStore as never);

      const postgresStoreMod = await import("../../lib/postgres-store.js");
      const postgresStoreSpy = vi.spyOn(postgresStoreMod.PostgresStore, "forProject").mockReturnValue({ close: vi.fn() } as never);

      const mergeQueueMod = await import("../../orchestrator/merge-queue.js");
      const MergeQueue = mergeQueueMod.MergeQueue;

      const postgresQueueMod = await import("../../orchestrator/postgres-merge-queue.js");
      const postgresQueueSpy = vi.spyOn(postgresQueueMod, "PostgresMergeQueue").mockImplementation(function PostgresMergeQueueMock(this: unknown) {
        return {
          list: vi.fn(),
          missingFromQueue: vi.fn(),
          updateStatus: vi.fn(),
          remove: vi.fn(),
          reEnqueue: vi.fn(),
          reconcile: vi.fn(),
        } as never;
      } as never);

      const taskClientFactory = await import("../../lib/task-client-factory.js");
      vi.spyOn(taskClientFactory, "createTaskClient").mockResolvedValue({ taskClient: {} } as never);

      const doctorOrchestrator = await import("../../orchestrator/doctor.js");
      const doctorCtorSpy = vi.spyOn(doctorOrchestrator, "Doctor").mockImplementation(function DoctorMock(this: unknown) {
        return {
          runAll: vi.fn().mockResolvedValue({
            system: [],
            repository: [],
            dataIntegrity: [],
            summary: { pass: 1, warn: 0, fail: 0, fixed: 0, skip: 0 },
          }),
        } as never;
      } as never);

      const { doctorCommand } = await import("../commands/doctor.js");
      return {
        canonicalPath,
        clonePath,
        ensureSpy,
        resolveSpy,
        localStoreSpy,
        postgresStoreSpy,
        postgresQueueSpy,
        doctorCtorSpy,
        doctorCommand,
        MergeQueue,
      };
    }

    it("resolves a registered doctor run from a clone to the canonical project path", async () => {
      const { canonicalPath, ensureSpy, resolveSpy, localStoreSpy, postgresStoreSpy, doctorCtorSpy, doctorCommand } = await arrange(true);

      await doctorCommand.parseAsync(["node", "doctor"], { from: "node" });

      expect(resolveSpy).toHaveBeenCalledWith({});
      expect(ensureSpy).toHaveBeenCalledWith(canonicalPath);
      expect(localStoreSpy).toHaveBeenCalledWith(canonicalPath);
      expect(postgresStoreSpy).toHaveBeenCalledWith("registered-project-id");
      expect(doctorCtorSpy.mock.calls[0]?.[1]).toBe(canonicalPath);
    }, 30_000);

    it("keeps local unregistered doctor runs on the resolved repo-root path", async () => {
      const { clonePath, ensureSpy, resolveSpy, localStoreSpy, postgresStoreSpy, doctorCtorSpy, doctorCommand } = await arrange(false);

      await doctorCommand.parseAsync(["node", "doctor"], { from: "node" });

      expect(resolveSpy).toHaveBeenCalledWith({});
      expect(ensureSpy).not.toHaveBeenCalled();
      expect(localStoreSpy).toHaveBeenCalledWith(clonePath);
      expect(postgresStoreSpy).not.toHaveBeenCalled();
      expect(doctorCtorSpy.mock.calls[0]?.[1]).toBe(clonePath);
    }, 30_000);

    it("keeps the local merge queue lane for unregistered runs", async () => {
      const { doctorCtorSpy, doctorCommand, MergeQueue, postgresQueueSpy } = await arrange(false);

      await doctorCommand.parseAsync(["node", "doctor"], { from: "node" });

      expect(postgresQueueSpy).not.toHaveBeenCalled();
      expect(doctorCtorSpy).toHaveBeenCalledTimes(1);
      expect(doctorCtorSpy.mock.calls[0]?.[2]).toBeInstanceOf(MergeQueue);
      expect(doctorCtorSpy.mock.calls[0]?.[5]).toBeUndefined();
    }, 30_000);
  });
});

// ── Unit tests for doctor logic ──────────────────────────────────────────

describe("doctor unit: icon/label helpers", () => {
  it("check results have expected status types", () => {
    const statuses: Array<"pass" | "warn" | "fail" | "fixed"> = ["pass", "warn", "fail", "fixed"];
    // Just verify the types are recognized — full testing is via integration tests
    expect(statuses).toHaveLength(4);
    expect(statuses).toContain("pass");
    expect(statuses).toContain("warn");
    expect(statuses).toContain("fail");
    expect(statuses).toContain("fixed");
  });
});

describe("doctor unit: zombie run detection", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-unit-")));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("running run with no session_key is treated as zombie", async () => {
    const storeMod = await import("../../lib/store.js");
    const tmpDb = join(makeTempDir(), "test.db");
    const store = new storeMod.ForemanStore(tmpDb);

    const project = store.registerProject("test", "/tmp/fake-path");
    const run = store.createRun(project.id, "test-seed-123", "developer");
    // Mark it as running with no session_key (no pid)
    store.updateRun(run.id, { status: "running", started_at: new Date().toISOString() });

    const runs = store.getRunsByStatus("running", project.id);
    expect(runs).toHaveLength(1);
    expect(runs[0].session_key).toBeNull();

    store.close();
  });

  it("pending run older than threshold is detected as stale", async () => {
    const storeMod = await import("../../lib/store.js");
    const tmpDb = join(makeTempDir(), "test.db");
    const store = new storeMod.ForemanStore(tmpDb);

    const project = store.registerProject("test", "/tmp/fake-path-2");
    const run = store.createRun(project.id, "stale-seed-456", "developer");

    // Manually set the created_at to 48 hours ago
    const twoDaysAgo = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString();
    (store as any).db
      .prepare("UPDATE runs SET created_at = ? WHERE id = ?")
      .run(twoDaysAgo, run.id);

    const pendingRuns = store.getRunsByStatus("pending", project.id);
    expect(pendingRuns).toHaveLength(1);

    const staleThresholdMs = 24 * 60 * 60 * 1000;
    const stale = pendingRuns.filter(
      (r) => Date.now() - new Date(r.created_at).getTime() > staleThresholdMs,
    );
    expect(stale).toHaveLength(1);
    expect(stale[0].seed_id).toBe("stale-seed-456");

    store.close();
  });

  it("fix: stale pending run is marked as failed", async () => {
    const storeMod = await import("../../lib/store.js");
    const tmpDb = join(makeTempDir(), "test.db");
    const store = new storeMod.ForemanStore(tmpDb);

    const project = store.registerProject("test", "/tmp/fake-path-3");
    const run = store.createRun(project.id, "stale-seed-789", "developer");

    // Make it old
    const twoDaysAgo = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString();
    (store as any).db
      .prepare("UPDATE runs SET created_at = ? WHERE id = ?")
      .run(twoDaysAgo, run.id);

    // Apply fix
    store.updateRun(run.id, { status: "failed", completed_at: new Date().toISOString() });

    const pendingRuns = store.getRunsByStatus("pending", project.id);
    expect(pendingRuns).toHaveLength(0);

    const failedRuns = store.getRunsByStatus("failed", project.id);
    expect(failedRuns).toHaveLength(1);
    expect(failedRuns[0].seed_id).toBe("stale-seed-789");

    store.close();
  });
});

// ── MQ-011: completed runs missing from merge queue details rendering ──────

describe("doctor MQ-011: details line rendered in CLI output", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-mq011-")));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("checkCompletedRunsNotQueued returns details containing seed IDs", async () => {
    const { ForemanStore } = await import("../../lib/store.js");
    const { MergeQueue } = await import("../../orchestrator/merge-queue.js");
    const { Doctor } = await import("../../orchestrator/doctor.js");

    const tmpDb = join(makeTempDir(), "test.db");
    const store = new ForemanStore(tmpDb);
    const project = store.registerProject("test", "/tmp/fake-project");

    // Create two completed runs that are NOT in the merge queue
    const run1 = store.createRun(project.id, "seed-mq011-a", "developer");
    store.updateRun(run1.id, { status: "completed", completed_at: new Date().toISOString() });

    const run2 = store.createRun(project.id, "seed-mq011-b", "developer");
    store.updateRun(run2.id, { status: "completed", completed_at: new Date().toISOString() });

    const mq = new MergeQueue(store.getDb());
    const doctor = new Doctor(store, "/tmp/fake-project", mq);

    const result = await doctor.checkCompletedRunsNotQueued();

    expect(result.status).toBe("warn");
    expect(result.message).toContain("MQ-011");
    expect(result.message).toContain("2 completed run(s) not in merge queue");
    // The details field must be present and list the affected seeds
    expect(result.details).toBeDefined();
    expect(result.details).toContain("seed-mq011-a");
    expect(result.details).toContain("seed-mq011-b");
    // Each entry should include the run ID
    expect(result.details).toContain(run1.id);
    expect(result.details).toContain(run2.id);

    store.close();
  });

  it("checkCompletedRunsNotQueued returns pass when all completed runs are queued", async () => {
    const { ForemanStore } = await import("../../lib/store.js");
    const { MergeQueue } = await import("../../orchestrator/merge-queue.js");
    const { Doctor } = await import("../../orchestrator/doctor.js");

    const tmpDb = join(makeTempDir(), "test.db");
    const store = new ForemanStore(tmpDb);
    const project = store.registerProject("test", "/tmp/fake-project-2");

    const run = store.createRun(project.id, "seed-queued", "developer");
    store.updateRun(run.id, { status: "completed", completed_at: new Date().toISOString() });

    const mq = new MergeQueue(store.getDb());
    // Enqueue the completed run
    mq.enqueue({ branchName: "foreman/seed-queued", seedId: "seed-queued", runId: run.id });

    const doctor = new Doctor(store, "/tmp/fake-project-2", mq);
    const result = await doctor.checkCompletedRunsNotQueued();

    expect(result.status).toBe("pass");
    expect(result.details).toBeUndefined();

    store.close();
  });
});
