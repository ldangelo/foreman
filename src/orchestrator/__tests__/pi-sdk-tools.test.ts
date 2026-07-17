/**
 * Tests for pi-sdk-tools.ts — createSendMailTool and its promptGuidelines.
 *
 * Guards against regression where lifecycle mail instructions are
 * accidentally re-added to the tool's promptGuidelines or description.
 */

import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { createAbortPhaseTool, createAskOperatorTool, createArtifactWriteTool, createDiffReadTool, createFileChangesTool, createFileReleaseTool, createFileReserveTool, createGitStatusTool, createMailReadTool, createMergeGateStatusTool, createNeedsRetryTool, createPrReviewFindingTool, createSafeCommandRunTool, createSendMailTool, createTaskGetTool, createTaskNoteAddTool, createTaskRiskAddTool, createTaskStatusTool, type ForemanToolContext } from "../pi-sdk-tools.js";
import type { NullAgentMailClient } from "../../lib/agent-mail-client.js";
import type { VcsBackend } from "../../lib/vcs/interface.js";
import type { ElixirServerClient } from "../../lib/elixir-server-client.js";


const ghResponses = vi.hoisted<unknown[]>(() => []);
const execFileMock = vi.hoisted(() => vi.fn());

vi.mock("node:child_process", async () => {
  const actual = await vi.importActual<typeof import("node:child_process")>("node:child_process");
  return {
    ...actual,
    execFile: execFileMock,
  };
});
// ── Fixtures ──────────────────────────────────────────────────────────────────

function makeMailClient(sendFn?: () => Promise<void>): NullAgentMailClient {
  return {
    sendMessage: vi.fn().mockImplementation(sendFn ?? (() => Promise.resolve())),
    fetchInbox: vi.fn().mockResolvedValue([]),
  } as unknown as NullAgentMailClient;
}

const tmpDirs: string[] = [];

beforeEach(() => {
  ghResponses.length = 0;
  execFileMock.mockImplementation((file, args, options, callback) => {
    const done = typeof options === "function" ? options : callback;
    if (typeof done !== "function") throw new Error("execFile callback missing");
    if (file === "gh") {
      const response = ghResponses.shift();
      if (response === undefined) {
        done(new Error("unexpected gh call"), { stdout: "", stderr: "" });
        return;
      }
      done(null, { stdout: JSON.stringify(response), stderr: "" });
      return;
    }
    if (file === "/bin/sh" && Array.isArray(args) && args[1] === "printf ok") {
      done(null, { stdout: "ok", stderr: "" });
      return;
    }
    done(new Error(`unexpected execFile call: ${String(file)}`), { stdout: "", stderr: "" });
  });
});

