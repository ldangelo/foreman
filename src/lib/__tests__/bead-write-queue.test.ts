import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createPostgresProjectFixture,
  startPostgresTestcontainer,
  stopPostgresTestcontainer,
} from "../../test-support/postgres-testcontainer.js";

/** Bead write queue coverage now targets production PostgresStore/PostgresAdapter. */
describe("Postgres bead_write_queue", { timeout: 120_000 }, () => {
  beforeAll(async () => {
    await startPostgresTestcontainer();
  });

  afterAll(async () => {
    await stopPostgresTestcontainer();
  });

  it("enqueues supported operations in insertion order", async () => {
    const { adapter, store, project } = await createPostgresProjectFixture("bead-queue");
    const ops = ["close-seed", "reset-seed", "mark-failed", "add-notes", "add-labels"];
    for (const operation of ops) {
      await adapter.enqueueBeadWrite(project.id, "sender", operation, { seedId: `bd-${operation}` });
    }

    const entries = await store.getPendingBeadWrites();
    expect(entries).toHaveLength(5);
    expect(entries.map((entry) => entry.operation)).toEqual(ops);
    expect(JSON.parse(entries[0].payload)).toEqual({ seedId: "bd-close-seed" });
    expect(new Set(entries.map((entry) => entry.id)).size).toBe(5);
  });

  it("marks entries processed and keeps project queues isolated", async () => {
    const a = await createPostgresProjectFixture("bead-queue-a");
    const b = await createPostgresProjectFixture("bead-queue-b");

    await a.adapter.enqueueBeadWrite(a.project.id, "sender", "close-seed", { seedId: "bd-a" });
    await b.adapter.enqueueBeadWrite(b.project.id, "sender", "close-seed", { seedId: "bd-b" });

    const [entry] = await a.store.getPendingBeadWrites();
    expect(await a.store.markBeadWriteProcessed(entry.id)).toBe(true);
    expect(await a.store.markBeadWriteProcessed(entry.id)).toBe(false);
    expect(await a.store.getPendingBeadWrites()).toEqual([]);
    expect(await b.store.getPendingBeadWrites()).toEqual([expect.objectContaining({ operation: "close-seed" })]);
  });
});
