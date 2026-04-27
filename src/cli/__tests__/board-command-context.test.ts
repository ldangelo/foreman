import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const { mockListRegisteredProjects, mockCreateTrpcClient } = vi.hoisted(() => {
  const mockListRegisteredProjects = vi.fn();
  const mockCreateTrpcClient = vi.fn();
  return { mockListRegisteredProjects, mockCreateTrpcClient };
});

vi.mock("../commands/project-task-support.js", () => ({
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

import { loadBoardTasks } from "../commands/board.js";

describe("foreman board command context", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-board-command-context-"));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    vi.clearAllMocks();
    mockListRegisteredProjects.mockReset();
    mockCreateTrpcClient.mockReset();
  });

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("resolves a registered board project when projectPath is a non-canonical equivalent path", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    const list = vi.fn().mockResolvedValue([]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list },
    });

    const equivalentPath = `${projectDir}/.`;
    const tasks = await loadBoardTasks(equivalentPath);

    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(list).toHaveBeenCalledWith({ projectId: "proj-1", limit: 1000 });
    expect(tasks.size).toBeGreaterThan(0);
  });

  it("keeps unregistered board project behavior unchanged", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "local-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list: vi.fn() },
    });

    await expect(loadBoardTasks(resolve(projectDir))).rejects.toThrow(
      `Project at '${resolve(projectDir)}' is not registered with the daemon.`,
    );

    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
  });
});