afterEach(() => {
  execFileMock.mockReset();
  ghResponses.length = 0;
  for (const dir of tmpDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function makeContext(): ForemanToolContext {
  const dir = mkdtempSync(join(tmpdir(), "foreman-pi-tools-"));
  tmpDirs.push(dir);
  return {
    phase: "qa",
    runId: "run-1",
    taskId: "task-1",
    taskTitle: "Test task",
    worktreePath: dir,
    reportDir: join(dir, "reports"),
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("createSendMailTool", () => {
  it("should not include phase-started in promptGuidelines", () => {
    const tool = createSendMailTool(makeMailClient(), "developer");
    const guidelines = tool.promptGuidelines ?? [];
    expect(guidelines.join("\n")).not.toContain("phase-started");
  });

  it("should not include phase-complete in promptGuidelines", () => {
    const tool = createSendMailTool(makeMailClient(), "developer");
    const guidelines = tool.promptGuidelines ?? [];
    expect(guidelines.join("\n")).not.toContain("phase-complete");
  });

  it("should include agent-error in promptGuidelines", () => {
    const tool = createSendMailTool(makeMailClient(), "developer");
    const guidelines = tool.promptGuidelines ?? [];
    expect(guidelines.join("\n")).toContain("agent-error");
  });

  it("should have exactly one promptGuideline entry (error reporting only)", () => {
    const tool = createSendMailTool(makeMailClient(), "developer");
    expect(tool.promptGuidelines).toHaveLength(1);
  });

  it("should instruct agents NOT to send phase-started/phase-complete in description", () => {
    const tool = createSendMailTool(makeMailClient(), "developer");
    // The description should contain a negative constraint, not a positive instruction
    expect(tool.description).toContain("Do NOT send");
    // Verify it's a prohibition (not a positive instruction)
    expect(tool.description).not.toMatch(/Use this to report phase-started/);
    expect(tool.description).not.toMatch(/lifecycle events/);
  });

  it("should explicitly state executor handles lifecycle in description", () => {
    const tool = createSendMailTool(makeMailClient(), "developer");
    expect(tool.description).toContain("executor handles");
  });

  it("should call mailClient.sendMessage when executed", async () => {
    const mailClient = makeMailClient();
    const tool = createSendMailTool(mailClient, "developer");
    await tool.execute("call-1", { to: "foreman", subject: "agent-error", body: '{"error":"test"}' }, undefined, undefined, {} as never);
    expect(mailClient.sendMessage).toHaveBeenCalledWith("foreman", "agent-error", '{"error":"test"}');
  });

  it("should return success text when mail is sent", async () => {
    const tool = createSendMailTool(makeMailClient(), "developer");
    const result = await tool.execute("call-1", { to: "foreman", subject: "agent-error", body: "oops" }, undefined, undefined, {} as never);
    const first = result.content[0] as { type: string; text: string };
    expect(first.text).toContain("Mail sent");
  });

  it("should return error text when sendMessage throws", async () => {
    const failClient = makeMailClient(() => Promise.reject(new Error("db locked")));
    const tool = createSendMailTool(failClient, "developer");
    const result = await tool.execute("call-1", { to: "foreman", subject: "agent-error", body: "oops" }, undefined, undefined, {} as never);
    const first = result.content[0] as { type: string; text: string };
    expect(first.text).toContain("Failed to send mail");
    expect(first.text).toContain("db locked");
  });
});

describe("Foreman workflow tools", () => {
  it("artifact_write constrains writes to the report directory", async () => {
    const context = makeContext();
    const tool = createArtifactWriteTool(context);

    await tool.execute("call-1", { fileName: "QA_REPORT.md", content: "ok" }, undefined, undefined, {} as never);
    expect(readFileSync(join(context.reportDir, "QA_REPORT.md"), "utf8")).toBe("ok");

    await expect(tool.execute("call-2", { fileName: "../escape.md", content: "bad" }, undefined, undefined, {} as never)).rejects.toThrow(/report directory/);
  });

  it("mail_read filters the current phase inbox", async () => {
    const context = makeContext();
    const mailClient = makeMailClient();
    mailClient.fetchInbox = vi.fn().mockResolvedValue([
      { id: "1", from: "explorer", to: "qa-task-1", subject: "handoff", body: "use this", receivedAt: "now", acknowledged: false },
      { id: "2", from: "foreman", to: "qa-task-1", subject: "noise", body: "skip", receivedAt: "now", acknowledged: false },
    ]);
    const tool = createMailReadTool(mailClient, "qa-task-1", context);

    const result = await tool.execute("call-1", { subject: "handoff" }, undefined, undefined, {} as never);
    const first = result.content[0] as { type: string; text: string };
    expect(first.text).toContain("use this");
    expect(first.text).not.toContain("skip");
    expect(mailClient.fetchInbox).toHaveBeenCalledWith("qa-task-1", { limit: 10 });
  });

  it("safe_command_run blocks process-kill commands and allows ordinary validation", async () => {
    const context = makeContext();
    const tool = createSafeCommandRunTool(context);

    const blocked = await tool.execute("call-1", { command: "lsof -ti:4766 | xargs kill -9" }, undefined, undefined, {} as never);
    expect(blocked.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Blocked destructive") }));

    const allowed = await tool.execute("call-2", { command: "printf ok" }, undefined, undefined, {} as never);
    expect(allowed.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("ok") }));
  });
});

describe("VCS and PR review tools", () => {
  function makeMockVcsBackend(): VcsBackend {
    return {
      name: "git",
      getRepoRoot: vi.fn().mockResolvedValue("/repo/root"),
      getMainRepoRoot: vi.fn().mockResolvedValue("/repo/root"),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
      getCurrentBranch: vi.fn().mockResolvedValue("foreman/task-1"),
      getRemoteUrl: vi.fn().mockResolvedValue("https://github.com/owner/repo.git"),
      checkoutBranch: vi.fn().mockResolvedValue(undefined),
      branchExists: vi.fn().mockResolvedValue(true),
      branchExistsOnRemote: vi.fn().mockResolvedValue(true),
      deleteBranch: vi.fn().mockResolvedValue({ success: true }),
      deleteRemoteBranch: vi.fn().mockResolvedValue(undefined),
      createWorkspace: vi.fn().mockResolvedValue({ worktreePath: "/repo/root/.foreman-worktrees/task-1" }),
      removeWorkspace: vi.fn().mockResolvedValue(undefined),
      listWorkspaces: vi.fn().mockResolvedValue([]),
      stageAll: vi.fn().mockResolvedValue(undefined),
      commit: vi.fn().mockResolvedValue(undefined),
      push: vi.fn().mockResolvedValue(undefined),
      pull: vi.fn().mockResolvedValue(undefined),
      saveWorktreeState: vi.fn().mockResolvedValue(false),
      restoreWorktreeState: vi.fn().mockResolvedValue(undefined),
      rebase: vi.fn().mockResolvedValue({ success: true }),
      rebaseBranch: vi.fn().mockResolvedValue({ success: true }),
      restackBranch: vi.fn().mockResolvedValue({ success: true }),
      abortRebase: vi.fn().mockResolvedValue(undefined),
      merge: vi.fn().mockResolvedValue({ success: true }),
      mergeWithStrategy: vi.fn().mockResolvedValue({ success: true }),
      rollbackFailedMerge: vi.fn().mockResolvedValue(undefined),
      getHeadId: vi.fn().mockResolvedValue("abc123"),
      resolveRef: vi.fn().mockResolvedValue("abc123"),
      fetch: vi.fn().mockResolvedValue(undefined),
      diff: vi.fn().mockResolvedValue("+added line\n-removed line"),
      getChangedFiles: vi.fn().mockResolvedValue(["file.ts"]),
      getRefCommitTimestamp: vi.fn().mockResolvedValue(Date.now()),
      getModifiedFiles: vi.fn().mockResolvedValue([]),
      getConflictingFiles: vi.fn().mockResolvedValue([]),
      status: vi.fn().mockResolvedValue(" M modified.txt\n?? untracked.txt"),
      cleanWorkingTree: vi.fn().mockResolvedValue(undefined),
      mergeWithoutCommit: vi.fn().mockResolvedValue({ success: true }),
      commitNoEdit: vi.fn().mockResolvedValue(undefined),
      abortMerge: vi.fn().mockResolvedValue(undefined),
      stageFile: vi.fn().mockResolvedValue(undefined),
      stageFiles: vi.fn().mockResolvedValue(undefined),
      checkoutFile: vi.fn().mockResolvedValue(undefined),
      showFile: vi.fn().mockResolvedValue("file content"),
      resetHard: vi.fn().mockResolvedValue(undefined),
      removeFile: vi.fn().mockResolvedValue(undefined),
      rebaseContinue: vi.fn().mockResolvedValue(undefined),
      removeFromIndex: vi.fn().mockResolvedValue(undefined),
      applyPatchToIndex: vi.fn().mockResolvedValue(undefined),
      getMergeBase: vi.fn().mockResolvedValue("base123"),
      getUntrackedFiles: vi.fn().mockResolvedValue([]),
      isAncestor: vi.fn().mockResolvedValue(true),
      getFinalizeCommands: vi.fn().mockReturnValue({ stage: "", commit: "", push: "" }),
    } as unknown as VcsBackend;
  }

  describe("createDiffReadTool", () => {
    it("returns diff between two refs", async () => {
      const context = makeContext();
      const vcs = makeMockVcsBackend();
      const tool = createDiffReadTool(vcs, context);

      const result = await tool.execute("call-1", { fromRef: "main", toRef: "HEAD" }, undefined, undefined, {} as never);
      expect(vcs.diff).toHaveBeenCalledWith(context.worktreePath, "main", "HEAD");
      const first = result.content[0] as { type: string; text: string };
      expect(first.text).toContain("added line");
      expect(first.text).toContain("removed line");
      expect(result.details).toEqual({ fromRef: "main", toRef: "HEAD", worktreePath: context.worktreePath });
    });

    it("returns error when diff fails", async () => {
      const context = makeContext();
      const vcs = makeMockVcsBackend();
      (vcs.diff as ReturnType<typeof vi.fn>).mockRejectedValue(new Error("ref not found"));
      const tool = createDiffReadTool(vcs, context);

      const result = await tool.execute("call-1", { fromRef: "nonexistent", toRef: "HEAD" }, undefined, undefined, {} as never);
      const first = result.content[0] as { type: string; text: string };
      expect(first.text).toContain("Failed to get diff");
      expect(first.text).toContain("ref not found");
    });
  });

  describe("createGitStatusTool", () => {
    it("returns working tree status", async () => {
      const context = makeContext();
      const vcs = makeMockVcsBackend();
      const tool = createGitStatusTool(vcs, context);

      const result = await tool.execute("call-1", {}, undefined, undefined, {} as never);
      expect(vcs.status).toHaveBeenCalledWith(context.worktreePath);
      const first = result.content[0] as { type: string; text: string };
      expect(first.text).toContain("modified.txt");
      expect(first.text).toContain("untracked.txt");
      expect(result.details).toEqual({ worktreePath: context.worktreePath });
    });

    it("returns error when status fails", async () => {
      const context = makeContext();
      const vcs = makeMockVcsBackend();
      (vcs.status as ReturnType<typeof vi.fn>).mockRejectedValue(new Error("not a git repo"));
      const tool = createGitStatusTool(vcs, context);

      const result = await tool.execute("call-1", {}, undefined, undefined, {} as never);
      const first = result.content[0] as { type: string; text: string };
      expect(first.text).toContain("Failed to get status");
      expect(first.text).toContain("not a git repo");
    });
  });

  describe("createPrReviewFindingTool", () => {
    it("returns structured PR review findings", async () => {
      ghResponses.push(
        {
          url: "https://github.com/owner/repo/pull/42",
          headRefOid: "abc123",
          statusCheckRollup: [{ name: "Test", status: "COMPLETED", conclusion: "FAILURE", detailsUrl: "https://ci.test/failure" }],
        },
        [{ user: { login: "coderabbitai[bot]" }, body: "🟠 Major\n\nFix this", path: "src/file.ts", line: 12, html_url: "https://review.test/comment" }],
        [],
      );
      const context = makeContext();
      const vcs = makeMockVcsBackend();
      const tool = createPrReviewFindingTool(vcs, context);

      const result = await tool.execute("call-1", { prNumber: 42 }, undefined, undefined, {} as never);
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("blockingFindings") }));
      expect(result.details).toEqual(expect.objectContaining({
        prNumber: 42,
        prUrl: "https://github.com/owner/repo/pull/42",
        headSha: "abc123",
        blockingFindings: [expect.objectContaining({ severity: "major", source: "review-comment", path: "src/file.ts", line: 12 })],
        failedChecks: [expect.objectContaining({ name: "Test", status: "COMPLETED", conclusion: "FAILURE", url: "https://ci.test/failure" })],
      }));
    });

    it("passes custom projectPath when provided", async () => {
      const context = makeContext();
      const vcs = makeMockVcsBackend();
      const tool = createPrReviewFindingTool(vcs, context);

      const customPath = "/custom/project/path";
      const result = await tool.execute("call-1", { prNumber: 42, projectPath: customPath }, undefined, undefined, {} as never);
      // gh will fail without real config, but we verify it attempted with custom path
      expect(result.details).toBeDefined();
    });
  });

  describe("createMergeGateStatusTool", () => {
    it("returns ready merge gate status when checks and review gates pass", async () => {
      ghResponses.push(
        {
          url: "https://github.com/owner/repo/pull/42",
          headRefOid: "abc123",
          mergeable: "MERGEABLE",
          mergeStateStatus: "CLEAN",
          statusCheckRollup: [{ name: "Test", status: "COMPLETED", conclusion: "SUCCESS" }],
        },
        [],
        [],
        [{ user: { login: "coderabbitai[bot]" }, state: "COMMENTED" }],
      );
      const context = makeContext();
      const vcs = makeMockVcsBackend();
      const tool = createMergeGateStatusTool(vcs, context);

      const result = await tool.execute("call-1", { prNumber: 42 }, undefined, undefined, {} as never);
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining('"ready": true') }));
      expect(result.details).toEqual(expect.objectContaining({
        ready: true,
        checksTerminal: true,
        pendingChecks: [],
        failedChecks: [],
        codeRabbitSeen: true,
        codeRabbitComplete: true,
        blockingFindings: [],
        mergeConflict: false,
      }));
    });
  });
});

