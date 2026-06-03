import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createPostgresProjectFixture,
  startPostgresTestcontainer,
  stopPostgresTestcontainer,
} from "../../test-support/postgres-testcontainer.js";

/** Task backend enqueue coverage now uses the production Postgres bead queue. */
describe("task backend ops enqueue — Postgres", { timeout: 120_000 }, () => {
  beforeAll(async () => {
    await startPostgresTestcontainer();
  });

  afterAll(async () => {
    await stopPostgresTestcontainer();
  });

  it("stores queued backend operations", async () => {
    const { adapter, store, project } = await createPostgresProjectFixture("task-backend-ops");
    await adapter.enqueueBeadWrite(project.id, "dispatcher", "reset-seed", { seedId: "bd-reset" });
    expect(await store.getPendingBeadWrites()).toEqual([
      expect.objectContaining({ sender: "dispatcher", operation: "reset-seed" }),
    ]);
  });
});
