import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const {
  mockResolveRepoRootProjectPath,
  mockListRegisteredProjects,
  mockCreateTrpcClient,
  mockParseTrd,
  mockAnalyzeParallel,
  mockExecute,
} = vi.hoisted(() => {
  const mockResolveRepoRootProjectPath = vi.fn();
  const mockListRegisteredProjects = vi.fn();
  const mockCreateTrpcClient = vi.fn();
  const mockParseTrd = vi.fn();
  const mockAnalyzeParallel = vi.fn();
  const mockExecute = vi.fn();

  return {
    mockResolveRepoRootProjectPath,
    mockListRegisteredProjects,
    mockCreateTrpcClient,
    mockParseTrd,
    mockAnalyzeParallel,
    mockExecute,
  };
});

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

vi.mock("../../orchestrator/trd-parser.js", () => ({
  parseTrd: mockParseTrd,
}));

vi.mock("../../orchestrator/sprint-parallel.js", () => ({
  analyzeParallel: mockAnalyzeParallel,
}));

vi.mock("../../orchestrator/sling-executor.js", () => ({
  execute: mockExecute,
}));

import { slingCommand } from "../commands/sling.js";

describe("foreman sling command context", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-sling-command-context-"));
    tempDirs.push(dir);
    return dir;
  }

  function createProject(baseDir: string, name: string): string {
    const projectPath = join(baseDir, name);
    mkdirSync(join(projectPath, "docs", "TRD"), { recursive: true });
    writeFileSync(join(projectPath, "docs", "TRD", "sling-trd.md"), "# Sling TRD\n");
    return projectPath;
  }

  async function run(args: string[]): Promise<void> {
    await slingCommand.parseAsync(args, { from: "user" });
  }

  beforeEach(() => {
    vi.clearAllMocks();
    mockResolveRepoRootProjectPath.mockReset();
    mockListRegisteredProjects.mockReset();
    mockCreateTrpcClient.mockReset();
    mockParseTrd.mockReset();
    mockAnalyzeParallel.mockReset();
    mockExecute.mockReset();
    process.exitCode = undefined;

    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);

    mockCreateTrpcClient.mockReturnValue({
      tasks: {
        list: vi.fn(),
        create: vi.fn(),
        update: vi.fn(),
        close: vi.fn(),
        addDependency: vi.fn(),
        get: vi.fn(),
      },
    });
    mockParseTrd.mockReturnValue({
      epic: { title: "Sling Epic" },
      sprints: [],
      acceptanceCriteria: new Map(),
      riskMap: new Map(),
    });
    mockAnalyzeParallel.mockReturnValue({ groups: [], warnings: [] });
    mockExecute.mockResolvedValue({
      native: { created: 0, skipped: 0, failed: 0, errors: [] },
      depErrors: [],
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("resolves a registered sling run from a non-canonical clone/worktree to the registered project path", async () => {
    const tmpBase = makeTempDir();
    const canonicalPath = createProject(tmpBase, "canonical-project");

    mockResolveRepoRootProjectPath.mockResolvedValue(canonicalPath);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "my-project", path: canonicalPath },
    ]);

    await run([
      "trd",
      "docs/TRD/sling-trd.md",
      "--project",
      "/worktrees/non-canonical-clone",
      "--auto",
    ]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({ project: "/worktrees/non-canonical-clone" });
    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockExecute).toHaveBeenCalledOnce();
    expect(process.exitCode).toBeUndefined();
  });

  it("keeps local unregistered behavior unchanged", async () => {
    const tmpBase = makeTempDir();
    const localPath = createProject(tmpBase, "local-project");

    mockResolveRepoRootProjectPath.mockResolvedValue(localPath);
    mockListRegisteredProjects.mockResolvedValue([]);

    await expect(
      run([
        "trd",
        "docs/TRD/sling-trd.md",
        "--auto",
      ]),
    ).rejects.toThrow(`Project at '${localPath}' is not registered with the daemon.`);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockExecute).not.toHaveBeenCalled();
  });
});