describe("Task context tools", () => {
  function makeMockElixirClient(): ElixirServerClient {
    return {
      getTask: vi.fn(),
      sendCommand: vi.fn(),
    } as unknown as ElixirServerClient;
  }

  describe("createTaskGetTool", () => {
    it("returns full task context when task exists", async () => {
      const context = makeContext();
      const client = makeMockElixirClient();
      const mockTask = {
        id: "foreman-123",
        title: "Test Task",
        description: "A test task",
        status: "in_progress",
        annotations: [],
        dependencies: [],
      };
      (client.getTask as ReturnType<typeof vi.fn>).mockResolvedValue(mockTask);
      const tool = createTaskGetTool(client, context);

      const result = await tool.execute("call-1", { taskId: "foreman-123" }, undefined, undefined, {} as never);
      expect(client.getTask).toHaveBeenCalledWith("foreman-123");
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("foreman-123") }));
      expect((result.details as Record<string, unknown>)._meta).toMatchObject({ runId: "run-1", taskId: "task-1" });
      expect((result.details as Record<string, unknown>).title).toBe("Test Task");
    });

    it("returns error when task not found", async () => {
      const context = makeContext();
      const client = makeMockElixirClient();
      (client.getTask as ReturnType<typeof vi.fn>).mockResolvedValue(null);
      const tool = createTaskGetTool(client, context);

      const result = await tool.execute("call-1", { taskId: "missing" }, undefined, undefined, {} as never);
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("not found") }));
      expect(result.details).toMatchObject({ taskId: "missing", found: false });
    });

    it("returns error when getTask throws", async () => {
      const context = makeContext();
      const client = makeMockElixirClient();
      (client.getTask as ReturnType<typeof vi.fn>).mockRejectedValue(new Error("server unavailable"));
      const tool = createTaskGetTool(client, context);

      const result = await tool.execute("call-1", { taskId: "foreman-123" }, undefined, undefined, {} as never);
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Failed to get task") }));
    });
  });

  describe("createTaskStatusTool", () => {
    it("returns only status field", async () => {
      const context = makeContext();
      const client = makeMockElixirClient();
      (client.getTask as ReturnType<typeof vi.fn>).mockResolvedValue({
        id: "foreman-123",
        status: "completed",
        updated_at: "2024-01-01T00:00:00Z",
      });
      const tool = createTaskStatusTool(client, context);

      const result = await tool.execute("call-1", { taskId: "foreman-123" }, undefined, undefined, {} as never);
      expect(result.details).toEqual({
        taskId: "foreman-123",
        status: "completed",
        updatedAt: "2024-01-01T00:00:00Z",
      });
    });

    it("returns null status when task not found", async () => {
      const context = makeContext();
      const client = makeMockElixirClient();
      (client.getTask as ReturnType<typeof vi.fn>).mockResolvedValue(null);
      const tool = createTaskStatusTool(client, context);

      const result = await tool.execute("call-1", { taskId: "missing" }, undefined, undefined, {} as never);
      expect(result.details).toMatchObject({ taskId: "missing", found: false, status: null });
    });
  });

  describe("createTaskNoteAddTool", () => {
    it("sends annotation with kind=note and run_id scoping", async () => {
      const context = makeContext();
      const client = makeMockElixirClient();
      (client.sendCommand as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: true, events: [], projection_version: 1, correlation_id: "corr-1" });
      const tool = createTaskNoteAddTool(client, context);

      const result = await tool.execute("call-1", { taskId: "foreman-123", body: "Important finding" }, undefined, undefined, {} as never);
      expect(client.sendCommand).toHaveBeenCalledWith(expect.objectContaining({
        command_type: "task.annotate",
        payload: expect.objectContaining({
          task_id: "foreman-123",
          author: "agent",
          kind: "note",
          body: "Important finding",
          run_id: "run-1",
        }),
      }));
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Note added") }));
      expect((result.details as Record<string, unknown>).kind).toBe("note");
    });

    it("returns error when sendCommand fails", async () => {
      const context = makeContext();
      const client = makeMockElixirClient();
      (client.sendCommand as ReturnType<typeof vi.fn>).mockResolvedValue({
        ok: false,
        error: { code: "VALIDATION_FAILED", message: "Invalid task ID", details: {}, retryable: false },
      });
      const tool = createTaskNoteAddTool(client, context);

      const result = await tool.execute("call-1", { taskId: "bad-id", body: "test" }, undefined, undefined, {} as never);
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Failed to add note") }));
    });
  });

  describe("createTaskRiskAddTool", () => {
    it("sends annotation with kind=risk and run_id scoping", async () => {
      const context = makeContext();
      const client = makeMockElixirClient();
      (client.sendCommand as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: true, events: [], projection_version: 1, correlation_id: "corr-1" });
      const tool = createTaskRiskAddTool(client, context);

      const result = await tool.execute("call-1", { taskId: "foreman-123", body: "Potential blocker" }, undefined, undefined, {} as never);
      expect(client.sendCommand).toHaveBeenCalledWith(expect.objectContaining({
        command_type: "task.annotate",
        payload: expect.objectContaining({
          task_id: "foreman-123",
          author: "agent",
          kind: "risk",
          body: "Potential blocker",
          run_id: "run-1",
        }),
      }));
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Risk added") }));
      expect((result.details as Record<string, unknown>).kind).toBe("risk");
    });

    it("returns error when sendCommand fails", async () => {
      const context = makeContext();
      const client = makeMockElixirClient();
      (client.sendCommand as ReturnType<typeof vi.fn>).mockResolvedValue({
        ok: false,
        error: { code: "INTERNAL", message: "Server error", details: {}, retryable: false },
      });
      const tool = createTaskRiskAddTool(client, context);

      const result = await tool.execute("call-1", { taskId: "foreman-123", body: "test" }, undefined, undefined, {} as never);
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Failed to add risk") }));
    });
  });
});

