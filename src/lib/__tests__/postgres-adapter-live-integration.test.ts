/**
 * Live Postgres integration smoke test for PostgresAdapter legacy compatibility APIs.
 *
 * This test runs only when DATABASE_URL points to a reachable Postgres database
 * with Foreman migrations already applied. Otherwise it skips cleanly.
 */

import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { Pool } from "pg";
import { randomUUID } from "node:crypto";
import { initPool, destroyPool, execute, query } from "../db/pool-manager.js";
import { PostgresAdapter } from "../db/postgres-adapter.js";

const DATABASE_URL = process.env.DATABASE_URL;

async function isPostgresAvailable(databaseUrl: string): Promise<boolean> {
  try {
    const pool = new Pool({ connectionString: databaseUrl, connectionTimeoutMillis: 2000 });
    await pool.query("SELECT 1");
    await pool.end();
    return true;
  } catch {
    return false;
  }
}

async function hasForemanSchema(databaseUrl: string): Promise<boolean> {
  try {
    const pool = new Pool({ connectionString: databaseUrl, connectionTimeoutMillis: 2000 });
    const result = await pool.query(
      `SELECT to_regclass('public.projects') AS projects,
              to_regclass('public.runs') AS runs,
              to_regclass('public.agent_messages') AS agent_messages,
              to_regclass('public.sentinel_configs') AS sentinel_configs,
              to_regclass('public.costs') AS costs`
    );
    await pool.end();
    const row = result.rows[0] as Record<string, string | null> | undefined;
    return Boolean(
      row?.projects && row?.runs && row?.agent_messages && row?.sentinel_configs && row?.costs
    );
  } catch {
    return false;
  }
}

describe("PostgresAdapter live integration", { timeout: 30_000 }, () => {
  let skipTests = false;
  const projectIds: string[] = [];

  beforeAll(async () => {
    if (!DATABASE_URL) {
      skipTests = true;
      return;
    }
    if (!(await isPostgresAvailable(DATABASE_URL))) {
      skipTests = true;
      return;
    }
    if (!(await hasForemanSchema(DATABASE_URL))) {
      skipTests = true;
      return;
    }

    initPool({ databaseUrl: DATABASE_URL });
  }, 120_000);

  afterEach(async () => {
    if (skipTests) return;
    while (projectIds.length > 0) {
      const id = projectIds.pop();
      if (!id) continue;
      await execute(`DELETE FROM projects WHERE id = $1`, [id]);
    }
  });

  afterAll(async () => {
    if (!skipTests) {
      await destroyPool();
    }
  });

  it("creates incrementing legacy runs and persists compatibility surfaces", async () => {
    if (skipTests) return;

    const adapter = new PostgresAdapter();
    const suffix = Date.now().toString();
    const project = await adapter.createProject({
      name: `pg-live-${suffix}`,
      path: `/tmp/pg-live-${suffix}`,
    });
    projectIds.push(project.id);

    const taskId = `bd-live-${suffix}`;
    const run1 = await adapter.createRun(project.id, taskId, "developer", {
      worktreePath: `/tmp/pg-live-${suffix}/wt1`,
      mergeStrategy: "auto",
    });
    const run2 = await adapter.createRun(project.id, taskId, "developer", {
      worktreePath: `/tmp/pg-live-${suffix}/wt2`,
      mergeStrategy: "auto",
    });

    expect(run1.task_id).toBe(taskId);
    expect(run2.task_id).toBe(taskId);

    await adapter.updateRun(project.id, run1.id, {
      status: "running",
      started_at: new Date().toISOString(),
    });
    await adapter.updateRunProgress(project.id, run1.id, {
      phase: "developer",
      tokensIn: 10,
      tokensOut: 20,
    });
    await adapter.recordCost(project.id, run1.id, {
      tokensIn: 10,
      tokensOut: 20,
      cacheRead: 1,
      estimatedCost: 0.01,
    });
    await adapter.logEvent(project.id, run1.id, "phase-start", "developer started");
    await adapter.logRateLimitEvent(project.id, run1.id, "claude-sonnet", "developer", "slow down", 60);
    const sent = await adapter.sendMessage(project.id, run1.id, "developer", "qa", "phase-complete", "hello");

    await adapter.markMessageRead(project.id, sent.id);
    await adapter.deleteMessage(project.id, sent.id);

    await adapter.upsertSentinelConfig(project.id, {
      branch: "main",
      pid: 321,
      enabled: 1,
    });

    const sentinelRunId = randomUUID();
    await adapter.recordSentinelRun(project.id, {
      id: sentinelRunId,
      branch: "main",
      commit_hash: "abc123",
      status: "running",
      test_command: "npm test",
      output: null,
      started_at: new Date().toISOString(),
      completed_at: null,
    });
    await adapter.updateSentinelRun(project.id, sentinelRunId, {
      status: "failed",
      failure_count: 2,
      completed_at: new Date().toISOString(),
    });

    const oldRun = await adapter.createRun(project.id, `bd-old-${suffix}`, "developer");
    await execute(`UPDATE runs SET status = 'failure', created_at = '2024-01-01T00:00:00Z' WHERE id = $1`, [oldRun.id]);

    const purged = await adapter.purgeOldRuns(project.id, "2024-06-01T00:00:00Z");
    expect(purged).toBe(1);

    const runs = await adapter.listRuns(project.id);
    expect(runs).toHaveLength(2);
    expect(runs.every((run) => run.task_id === taskId || run.task_id === `bd-old-${suffix}`)).toBe(true);

    const refreshed = await adapter.getRun(project.id, run1.id);
    expect(refreshed).not.toBeNull();
    expect(JSON.parse(refreshed?.progress ?? "{}")).toEqual(
      expect.objectContaining({ phase: "developer", tokensIn: 10, tokensOut: 20 })
    );

    const costCount = await query<{ n: number }>(`SELECT count(*)::int as n FROM costs WHERE run_id = $1`, [run1.id]);
    expect(costCount[0].n).toBe(1);

    const eventCount = await query<{ n: number }>(`SELECT count(*)::int as n FROM events WHERE project_id = $1`, [project.id]);
    expect(eventCount[0].n).toBe(1);

    const rateCount = await query<{ n: number }>(`SELECT count(*)::int as n FROM rate_limit_events WHERE project_id = $1`, [project.id]);
    expect(rateCount[0].n).toBe(1);

    const deletedMessages = await query<{ n: number }>(
      `SELECT count(*)::int as n FROM agent_messages WHERE run_id = $1 AND deleted_at IS NOT NULL`,
      [run1.id]
    );
    expect(deletedMessages[0].n).toBe(1);

    const sentinelRows = await adapter.getSentinelRuns(project.id, 10);
    expect(sentinelRows).toHaveLength(1);
    expect(sentinelRows[0]).toEqual(expect.objectContaining({ id: sentinelRunId, status: "failed", failure_count: 2 }));

    const deleted = await adapter.deleteRun(project.id, run1.id);
    expect(deleted).toBe(true);
  });
});
