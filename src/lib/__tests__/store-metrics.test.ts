import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createPostgresProjectFixture,
  startPostgresTestcontainer,
  stopPostgresTestcontainer,
} from "../../test-support/postgres-testcontainer.js";

/** Metrics coverage now targets production PostgresStore. */
describe("PostgresStore metrics", { timeout: 120_000 }, () => {
  beforeAll(async () => {
    await startPostgresTestcontainer();
  });

  afterAll(async () => {
    await stopPostgresTestcontainer();
  });

  it("returns costs with date filtering and runtime joinability", async () => {
    const { store, project } = await createPostgresProjectFixture("metrics-costs");
    const r1 = await store.createRun(project.id, "bd-1", "claude-code", null);
    const r2 = await store.createRun(project.id, "bd-2", "pi", null);

    await store.recordCost(r1.id, 1000, 500, 0, 0.05);
    await store.recordCost(r1.id, 500, 250, 0, 0.02);
    await store.recordCost(r2.id, 2000, 1000, 0, 0.10);

    const costs = await store.getCosts(project.id);
    expect(costs).toHaveLength(3);
    expect(await store.getCosts(project.id, "2099-01-01T00:00:00Z")).toEqual([]);
    expect(await store.getCosts(project.id, "2000-01-01T00:00:00Z")).toHaveLength(3);

    const byRuntime: Record<string, number> = {};
    for (const cost of costs) {
      const run = await store.getRun(cost.run_id);
      if (run) byRuntime[run.agent_type] = (byRuntime[run.agent_type] ?? 0) + cost.estimated_cost;
    }
    expect(byRuntime["claude-code"]).toBeCloseTo(0.07);
    expect(byRuntime.pi).toBeCloseTo(0.10);
  });

  it("aggregates phase metrics and success rate", async () => {
    const { store, project } = await createPostgresProjectFixture("metrics-phase");
    const merged = await store.createRun(project.id, "bd-ok", "pipeline", null);
    const failed = await store.createRun(project.id, "bd-fail", "pipeline", null);

    await store.recordCost(merged.id, 100, 50, 10, 0.10);
    await store.recordCost(failed.id, 200, 100, 0, 0.20);
    await store.updateRun(merged.id, { status: "merged" });
    await store.updateRun(failed.id, { status: "failed" });

    const metrics = await store.getPhaseMetrics(project.id);
    expect(metrics.totalCost).toBeCloseTo(0.30);
    expect(metrics.totalTokens).toBe(460);
    expect(metrics.tasksByStatus).toEqual(expect.objectContaining({ completed: 1, failed: 1 }));
    expect(await store.getSuccessRate(project.id)).toEqual({ rate: 0.5, merged: 1, failed: 1 });
  });

  it("returns cost breakdown for a run with costs", async () => {
    const { store, project } = await createPostgresProjectFixture("metrics-breakdown");
    const run = await store.createRun(project.id, "bd-cost", "developer", null);
    expect(await store.getCostBreakdown(run.id)).toEqual({ byPhase: { total: 0 }, byAgent: { unknown: 0 } });
    await store.recordCost(run.id, 100, 50, 0, 0.25);
    expect(await store.getCostBreakdown(run.id)).toEqual({ byPhase: { total: 0.25 }, byAgent: { developer: 0.25 } });
  });
});
