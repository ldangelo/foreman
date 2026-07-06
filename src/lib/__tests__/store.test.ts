import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createPostgresProjectFixture,
  startPostgresTestcontainer,
  stopPostgresTestcontainer,
} from "../../test-support/postgres-testcontainer.js";

/**
 * Store coverage now targets the production PostgresStore/PostgresAdapter path.
 * The old ForemanStore file-backed sqlite assertions were removed because local
 * sqlite storage is no longer production behavior.
 */
describe("PostgresStore", { timeout: 120_000 }, () => {
  beforeAll(async () => {
    await startPostgresTestcontainer();
  }, 120_000);

  afterAll(async () => {
    await stopPostgresTestcontainer();
  });

  it("reads and updates projects through the production Postgres store", async () => {
    const { store, project } = await createPostgresProjectFixture("store-project");

    expect(await store.getProject(project.id)).toEqual(expect.objectContaining({ id: project.id, name: project.name }));
    expect(await store.getProjectByPath(project.path)).toEqual(expect.objectContaining({ id: project.id }));
    expect(await store.listProjects("active")).toEqual([expect.objectContaining({ id: project.id })]);

    await store.updateProject(project.id, { name: "renamed", status: "paused" });
    expect(await store.getProject(project.id)).toEqual(expect.objectContaining({ name: "renamed", status: "paused" }));
  });

  it("creates, updates, filters, and deletes runs", async () => {
    const { store, project } = await createPostgresProjectFixture("store-runs");

    const run1 = await store.createRun(project.id, "bd-a1", "developer", "/tmp/wt1", {
      baseBranch: "main",
      mergeStrategy: "auto",
      sessionKey: "session-1",
    });
    const run2 = await store.createRun(project.id, "bd-a1", "qa", "/tmp/wt2");
    await store.updateRun(run1.id, { status: "running", started_at: "2026-01-01T00:00:00.000Z" });
    await store.updateRun(run2.id, { status: "completed" });

    expect(await store.getRun(run1.id)).toEqual(expect.objectContaining({ id: run1.id, status: "running" }));
    expect(await store.getActiveRuns(project.id)).toEqual([expect.objectContaining({ id: run1.id })]);
    expect(await store.getRunsForTask("bd-a1", project.id)).toHaveLength(2);
    expect(await store.hasActiveOrPendingRun("bd-a1", project.id)).toBe(true);
    expect(await store.getRunsByBaseBranch("main", project.id)).toEqual([expect.objectContaining({ id: run1.id })]);

    await store.updateRun(run1.id, { status: "failed" });
    await store.updateRun(run2.id, { status: "reset" });
    expect(await store.hasActiveOrPendingRun("bd-a1", project.id)).toBe(false);
    expect(await store.deleteRun(run1.id)).toBe(true);
    expect(await store.getRun(run1.id)).toBeNull();
  });

  it("persists run progress, events, costs, and success metrics", async () => {
    const { store, project } = await createPostgresProjectFixture("store-observability");
    const run = await store.createRun(project.id, "bd-obs", "developer", "/tmp/wt");

    await store.updateRunProgress(run.id, {
      currentPhase: "developer",
      toolCalls: 2,
      toolBreakdown: { read: 1, edit: 1 },
      filesChanged: ["src/a.ts"],
      turns: 3,
      costUsd: 0.02,
      tokensIn: 10,
      tokensOut: 20,
      lastToolCall: "edit",
      lastActivity: "2026-01-01T00:00:00.000Z",
    });
    await store.logEvent(project.id, "phase-start", { taskId: "bd-obs", phase: "developer" }, run.id);
    await store.recordCost(run.id, 10, 20, 5, 0.02);
    await store.updateRun(run.id, { status: "merged" });

    expect(await store.getRunProgress(run.id)).toEqual(
      expect.objectContaining({ currentPhase: "developer", tokensIn: 10, tokensOut: 20 }),
    );
    expect(await store.getRunEvents(run.id, "phase-start")).toHaveLength(1);
    expect(await store.getEvents(project.id, 10, "phase-start")).toHaveLength(1);
    expect(await store.getCosts(project.id)).toEqual([expect.objectContaining({ run_id: run.id, tokens_in: 10 })]);
    expect(await store.getCostBreakdown(run.id)).toEqual(expect.objectContaining({ byAgent: { developer: 0.02 } }));
    expect(await store.getPhaseMetrics(project.id)).toEqual(
      expect.objectContaining({ totalCost: 0.02, totalTokens: 35, tasksByStatus: expect.objectContaining({ completed: 1 }) }),
    );
    expect(await store.getSuccessRate(project.id)).toEqual({ rate: 1, merged: 1, failed: 0 });
  });

  it("persists agent messages", async () => {
    const { store, project } = await createPostgresProjectFixture("store-messages");
    const run = await store.createRun(project.id, "bd-msg", "developer", "/tmp/wt");

    await store.sendMessage(run.id, "developer", "qa", "phase-complete", "done");
    const unread = await store.getMessages(run.id, "qa", true);
    expect(unread).toEqual([expect.objectContaining({ subject: "phase-complete", body: "done", read: 0 })]);

    await store.markMessageRead(unread[0].id);
    expect(await store.getMessages(run.id, "qa", true)).toEqual([]);
    expect(await store.getAllMessages(run.id)).toHaveLength(1);
    await store.deleteMessage(unread[0].id);
    expect(await store.getAllMessages(run.id)).toEqual([]);
  });
});
