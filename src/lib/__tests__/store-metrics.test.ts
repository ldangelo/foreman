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

  it("getCostsByPhase returns aggregated costs per phase", () => {
    const project = store.registerProject("p", "/p");
    const r1 = store.createRun(project.id, "bd-1", "claude-sonnet-4-5");
    const r2 = store.createRun(project.id, "bd-2", "claude-sonnet-4-5");

    store.recordPhaseCost(r1.id, "explorer", "claude-sonnet-4-5", 1000, 500, 0, 0.05);
    store.recordPhaseCost(r1.id, "developer", "claude-sonnet-4-5", 2000, 1000, 0, 0.10);
    store.recordPhaseCost(r1.id, "qa", "claude-sonnet-4-5", 500, 200, 0, 0.03);
    store.recordPhaseCost(r2.id, "developer", "claude-sonnet-4-5", 1000, 500, 0, 0.06);

    const byPhase = store.getCostsByPhase(project.id);

    expect(byPhase).toHaveLength(3);
    const developerRow = byPhase.find((r) => r.phase === "developer");
    expect(developerRow).toBeDefined();
    expect(developerRow!.total_cost).toBeCloseTo(0.16);
    expect(developerRow!.total_tokens).toBe(4500); // (2000+1000) + (1000+500)

    const explorerRow = byPhase.find((r) => r.phase === "explorer");
    expect(explorerRow!.total_cost).toBeCloseTo(0.05);

    const qaRow = byPhase.find((r) => r.phase === "qa");
    expect(qaRow!.total_cost).toBeCloseTo(0.03);
  });

  it("getCostsByPhase with date filter", () => {
    const project = store.registerProject("p2", "/p2");
    const run = store.createRun(project.id, "bd-1", "claude-sonnet-4-5");

    store.recordPhaseCost(run.id, "explorer", "claude-sonnet-4-5", 1000, 500, 0, 0.05);

    const future = "2099-01-01T00:00:00Z";
    expect(store.getCostsByPhase(project.id, future)).toHaveLength(0);

    const past = "2000-01-01T00:00:00Z";
    expect(store.getCostsByPhase(project.id, past)).toHaveLength(1);
  });

  it("getCostsByAgentAndPhase returns 2D breakdown", () => {
    const project = store.registerProject("p3", "/p3");
    const r1 = store.createRun(project.id, "bd-1", "claude-sonnet-4-5");
    const r2 = store.createRun(project.id, "bd-2", "claude-opus-4-5");

    store.recordPhaseCost(r1.id, "explorer", "claude-sonnet-4-5", 1000, 500, 0, 0.05);
    store.recordPhaseCost(r1.id, "developer", "claude-sonnet-4-5", 2000, 1000, 0, 0.10);
    store.recordPhaseCost(r2.id, "explorer", "claude-opus-4-5", 500, 200, 0, 0.08);

    const breakdown = store.getCostsByAgentAndPhase(project.id);

    expect(breakdown).toHaveLength(3);
    const sonnetDev = breakdown.find((r) => r.agent_type === "claude-sonnet-4-5" && r.phase === "developer");
    expect(sonnetDev).toBeDefined();
    expect(sonnetDev!.total_cost).toBeCloseTo(0.10);

    const opusExpl = breakdown.find((r) => r.agent_type === "claude-opus-4-5" && r.phase === "explorer");
    expect(opusExpl).toBeDefined();
    expect(opusExpl!.total_cost).toBeCloseTo(0.08);
  });

  it("getMetrics includes costByPhase and costByAgentAndPhase", () => {
    const project = store.registerProject("p4", "/p4");
    const run = store.createRun(project.id, "bd-1", "claude-sonnet-4-5");

    store.recordPhaseCost(run.id, "explorer", "claude-sonnet-4-5", 1000, 500, 0, 0.05);
    store.recordPhaseCost(run.id, "developer", "claude-sonnet-4-5", 2000, 1000, 0, 0.10);

    const metrics = store.getMetrics(project.id);

    expect(metrics.costByPhase).toHaveLength(2);
    expect(metrics.costByAgentAndPhase).toHaveLength(2);
    expect(metrics.costByPhase.find((r) => r.phase === "developer")?.total_cost).toBeCloseTo(0.10);
  });

  it("empty project returns empty phase cost arrays", () => {
    const project = store.registerProject("empty2", "/empty2");
    const metrics = store.getMetrics(project.id);

    expect(metrics.costByPhase).toEqual([]);
    expect(metrics.costByAgentAndPhase).toEqual([]);
  });

  it("recordPhaseCost throws on non-existent runId (foreign key enforced)", () => {
    // The store opens with `PRAGMA foreign_keys = ON`, so inserting a phase_cost
    // record that references a non-existent run_id must raise a constraint error.
    expect(() =>
      store.recordPhaseCost("nonexistent-run-id", "explorer", "claude-sonnet-4-5", 100, 50, 0, 0.01)
    ).toThrow();
  });
});
