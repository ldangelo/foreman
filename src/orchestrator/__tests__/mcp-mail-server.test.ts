import { describe, it, expect, beforeEach } from "vitest";
import { createMailServer, MAIL_ROLES } from "../mcp-mail-server.js";
import type { MailServerHandle } from "../mcp-mail-server.js";

describe("createMailServer()", () => {
  let mail: MailServerHandle;

  beforeEach(() => {
    mail = createMailServer();
  });

  // ── mcpConfig structure ────────────────────────────────────────────────

  it("returns an mcpConfig object with type 'sdk'", () => {
    expect(mail.mcpConfig).toBeDefined();
    expect(mail.mcpConfig.type).toBe("sdk");
    expect(mail.mcpConfig.name).toBe("agent-mail");
    expect(mail.mcpConfig.instance).toBeDefined();
  });

  // ── Initial state ──────────────────────────────────────────────────────

  it("starts with empty inboxes for all roles", () => {
    for (const role of MAIL_ROLES) {
      expect(mail.getMessages(role)).toHaveLength(0);
    }
  });

  it("getAllMessages() returns empty object when no messages", () => {
    const all = mail.getAllMessages();
    expect(Object.keys(all)).toHaveLength(0);
  });

  // ── MAIL_ROLES constant ────────────────────────────────────────────────

  it("MAIL_ROLES includes all pipeline roles", () => {
    expect(MAIL_ROLES).toContain("explorer");
    expect(MAIL_ROLES).toContain("developer");
    expect(MAIL_ROLES).toContain("qa");
    expect(MAIL_ROLES).toContain("reviewer");
  });

  // ── _sendMessage (business logic) ─────────────────────────────────────

  it("_sendMessage stores message in recipient inbox", () => {
    mail._sendMessage({
      to: "developer",
      from: "explorer",
      subject: "Key finding",
      body: "Found important patterns in src/orchestrator/",
    });

    const messages = mail.getMessages("developer");
    expect(messages).toHaveLength(1);
    expect(messages[0].from).toBe("explorer");
    expect(messages[0].to).toBe("developer");
    expect(messages[0].subject).toBe("Key finding");
    expect(messages[0].body).toBe("Found important patterns in src/orchestrator/");
    expect(messages[0].timestamp).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(messages[0].id).toBe(1);
  });

  it("_sendMessage returns success with messageId", () => {
    const result = mail._sendMessage({
      to: "qa",
      from: "developer",
      subject: "Test coverage",
      body: "Please test edge case X",
    });

    expect(result.success).toBe(true);
    expect(result.messageId).toBe(1);
    expect(result.error).toBeUndefined();
  });

  it("_sendMessage rejects unknown role", () => {
    const result = mail._sendMessage({
      to: "unknown-role",
      from: "developer",
      subject: "Test",
      body: "Body",
    });

    expect(result.success).toBe(false);
    expect(result.error).toContain("unknown-role");
    expect(result.messageId).toBeUndefined();
  });

  it("_sendMessage does not store message for unknown role", () => {
    mail._sendMessage({
      to: "invalid",
      from: "developer",
      subject: "Test",
      body: "Body",
    });

    // No entry should be created for invalid role
    const all = mail.getAllMessages();
    expect(Object.keys(all)).not.toContain("invalid");
  });

  it("_sendMessage assigns incrementing IDs across all messages", () => {
    mail._sendMessage({ to: "developer", from: "explorer", subject: "First", body: "A" });
    mail._sendMessage({ to: "developer", from: "qa", subject: "Second", body: "B" });
    mail._sendMessage({ to: "qa", from: "developer", subject: "Third", body: "C" });

    const devMessages = mail.getMessages("developer");
    const qaMessages = mail.getMessages("qa");

    expect(devMessages[0].id).toBe(1);
    expect(devMessages[1].id).toBe(2);
    expect(qaMessages[0].id).toBe(3);
  });

  it("messages go to correct inboxes independently", () => {
    mail._sendMessage({ to: "developer", from: "explorer", subject: "For dev", body: "Dev msg" });
    mail._sendMessage({ to: "qa", from: "developer", subject: "For QA", body: "QA msg" });

    expect(mail.getMessages("developer")).toHaveLength(1);
    expect(mail.getMessages("qa")).toHaveLength(1);
    expect(mail.getMessages("reviewer")).toHaveLength(0);
    expect(mail.getMessages("explorer")).toHaveLength(0);
  });

  it("multiple messages can be sent to the same inbox", () => {
    mail._sendMessage({ to: "developer", from: "explorer", subject: "Msg 1", body: "A" });
    mail._sendMessage({ to: "developer", from: "explorer", subject: "Msg 2", body: "B" });
    mail._sendMessage({ to: "developer", from: "qa", subject: "Msg 3", body: "C" });

    expect(mail.getMessages("developer")).toHaveLength(3);
  });

  // ── _readMessages (business logic) ────────────────────────────────────

  it("_readMessages returns 'No messages' message for empty inbox", () => {
    const result = mail._readMessages({ role: "developer" });

    expect(result.messages).toHaveLength(0);
    expect(result.formatted).toContain("No messages");
    expect(result.formatted).toContain("developer");
  });

  it("_readMessages returns all messages for a role", () => {
    mail._sendMessage({
      to: "qa",
      from: "developer",
      subject: "What to test",
      body: "Test the edge case where input is empty",
    });

    const result = mail._readMessages({ role: "qa" });

    expect(result.messages).toHaveLength(1);
    expect(result.formatted).toContain("1 message(s)");
    expect(result.formatted).toContain("developer");
    expect(result.formatted).toContain("What to test");
    expect(result.formatted).toContain("Test the edge case where input is empty");
  });

  it("_readMessages returns multiple messages in order (oldest first)", () => {
    mail._sendMessage({ to: "reviewer", from: "developer", subject: "First", body: "Body A" });
    mail._sendMessage({ to: "reviewer", from: "qa", subject: "Second", body: "Body B" });

    const result = mail._readMessages({ role: "reviewer" });

    expect(result.messages).toHaveLength(2);
    expect(result.formatted).toContain("2 message(s)");

    // First message should appear before second in formatted output
    const firstIdx = result.formatted.indexOf("First");
    const secondIdx = result.formatted.indexOf("Second");
    expect(firstIdx).toBeLessThan(secondIdx);
  });

  it("_readMessages includes message ID, from, subject in formatted output", () => {
    mail._sendMessage({ to: "qa", from: "explorer", subject: "Important note", body: "Details" });

    const result = mail._readMessages({ role: "qa" });

    expect(result.formatted).toContain("Message #1");
    expect(result.formatted).toContain("From: explorer");
    expect(result.formatted).toContain("Subject: Important note");
  });

  it("_readMessages only returns messages for the specified role", () => {
    mail._sendMessage({ to: "developer", from: "explorer", subject: "Dev msg", body: "Dev" });
    mail._sendMessage({ to: "qa", from: "developer", subject: "QA msg", body: "QA" });

    const devResult = mail._readMessages({ role: "developer" });
    expect(devResult.messages).toHaveLength(1);
    expect(devResult.messages[0].subject).toBe("Dev msg");

    const qaResult = mail._readMessages({ role: "qa" });
    expect(qaResult.messages).toHaveLength(1);
    expect(qaResult.messages[0].subject).toBe("QA msg");
  });

  // ── getMessages() helper ───────────────────────────────────────────────

  it("getMessages() returns a copy, not the internal array", () => {
    mail._sendMessage({ to: "developer", from: "explorer", subject: "Test", body: "Body" });

    const copy1 = mail.getMessages("developer");
    const copy2 = mail.getMessages("developer");

    // Different array instances
    expect(copy1).not.toBe(copy2);
    // Same content
    expect(copy1).toEqual(copy2);
  });

  it("mutating getMessages() result does not affect internal state", () => {
    mail._sendMessage({ to: "developer", from: "explorer", subject: "Test", body: "Body" });

    const copy = mail.getMessages("developer");
    copy.pop(); // Mutate the returned copy

    // Internal state should be unchanged
    expect(mail.getMessages("developer")).toHaveLength(1);
  });

  // ── getAllMessages() helper ────────────────────────────────────────────

  it("getAllMessages() returns snapshot of all inboxes that have messages", () => {
    mail._sendMessage({ to: "developer", from: "explorer", subject: "For dev", body: "Dev" });
    mail._sendMessage({ to: "qa", from: "developer", subject: "For QA", body: "QA" });

    const all = mail.getAllMessages();

    expect(Object.keys(all)).toHaveLength(2);
    expect(all["developer"]).toHaveLength(1);
    expect(all["qa"]).toHaveLength(1);
    expect(all["reviewer"]).toBeUndefined();
  });

  it("getAllMessages() does not include roles with no messages", () => {
    // Only send to developer
    mail._sendMessage({ to: "developer", from: "explorer", subject: "Test", body: "Body" });

    const all = mail.getAllMessages();
    expect(Object.keys(all)).not.toContain("qa");
    expect(Object.keys(all)).not.toContain("reviewer");
    expect(Object.keys(all)).not.toContain("explorer");
  });

  // ── clearAll() helper ─────────────────────────────────────────────────

  it("clearAll() removes all messages", () => {
    mail._sendMessage({ to: "developer", from: "explorer", subject: "Pre-clear", body: "Del" });
    mail._sendMessage({ to: "qa", from: "developer", subject: "Pre-clear 2", body: "Del" });

    expect(mail.getMessages("developer")).toHaveLength(1);
    expect(mail.getMessages("qa")).toHaveLength(1);

    mail.clearAll();

    expect(mail.getMessages("developer")).toHaveLength(0);
    expect(mail.getMessages("qa")).toHaveLength(0);
    expect(mail.getAllMessages()).toEqual({});
  });

  it("clearAll() resets ID counter to 1", () => {
    mail._sendMessage({ to: "developer", from: "explorer", subject: "First", body: "A" });
    expect(mail.getMessages("developer")[0].id).toBe(1);

    mail.clearAll();

    mail._sendMessage({ to: "developer", from: "explorer", subject: "Post-clear", body: "B" });
    expect(mail.getMessages("developer")[0].id).toBe(1);
  });

  // ── Multiple server instances are independent ──────────────────────────

  it("two server instances have independent state", () => {
    const mail2 = createMailServer();

    mail._sendMessage({ to: "developer", from: "explorer", subject: "Server 1", body: "From 1" });

    expect(mail.getMessages("developer")).toHaveLength(1);
    expect(mail2.getMessages("developer")).toHaveLength(0);
  });

  it("clearAll() on one instance does not affect another", () => {
    const mail2 = createMailServer();

    mail._sendMessage({ to: "developer", from: "explorer", subject: "Msg", body: "Body" });
    mail2._sendMessage({ to: "qa", from: "developer", subject: "Msg 2", body: "Body 2" });

    mail.clearAll();

    // mail is cleared
    expect(mail.getMessages("developer")).toHaveLength(0);
    // mail2 is unaffected
    expect(mail2.getMessages("qa")).toHaveLength(1);
  });

  // ── Pipeline simulation ───────────────────────────────────────────────

  it("simulates realistic pipeline message flow", () => {
    // Explorer → Developer: architectural findings
    mail._sendMessage({
      to: "developer",
      from: "explorer",
      subject: "Architecture findings",
      body: "Key files: src/foo.ts, src/bar.ts. Pattern: use addX() factory function.",
    });

    // Developer reads inbox before starting
    const devInbox = mail._readMessages({ role: "developer" });
    expect(devInbox.messages).toHaveLength(1);
    expect(devInbox.messages[0].subject).toBe("Architecture findings");

    // Developer → QA: implementation summary
    mail._sendMessage({
      to: "qa",
      from: "developer",
      subject: "Implementation complete",
      body: "Changed foo.ts and bar.ts. Edge case: empty input returns null.",
    });

    // QA reads inbox
    const qaInbox = mail._readMessages({ role: "qa" });
    expect(qaInbox.messages).toHaveLength(1);
    expect(qaInbox.messages[0].from).toBe("developer");

    // QA → Reviewer: test results
    mail._sendMessage({
      to: "reviewer",
      from: "qa",
      subject: "QA results",
      body: "All tests pass. Edge case tested.",
    });

    // Reviewer reads inbox
    const reviewerInbox = mail._readMessages({ role: "reviewer" });
    expect(reviewerInbox.messages).toHaveLength(1);
    expect(reviewerInbox.messages[0].from).toBe("qa");

    // Explorer inbox should still be empty (no one messages it)
    expect(mail.getMessages("explorer")).toHaveLength(0);

    // Total message count
    const all = mail.getAllMessages();
    const totalMessages = Object.values(all).reduce((sum, msgs) => sum + msgs.length, 0);
    expect(totalMessages).toBe(3);
  });
});

