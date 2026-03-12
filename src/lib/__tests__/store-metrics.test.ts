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
    expect(metrics.costByPhase).toBeUndefined();
    expect(metrics.agentCostBreakdown).toBeUndefined();
  });

  it("getCostBreakdown returns empty records for runs without phase data", () => {
    const project = store.registerProject("p", "/p");
    const run = store.createRun(project.id, "seed-1", "claude-code");

    // No progress set yet
    const breakdown = store.getCostBreakdown(run.id);
    expect(breakdown.byPhase).toEqual({});
    expect(breakdown.byAgent).toEqual({});
  });

  it("getCostBreakdown returns empty records for runs with progress but no phase data", () => {
    const project = store.registerProject("p", "/p");
    const run = store.createRun(project.id, "seed-1", "claude-code");

    // Progress without costByPhase (backwards compat — single-agent mode)
    store.updateRunProgress(run.id, {
      toolCalls: 5,
      toolBreakdown: { Read: 5 },
      filesChanged: [],
      turns: 3,
      costUsd: 0.05,
      tokensIn: 1000,
      tokensOut: 500,
      lastToolCall: "Read",
      lastActivity: new Date().toISOString(),
    });

    const breakdown = store.getCostBreakdown(run.id);
    expect(breakdown.byPhase).toEqual({});
    expect(breakdown.byAgent).toEqual({});
  });

  it("getCostBreakdown returns correct phase and agent costs", () => {
    const project = store.registerProject("p", "/p");
    const run = store.createRun(project.id, "seed-1", "pipeline");

    store.updateRunProgress(run.id, {
      toolCalls: 10,
      toolBreakdown: { Read: 10 },
      filesChanged: ["src/foo.ts"],
      turns: 8,
      costUsd: 0.30,
      tokensIn: 5000,
      tokensOut: 2000,
      lastToolCall: "Edit",
      lastActivity: new Date().toISOString(),
      currentPhase: "developer",
      costByPhase: {
        explorer: 0.05,
        developer: 0.20,
        qa: 0.05,
      },
      agentByPhase: {
        explorer: "claude-haiku-4-5",
        developer: "claude-sonnet-4-6",
        qa: "claude-sonnet-4-6",
      },
    });

    const breakdown = store.getCostBreakdown(run.id);
    expect(breakdown.byPhase.explorer).toBeCloseTo(0.05);
    expect(breakdown.byPhase.developer).toBeCloseTo(0.20);
    expect(breakdown.byPhase.qa).toBeCloseTo(0.05);

    // claude-haiku-4-5 = 0.05, claude-sonnet-4-6 = 0.20 + 0.05 = 0.25
    expect(breakdown.byAgent["claude-haiku-4-5"]).toBeCloseTo(0.05);
    expect(breakdown.byAgent["claude-sonnet-4-6"]).toBeCloseTo(0.25);
  });

  it("getPhaseMetrics aggregates phase costs across multiple runs", () => {
    const project = store.registerProject("p", "/p");

    const run1 = store.createRun(project.id, "seed-1", "pipeline");
    store.updateRunProgress(run1.id, {
      toolCalls: 5,
      toolBreakdown: {},
      filesChanged: [],
      turns: 4,
      costUsd: 0.25,
      tokensIn: 3000,
      tokensOut: 1000,
      lastToolCall: null,
      lastActivity: new Date().toISOString(),
      costByPhase: { explorer: 0.05, developer: 0.15, qa: 0.05 },
      agentByPhase: {
        explorer: "claude-haiku-4-5",
        developer: "claude-sonnet-4-6",
        qa: "claude-sonnet-4-6",
      },
    });

    const run2 = store.createRun(project.id, "seed-2", "pipeline");
    store.updateRunProgress(run2.id, {
      toolCalls: 8,
      toolBreakdown: {},
      filesChanged: [],
      turns: 6,
      costUsd: 0.40,
      tokensIn: 5000,
      tokensOut: 2000,
      lastToolCall: null,
      lastActivity: new Date().toISOString(),
      costByPhase: { explorer: 0.10, developer: 0.25, qa: 0.05 },
      agentByPhase: {
        explorer: "claude-haiku-4-5",
        developer: "claude-sonnet-4-6",
        qa: "claude-sonnet-4-6",
      },
    });

    const phaseMetrics = store.getPhaseMetrics(project.id);

    expect(phaseMetrics.totalByPhase.explorer).toBeCloseTo(0.15);
    expect(phaseMetrics.totalByPhase.developer).toBeCloseTo(0.40);
    expect(phaseMetrics.totalByPhase.qa).toBeCloseTo(0.10);

    expect(phaseMetrics.runsByPhase.explorer).toBe(2);
    expect(phaseMetrics.runsByPhase.developer).toBe(2);
    expect(phaseMetrics.runsByPhase.qa).toBe(2);

    // haiku: 0.05 + 0.10 = 0.15; sonnet: (0.15+0.05) + (0.25+0.05) = 0.50
    expect(phaseMetrics.totalByAgent["claude-haiku-4-5"]).toBeCloseTo(0.15);
    expect(phaseMetrics.totalByAgent["claude-sonnet-4-6"]).toBeCloseTo(0.50);
  });

  it("getMetrics includes costByPhase and agentCostBreakdown when phase data exists", () => {
    const project = store.registerProject("p", "/p");
    const run = store.createRun(project.id, "seed-1", "pipeline");

    store.recordCost(run.id, 5000, 2000, 0, 0.30);

    store.updateRunProgress(run.id, {
      toolCalls: 10,
      toolBreakdown: {},
      filesChanged: [],
      turns: 8,
      costUsd: 0.30,
      tokensIn: 5000,
      tokensOut: 2000,
      lastToolCall: null,
      lastActivity: new Date().toISOString(),
      costByPhase: { explorer: 0.05, developer: 0.20, qa: 0.05 },
      agentByPhase: {
        explorer: "claude-haiku-4-5",
        developer: "claude-sonnet-4-6",
        qa: "claude-sonnet-4-6",
      },
    });

    const metrics = store.getMetrics(project.id);

    expect(metrics.totalCost).toBeCloseTo(0.30);
    expect(metrics.costByPhase).toBeDefined();
    expect(metrics.costByPhase!.explorer).toBeCloseTo(0.05);
    expect(metrics.costByPhase!.developer).toBeCloseTo(0.20);
    expect(metrics.agentCostBreakdown).toBeDefined();
    expect(metrics.agentCostBreakdown!["claude-haiku-4-5"]).toBeCloseTo(0.05);
    expect(metrics.agentCostBreakdown!["claude-sonnet-4-6"]).toBeCloseTo(0.25);
  });

  it("getMetrics omits costByPhase/agentCostBreakdown for runs without phase data", () => {
    const project = store.registerProject("p", "/p");
    const run = store.createRun(project.id, "seed-1", "claude-code");
    store.recordCost(run.id, 1000, 500, 0, 0.05);

    // Set progress without phase info (single-agent mode)
    store.updateRunProgress(run.id, {
      toolCalls: 3,
      toolBreakdown: {},
      filesChanged: [],
      turns: 2,
      costUsd: 0.05,
      tokensIn: 1000,
      tokensOut: 500,
      lastToolCall: null,
      lastActivity: new Date().toISOString(),
    });

    const metrics = store.getMetrics(project.id);
    expect(metrics.totalCost).toBeCloseTo(0.05);
    expect(metrics.costByPhase).toBeUndefined();
    expect(metrics.agentCostBreakdown).toBeUndefined();
  });
});
