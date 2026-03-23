/**
 * Tests for pi-sdk-tools.ts — createSendMailTool and its promptGuidelines.
 *
 * Guards against regression where lifecycle mail instructions are
 * accidentally re-added to the tool's promptGuidelines or description.
 */

import { describe, it, expect, vi } from "vitest";
import { createSendMailTool } from "../pi-sdk-tools.js";
import type { SqliteMailClient } from "../../lib/sqlite-mail-client.js";

// ── Fixtures ──────────────────────────────────────────────────────────────────

function makeMailClient(sendFn?: () => Promise<void>): SqliteMailClient {
  return {
    sendMessage: vi.fn().mockImplementation(sendFn ?? (() => Promise.resolve())),
    fetchInbox: vi.fn().mockResolvedValue([]),
  } as unknown as SqliteMailClient;
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
