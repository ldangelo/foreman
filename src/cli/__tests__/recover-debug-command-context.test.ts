import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, readFileSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";
import * as trpcClientModule from "../../lib/trpc-client.js";
import * as projectTaskSupport from "../commands/project-task-support.js";
import { debugCommand } from "../commands/debug.js";
import { applyCleanReplayChanges, parseChangedFiles, recoverCommand, validateCleanReplayWorkspace } from "../commands/recover.js";

const mockExecFileSync = vi.hoisted(() => vi.fn(() => "mock-output\n"));
const mockExecFile = vi.hoisted(() => vi.fn());
const mockCreateTrpcClient = vi.hoisted(() => vi.fn());
const mockRunWithPiSdk = vi.hoisted(() => vi.fn().mockResolvedValue({
  success: true,
  outputText: "done",
  costUsd: 0,
}));
const mockVcsFactoryCreate = vi.hoisted(() => vi.fn());

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

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockVcsFactoryCreate,
  },
}));

vi.mock("../commands/project-task-support.js", () => ({
  ensureCliPostgresPool: vi.fn(),
  listRegisteredProjects: vi.fn(),
  resolveRepoRootProjectPath: vi.fn(),
}));

describe("clean replay helpers", () => {
  it("parses git status output into normalized changed file paths", () => {
    expect(parseChangedFiles([" M src/foo.ts", "A  test/bar.test.ts", "R  old.ts -> src/new.ts"].join("\n"))).toEqual([
      "src/foo.ts",
      "test/bar.test.ts",
      "src/new.ts",
    ]);
  });

  it("copies intended files and skips generated artifacts", () => {
    const sourceDir = mkdtempSync(join(tmpdir(), "foreman-replay-source-"));
    const destinationDir = mkdtempSync(join(tmpdir(), "foreman-replay-dest-"));
    mkdirSync(join(sourceDir, "src"), { recursive: true });
    mkdirSync(join(sourceDir, "docs", "reports", "seed-1"), { recursive: true });
    writeFileSync(join(sourceDir, "src", "feature.ts"), "export const value = 1;\n");
    writeFileSync(join(sourceDir, "TEST_RESULTS.md"), "generated\n");
    writeFileSync(join(sourceDir, "docs", "reports", "seed-1", "QA_REPORT.md"), "report\n");

    const result = applyCleanReplayChanges(
      sourceDir,
      destinationDir,
      [" M src/feature.ts", "?? TEST_RESULTS.md", "?? docs/reports/seed-1/QA_REPORT.md"].join("\n"),
    );

    expect(result.copiedFiles).toEqual(["src/feature.ts"]);
    expect(result.skippedFiles).toEqual(["TEST_RESULTS.md", "docs/reports/seed-1/QA_REPORT.md"]);
    expect(readFileSync(join(destinationDir, "src", "feature.ts"), "utf-8")).toContain("value = 1");
    rmSync(sourceDir, { recursive: true, force: true });
    rmSync(destinationDir, { recursive: true, force: true });
  });

  it("validates clean replay workspace with tsc and build steps", () => {
    const workspacePath = mkdtempSync(join(tmpdir(), "foreman-replay-validate-"));
    mockExecFileSync.mockImplementation(((command: string, args?: string[]) => {
      if (command === "npx" && args?.join(" ") === "tsc --noEmit") return "tsc ok\n";
      if (command === "npm" && args?.join(" ") === "run build") return "build ok\n";
      return "mock-output\n";
    }) as (...args: unknown[]) => string);

    const result = validateCleanReplayWorkspace(workspacePath);

    expect(result.success).toBe(true);
    expect(result.steps.map((step) => step.name)).toEqual(["tsc", "build"]);
    rmSync(workspacePath, { recursive: true, force: true });
  });
});

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
    mockExecFileSync.mockImplementation(((command: string, args?: string[]) => {
      if (command === "git" && args?.join(" ") === "status --short") {
        return "";
      }
      return "mock-output\n";
    }) as (...args: unknown[]) => string);
    mockVcsFactoryCreate.mockResolvedValue({
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
      createWorkspace: vi.fn().mockImplementation(() => {
        const workspacePath = join(tmpDir, "clean-replay-workspace");
        mkdirSync(workspacePath, { recursive: true });
        return Promise.resolve({
          workspacePath,
          branchName: "foreman/seed-1-clean-replay",
        });
      }),
      stageAll: vi.fn().mockResolvedValue(undefined),
      commit: vi.fn().mockResolvedValue(undefined),
      push: vi.fn().mockResolvedValue(undefined),
    });
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

  it("prepares a clean replay workspace when requested", async () => {
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const worktreePath = join(tmpDir, "worktree-prepare-replay");
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

    await runCommand(recoverCommand, ["seed-1", "--raw", "--prepare-clean-replay"]);

    expect(mockVcsFactoryCreate).toHaveBeenCalledWith({ backend: "auto" }, tmpDir);
    const vcs = await mockVcsFactoryCreate.mock.results[0]?.value;
    expect(vcs.detectDefaultBranch).toHaveBeenCalledWith(tmpDir);
    expect(vcs.createWorkspace).toHaveBeenCalledWith(tmpDir, "seed-1-clean-replay", "main");
    const output = vi.mocked(console.log).mock.calls.map((call) => call.join(" ")).join("\n");
    expect(output).toContain("─── Clean Replay Workspace ───");
    expect(output).toContain("Branch: foreman/seed-1-clean-replay");
    expect(output).toContain(`Path: ${join(tmpDir, "clean-replay-workspace")}`);
  });

  it("applies intended files into the clean replay workspace when requested", async () => {
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const worktreePath = join(tmpDir, "worktree-apply-replay");
    mkdirSync(join(worktreePath, "src"), { recursive: true });
    mkdirSync(join(worktreePath, "docs", "reports", "seed-1"), { recursive: true });
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), [
      "## Rebase",
      "- Status: FAILED",
      "- Recommended recovery: clean replay from current main",
      "",
    ].join("\n"));
    writeFileSync(join(worktreePath, "src", "feature.ts"), "export const replayed = true;\n");
    writeFileSync(join(worktreePath, "TEST_RESULTS.md"), "generated\n");

    mockExecFileSync.mockImplementation(((command: string, args?: string[]) => {
      if (command === "git" && args?.join(" ") === "status --short") {
        return [" M src/feature.ts", "?? TEST_RESULTS.md"].join("\n");
      }
      return "mock-output\n";
    }) as (...args: unknown[]) => string);

    localStore.getRunsForSeed.mockReturnValue([{ ...mockLocalRun(), worktree_path: worktreePath }]);
    localStore.getRunProgress.mockReturnValue(null);
    localStore.getAllMessages.mockReturnValue([]);
    resolveRepoRootProjectPathMock.mockResolvedValue(tmpDir);
    listRegisteredProjectsMock.mockResolvedValue([]);

    await runCommand(recoverCommand, ["seed-1", "--raw", "--apply-clean-replay"]);

    const destinationPath = join(tmpDir, "clean-replay-workspace", "src", "feature.ts");
    expect(readFileSync(destinationPath, "utf-8")).toContain("replayed = true");
    const output = vi.mocked(console.log).mock.calls.map((call) => call.join(" ")).join("\n");
    expect(output).toContain("─── Clean Replay Applied Files ───");
    expect(output).toContain("src/feature.ts");
    expect(output).toContain("─── Clean Replay Skipped Files ───");
    expect(output).toContain("TEST_RESULTS.md");
  });

  it("validates the clean replay workspace when requested", async () => {
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const worktreePath = join(tmpDir, "worktree-validate-replay");
    mkdirSync(worktreePath, { recursive: true });
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), [
      "## Rebase",
      "- Status: FAILED",
      "- Recommended recovery: clean replay from current main",
      "",
    ].join("\n"));

    mockExecFileSync.mockImplementation(((command: string, args?: string[]) => {
      if (command === "git" && args?.join(" ") === "status --short") return "";
      if (command === "npx" && args?.join(" ") === "tsc --noEmit") return "tsc ok\n";
      if (command === "npm" && args?.join(" ") === "run build") return "build ok\n";
      return "mock-output\n";
    }) as (...args: unknown[]) => string);

    localStore.getRunsForSeed.mockReturnValue([{ ...mockLocalRun(), worktree_path: worktreePath }]);
    localStore.getRunProgress.mockReturnValue(null);
    localStore.getAllMessages.mockReturnValue([]);
    resolveRepoRootProjectPathMock.mockResolvedValue(tmpDir);
    listRegisteredProjectsMock.mockResolvedValue([]);

    await runCommand(recoverCommand, ["seed-1", "--raw", "--validate-clean-replay"]);

    const output = vi.mocked(console.log).mock.calls.map((call) => call.join(" ")).join("\n");
    expect(output).toContain("─── Clean Replay Validation ───");
    expect(output).toContain("Overall: PASS");
    expect(output).toContain("- tsc: PASS");
    expect(output).toContain("- build: PASS");
  });

  it("commits the clean replay workspace after successful validation", async () => {
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const worktreePath = join(tmpDir, "worktree-commit-replay");
    mkdirSync(worktreePath, { recursive: true });
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), [
      "## Rebase",
      "- Status: FAILED",
      "- Recommended recovery: clean replay from current main",
      "",
    ].join("\n"));

    mockExecFileSync.mockImplementation(((command: string, args?: string[]) => {
      if (command === "npx" && args?.join(" ") === "tsc --noEmit") return "tsc ok\n";
      if (command === "npm" && args?.join(" ") === "run build") return "build ok\n";
      return "mock-output\n";
    }) as (...args: unknown[]) => string);

    localStore.getRunsForSeed.mockReturnValue([{ ...mockLocalRun(), worktree_path: worktreePath }]);
    localStore.getRunProgress.mockReturnValue(null);
    localStore.getAllMessages.mockReturnValue([]);
    resolveRepoRootProjectPathMock.mockResolvedValue(tmpDir);
    listRegisteredProjectsMock.mockResolvedValue([]);

    await runCommand(recoverCommand, ["seed-1", "--raw", "--commit-clean-replay"]);

    const vcs = await mockVcsFactoryCreate.mock.results[0]?.value;
    expect(vcs.stageAll).toHaveBeenCalledWith(join(tmpDir, "clean-replay-workspace"));
    expect(vcs.commit).toHaveBeenCalledWith(join(tmpDir, "clean-replay-workspace"), "fix: replay seed-1 cleanly from current main");
    const output = vi.mocked(console.log).mock.calls.map((call) => call.join(" ")).join("\n");
    expect(output).toContain("─── Clean Replay Commit ───");
    expect(output).toContain("Status: PASS");
  });

  it("pushes the clean replay workspace after successful validation and commit", async () => {
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const worktreePath = join(tmpDir, "worktree-push-replay");
    mkdirSync(worktreePath, { recursive: true });
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), [
      "## Rebase",
      "- Status: FAILED",
      "- Recommended recovery: clean replay from current main",
      "",
    ].join("\n"));

    mockExecFileSync.mockImplementation(((command: string, args?: string[]) => {
      if (command === "npx" && args?.join(" ") === "tsc --noEmit") return "tsc ok\n";
      if (command === "npm" && args?.join(" ") === "run build") return "build ok\n";
      return "mock-output\n";
    }) as (...args: unknown[]) => string);

    localStore.getRunsForSeed.mockReturnValue([{ ...mockLocalRun(), worktree_path: worktreePath }]);
    localStore.getRunProgress.mockReturnValue(null);
    localStore.getAllMessages.mockReturnValue([]);
    resolveRepoRootProjectPathMock.mockResolvedValue(tmpDir);
    listRegisteredProjectsMock.mockResolvedValue([]);

    await runCommand(recoverCommand, ["seed-1", "--raw", "--push-clean-replay"]);

    const vcs = await mockVcsFactoryCreate.mock.results[0]?.value;
    expect(vcs.stageAll).toHaveBeenCalledWith(join(tmpDir, "clean-replay-workspace"));
    expect(vcs.commit).toHaveBeenCalledWith(join(tmpDir, "clean-replay-workspace"), "fix: replay seed-1 cleanly from current main");
    expect(vcs.push).toHaveBeenCalledWith(join(tmpDir, "clean-replay-workspace"), "foreman/seed-1-clean-replay");
    const output = vi.mocked(console.log).mock.calls.map((call) => call.join(" ")).join("\n");
    expect(output).toContain("─── Clean Replay Push ───");
    expect(output).toContain("Branch: foreman/seed-1-clean-replay");
  });

  it("refuses to commit the clean replay workspace when validation fails", async () => {
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const worktreePath = join(tmpDir, "worktree-commit-replay-fail");
    mkdirSync(worktreePath, { recursive: true });
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), [
      "## Rebase",
      "- Status: FAILED",
      "- Recommended recovery: clean replay from current main",
      "",
    ].join("\n"));

    mockExecFileSync.mockImplementation(((command: string, args?: string[]) => {
      if (command === "npx" && args?.join(" ") === "tsc --noEmit") {
        const error = new Error("tsc failed") as Error & { stdout?: string };
        error.stdout = "type error\n";
        throw error;
      }
      if (command === "npm" && args?.join(" ") === "run build") return "build ok\n";
      return "mock-output\n";
    }) as (...args: unknown[]) => string);

    localStore.getRunsForSeed.mockReturnValue([{ ...mockLocalRun(), worktree_path: worktreePath }]);
    localStore.getRunProgress.mockReturnValue(null);
    localStore.getAllMessages.mockReturnValue([]);
    resolveRepoRootProjectPathMock.mockResolvedValue(tmpDir);
    listRegisteredProjectsMock.mockResolvedValue([]);

    await expect(runCommand(recoverCommand, ["seed-1", "--raw", "--commit-clean-replay"]))
      .rejects.toThrow();

    const vcs = await mockVcsFactoryCreate.mock.results[0]?.value;
    expect(vcs.stageAll).not.toHaveBeenCalled();
    expect(vcs.commit).not.toHaveBeenCalled();
    const errorOutput = vi.mocked(console.error).mock.calls.map((call) => call.join(" ")).join("\n");
    expect(errorOutput).toContain("--commit-clean-replay/--push-clean-replay requires successful clean replay validation");
  });

  it("refuses to push the clean replay workspace when validation fails", async () => {
    const resolveRepoRootProjectPathMock = vi.mocked(projectTaskSupport.resolveRepoRootProjectPath);
    const listRegisteredProjectsMock = vi.mocked(projectTaskSupport.listRegisteredProjects);
    const worktreePath = join(tmpDir, "worktree-push-replay-fail");
    mkdirSync(worktreePath, { recursive: true });
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), [
      "## Rebase",
      "- Status: FAILED",
      "- Recommended recovery: clean replay from current main",
      "",
    ].join("\n"));

    mockExecFileSync.mockImplementation(((command: string, args?: string[]) => {
      if (command === "npx" && args?.join(" ") === "tsc --noEmit") {
        const error = new Error("tsc failed") as Error & { stdout?: string };
        error.stdout = "type error\n";
        throw error;
      }
      if (command === "npm" && args?.join(" ") === "run build") return "build ok\n";
      return "mock-output\n";
    }) as (...args: unknown[]) => string);

    localStore.getRunsForSeed.mockReturnValue([{ ...mockLocalRun(), worktree_path: worktreePath }]);
    localStore.getRunProgress.mockReturnValue(null);
    localStore.getAllMessages.mockReturnValue([]);
    resolveRepoRootProjectPathMock.mockResolvedValue(tmpDir);
    listRegisteredProjectsMock.mockResolvedValue([]);

    await expect(runCommand(recoverCommand, ["seed-1", "--raw", "--push-clean-replay"]))
      .rejects.toThrow();

    const vcs = await mockVcsFactoryCreate.mock.results[0]?.value;
    expect(vcs.stageAll).not.toHaveBeenCalled();
    expect(vcs.commit).not.toHaveBeenCalled();
    expect(vcs.push).not.toHaveBeenCalled();
    const errorOutput = vi.mocked(console.error).mock.calls.map((call) => call.join(" ")).join("\n");
    expect(errorOutput).toContain("--commit-clean-replay/--push-clean-replay requires successful clean replay validation");
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
