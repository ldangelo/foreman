import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const { mockResolveRepoRootProjectPath, mockListRegisteredProjects, mockCreateTrpcClient } = vi.hoisted(() => {
  const mockResolveRepoRootProjectPath = vi.fn();
  const mockListRegisteredProjects = vi.fn();
  const mockCreateTrpcClient = vi.fn();
  return { mockResolveRepoRootProjectPath, mockListRegisteredProjects, mockCreateTrpcClient };
});

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

import { mailCommand } from "../commands/mail.js";

describe("foreman mail command context", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-mail-command-context-"));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    vi.clearAllMocks();
    mockResolveRepoRootProjectPath.mockReset();
    mockListRegisteredProjects.mockReset();
    mockCreateTrpcClient.mockReset();
    vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => undefined) as typeof process.exit);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  async function runMailSend(): Promise<void> {
    await mailCommand.parseAsync([
      "send",
      "--run-id",
      "run-1",
      "--from",
      "developer",
      "--to",
      "foreman",
      "--subject",
      "phase-complete",
      "--body",
      "{}",
    ], { from: "user" });
  }

  it("resolves a registered mail project when projectPath is a non-canonical equivalent path", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    const equivalentPath = `${projectDir}/.`;
    mockResolveRepoRootProjectPath.mockResolvedValue(equivalentPath);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);

    const send = vi.fn().mockResolvedValue(undefined);
    mockCreateTrpcClient.mockReturnValue({ mail: { send } });

    await runMailSend();

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockCreateTrpcClient).toHaveBeenCalledOnce();
    expect(send).toHaveBeenCalledWith({
      projectId: "proj-1",
      runId: "run-1",
      senderAgentType: "developer",
      recipientAgentType: "foreman",
      subject: "phase-complete",
      body: "{}",
    });
  });

  it("keeps outside-a-repo behavior unchanged", async () => {
    const outsideError = new Error("not a repo");
    mockResolveRepoRootProjectPath.mockRejectedValue(outsideError);

    await expect(runMailSend()).rejects.toThrow("not a repo");

    expect(mockListRegisteredProjects).not.toHaveBeenCalled();
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
  });

  it("keeps unregistered project behavior unchanged", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "local-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(resolve(projectDir));
    mockListRegisteredProjects.mockResolvedValue([]);
    mockCreateTrpcClient.mockReturnValue({ mail: { send: vi.fn() } });

    await runMailSend();

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(process.stderr.write).toHaveBeenCalledWith(
      `mail send error: Project at '${resolve(projectDir)}' is not registered with the daemon.\n`,
    );
    expect(process.exit).toHaveBeenCalledWith(1);
  });
});
