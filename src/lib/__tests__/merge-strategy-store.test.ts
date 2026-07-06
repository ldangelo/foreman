import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createPostgresProjectFixture,
  startPostgresTestcontainer,
  stopPostgresTestcontainer,
} from "../../test-support/postgres-testcontainer.js";

/** merge_strategy coverage now targets production PostgresStore. */
describe("merge_strategy in Postgres runs table", { timeout: 120_000 }, () => {
  let postgresAvailable = true;

  beforeAll(async () => {
    try {
      await startPostgresTestcontainer();
    } catch {
      postgresAvailable = false;
    }
  }, 120_000);

  afterAll(async () => {
    if (postgresAvailable) {
      await stopPostgresTestcontainer();
    }
  });

  it.each(["pr", "none", "auto"] as const)("stores and retrieves merge_strategy: %s", async (strategy) => {
    if (!postgresAvailable) return;
    const { store, project } = await createPostgresProjectFixture(`merge-${strategy}`);
    const run = await store.createRun(project.id, `task-${strategy}`, "developer", null, { mergeStrategy: strategy });

    expect(run.merge_strategy).toBe(strategy);
    expect((await store.getRun(run.id))?.merge_strategy).toBe(strategy);
  });

  it("defaults merge_strategy to auto when not specified", async () => {
    if (!postgresAvailable) return;
    const { store, project } = await createPostgresProjectFixture("merge-default");
    const run = await store.createRun(project.id, "task-default", "developer", null);

    expect(run.merge_strategy).toBe("auto");
    expect((await store.getRun(run.id))?.merge_strategy).toBe("auto");
  });

  it("updateRun can change merge_strategy", async () => {
    if (!postgresAvailable) return;
    const { store, project } = await createPostgresProjectFixture("merge-update");
    const run = await store.createRun(project.id, "task-update", "developer", null, { mergeStrategy: "none" });

    await store.updateRun(run.id, { merge_strategy: "pr" });
    expect((await store.getRun(run.id))?.merge_strategy).toBe("pr");
  });
});
