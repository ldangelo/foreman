import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";
import * as trpcClientModule from "../../lib/trpc-client.js";
import { debugCommand } from "../commands/debug.js";
import { recoverCommand } from "../commands/recover.js";

const mockExecFileSync = vi.hoisted(() => vi.fn(() => "mock-output\n"));
const mockListRegisteredProjects = vi.hoisted(() => vi.fn());
const mockCreateVcsBackend = vi.hoisted(() => vi.fn());
const mockCreateTrpcClient = vi.hoisted(() => vi.fn());

vi.mock("node:child_process", () => ({
  execFileSync: mockExecFileSync,
}));

vi.mock("../commands/project-task-support.js", () => ({
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockCreateVcsBackend,
  },
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

type CommandCase = {
  name: string;
  command: typeof debugCommand;
  args: string[];
};

const commandCases: CommandCase[] = [
  { name: "debug", command: debugCommand, args: ["seed-1", "--raw"] },
  { name: "recover", command: recoverCommand, args: ["seed-1", "--raw", "--reason", "stale-blocked"] },
];

function makeDaemonRun() {
  return {
    id: "run-daemon",
    project_id: "proj-daemon",
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

function makeLocalRun() {
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

describe("daemon context fallback", () => {
  let tmpDir: string;
  let localStore: {
    getRunsForSeed: ReturnType<typeof vi.fn>;
    getRunProgress: ReturnType<typeof vi.fn>;
    getAllMessages: ReturnType<typeof vi.fn>;
    close: ReturnType<typeof vi.fn>;
  };

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-daemon-fallback-"));
    mkdirSync(join(tmpDir, ".foreman"), { recursive: true });
    vi.clearAllMocks();
    localStore = {
      getRunsForSeed: vi.fn(),
      getRunProgress: vi.fn(),
      getAllMessages: vi.fn(),
      close: vi.fn(),
    };
    vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore as unknown as ForemanStore);
    mockCreateVcsBackend.mockResolvedValue({
      getRepoRoot: vi.fn().mockResolvedValue(tmpDir),
    });
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit called with code: ${code}`);
    }) as typeof process.exit);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  async function runCommand(command: CommandCase["command"], args: string[]): Promise<void> {
    await command.parseAsync(args, { from: "user" });
  }

  it("resolves daemon context only for exact project-path matches", async () => {
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "foreman", path: tmpDir }]);
    const daemonRunsList = vi.fn().mockResolvedValue([makeDaemonRun()]);
    const daemonMailList = vi.fn().mockResolvedValue([]);
    mockCreateTrpcClient.mockReturnValue({ runs: { list: daemonRunsList }, mail: { list: daemonMailList } } as unknown as trpcClientModule.TrpcClient);

    for (const { command, args } of commandCases) {
      await runCommand(command, args);
    }

    expect(mockCreateTrpcClient).toHaveBeenCalledTimes(2);
    expect(localStore.getRunsForSeed).not.toHaveBeenCalled();
    expect(localStore.getRunProgress).not.toHaveBeenCalled();
    expect(localStore.getAllMessages).not.toHaveBeenCalled();
    expect(daemonRunsList).toHaveBeenCalledWith({ projectId: "proj-1", beadId: "seed-1", limit: 50 });
    expect(daemonMailList).toHaveBeenCalledWith({ projectId: "proj-1", runId: "run-daemon" });
  });

  it("does not resolve daemon context for a matching name with a different path", async () => {
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "foreman", path: "/elsewhere/foreman" }]);
    localStore.getRunsForSeed.mockReturnValue([makeLocalRun()]);
    localStore.getRunProgress.mockReturnValue(null);
    localStore.getAllMessages.mockReturnValue([]);

    for (const { command, args } of commandCases) {
      await runCommand(command, args);
    }

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(localStore.getRunsForSeed).toHaveBeenCalledWith("seed-1");
    expect(localStore.getRunProgress).toHaveBeenCalled();
    expect(localStore.getAllMessages).toHaveBeenCalled();
  });

  it("keeps local fallback behavior intact when no registered project matches", async () => {
    mockListRegisteredProjects.mockResolvedValue([]);
    localStore.getRunsForSeed.mockReturnValue([makeLocalRun()]);
    localStore.getRunProgress.mockReturnValue(null);
    localStore.getAllMessages.mockReturnValue([]);

    for (const { command, args } of commandCases) {
      await runCommand(command, args);
    }

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(localStore.getRunsForSeed).toHaveBeenCalledWith("seed-1");
    expect(localStore.getAllMessages).toHaveBeenCalled();
  });
});
