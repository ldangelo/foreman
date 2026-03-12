import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../store.js";
import { MailClient } from "../mail.js";

describe("MailClient", () => {
  let store: ForemanStore;
  let tmpDir: string;
  let runId: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-mail-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));

    // Set up a project and run for each test
    const project = store.registerProject("test-project", "/test-project");
    const run = store.createRun(project.id, "sd-test-1", "claude-code");
    runId = run.id;
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  describe("send", () => {
    it("sends a message and returns a MailMessage", () => {
      const mail = new MailClient(store, runId, "explorer");
      const msg = mail.send("developer", "Phase complete", "Exploration is done.");

      expect(msg.id).toBeDefined();
      expect(msg.from).toBe("explorer");
      expect(msg.to).toBe("developer");
      expect(msg.subject).toBe("Phase complete");
      expect(msg.body).toBe("Exploration is done.");
      expect(msg.read).toBe(false);
      expect(msg.createdAt).toBeInstanceOf(Date);
    });
  });

  describe("inbox", () => {
    it("returns unread messages by default", () => {
      const explorerMail = new MailClient(store, runId, "explorer");
      const devMail = new MailClient(store, runId, "developer");

      explorerMail.send("developer", "Hello", "From explorer");
      explorerMail.send("developer", "Another", "Second message");

      const inbox = devMail.inbox();
      expect(inbox).toHaveLength(2);
      expect(inbox.every((m) => m.read === false)).toBe(true);
    });

    it("does not include messages for other agents", () => {
      const explorerMail = new MailClient(store, runId, "explorer");
      const qaMail = new MailClient(store, runId, "qa");

      explorerMail.send("qa", "QA message", "For QA only");
      explorerMail.send("developer", "Dev message", "For developer only");

      const qaInbox = qaMail.inbox();
      expect(qaInbox).toHaveLength(1);
      expect(qaInbox[0].subject).toBe("QA message");
    });

    it("excludes read messages when unreadOnly=true", () => {
      const explorerMail = new MailClient(store, runId, "explorer");
      const devMail = new MailClient(store, runId, "developer");

      const m1 = explorerMail.send("developer", "First", "body1");
      explorerMail.send("developer", "Second", "body2");

      devMail.markRead(m1.id);

      const unread = devMail.inbox(true);
      expect(unread).toHaveLength(1);
      expect(unread[0].subject).toBe("Second");
    });

    it("includes read messages when unreadOnly=false", () => {
      const explorerMail = new MailClient(store, runId, "explorer");
      const devMail = new MailClient(store, runId, "developer");

      const m1 = explorerMail.send("developer", "First", "body1");
      devMail.markRead(m1.id);

      const all = devMail.inbox(false);
      expect(all).toHaveLength(1);
      expect(all[0].read).toBe(true);
    });
  });

  describe("allMessages", () => {
    it("returns all non-deleted messages including read", () => {
      const explorerMail = new MailClient(store, runId, "explorer");
      const devMail = new MailClient(store, runId, "developer");

      explorerMail.send("developer", "A", "body");
      explorerMail.send("developer", "B", "body");
      devMail.markAllRead();

      const all = devMail.allMessages();
      expect(all).toHaveLength(2);
    });
  });

  describe("markRead / markAllRead", () => {
    it("marks a single message read", () => {
      const explorerMail = new MailClient(store, runId, "explorer");
      const devMail = new MailClient(store, runId, "developer");

      const msg = explorerMail.send("developer", "Hi", "body");
      expect(devMail.inbox(true)).toHaveLength(1);

      devMail.markRead(msg.id);
      expect(devMail.inbox(true)).toHaveLength(0);
    });

    it("marks all messages read at once", () => {
      const explorerMail = new MailClient(store, runId, "explorer");
      const qaMail = new MailClient(store, runId, "qa");
      const devMail = new MailClient(store, runId, "developer");

      explorerMail.send("developer", "A", "body");
      explorerMail.send("developer", "B", "body");
      explorerMail.send("qa", "C", "body"); // to qa, not developer

      devMail.markAllRead();

      expect(devMail.inbox(true)).toHaveLength(0);
      // QA message unaffected
      expect(qaMail.inbox(true)).toHaveLength(1);
    });
  });

  describe("delete", () => {
    it("soft-deletes a message so it no longer appears in inbox", () => {
      const explorerMail = new MailClient(store, runId, "explorer");
      const devMail = new MailClient(store, runId, "developer");

      const msg = explorerMail.send("developer", "Delete me", "body");
      devMail.delete(msg.id);

      expect(devMail.inbox(false)).toHaveLength(0);
    });
  });

  describe("allRunMessages", () => {
    it("returns all non-deleted messages across all agents in a run", () => {
      const explorerMail = new MailClient(store, runId, "explorer");
      const devMail = new MailClient(store, runId, "developer");
      const leadMail = new MailClient(store, runId, "lead");

      explorerMail.send("developer", "From explorer", "body");
      devMail.send("qa", "From developer", "body");
      const msg = leadMail.send("explorer", "From lead", "body");
      devMail.delete(msg.id); // delete lead's message to explorer

      const all = leadMail.allRunMessages();
      expect(all).toHaveLength(2);
    });
  });

  describe("formatInbox", () => {
    it("returns a placeholder when there are no unread messages", () => {
      const devMail = new MailClient(store, runId, "developer");
      expect(devMail.formatInbox()).toBe("(no unread messages)");
    });

    it("formats unread messages as a numbered list", () => {
      const explorerMail = new MailClient(store, runId, "explorer");
      const devMail = new MailClient(store, runId, "developer");

      explorerMail.send("developer", "First subject", "First body");
      explorerMail.send("developer", "Second subject", "Second body");

      const formatted = devMail.formatInbox();
      expect(formatted).toContain("[1]");
      expect(formatted).toContain("[2]");
      expect(formatted).toContain("From: explorer");
      expect(formatted).toContain("First subject");
      expect(formatted).toContain("Second subject");
    });
  });

  describe("run isolation", () => {
    it("messages in one run are not visible to another run's agents", () => {
      const project = store.registerProject("p2", "/p2");
      const run2 = store.createRun(project.id, "sd-test-2", "claude-code");

      const mail1 = new MailClient(store, runId, "explorer");
      const mail2 = new MailClient(store, run2.id, "developer");

      mail1.send("developer", "Run 1 message", "body");

      // developer in run2 should see nothing
      expect(mail2.inbox()).toHaveLength(0);
    });
  });

  describe("edge cases", () => {
    it("an agent can send a message to itself", () => {
      const devMail = new MailClient(store, runId, "developer");
      const msg = devMail.send("developer", "Self note", "Remember this");

      expect(msg.from).toBe("developer");
      expect(msg.to).toBe("developer");
      const inbox = devMail.inbox();
      expect(inbox).toHaveLength(1);
      expect(inbox[0].subject).toBe("Self note");
    });

    it("soft-deleted messages are still retrievable via store.getMessage", () => {
      const explorerMail = new MailClient(store, runId, "explorer");
      const devMail = new MailClient(store, runId, "developer");

      const msg = explorerMail.send("developer", "Ephemeral", "body");
      devMail.delete(msg.id);

      // inbox and allMessages exclude it
      expect(devMail.inbox(false)).toHaveLength(0);
      expect(devMail.allMessages()).toHaveLength(0);

      // but store.getMessage still returns it (audit trail)
      const raw = store.getMessage(msg.id);
      expect(raw).not.toBeNull();
      expect(raw!.deleted_at).not.toBeNull();
    });

    it("markRead on a soft-deleted message does not throw", () => {
      const explorerMail = new MailClient(store, runId, "explorer");
      const devMail = new MailClient(store, runId, "developer");

      const msg = explorerMail.send("developer", "Gone", "body");
      devMail.delete(msg.id);

      // MailClient.markRead returns void; should not throw even for a soft-deleted message
      expect(() => devMail.markRead(msg.id)).not.toThrow();
      // The underlying store.markMessageRead returns true (row still exists)
      expect(store.markMessageRead(msg.id)).toBe(true);
    });

    it("formatInbox separates multiple messages with ---", () => {
      const explorerMail = new MailClient(store, runId, "explorer");
      const devMail = new MailClient(store, runId, "developer");

      explorerMail.send("developer", "Msg 1", "body 1");
      explorerMail.send("developer", "Msg 2", "body 2");

      const formatted = devMail.formatInbox();
      expect(formatted).toContain("---");
    });

    it("delete on a non-existent message id does not throw", () => {
      const devMail = new MailClient(store, runId, "developer");
      // store.deleteMessage returns false for non-existent, MailClient.delete returns void
      expect(() => devMail.delete("non-existent-id")).not.toThrow();
    });
  });
});
