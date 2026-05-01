import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";
import * as trpcClientModule from "../../lib/trpc-client.js";
import * as projectTaskSupport from "../commands/project-task-support.js";
import { debugCommand } from "../commands/debug.js";
import { recoverCommand } from "../commands/recover.js";

const mockExecFileSync = vi.hoisted(() => vi.fn(() => "mock-output\n"));
const mockExecFile = vi.hoisted(() => vi.fn());
const mockCreateTrpcClient = vi.hoisted(() => vi.fn());
const mockRunWithPiSdk = vi.hoisted(() => vi.fn().mockResolvedValue({
  success: true,
  outputText: "done",
  costUsd: 0,
}));

vi.mock("node:child_process", () => ({
  execFile: mockExecFile,
  execFileSync: mockExecFileSync,
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

vi.mock("../../orchestrator/pi-sdk-runner.js", () => ({
  runWithPiSdk: mockRunWithPiSdk,
}));

vi.mock("../commands/project-task-support.js", () => ({
  ensureCliPostgresPool: vi.fn(),
  listRegisteredProjects: vi.fn(),
  resolveRepoRootProjectPath: vi.fn(),
}));

describe("foreman debug/recover command context", () => {
  let tmpDir: string;
  let localStore: {
    getRunsForSeed: ReturnType<typeof vi.fn>;
    getRunProgress: ReturnType<typeof vi.fn>;
    getAllMessages: ReturnType<typeof vi.fn>;
    close: ReturnType<typeof vi.fn>;
  };

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-debug-recover-test-"));
    mkdirSync(join(tmpDir, ".foreman"), { recursive: true });
    vi.clearAllMocks();
    mockRunWithPiSdk.mockResolvedValue({ success: true, outputText: "done", costUsd: 0 });
    localStore = {
      getRunsForSeed: vi.fn(),
      getRunProgress: vi.fn(),
      getAllMessages: vi.fn(),
      close: vi.fn(),
    };
    vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore as unknown as ForemanStore);
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  function mockDaemonRun() {
    return {
      id: "run-daemon",
      project_id: "proj-1",
      bead_id: "seed-1",
      status: "running",
      branch: "foreman/seed-1",
      agent_type: "daemon",
      session_key: null,
      worktree_path: null,
      progress: JSON.stringify({ stage: "daemon" }),
      base_branch: null,
      merge_strategy: null,
      queued_at: "2026-04-25T00:00:00.000Z",
      started_at: "2026-04-25T00:01:00.000Z",
      finished_at: null,
      created_at: "2026-04-25T00:00:00.000Z",
    };
  }

  function mockLocalRun() {
    return {
      id: "run-local",
      project_id: "proj-local",
      seed_id: "seed-1",
      status: "running",
      agent_type: "daemon",
      session_key: null,
      worktree_path: null,
      started_at: "2026-04-25T00:01:00.000Z",
      completed_at: null,
      created_at: "2026-04-25T00:00:00.000Z",
      progress: null,
      base_branch: null,
      merge_strategy: null,
    };
  }

  async function runCommand(command: typeof debugCommand | typeof recoverCommand, args: string[]): Promise<void> {
    await command.parseAsync(args, { from: "user" });
  }

  it("resolves registered recover from a non-canonical cwd to the registered project path", async () => {
    const canonicalPath = "/canonical/project";
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const daemonRunsList = vi.fn().mockResolvedValue([mockDaemonRun()]);
    const daemonMailList = vi.fn().mockResolvedValue([]);
    mockCreateTrpcClient.mockReturnValue({ runs: { list: daemonRunsList }, mail: { list: daemonMailList } } as unknown as trpcClientModule.TrpcClient);

    resolveRepoRootProjectPathMock.mockResolvedValue(canonicalPath);
    listRegisteredProjectsMock.mockResolvedValue([{ id: "proj-1", name: "foreman", path: canonicalPath }]);

    await runCommand(recoverCommand, ["seed-1", "--raw", "--reason", "stale-blocked"]);

    expect(resolveRepoRootProjectPathMock).toHaveBeenCalledWith({});
    expect(ForemanStore.forProject).toHaveBeenCalledWith(canonicalPath);
    expect(mockCreateTrpcClient).toHaveBeenCalledTimes(1);
    expect(daemonRunsList).toHaveBeenCalledWith({ projectId: "proj-1", beadId: "seed-1", limit: 50 });
    expect(localStore.getRunsForSeed).not.toHaveBeenCalled();
  });

  it("resolves registered debug from a non-canonical cwd to the registered project path", async () => {
    const canonicalPath = "/canonical/project";
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const daemonRunsList = vi.fn().mockResolvedValue([mockDaemonRun()]);
    const daemonMailList = vi.fn().mockResolvedValue([]);
    mockCreateTrpcClient.mockReturnValue({ runs: { list: daemonRunsList }, mail: { list: daemonMailList } } as unknown as trpcClientModule.TrpcClient);

    resolveRepoRootProjectPathMock.mockResolvedValue(canonicalPath);
    listRegisteredProjectsMock.mockResolvedValue([{ id: "proj-1", name: "foreman", path: canonicalPath }]);

    await runCommand(debugCommand, ["seed-1", "--raw"]);

    expect(resolveRepoRootProjectPathMock).toHaveBeenCalledWith({});
    expect(ForemanStore.forProject).toHaveBeenCalledWith(canonicalPath);
    expect(mockCreateTrpcClient).toHaveBeenCalledTimes(1);
    expect(daemonRunsList).toHaveBeenCalledWith({ projectId: "proj-1", beadId: "seed-1", limit: 50 });
    expect(localStore.getRunsForSeed).not.toHaveBeenCalled();
  });

  it("keeps local unregistered behavior unchanged", async () => {
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const localRun = mockLocalRun();
    localStore.getRunsForSeed.mockReturnValue([localRun]);
    localStore.getRunProgress.mockReturnValue(null);
    localStore.getAllMessages.mockReturnValue([]);

    resolveRepoRootProjectPathMock.mockResolvedValue(tmpDir);
    listRegisteredProjectsMock.mockResolvedValue([]);

    await runCommand(recoverCommand, ["seed-1", "--raw", "--reason", "stale-blocked"]);
    await runCommand(debugCommand, ["seed-1", "--raw"]);

    expect(resolveRepoRootProjectPathMock).toHaveBeenCalledWith({});
    expect(ForemanStore.forProject).toHaveBeenCalledWith(tmpDir);
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(localStore.getRunsForSeed).toHaveBeenCalledWith("seed-1");
    expect(localStore.getRunProgress).toHaveBeenCalled();
    expect(localStore.getAllMessages).toHaveBeenCalled();
  });

  it("surfaces recommended clean replay in raw recover output", async () => {
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const worktreePath = join(tmpDir, "worktree");
    mkdirSync(worktreePath, { recursive: true });
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), [
      "## Rebase",
      "- Status: FAILED",
      "- Recommended recovery: clean replay from current main",
      "",
    ].join("\n"));

    localStore.getRunsForSeed.mockReturnValue([{ ...mockLocalRun(), worktree_path: worktreePath }]);
    localStore.getRunProgress.mockReturnValue(null);
    localStore.getAllMessages.mockReturnValue([]);
    resolveRepoRootProjectPathMock.mockResolvedValue(tmpDir);
    listRegisteredProjectsMock.mockResolvedValue([]);

    await runCommand(recoverCommand, ["seed-1", "--raw", "--reason", "stale-blocked"]);

    const output = vi.mocked(console.log).mock.calls.map((call) => call.join(" ")).join("\n");
    expect(output).toContain("─── Recommended Recovery ───");
    expect(output).toContain("Recommended recovery: clean-replay-from-main");
  });

  it("auto-selects finalize-conflict when clean replay is recommended", async () => {
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const worktreePath = join(tmpDir, "worktree-auto-reason");
    mkdirSync(worktreePath, { recursive: true });
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), [
      "## Rebase",
      "- Status: FAILED",
      "- Recommended recovery: clean replay from current main",
      "",
    ].join("\n"));

    localStore.getRunsForSeed.mockReturnValue([{ ...mockLocalRun(), worktree_path: worktreePath }]);
    localStore.getRunProgress.mockReturnValue(null);
    localStore.getAllMessages.mockReturnValue([]);
    resolveRepoRootProjectPathMock.mockResolvedValue(tmpDir);
    listRegisteredProjectsMock.mockResolvedValue([]);

    await runCommand(recoverCommand, ["seed-1"]);

    const prompt = mockRunWithPiSdk.mock.calls[0]?.[0]?.prompt as string;
    const output = vi.mocked(console.log).mock.calls.map((call) => call.join(" ")).join("\n");
    expect(output).toContain("Auto-selected recovery reason: finalize-conflict");
    expect(prompt).toContain("**Failure reason reported:** `finalize-conflict`");
  });

  it("keeps an explicit recover reason even when clean replay is recommended", async () => {
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const worktreePath = join(tmpDir, "worktree-explicit-reason");
    mkdirSync(worktreePath, { recursive: true });
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), [
      "## Rebase",
      "- Status: FAILED",
      "- Recommended recovery: clean replay from current main",
      "",
    ].join("\n"));

    localStore.getRunsForSeed.mockReturnValue([{ ...mockLocalRun(), worktree_path: worktreePath }]);
    localStore.getRunProgress.mockReturnValue(null);
    localStore.getAllMessages.mockReturnValue([]);
    resolveRepoRootProjectPathMock.mockResolvedValue(tmpDir);
    listRegisteredProjectsMock.mockResolvedValue([]);

    await runCommand(recoverCommand, ["seed-1", "--reason", "stale-blocked"]);

    const prompt = mockRunWithPiSdk.mock.calls[0]?.[0]?.prompt as string;
    const output = vi.mocked(console.log).mock.calls.map((call) => call.join(" ")).join("\n");
    expect(output).not.toContain("Auto-selected recovery reason: finalize-conflict");
    expect(prompt).toContain("**Failure reason reported:** `stale-blocked`");
  });

  it("passes recommended clean replay guidance into the recovery prompt", async () => {
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const worktreePath = join(tmpDir, "worktree-prompt");
    mkdirSync(worktreePath, { recursive: true });
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), [
      "## Rebase",
      "- Status: FAILED",
      "- Recommended recovery: clean replay from current main",
      "",
    ].join("\n"));

    localStore.getRunsForSeed.mockReturnValue([{ ...mockLocalRun(), worktree_path: worktreePath }]);
    localStore.getRunProgress.mockReturnValue(null);
    localStore.getAllMessages.mockReturnValue([]);
    resolveRepoRootProjectPathMock.mockResolvedValue(tmpDir);
    listRegisteredProjectsMock.mockResolvedValue([]);

    await runCommand(recoverCommand, ["seed-1", "--reason", "finalize-conflict"]);

    const prompt = mockRunWithPiSdk.mock.calls[0]?.[0]?.prompt as string;
    expect(prompt).toContain("**Failure reason reported:** `finalize-conflict`");
    expect(prompt).toContain("## Recommended Recovery");
    expect(prompt).toContain("Recommended recovery: clean-replay-from-main");
    expect(prompt).toContain("### PLAYBOOK: `finalize-conflict`");
  });

  it("keeps outside-a-repo behavior unchanged", async () => {
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);

    resolveRepoRootProjectPathMock.mockRejectedValue(new Error("not a repo"));

    await expect(runCommand(recoverCommand, ["seed-1", "--raw", "--reason", "stale-blocked"]))
      .rejects.toThrow("not a repo");
    await expect(runCommand(debugCommand, ["seed-1", "--raw"]))
      .rejects.toThrow("not a repo");

    expect(resolveRepoRootProjectPathMock).toHaveBeenCalledWith({});
    expect(ForemanStore.forProject).not.toHaveBeenCalled();
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
  });
});