// ── Integration: prompt references agent-mail ─────────────────────────────────

describe("role prompts include agent-mail documentation", () => {
  it("explorerPrompt mentions agent-mail tools", async () => {
    const { explorerPrompt } = await import("../roles.js");
    const prompt = explorerPrompt("seed-1", "Test Task", "Description");
    expect(prompt).toContain("agent-mail");
    expect(prompt).toContain("send_message");
    expect(prompt).toContain("read_messages");
  });

  it("developerPrompt mentions agent-mail tools and role", async () => {
    const { developerPrompt } = await import("../roles.js");
    const prompt = developerPrompt("seed-1", "Test Task", "Description", true);
    expect(prompt).toContain("agent-mail");
    expect(prompt).toContain("send_message");
    expect(prompt).toContain("read_messages");
    expect(prompt).toContain('"developer"');
  });

  it("qaPrompt mentions agent-mail tools and role", async () => {
    const { qaPrompt } = await import("../roles.js");
    const prompt = qaPrompt("seed-1", "Test Task");
    expect(prompt).toContain("agent-mail");
    expect(prompt).toContain("send_message");
    expect(prompt).toContain("read_messages");
    expect(prompt).toContain('"qa"');
  });

  it("reviewerPrompt mentions agent-mail tools and role", async () => {
    const { reviewerPrompt } = await import("../roles.js");
    const prompt = reviewerPrompt("seed-1", "Test Task", "Description");
    expect(prompt).toContain("agent-mail");
    expect(prompt).toContain("send_message");
    expect(prompt).toContain("read_messages");
    expect(prompt).toContain('"reviewer"');
  });

  it("developerPrompt without feedback still includes agent-mail section", async () => {
    const { developerPrompt } = await import("../roles.js");
    const prompt = developerPrompt("seed-1", "Test", "Desc", false, undefined);
    expect(prompt).toContain("agent-mail");
  });

  it("developerPrompt with feedback still includes agent-mail section", async () => {
    const { developerPrompt } = await import("../roles.js");
    const prompt = developerPrompt("seed-1", "Test", "Desc", true, "Fix the bug on line 42");
    expect(prompt).toContain("agent-mail");
    expect(prompt).toContain("Fix the bug on line 42");
  });
});
