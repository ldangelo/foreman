import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../store.js";

describe("ForemanStore", () => {
  let store: ForemanStore;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // ── Projects ──────────────────────────────────────────────────────

  describe("projects", () => {
    it("registers and retrieves a project", () => {
      const project = store.registerProject("my-app", "/home/user/my-app");
      expect(project.name).toBe("my-app");
      expect(project.status).toBe("active");

      const fetched = store.getProject(project.id);
      expect(fetched).toEqual(project);
    });

    it("retrieves a project by path", () => {
      const project = store.registerProject("my-app", "/home/user/my-app");
      const fetched = store.getProjectByPath("/home/user/my-app");
      expect(fetched).toEqual(project);
    });

    it("returns null for non-existent project", () => {
      expect(store.getProject("nonexistent")).toBeNull();
      expect(store.getProjectByPath("/nope")).toBeNull();
    });

    it("lists projects filtered by status", () => {
      store.registerProject("a", "/a");
      const b = store.registerProject("b", "/b");
      store.updateProject(b.id, { status: "archived" });

      expect(store.listProjects("active")).toHaveLength(1);
      expect(store.listProjects("archived")).toHaveLength(1);
      expect(store.listProjects()).toHaveLength(2);
    });

    it("updates project fields", () => {
      const project = store.registerProject("old", "/old");
      store.updateProject(project.id, { name: "new", status: "paused" });

      const updated = store.getProject(project.id)!;
      expect(updated.name).toBe("new");
      expect(updated.status).toBe("paused");
      expect(updated.updated_at).toBeDefined();
    });

    it("enforces unique path constraint", () => {
      store.registerProject("a", "/same/path");
      expect(() => store.registerProject("b", "/same/path")).toThrow();
    });
  });

  // ── Runs ──────────────────────────────────────────────────────────

  describe("runs", () => {
    it("creates and retrieves a run", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-a1b2", "claude-code", "/tmp/wt");

      expect(run.status).toBe("pending");
      expect(run.seed_id).toBe("bd-a1b2");
      expect(store.getRun(run.id)).toEqual(run);
    });

    it("updates run status", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-x1", "pi");
      const now = new Date().toISOString();

      store.updateRun(run.id, { status: "running", started_at: now });
      const updated = store.getRun(run.id)!;
      expect(updated.status).toBe("running");
      expect(updated.started_at).toBe(now);
    });

    it("gets active runs filtered by project", () => {
      const p1 = store.registerProject("p1", "/p1");
      const p2 = store.registerProject("p2", "/p2");

      store.createRun(p1.id, "bd-1", "claude-code");
      store.createRun(p2.id, "bd-2", "codex");
      const completed = store.createRun(p1.id, "bd-3", "pi");
      store.updateRun(completed.id, { status: "completed" });

      expect(store.getActiveRuns(p1.id)).toHaveLength(1);
      expect(store.getActiveRuns()).toHaveLength(2);
    });
  });

  describe("getRunsForSeed", () => {
    it("returns runs for a seed sorted by created_at DESC", () => {
      const project = store.registerProject("p", "/p");
      const run1 = store.createRun(project.id, "bd-abc", "claude-sonnet-4-6", "/wt1");
      store.updateRun(run1.id, { status: "completed" });
      const run2 = store.createRun(project.id, "bd-abc", "claude-opus-4-6", "/wt1");

      const runs = store.getRunsForSeed("bd-abc", project.id);
      expect(runs).toHaveLength(2);
      // Most recent first
      expect(runs[0].id).toBe(run2.id);
      expect(runs[1].id).toBe(run1.id);
    });

    it("filters by project when projectId given", () => {
      const p1 = store.registerProject("p1", "/p1");
      const p2 = store.registerProject("p2", "/p2");
      store.createRun(p1.id, "bd-abc", "claude-code", "/wt1");
      store.createRun(p2.id, "bd-abc", "claude-code", "/wt2");

      expect(store.getRunsForSeed("bd-abc", p1.id)).toHaveLength(1);
      expect(store.getRunsForSeed("bd-abc")).toHaveLength(2);
    });

    it("returns empty array when no runs exist", () => {
      expect(store.getRunsForSeed("sd-nonexistent")).toEqual([]);
    });
  });

  // ── Costs ─────────────────────────────────────────────────────────

  describe("costs", () => {
    it("records and retrieves costs", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-1", "claude-code");

      store.recordCost(run.id, 1000, 500, 200, 0.05);
      store.recordCost(run.id, 2000, 1000, 0, 0.10);

      const costs = store.getCosts(project.id);
      expect(costs).toHaveLength(2);
      expect(costs[0].tokens_in + costs[1].tokens_in).toBe(3000);
    });

    it("filters costs by since", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-1", "claude-code");
      store.recordCost(run.id, 100, 50, 0, 0.01);

      const future = new Date(Date.now() + 100000).toISOString();
      expect(store.getCosts(project.id, future)).toHaveLength(0);
    });
  });

  // ── Events ────────────────────────────────────────────────────────

  describe("events", () => {
    it("logs and retrieves events", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-1", "claude-code");

      store.logEvent(project.id, "dispatch", { seed: "bd-1" }, run.id);
      store.logEvent(project.id, "complete", { result: "ok" }, run.id);

      const events = store.getEvents(project.id);
      expect(events).toHaveLength(2);
      const types = events.map((e) => e.event_type).sort();
      expect(types).toEqual(["complete", "dispatch"]);
    });

    it("filters events by type and limit", () => {
      const project = store.registerProject("p", "/p");
      store.logEvent(project.id, "dispatch");
      store.logEvent(project.id, "dispatch");
      store.logEvent(project.id, "complete");

      expect(store.getEvents(project.id, undefined, "dispatch")).toHaveLength(2);
      expect(store.getEvents(project.id, 1)).toHaveLength(1);
    });

    it("stores string details directly", () => {
      const project = store.registerProject("p", "/p");
      store.logEvent(project.id, "fail", "something broke");

      const events = store.getEvents(project.id);
      expect(events[0].details).toBe("something broke");
    });
  });

  // ── Task Groups ───────────────────────────────────────────────────

  describe("task groups", () => {
    it("creates and retrieves a group", () => {
      const project = store.registerProject("p", "/p");
      const group = store.createGroup(project.id, "my-batch", "seed-epic-1");

      expect(group.name).toBe("my-batch");
      expect(group.parent_seed_id).toBe("seed-epic-1");
      expect(group.status).toBe("active");

      const fetched = store.getGroup(group.id);
      expect(fetched).toEqual(group);
    });

    it("returns null for non-existent group", () => {
      expect(store.getGroup("nonexistent")).toBeNull();
    });

    it("adds group members idempotently", () => {
      const project = store.registerProject("p", "/p");
      const group = store.createGroup(project.id, "batch");

      store.addGroupMember(group.id, "seed-1");
      store.addGroupMember(group.id, "seed-2");
      store.addGroupMember(group.id, "seed-1"); // duplicate — should be ignored

      const members = store.getGroupMembers(group.id);
      expect(members).toHaveLength(2);
      expect(members.map((m) => m.seed_id).sort()).toEqual(["seed-1", "seed-2"]);
    });

    it("lists groups by project", () => {
      const p1 = store.registerProject("p1", "/p1");
      const p2 = store.registerProject("p2", "/p2");

      store.createGroup(p1.id, "g1");
      store.createGroup(p1.id, "g2");
      store.createGroup(p2.id, "g3");

      expect(store.listGroupsByProject(p1.id)).toHaveLength(2);
      expect(store.listGroupsByProject(p2.id)).toHaveLength(1);
    });

    it("lists only active groups", () => {
      const project = store.registerProject("p", "/p");
      const g1 = store.createGroup(project.id, "active-group");
      const g2 = store.createGroup(project.id, "completed-group");
      store.updateGroup(g2.id, { status: "completed", completed_at: new Date().toISOString() });

      const active = store.listActiveGroups(project.id);
      expect(active).toHaveLength(1);
      expect(active[0].id).toBe(g1.id);
    });

    it("updates group status", () => {
      const project = store.registerProject("p", "/p");
      const group = store.createGroup(project.id, "test");
      const now = new Date().toISOString();

      store.updateGroup(group.id, { status: "completed", completed_at: now });

      const updated = store.getGroup(group.id)!;
      expect(updated.status).toBe("completed");
      expect(updated.completed_at).toBe(now);
    });
  });

  // ── Metrics ───────────────────────────────────────────────────────

  describe("metrics", () => {
    it("aggregates costs and run statuses", () => {
      const project = store.registerProject("p", "/p");
      const r1 = store.createRun(project.id, "bd-1", "claude-code");
      const r2 = store.createRun(project.id, "bd-2", "pi");

      store.updateRun(r1.id, {
        status: "completed",
        started_at: "2025-01-01T00:00:00Z",
        completed_at: "2025-01-01T00:10:00Z",
      });
      store.updateRun(r2.id, { status: "failed" });

      store.recordCost(r1.id, 1000, 500, 0, 0.05);
      store.recordCost(r2.id, 2000, 1000, 0, 0.10);

      const metrics = store.getMetrics(project.id);
      expect(metrics.totalCost).toBeCloseTo(0.15);
      expect(metrics.totalTokens).toBe(4500);
      expect(metrics.tasksByStatus.completed).toBe(1);
      expect(metrics.tasksByStatus.failed).toBe(1);
      expect(metrics.costByRuntime).toHaveLength(2);

      const r1Metric = metrics.costByRuntime.find((r) => r.run_id === r1.id)!;
      expect(r1Metric.duration_seconds).toBe(600);
    });
  });
});
