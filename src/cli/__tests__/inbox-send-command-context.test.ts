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
  requireProjectOrAllInMultiMode: vi.fn().mockResolvedValue(undefined),
  ensureCliPostgresPool: vi.fn(),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

import { inboxCommand } from "../commands/inbox.js";

describe("foreman inbox send command context", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-inbox-send-command-context-"));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    process.env.FOREMAN_BACKEND = "node";
    vi.clearAllMocks();
    mockResolveRepoRootProjectPath.mockReset();
    mockListRegisteredProjects.mockReset();
    mockCreateTrpcClient.mockReset();
    vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => undefined) as typeof process.exit);
  });

  afterEach(() => {
    delete process.env.FOREMAN_BACKEND;
    vi.restoreAllMocks();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  async function runInboxSend(extraArgs: string[] = []): Promise<void> {
    await inboxCommand.parseAsync([
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
      ...extraArgs,
    ], { from: "user" });
  }

  it("sends mail via the daemon for a registered project", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);

    const send = vi.fn().mockResolvedValue(undefined);
    mockCreateTrpcClient.mockReturnValue({ mail: { send } });

    await runInboxSend();

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

  it("resolves a registered project when projectPath is a non-canonical equivalent path", async () => {
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

    await runInboxSend();

    expect(send).toHaveBeenCalledWith({
      projectId: "proj-1",
      runId: "run-1",
      senderAgentType: "developer",
      recipientAgentType: "foreman",
      subject: "phase-complete",
      body: "{}",
    });
  });

  it("falls back to FOREMAN_RUN_ID when --run-id is omitted", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockResolveRepoRootProjectPath.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);

    const send = vi.fn().mockResolvedValue(undefined);
    mockCreateTrpcClient.mockReturnValue({ mail: { send } });

    vi.stubEnv("FOREMAN_RUN_ID", "env-run-9");
    try {
      await inboxCommand.parseAsync([
        "send",
        "--from",
        "developer",
        "--to",
        "foreman",
        "--subject",
        "phase-complete",
        "--body",
        "{}",
      ], { from: "user" });
    } finally {
      vi.unstubAllEnvs();
    }

    expect(send).toHaveBeenCalledWith(expect.objectContaining({ runId: "env-run-9" }));
  });

  it("errors when no run id is provided and FOREMAN_RUN_ID is unset", async () => {
    vi.stubEnv("FOREMAN_RUN_ID", "");
    try {
      await inboxCommand.parseAsync([
        "send",
        "--from",
        "developer",
        "--to",
        "foreman",
        "--subject",
        "phase-complete",
      ], { from: "user" });
    } finally {
      vi.unstubAllEnvs();
    }

    expect(process.stderr.write).toHaveBeenCalledWith(
      "inbox send error: --run-id is required (or set FOREMAN_RUN_ID)\n",
    );
    expect(process.exit).toHaveBeenCalledWith(1);
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
  });

  it("errors when --body is not valid JSON", async () => {
    await inboxCommand.parseAsync([
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
      "not-json",
    ], { from: "user" });

    expect(process.stderr.write).toHaveBeenCalledWith(
      "inbox send error: --body must be valid JSON (got: not-json)\n",
    );
    expect(process.exit).toHaveBeenCalledWith(1);
  });

  it("keeps outside-a-repo behavior unchanged", async () => {
    const outsideError = new Error("not a repo");
    mockResolveRepoRootProjectPath.mockRejectedValue(outsideError);

    await expect(runInboxSend()).rejects.toThrow("not a repo");

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

    await runInboxSend();

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(process.stderr.write).toHaveBeenCalledWith(
      `inbox send error: Project at '${resolve(projectDir)}' is not registered with the daemon.\n`,
    );
    expect(process.exit).toHaveBeenCalledWith(1);
  });
});
