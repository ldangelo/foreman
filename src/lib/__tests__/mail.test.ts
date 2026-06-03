import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createPostgresProjectFixture,
  startPostgresTestcontainer,
  stopPostgresTestcontainer,
} from "../../test-support/postgres-testcontainer.js";

/**
 * Mail persistence now targets PostgresStore directly. The old synchronous
 * MailClient wraps removed local ForemanStore behavior, so these tests cover the
 * production message API used by PostgresMailClient/agents.
 */
describe("Postgres mail storage", { timeout: 120_000 }, () => {
  beforeAll(async () => {
    await startPostgresTestcontainer();
  });

  afterAll(async () => {
    await stopPostgresTestcontainer();
  });

  it("sends, reads, marks read, and soft-deletes messages", async () => {
    const { store, project } = await createPostgresProjectFixture("mail");
    const run = await store.createRun(project.id, "bd-mail", "developer", "/tmp/wt");

    await store.sendMessage(run.id, "explorer", "developer", "Hello", "From explorer");
    await store.sendMessage(run.id, "explorer", "developer", "Another", "Second message");
    await store.sendMessage(run.id, "explorer", "qa", "QA", "For QA only");

    const devInbox = await store.getMessages(run.id, "developer", true);
    expect(devInbox).toHaveLength(2);
    expect(devInbox.every((m) => m.read === 0)).toBe(true);
    expect(await store.getMessages(run.id, "qa", true)).toEqual([expect.objectContaining({ subject: "QA" })]);

    await store.markMessageRead(devInbox[0].id);
    expect(await store.getMessages(run.id, "developer", true)).toHaveLength(1);
    expect(await store.getMessages(run.id, "developer", false)).toHaveLength(2);

    await store.markAllMessagesRead(run.id, "developer");
    expect(await store.getMessages(run.id, "developer", true)).toEqual([]);

    await store.deleteMessage(devInbox[0].id);
    expect(await store.getAllMessages(run.id)).toHaveLength(2);
  });

  it("isolates messages by run", async () => {
    const { store, project } = await createPostgresProjectFixture("mail-isolation");
    const run1 = await store.createRun(project.id, "bd-mail-1", "developer", "/tmp/wt1");
    const run2 = await store.createRun(project.id, "bd-mail-2", "developer", "/tmp/wt2");

    await store.sendMessage(run1.id, "explorer", "developer", "Run 1", "body");

    expect(await store.getMessages(run1.id, "developer", true)).toHaveLength(1);
    expect(await store.getMessages(run2.id, "developer", true)).toEqual([]);
  });

  it("allows self messages", async () => {
    const { store, project } = await createPostgresProjectFixture("mail-self");
    const run = await store.createRun(project.id, "bd-mail-self", "developer", "/tmp/wt");

    await store.sendMessage(run.id, "developer", "developer", "Self note", "Remember this");

    expect(await store.getMessages(run.id, "developer", true)).toEqual([
      expect.objectContaining({ sender_agent_type: "developer", recipient_agent_type: "developer", subject: "Self note" }),
    ]);
  });
});
