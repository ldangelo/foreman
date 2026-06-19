import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";

const { mockListRegisteredProjects, mockCreateTrpcClient } = vi.hoisted(() => {
  const mockListRegisteredProjects = vi.fn();
  const mockCreateTrpcClient = vi.fn();
  return { mockListRegisteredProjects, mockCreateTrpcClient };
});

vi.mock("../commands/project-task-support.js", () => ({
  listRegisteredProjects: mockListRegisteredProjects,
  resolveRepoRootProjectPath: vi.fn(async ({ projectPath }: { projectPath?: string }) => resolve(projectPath ?? process.cwd())),
  requireProjectOrAllInMultiMode: vi.fn(),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

import { inboxCommand, resolveDaemonInboxContext } from "../commands/inbox.js";

describe("inbox command context", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-inbox-command-context-"));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    vi.clearAllMocks();
    mockListRegisteredProjects.mockReset();
    mockCreateTrpcClient.mockReset();
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit called with code: ${code}`);
    }) as typeof process.exit);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("resolves a registered inbox project when projectPath is a non-canonical equivalent path", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    const client = { inbox: true };
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    mockCreateTrpcClient.mockReturnValue(client);

    const equivalentPath = `${projectDir}/.`;
    const daemon = await resolveDaemonInboxContext(equivalentPath);

    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockCreateTrpcClient).toHaveBeenCalledOnce();
    expect(daemon).toEqual({ client, projectId: "proj-1" });
  });

  it("keeps explicit project selection by id or name unchanged", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: "/elsewhere/registered-project" },
    ]);
    const client = { inbox: true };
    mockCreateTrpcClient.mockReturnValue(client);

    await expect(resolveDaemonInboxContext("/totally/different", "proj-1")).resolves.toEqual({
      client,
      projectId: "proj-1",
    });
    await expect(resolveDaemonInboxContext("/totally/different", "registered-project")).resolves.toEqual({
      client,
      projectId: "proj-1",
    });
  });

  it("keeps local fallback behavior unchanged when no project matches", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "local-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([]);

    const localStore = {
      getAllMessagesGlobal: vi.fn().mockReturnValue([]),
      close: vi.fn(),
    };
    const forProjectSpy = vi.spyOn(ForemanStore, "forProject").mockReturnValue(localStore as unknown as ForemanStore);

    await inboxCommand.parseAsync(["--all", "--project-path", `${projectDir}/.`], { from: "user" });

    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(forProjectSpy).toHaveBeenCalledWith(resolve(projectDir));
    expect(localStore.getAllMessagesGlobal).toHaveBeenCalledWith(50);
  });
});
