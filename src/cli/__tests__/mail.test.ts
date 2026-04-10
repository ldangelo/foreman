import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";

const { mockGetMainRepoRoot, mockCreateVcsBackend } = vi.hoisted(() => ({
  mockGetMainRepoRoot: vi.fn(),
  mockCreateVcsBackend: vi.fn(),
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: (...args: unknown[]) => mockCreateVcsBackend(...args),
  },
}));

describe("foreman mail", () => {
  let projectRoot: string;
  let store: ForemanStore;
  let stderrSpy: ReturnType<typeof vi.spyOn>;
  let originalRunId: string | undefined;

  beforeEach(() => {
    projectRoot = mkdtempSync(join(tmpdir(), "foreman-mail-test-"));
    mkdirSync(join(projectRoot, ".foreman"), { recursive: true });
    store = ForemanStore.forProject(projectRoot);

    mockGetMainRepoRoot.mockReset();
    mockCreateVcsBackend.mockReset();
    mockGetMainRepoRoot.mockResolvedValue(projectRoot);
    mockCreateVcsBackend.mockResolvedValue({
      getMainRepoRoot: mockGetMainRepoRoot,
    });

    stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation(() => true as never);
    originalRunId = process.env.FOREMAN_RUN_ID;
    delete process.env.FOREMAN_RUN_ID;
  });

  afterEach(() => {
    stderrSpy.mockRestore();
    store.close();
    rmSync(projectRoot, { recursive: true, force: true });
    if (originalRunId === undefined) {
      delete process.env.FOREMAN_RUN_ID;
    } else {
      process.env.FOREMAN_RUN_ID = originalRunId;
    }
    vi.restoreAllMocks();
  });

  it("uses FOREMAN_RUN_ID fallback and records the normalized JSON body", async () => {
    const project = store.registerProject("test-project", projectRoot);
    const run = store.createRun(project.id, "bd-mail", "claude-code", "/tmp/wt");

    process.env.FOREMAN_RUN_ID = run.id;

    const { mailSendAction } = await import("../commands/mail.js");
    const exitCode = await mailSendAction({
      from: "explorer",
      to: "developer",
      subject: "phase-complete",
      body: '{ "phase": "exploration", "count": 1 }',
    });

    expect(exitCode).toBe(0);
    expect(stderrSpy).not.toHaveBeenCalled();

    const messages = store.getAllMessages(run.id);
    expect(messages).toHaveLength(1);
    expect(messages[0].body).toBe('{"phase":"exploration","count":1}');
  });

  it("fails before touching git or the store when --body is invalid JSON", async () => {
    const forProjectSpy = vi.spyOn(ForemanStore, "forProject");

    const { mailSendAction } = await import("../commands/mail.js");
    const exitCode = await mailSendAction({
      runId: "run-123",
      from: "explorer",
      to: "developer",
      subject: "phase-complete",
      body: "{not-json}",
    });

    expect(exitCode).toBe(1);
    expect(mockCreateVcsBackend).not.toHaveBeenCalled();
    expect(forProjectSpy).not.toHaveBeenCalled();
    expect(stderrSpy).toHaveBeenCalledWith(
      "mail send error: --body must be valid JSON (got: {not-json})\n",
    );
  });

  it("fails explicitly when git project-path resolution fails instead of falling back to cwd", async () => {
    const forProjectSpy = vi.spyOn(ForemanStore, "forProject");
    mockCreateVcsBackend.mockRejectedValueOnce(new Error("not in a git repository"));

    const { mailSendAction } = await import("../commands/mail.js");
    const exitCode = await mailSendAction({
      runId: "run-123",
      from: "explorer",
      to: "developer",
      subject: "phase-complete",
      body: "{}",
    });

    expect(exitCode).toBe(1);
    expect(forProjectSpy).not.toHaveBeenCalled();
    expect(stderrSpy).toHaveBeenCalledWith(
      "mail send error: unable to resolve project path: not in a git repository\n",
    );
  });
});
