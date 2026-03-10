import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../store.js";

describe("ForemanStore — metrics queries", () => {
  let store: ForemanStore;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-metrics-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("getCosts returns costs grouped by project with runtime join", () => {
    const project = store.registerProject("p", "/p");
    const r1 = store.createRun(project.id, "bd-1", "claude-code");
    const r2 = store.createRun(project.id, "bd-2", "pi");

    store.recordCost(r1.id, 1000, 500, 0, 0.05);
    store.recordCost(r1.id, 500, 250, 0, 0.02);
    store.recordCost(r2.id, 2000, 1000, 0, 0.10);

    const costs = store.getCosts(project.id);
    expect(costs).toHaveLength(3);

    // Verify we can join costs back to runs for runtime grouping
    const byRuntime: Record<string, number> = {};
    for (const c of costs) {
      const run = store.getRun(c.run_id);
      if (run) {
        byRuntime[run.agent_type] = (byRuntime[run.agent_type] ?? 0) + c.estimated_cost;
      }
    }
    expect(byRuntime["claude-code"]).toBeCloseTo(0.07);
    expect(byRuntime["pi"]).toBeCloseTo(0.10);
  });

  it("date filtering works (costs after a specific date)", () => {
    const project = store.registerProject("p", "/p");
    const run = store.createRun(project.id, "bd-1", "claude-code");

    store.recordCost(run.id, 1000, 500, 0, 0.05);
    store.recordCost(run.id, 2000, 1000, 0, 0.10);

    // All costs were recorded "now", so a far-future since should return 0
    const futureDate = "2099-01-01T00:00:00Z";
    expect(store.getCosts(project.id, futureDate)).toHaveLength(0);

    // A far-past since should return all
    const pastDate = "2000-01-01T00:00:00Z";
    expect(store.getCosts(project.id, pastDate)).toHaveLength(2);
  });

  it("getRunsByStatus filters correctly", () => {
    const project = store.registerProject("p", "/p");
    const r1 = store.createRun(project.id, "bd-1", "claude-code");
    const r2 = store.createRun(project.id, "bd-2", "pi");
    const r3 = store.createRun(project.id, "bd-3", "codex");
    const r4 = store.createRun(project.id, "bd-4", "claude-code");

    // r1, r2 start as pending
    store.updateRun(r1.id, { status: "running", started_at: new Date().toISOString() });
    store.updateRun(r2.id, {
      status: "completed",
      started_at: new Date().toISOString(),
      completed_at: new Date().toISOString(),
    });
    store.updateRun(r3.id, { status: "failed" });
    // r4 stays pending

    expect(store.getRunsByStatus("pending", project.id)).toHaveLength(1);
    expect(store.getRunsByStatus("running", project.id)).toHaveLength(1);
    expect(store.getRunsByStatus("completed", project.id)).toHaveLength(1);
    expect(store.getRunsByStatus("failed", project.id)).toHaveLength(1);

    // Cross-project (no filter)
    expect(store.getRunsByStatus("pending")).toHaveLength(1);
  });

  it("empty project returns zero metrics (not errors)", () => {
    const project = store.registerProject("empty", "/empty");
    const metrics = store.getMetrics(project.id);

    expect(metrics.totalCost).toBe(0);
    expect(metrics.totalTokens).toBe(0);
    expect(metrics.tasksByStatus).toEqual({});
    expect(metrics.costByRuntime).toEqual([]);
  });
});
