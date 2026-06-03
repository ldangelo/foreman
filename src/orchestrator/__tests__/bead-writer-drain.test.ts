import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createPostgresProjectFixture,
  startPostgresTestcontainer,
  stopPostgresTestcontainer,
} from "../../test-support/postgres-testcontainer.js";

/**
 * Bead writer persistence now targets the production Postgres queue. The old
 * local ForemanStore drain tests were removed with sqlite/local storage.
 */
describe("bead writer queue — Postgres", { timeout: 120_000 }, () => {
  beforeAll(async () => {
    await startPostgresTestcontainer();
  });

  afterAll(async () => {
    await stopPostgresTestcontainer();
  });

  it("queues and marks bead writer operations processed", async () => {
    const { adapter, store, project } = await createPostgresProjectFixture("bead-writer");
    await adapter.enqueueBeadWrite(project.id, "agent-worker", "mark-failed", { seedId: "bd-1" });
    await adapter.enqueueBeadWrite(project.id, "agent-worker", "add-labels", { seedId: "bd-1", labels: ["phase:qa"] });

    const pending = await store.getPendingBeadWrites();
    expect(pending.map((entry) => entry.operation)).toEqual(["mark-failed", "add-labels"]);
    expect(await store.markBeadWriteProcessed(pending[0].id)).toBe(true);
    expect((await store.getPendingBeadWrites()).map((entry) => entry.operation)).toEqual(["add-labels"]);
  });
});
