import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { PostgresAdapter } from "../db/postgres-adapter.js";
import { query } from "../db/pool-manager.js";
import { PostgresStore } from "../postgres-store.js";
import {
  startPostgresTestcontainer,
  stopPostgresTestcontainer,
} from "../../test-support/postgres-testcontainer.js";

/**
 * Verifies production PostgresStore/PostgresAdapter behavior against a real
 * disposable Postgres instance. This prevents local-only store behavior from
 * drifting away from the registered-project runtime path.
 */
describe("PostgresStore testcontainer integration", { timeout: 120_000 }, () => {
  beforeAll(async () => {
    await startPostgresTestcontainer();
  }, 120_000);

  afterAll(async () => {
    await stopPostgresTestcontainer();
  });

  it("persists project-scoped runs, progress, events, costs, messages, tasks, and queue entries", async () => {
    const adapter = new PostgresAdapter();
    const suffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const project = await adapter.createProject({
      name: `pg-store-${suffix}`,
      path: `/tmp/pg-store-${suffix}`,
      defaultBranch: "main",
    });
    const store = new PostgresStore(project.id, adapter);

    const task = await adapter.createTask(project.id, {
      id: `foreman-${suffix.slice(-5)}`,
      title: "Test task",
      description: "exercise production postgres task path",
      type: "task",
      priority: 2,
      status: "ready",
    });
    expect(task.status).toBe("ready");

    const run = await store.createRun(project.id, task.id, "developer", `/tmp/wt-${suffix}`, {
      baseBranch: "main",
      mergeStrategy: "auto",
      sessionKey: `session-${suffix}`,
    });
    expect(run.status).toBe("pending");

    expect(await store.claimTaskAsync(task.id, run.id)).toBe(true);
    await store.updateRun(run.id, {
      status: "running",
      started_at: "2026-01-01T00:00:00.000Z",
    });
    await store.updateRunProgress(run.id, {
      currentPhase: "developer",
      tokensIn: 11,
      tokensOut: 22,
      lastActivity: "2026-01-01T00:01:00.000Z",
      toolCalls: 1,
      toolBreakdown: {},
      filesChanged: [],
      turns: 1,
      costUsd: 0.01,
      lastToolCall: "read",
    });
    await store.recordCost(run.id, 11, 22, 0, 0.01);
    await store.logEvent(project.id, "phase-start", { phase: "developer" }, run.id);
    await store.sendMessage(run.id, "developer", "qa", "phase-complete", "done");

    const fetchedRun = await store.getRun(run.id);
    expect(fetchedRun).toEqual(expect.objectContaining({ id: run.id, status: "running", seed_id: task.id }));
    expect(await store.getRunProgress(run.id)).toEqual(
      expect.objectContaining({ currentPhase: "developer", tokensIn: 11, tokensOut: 22 }),
    );
    expect(await store.getActiveRuns(project.id)).toHaveLength(1);
    expect(await store.hasActiveOrPendingRun(task.id, project.id)).toBe(true);
    expect(await store.getTaskById(task.id)).toEqual(expect.objectContaining({ id: task.id, run_id: run.id }));
    expect(await store.getEvents(project.id)).toHaveLength(1);
    expect(await store.getAllMessages(run.id)).toEqual([expect.objectContaining({ body: "done" })]);

    const costRows = await query<{ id: string }>(`SELECT id FROM costs WHERE run_id = $1`, [run.id]);
    expect(costRows).toHaveLength(1);
  });
});