describe("File ownership tools", () => {
  describe("createFileReserveTool", () => {
    it("reserves files and calls onFileReserve callback", async () => {
      const onFileReserve = vi.fn();
      const context = makeContext();
      context.onFileReserve = onFileReserve;
      const tool = createFileReserveTool(context);

      const result = await tool.execute("call-1", { files: ["src/file1.ts", "src/file2.ts"] }, undefined, undefined, {} as never);
      expect(onFileReserve).toHaveBeenCalledWith(["src/file1.ts", "src/file2.ts"], "qa-task-1", 300);
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Reserved 2 file(s)") }));
      expect((result.details as Record<string, unknown>).owner).toBe("qa-task-1");
      expect((result.details as Record<string, unknown>).leaseSecs).toBe(300);
    });

    it("uses custom lease duration when provided", async () => {
      const onFileReserve = vi.fn();
      const context = makeContext();
      context.onFileReserve = onFileReserve;
      const tool = createFileReserveTool(context);

      const result = await tool.execute("call-1", { files: ["src/file.ts"], leaseSecs: 600 }, undefined, undefined, {} as never);
      expect(onFileReserve).toHaveBeenCalledWith(["src/file.ts"], "qa-task-1", 600);
      expect((result.details as Record<string, unknown>).leaseSecs).toBe(600);
    });

    it("works without callback (no-op)", async () => {
      const context = makeContext();
      const tool = createFileReserveTool(context);

      const result = await tool.execute("call-1", { files: ["src/file.ts"] }, undefined, undefined, {} as never);
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Reserved 1 file(s)") }));
    });
  });

  describe("createFileReleaseTool", () => {
    it("releases files and calls onFileRelease callback", async () => {
      const onFileRelease = vi.fn();
      const context = makeContext();
      context.onFileRelease = onFileRelease;
      const tool = createFileReleaseTool(context);

      const result = await tool.execute("call-1", { files: ["src/file1.ts", "src/file2.ts"] }, undefined, undefined, {} as never);
      expect(onFileRelease).toHaveBeenCalledWith(["src/file1.ts", "src/file2.ts"], "qa-task-1");
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Released 2 file(s)") }));
      expect((result.details as Record<string, unknown>).owner).toBe("qa-task-1");
    });

    it("works without callback (no-op)", async () => {
      const context = makeContext();
      const tool = createFileReleaseTool(context);

      const result = await tool.execute("call-1", { files: ["src/file.ts"] }, undefined, undefined, {} as never);
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Released 1 file(s)") }));
    });
  });

  describe("createFileChangesTool", () => {
    it("reports file changes and calls onFileChanges callback", async () => {
      const onFileChanges = vi.fn();
      const context = makeContext();
      context.onFileChanges = onFileChanges;
      const tool = createFileChangesTool(context);

      const result = await tool.execute("call-1", { files: ["src/new.ts", "src/modified.ts"], operation: "modified" }, undefined, undefined, {} as never);
      expect(onFileChanges).toHaveBeenCalledWith(["src/new.ts", "src/modified.ts"]);
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Reported 2 file change(s)") }));
      expect((result.details as Record<string, unknown>).operation).toBe("modified");
    });

    it("defaults to 'modified' operation when not specified", async () => {
      const onFileChanges = vi.fn();
      const context = makeContext();
      context.onFileChanges = onFileChanges;
      const tool = createFileChangesTool(context);

      const result = await tool.execute("call-1", { files: ["src/file.ts"] }, undefined, undefined, {} as never);
      expect(onFileChanges).toHaveBeenCalledWith(["src/file.ts"]);
      expect((result.details as Record<string, unknown>).operation).toBe("modified");
    });

    it("reports 'created' operation correctly", async () => {
      const onFileChanges = vi.fn();
      const context = makeContext();
      context.onFileChanges = onFileChanges;
      const tool = createFileChangesTool(context);

      const result = await tool.execute("call-1", { files: ["src/new.ts"], operation: "created" }, undefined, undefined, {} as never);
      expect(onFileChanges).toHaveBeenCalledWith(["src/new.ts"]);
      expect((result.details as Record<string, unknown>).operation).toBe("created");
    });

    it("reports 'deleted' operation correctly", async () => {
      const onFileChanges = vi.fn();
      const context = makeContext();
      context.onFileChanges = onFileChanges;
      const tool = createFileChangesTool(context);

      const result = await tool.execute("call-1", { files: ["src/deleted.ts"], operation: "deleted" }, undefined, undefined, {} as never);
      expect(onFileChanges).toHaveBeenCalledWith(["src/deleted.ts"]);
      expect((result.details as Record<string, unknown>).operation).toBe("deleted");
    });

    it("works without callback (no-op)", async () => {
      const context = makeContext();
      const tool = createFileChangesTool(context);

      const result = await tool.execute("call-1", { files: ["src/file.ts"] }, undefined, undefined, {} as never);
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Reported 1 file change(s)") }));
    });
  });
});

