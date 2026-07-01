/**
 * Tests for pi-sdk-tools.ts — createSendMailTool and its promptGuidelines.
 *
 * Guards against regression where lifecycle mail instructions are
 * accidentally re-added to the tool's promptGuidelines or description.
 */

import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it, expect, vi, afterEach } from "vitest";
import { createArtifactWriteTool, createMailReadTool, createSafeCommandRunTool, createSendMailTool, type ForemanToolContext } from "../pi-sdk-tools.js";
import type { NullAgentMailClient } from "../../lib/agent-mail-client.js";

// ── Fixtures ──────────────────────────────────────────────────────────────────

function makeMailClient(sendFn?: () => Promise<void>): NullAgentMailClient {
  return {
    sendMessage: vi.fn().mockImplementation(sendFn ?? (() => Promise.resolve())),
    fetchInbox: vi.fn().mockResolvedValue([]),
  } as unknown as NullAgentMailClient;
}

const tmpDirs: string[] = [];

afterEach(() => {
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
    expect((blocked.content[0] as { text: string }).text).toContain("Blocked destructive");

    const allowed = await tool.execute("call-2", { command: "printf ok" }, undefined, undefined, {} as never);
    expect((allowed.content[0] as { text: string }).text).toContain("ok");
  });
});
