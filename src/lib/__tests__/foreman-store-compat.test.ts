import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { ForemanStore } from "../store.js";

const tempDirs: string[] = [];

function tempProject(): string {
  const dir = mkdtempSync(join(tmpdir(), "foreman-store-compat-"));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
  tempDirs.length = 0;
});

describe("ForemanStore disabled local-store compatibility", () => {
  it("constructs compatibility handles and exposes a disabled database", () => {
    const projectPath = tempProject();
    const store = ForemanStore.forProject(projectPath);
    const dashboardStore = ForemanStore.forDashboard(projectPath);
    const readonlyDb = ForemanStore.openReadonly(projectPath);

    expect(store.isOpen()).toBe(true);
    expect(readonlyDb.prepare("SELECT 1").get()).toBeUndefined();
    expect(readonlyDb.prepare("SELECT 1").all()).toEqual([]);
    expect(readonlyDb.prepare("UPDATE x").run()).toEqual({ changes: 0 });
    expect(readonlyDb.pragma("user_version")).toBe(0);
    expect(readonlyDb.transaction((value: unknown) => `tx:${value}`)("ok")).toBe("tx:ok");

    dashboardStore.close();
    store.close();
  });

  it("returns empty read models and no-op mutation results from local compatibility APIs", () => {
    const store = new ForemanStore(join(tempProject(), ".foreman", "foreman.db"));

    expect(store.listTasksByStatus([])).toEqual([]);
    expect(store.listTasksByStatus(["ready", "blocked"])).toEqual([]);
    expect(() => store.updateTaskStatus("task-1", "in_progress")).not.toThrow();
    expect(() => store.updateTaskLabels("task-1", ["a", "b"])).not.toThrow();

    const project = store.registerProject("Demo", join(tempProject(), "missing"));
    expect(project).toMatchObject({ name: "Demo", status: "active" });
    expect(project.path).toContain("missing");
    expect(store.getProject("project-1")).toBeNull();
    expect(store.getProjectByPath(project.path)).toBeNull();
    expect(store.listProjects()).toEqual([]);
    expect(store.listProjects("active")).toEqual([]);
    expect(() => store.updateProject("project-1", { name: "Renamed", path: project.path, status: "paused" })).not.toThrow();

    expect(store.getRun("run-1")).toBeNull();
    expect(store.getActiveRuns()).toEqual([]);
    expect(store.getActiveRuns("project-1")).toEqual([]);
    expect(store.getRunsByStatus("running")).toEqual([]);
    expect(store.getRunsByStatus("running", "project-1")).toEqual([]);
    expect(store.getRunsByStatuses([])).toEqual([]);
    expect(store.getRunsByStatuses(["running", "pending"], "project-1")).toEqual([]);
    expect(store.getRunsByStatusSince("failed", "2026-01-01T00:00:00.000Z")).toEqual([]);
    expect(store.getRunsByStatusesSince([], "2026-01-01T00:00:00.000Z")).toEqual([]);
    expect(store.getRunsByStatusesSince(["failed"], "2026-01-01T00:00:00.000Z", "project-1")).toEqual([]);
    expect(store.purgeOldRuns("2026-01-01T00:00:00.000Z")).toBe(0);
    expect(store.deleteRun("run-1")).toBe(false);
    expect(store.getRunsForTask("task-1")).toEqual([]);
    expect(store.hasActiveOrPendingRun("task-1")).toBe(false);
    expect(store.getRunsByBaseBranch("main")).toEqual([]);

    expect(store.getRunEvents("run-1")).toEqual([]);
    expect(store.getRunEvents("run-1", "phase-start")).toEqual([]);
    store.updateRunProgress("run-1", { currentPhase: "qa" } as any);
    expect(store.getRunProgress("run-1")).toBeNull();
    expect(store.getCosts()).toEqual([]);
    expect(store.getCostBreakdown("run-1")).toEqual({ byPhase: {}, byAgent: {} });
    expect(store.getPhaseMetrics()).toEqual({ totalByPhase: {}, totalByAgent: {}, runsByPhase: {} });
    expect(store.getRecentOutcomeCounts()).toEqual({ merged: 0, failed: 0, stuck: 0 });
    expect(store.getSuccessRate()).toEqual({ rate: null, merged: 0, failed: 0 });
    expect(store.getEvents()).toEqual([]);

    expect(store.getMessages("run-1", "qa")).toEqual([]);
    expect(store.getMessages("run-1", "qa", true)).toEqual([]);
    expect(store.getAllMessages("run-1")).toEqual([]);
    expect(store.getAllMessagesGlobal()).toEqual([]);
    expect(store.markMessageRead("message-1")).toBe(false);
    expect(() => store.markAllMessagesRead("run-1", "qa")).not.toThrow();
    expect(store.deleteMessage("message-1")).toBe(false);
    expect(store.getMessage("message-1")).toBeNull();

    expect(store.getSentinelConfig("project-1")).toBeNull();
    expect(() => store.recordSentinelRun({ id: "sentinel-1", project_id: "project-1", status: "running", started_at: "now" } as any)).not.toThrow();
    expect(() => store.updateSentinelRun("sentinel-1", { status: "passed", failure_count: 0 })).not.toThrow();
    expect(store.getSentinelRuns()).toEqual([]);
    expect(store.getMergeAgentConfig()).toBeNull();
    expect(() => store.getMetrics()).toThrow(/totalCost|totalTurns/);

    expect(store.hasNativeTasks()).toBe(false);
    expect(store.getTaskById("task-1")).toBeNull();
    expect(store.getTaskByExternalId("EXT-1")).toBeNull();
    expect(store.getReadyTasks()).toEqual([]);
    expect(store.claimTask("task-1", "run-1")).toBe(false);

    store.close();
  });
});