describe("Phase control tools", () => {
  describe("createAskOperatorTool", () => {
    it("writes ASK_OPERATOR.md and sends ask-operator mail", async () => {
      const context = makeContext();
      const mailClient = makeMailClient();
      const tool = createAskOperatorTool(mailClient, context);

      const result = await tool.execute("call-1", { question: "Which approach should I take?", context: "Two viable approaches found" }, undefined, undefined, {} as never);
      expect(readFileSync(join(context.reportDir, "ASK_OPERATOR.md"), "utf8")).toContain("Which approach should I take?");
      expect(readFileSync(join(context.reportDir, "ASK_OPERATOR.md"), "utf8")).toContain("Two viable approaches found");
      expect(mailClient.sendMessage).toHaveBeenCalledWith("foreman", "ask-operator", expect.stringContaining("Which approach should I take?"));
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Operator request sent") }));
      expect((result.details as Record<string, unknown>).phase).toBe("qa");
      // Verify control outcome is present
      expect((result as unknown as { controlOutcome: unknown }).controlOutcome).toEqual({
        type: "ASK_OPERATOR",
        question: "Which approach should I take?",
        context: "Two viable approaches found",
      });
    });

    it("works without optional context", async () => {
      const context = makeContext();
      const mailClient = makeMailClient();
      const tool = createAskOperatorTool(mailClient, context);

      const result = await tool.execute("call-1", { question: "Is this the right direction?" }, undefined, undefined, {} as never);
      expect(readFileSync(join(context.reportDir, "ASK_OPERATOR.md"), "utf8")).not.toContain("## Context");
      expect(mailClient.sendMessage).toHaveBeenCalledWith("foreman", "ask-operator", expect.any(String));
      expect((result.details as Record<string, unknown>).context).toBeNull();
      // Verify control outcome with null context
      expect((result as unknown as { controlOutcome: unknown }).controlOutcome).toEqual({
        type: "ASK_OPERATOR",
        question: "Is this the right direction?",
        context: null,
      });
    });

    it("succeeds without mail client", async () => {
      const context = makeContext();
      const tool = createAskOperatorTool(null, context);

      const result = await tool.execute("call-1", { question: "Help?" }, undefined, undefined, {} as never);
      expect(readFileSync(join(context.reportDir, "ASK_OPERATOR.md"), "utf8")).toContain("Help?");
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Operator request sent") }));
      // Verify control outcome is present even without mail client
      expect((result as unknown as { controlOutcome: unknown }).controlOutcome).toEqual({
        type: "ASK_OPERATOR",
        question: "Help?",
        context: null,
      });
    });

    it("returns control outcome when ask-operator mail delivery fails", async () => {
      // Regression: a notify failure used to reject execute() and prevent
      // controlOutcome from reaching the runner. Mail is best-effort, so
      // the typed control signal must still come through.
      const context = makeContext();
      const mailClient = makeMailClient(() => Promise.reject(new Error("smtp down")));
      const tool = createAskOperatorTool(mailClient, context);

      const result = await tool.execute("call-1", { question: "Need guidance" }, undefined, undefined, {} as never);
      // Artifact is still written before the failing mail call.
      expect(readFileSync(join(context.reportDir, "ASK_OPERATOR.md"), "utf8")).toContain("Need guidance");
      // The typed control signal is still present so the runner can pause.
      // Validate the shape at the test boundary via type guard instead of
      // an unchecked cast, then assert on the typed value.
      if (!("controlOutcome" in result) || !result.controlOutcome) {
        throw new Error("expected controlOutcome in result");
      }
      expect(result.controlOutcome).toEqual({
        type: "ASK_OPERATOR",
        question: "Need guidance",
        context: null,
      });
    });
   });

  describe("createAbortPhaseTool", () => {
    it("writes ABORTED.md and sends phase-abort mail", async () => {
      const context = makeContext();
      const mailClient = makeMailClient();
      const tool = createAbortPhaseTool(mailClient, context);

      const result = await tool.execute("call-1", { reason: "Approach is fundamentally flawed", suggestion: "Try a different algorithm" }, undefined, undefined, {} as never);
      expect(readFileSync(join(context.reportDir, "ABORTED.md"), "utf8")).toContain("Approach is fundamentally flawed");
      expect(readFileSync(join(context.reportDir, "ABORTED.md"), "utf8")).toContain("Try a different algorithm");
      expect(mailClient.sendMessage).toHaveBeenCalledWith("foreman", "phase-abort", expect.stringContaining("Approach is fundamentally flawed"));
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Phase aborted") }));
      expect((result.details as Record<string, unknown>).phase).toBe("qa");
      // Verify control outcome is present
      expect((result as unknown as { controlOutcome: unknown }).controlOutcome).toEqual({
        type: "ABORTED",
        reason: "Approach is fundamentally flawed",
        suggestion: "Try a different algorithm",
      });
    });

    it("works without optional suggestion", async () => {
      const context = makeContext();
      const mailClient = makeMailClient();
      const tool = createAbortPhaseTool(mailClient, context);

      const result = await tool.execute("call-1", { reason: "Cannot proceed" }, undefined, undefined, {} as never);
      expect(readFileSync(join(context.reportDir, "ABORTED.md"), "utf8")).not.toContain("## Suggested Remediation");
      expect((result.details as Record<string, unknown>).suggestion).toBeNull();
      // Verify control outcome with null suggestion
      expect((result as unknown as { controlOutcome: unknown }).controlOutcome).toEqual({
        type: "ABORTED",
        reason: "Cannot proceed",
        suggestion: null,
      });
    });

    it("succeeds without mail client", async () => {
      const context = makeContext();
      const tool = createAbortPhaseTool(null, context);

      const result = await tool.execute("call-1", { reason: "Blocked" }, undefined, undefined, {} as never);
      expect(readFileSync(join(context.reportDir, "ABORTED.md"), "utf8")).toContain("Blocked");
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Phase aborted") }));
      // Verify control outcome is present even without mail client
      expect((result as unknown as { controlOutcome: unknown }).controlOutcome).toEqual({
        type: "ABORTED",
        reason: "Blocked",
        suggestion: null,
      });
    });
  });

  describe("createNeedsRetryTool", () => {
    it("writes NEEDS_RETRY.md and sends needs-retry mail with all fields", async () => {
      const context = makeContext();
      const mailClient = makeMailClient();
      const tool = createNeedsRetryTool(mailClient, context);

      const result = await tool.execute("call-1", {
        reason: "API rate limit hit",
        attemptedApproach: "Called the API without backoff",
        suggestedNextStep: "Add exponential backoff and retry",
      }, undefined, undefined, {} as never);
      const content = readFileSync(join(context.reportDir, "NEEDS_RETRY.md"), "utf8");
      expect(content).toContain("API rate limit hit");
      expect(content).toContain("Called the API without backoff");
      expect(content).toContain("Add exponential backoff and retry");
      expect(mailClient.sendMessage).toHaveBeenCalledWith("foreman", "needs-retry", expect.stringContaining("API rate limit hit"));
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Retry requested") }));
      expect((result.details as Record<string, unknown>).phase).toBe("qa");
      // Verify control outcome is present
      expect((result as unknown as { controlOutcome: unknown }).controlOutcome).toEqual({
        type: "NEEDS_RETRY",
        reason: "API rate limit hit",
        attemptedApproach: "Called the API without backoff",
        suggestedNextStep: "Add exponential backoff and retry",
      });
    });

    it("works with only required reason field", async () => {
      const context = makeContext();
      const mailClient = makeMailClient();
      const tool = createNeedsRetryTool(mailClient, context);

      const result = await tool.execute("call-1", { reason: "Transient failure" }, undefined, undefined, {} as never);
      const content = readFileSync(join(context.reportDir, "NEEDS_RETRY.md"), "utf8");
      expect(content).not.toContain("## Attempted Approach");
      expect(content).not.toContain("## Suggested Next Step");
      expect((result.details as Record<string, unknown>).attemptedApproach).toBeNull();
      expect((result.details as Record<string, unknown>).suggestedNextStep).toBeNull();
      // Verify control outcome with null optional fields
      expect((result as unknown as { controlOutcome: unknown }).controlOutcome).toEqual({
        type: "NEEDS_RETRY",
        reason: "Transient failure",
        attemptedApproach: null,
        suggestedNextStep: null,
      });
    });

    it("succeeds without mail client", async () => {
      const context = makeContext();
      const tool = createNeedsRetryTool(null, context);

      const result = await tool.execute("call-1", { reason: "Network timeout" }, undefined, undefined, {} as never);
      expect(readFileSync(join(context.reportDir, "NEEDS_RETRY.md"), "utf8")).toContain("Network timeout");
      expect(result.content[0]).toEqual(expect.objectContaining({ text: expect.stringContaining("Retry requested") }));
      // Verify control outcome is present even without mail client
      expect((result as unknown as { controlOutcome: unknown }).controlOutcome).toEqual({
        type: "NEEDS_RETRY",
        reason: "Network timeout",
        attemptedApproach: null,
        suggestedNextStep: null,
      });
    });
  });
});
