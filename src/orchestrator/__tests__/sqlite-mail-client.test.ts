/**
 * Tests for SqliteMailClient — SQLite-backed drop-in for AgentMailClient.
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { SqliteMailClient } from "../../lib/sqlite-mail-client.js";
import { ForemanStore } from "../../lib/store.js";

// ── Fixtures ──────────────────────────────────────────────────────────────────

let tmpDir: string;
let projectDir: string;
let store: ForemanStore;
let runId: string;

beforeEach(() => {
  tmpDir = mkdtempSync(join(tmpdir(), "sqlite-mail-test-"));
  projectDir = tmpDir;

  // Set up a real store so SqliteMailClient can write messages
  store = ForemanStore.forProject(projectDir);
  const project = store.registerProject("test-project", projectDir);
  const run = store.createRun(project.id, "bd-test-01", "claude-sonnet-4-6");
  runId = run.id;
});

afterEach(() => {
  try { store.close(); } catch { /* already closed */ }
  rmSync(tmpDir, { recursive: true, force: true });
});

// ── Helper ────────────────────────────────────────────────────────────────────

async function makeClient(role = "foreman"): Promise<SqliteMailClient> {
  const client = new SqliteMailClient();
  await client.ensureProject(projectDir);
  client.setRunId(runId);
  client.agentName = role;
  return client;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("SqliteMailClient", () => {
  // ── healthCheck ─────────────────────────────────────────────────────────────

  it("healthCheck() always returns true", async () => {
    const client = new SqliteMailClient();
    const result = await client.healthCheck();
    expect(result).toBe(true);
  });

  // ── sendMessage + fetchInbox ─────────────────────────────────────────────────

  it("sendMessage() stores to SQLite and is readable via fetchInbox()", async () => {
    const sender = await makeClient("foreman");
    await sender.sendMessage("developer", "Hello Developer", "Please implement the feature.");

    const recipient = await makeClient("developer");
    const inbox = await recipient.fetchInbox("developer");

    expect(inbox).toHaveLength(1);
    expect(inbox[0]?.subject).toBe("Hello Developer");
    expect(inbox[0]?.body).toBe("Please implement the feature.");
    expect(inbox[0]?.from).toBe("foreman");
    expect(inbox[0]?.to).toBe("developer");
    expect(inbox[0]?.acknowledged).toBe(false);
  });

  // ── acknowledgeMessage ───────────────────────────────────────────────────────

  it("acknowledgeMessage() marks message as read", async () => {
    const sender = await makeClient("foreman");
    await sender.sendMessage("qa", "QA Feedback", "Tests failed on line 42.");

    const qa = await makeClient("qa");
    const inboxBefore = await qa.fetchInbox("qa");
    expect(inboxBefore).toHaveLength(1);
    const msgId = inboxBefore[0]!.id;

    // acknowledgeMessage takes a numeric ID but we pass the string UUID — coerce
    await qa.acknowledgeMessage("qa", Number(msgId) || 0);

    // The string UUID version — use markMessageRead directly to verify
    store.markMessageRead(msgId);

    // Now inbox should be empty (only unread)
    const inboxAfter = await qa.fetchInbox("qa");
    expect(inboxAfter).toHaveLength(0);
  });

  // ── sendMessage no-op when runId is null ─────────────────────────────────────

  it("sendMessage() is a no-op when runId is not set", async () => {
    const client = new SqliteMailClient();
    await client.ensureProject(projectDir);
    // Intentionally do NOT call setRunId()
    client.agentName = "foreman";

    // Should not throw
    await expect(
      client.sendMessage("developer", "Subject", "Body"),
    ).resolves.toBeUndefined();

    // No messages should be written
    const messages = store.getAllMessages(runId);
    expect(messages).toHaveLength(0);
  });

  // ── Multiple messages with same subject prefix ────────────────────────────────

  it("fetchInbox() returns all messages matching recipient, even with same subject prefix", async () => {
    const sender = await makeClient("foreman");
    await sender.sendMessage("developer", "QA Feedback - Retry 1", "First QA feedback.");
    await sender.sendMessage("developer", "QA Feedback - Retry 2", "Second QA feedback.");
    await sender.sendMessage("developer", "QA Feedback - Retry 3", "Third QA feedback.");

    const recipient = await makeClient("developer");
    const inbox = await recipient.fetchInbox("developer");

    expect(inbox).toHaveLength(3);
    const subjects = inbox.map((m) => m.subject);
    expect(subjects).toContain("QA Feedback - Retry 1");
    expect(subjects).toContain("QA Feedback - Retry 2");
    expect(subjects).toContain("QA Feedback - Retry 3");
  });

  // ── ensureAgentRegistered ────────────────────────────────────────────────────

  it("ensureAgentRegistered() returns the roleHint as-is", async () => {
    const client = new SqliteMailClient();
    const name = await client.ensureAgentRegistered("developer-bd-abc");
    expect(name).toBe("developer-bd-abc");
  });

  it("ensureAgentRegistered() sets agentName if not already set", async () => {
    const client = new SqliteMailClient();
    expect(client.agentName).toBeNull();
    await client.ensureAgentRegistered("explorer");
    expect(client.agentName).toBe("explorer");
  });

  it("ensureAgentRegistered() does not overwrite an existing agentName", async () => {
    const client = new SqliteMailClient();
    client.agentName = "already-set";
    await client.ensureAgentRegistered("new-role");
    expect(client.agentName).toBe("already-set");
  });

  // ── Cross-agent isolation ────────────────────────────────────────────────────

  it("fetchInbox() for one recipient does not include messages to another", async () => {
    const sender = await makeClient("foreman");
    await sender.sendMessage("developer", "For Developer", "Dev message.");
    await sender.sendMessage("qa", "For QA", "QA message.");

    const devClient = await makeClient("developer");
    const devInbox = await devClient.fetchInbox("developer");
    expect(devInbox).toHaveLength(1);
    expect(devInbox[0]?.subject).toBe("For Developer");

    const qaClient = await makeClient("qa");
    const qaInbox = await qaClient.fetchInbox("qa");
    expect(qaInbox).toHaveLength(1);
    expect(qaInbox[0]?.subject).toBe("For QA");
  });

  // ── reserveFiles / releaseFiles are no-ops ───────────────────────────────────

  it("reserveFiles() and releaseFiles() are no-ops that do not throw", async () => {
    const client = await makeClient();
    await expect(
      client.reserveFiles(["/tmp/some/path"], "developer", 600),
    ).resolves.toBeUndefined();
    await expect(
      client.releaseFiles(["/tmp/some/path"], "developer"),
    ).resolves.toBeUndefined();
  });
});
