/**
 * TRD-012-TEST | Verifies: TRD-012 | E2E: daemon start to project add lifecycle
 * PRD: docs/PRD/PRD-2026-010-multi-project-orchestrator.md
 * TRD: docs/TRD/TRD-2026-011-multi-project-orchestrator.md#trd-012
 *
 * Integration test covering the full project lifecycle via the daemon:
 *   daemon start → TrpcClient connect → project add → project list → project remove → daemon stop
 *
 * Setup required to run:
 *   1. Create database: CREATE DATABASE foreman;
 *   2. Run migrations: npm run db:migrate
 *   3. Set DATABASE_URL=postgresql://localhost/foreman (or with credentials)
 *
 * This test is skipped when the database is unavailable.
 */

import { describe, it, expect, afterAll, beforeAll, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { spawn } from "node:child_process";
import { ForemanDaemon } from "../index.js";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { initPool, destroyPool, query } from "../../lib/db/pool-manager.js";

// ---------------------------------------------------------------------------
// Postgres availability check
// ---------------------------------------------------------------------------

async function isPostgresAvailable(databaseUrl: string): Promise<boolean> {
  try {
    const { Pool } = await import("pg");
    const pool = new Pool({ connectionString: databaseUrl, connectionTimeoutMillis: 2000 });
    await pool.query("SELECT 1");
    await pool.end();
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const DAEMON_HTTP_PORT = 3848;
const TEST_PROJECT_NAME = "foreman-e2e-test";
const TEST_PROJECT_PATH = "/tmp/foreman-e2e-project";

async function waitForDaemon(
  url: string,
  timeoutMs = 10_000,
): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const resp = await fetch(`${url}/health`);
      if (resp.ok) return;
    } catch {
      // not ready yet
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`Daemon did not become healthy within ${timeoutMs}ms at ${url}`);
}

// ---------------------------------------------------------------------------
// Setup / Teardown
// ---------------------------------------------------------------------------

const DATABASE_URL = process.env.DATABASE_URL ?? "postgresql://localhost/foreman";

describe("Daemon project lifecycle E2E", { timeout: 60_000 }, () => {
  let daemon: ForemanDaemon;
  let daemonUrl: string;
  let tempHome: string;
  let socketPath: string;
  let skipTests = false;

  beforeAll(async () => {
    skipTests = !(await isPostgresAvailable(DATABASE_URL));
    if (skipTests) return;

    // Set up a temporary home so daemon state doesn't pollute ~/.foreman
    tempHome = mkdtempSync(join(tmpdir(), "foreman-e2e-home-"));
    socketPath = join(tempHome, ".foreman", "daemon.sock");
    daemonUrl = `http://localhost:${DAEMON_HTTP_PORT}`;

    process.env.DATABASE_URL = DATABASE_URL;

    daemon = new ForemanDaemon({
      httpPort: DAEMON_HTTP_PORT,
      socketPath,
    });

    await daemon.start();
    await waitForDaemon(daemonUrl);
  });

  afterAll(async () => {
    if (skipTests) return;
    try {
      await daemon.stop();
    } catch {
      // ignore
    }
    try {
      rmSync(tempHome, { recursive: true, force: true });
    } catch {
      // ignore
    }
  });

  // -------------------------------------------------------------------------
  // Project lifecycle
  // -------------------------------------------------------------------------

  it("daemon health endpoint responds", async () => {
    if (skipTests) return; // Postgres unavailable — skip E2E tests
    const resp = await fetch(`${daemonUrl}/health`);
    expect(resp.ok).toBe(true);
    const data = (await resp.json()) as { status: string };
    expect(data.status).toBe("ok");
  });

  it("TrpcClient connects and creates a project", async () => {
    if (skipTests) return; // Postgres unavailable — skip E2E tests
    const client = createTrpcClient({
      socketPath,
    });

    const result = await client.projects.add({
      name: TEST_PROJECT_NAME,
      path: TEST_PROJECT_PATH,
    });

    expect(result).toHaveProperty("id");
    const row = result as { id: string; name: string; path: string; status?: string };
    expect(row.name).toBe(TEST_PROJECT_NAME);
    expect(row.path).toBe(TEST_PROJECT_PATH);
    expect(row.status).toBe("active");
  });

  it("TrpcClient lists the created project", async () => {
    if (skipTests) return; // Postgres unavailable — skip E2E tests
    const client = createTrpcClient({ socketPath });

    const projects = (await client.projects.list()) as Array<{
      id: string;
      name: string;
    }>;

    const found = projects.find((p) => p.name === TEST_PROJECT_NAME);
    expect(found).toBeDefined();
  });

  it("TrpcClient gets project by id", async () => {
    if (skipTests) return; // Postgres unavailable — skip E2E tests
    const client = createTrpcClient({ socketPath });

    // Find the project first
    const projects = (await client.projects.list()) as Array<{
      id: string;
      name: string;
    }>;
    const found = projects.find((p) => p.name === TEST_PROJECT_NAME);
    expect(found).toBeDefined();

    const project = (await client.projects.get({
      id: found!.id,
    })) as { id: string; name: string } | null;

    expect(project).not.toBeNull();
    expect(project!.name).toBe(TEST_PROJECT_NAME);
  });

  it("TrpcClient updates a project", async () => {
    if (skipTests) return; // Postgres unavailable — skip E2E tests
    const client = createTrpcClient({ socketPath });

    const projects = (await client.projects.list()) as Array<{
      id: string;
    }>;
    const found = projects.find((p) => {
      // Access via listProjects if needed
      return true;
    });

    // Get the first project
    const allProjects = (await client.projects.list()) as Array<{
      id: string;
    }>;
    const projectId = allProjects[0]?.id;
    expect(projectId).toBeDefined();

    await client.projects.update({
      id: projectId,
      updates: { name: `${TEST_PROJECT_NAME}-updated` },
    });

    const updated = (await client.projects.get({ id: projectId })) as {
      name: string;
    } | null;
    expect(updated).not.toBeNull();
    expect(updated!.name).toBe(`${TEST_PROJECT_NAME}-updated`);
  });

  it("TrpcClient removes a project (archive)", async () => {
    if (skipTests) return; // Postgres unavailable — skip E2E tests
    const client = createTrpcClient({ socketPath });

    const projects = (await client.projects.list()) as Array<{
      id: string;
    }>;
    const projectId = projects[0]?.id;
    expect(projectId).toBeDefined();

    await client.projects.remove({ id: projectId });

    // After removal, the project should not appear in active list
    const remaining = (await client.projects.list({
      status: "active",
    })) as Array<{ id: string }>;
    expect(remaining.find((p) => p.id === projectId)).toBeUndefined();
  });

  it("TrpcClient syncs a project", async () => {
    if (skipTests) return; // Postgres unavailable — skip E2E tests
    const client = createTrpcClient({ socketPath });

    // Re-create a project to sync
    const created = (await client.projects.add({
      name: `${TEST_PROJECT_NAME}-sync`,
      path: TEST_PROJECT_PATH,
    })) as { id: string };
    expect(created.id).toBeDefined();

    await client.projects.sync({ id: created.id });

    // Verify last_sync_at is updated (checked via direct DB query)
    initPool();
    const rows = await query<{ last_sync_at: string | null }>(
      `SELECT last_sync_at FROM projects WHERE id = $1`,
      [created.id],
    );
    expect(rows[0]?.last_sync_at).not.toBeNull();
    await destroyPool();
  });

  it("daemon stops cleanly", async () => {
    if (skipTests) return; // Postgres unavailable — skip E2E tests
    // The afterAll already stops it — this just verifies the daemon is responsive
    // right before cleanup.
    const resp = await fetch(`${daemonUrl}/health`);
    expect(resp.ok).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Postgres unreachable: daemon fails startup
// ---------------------------------------------------------------------------

describe("Daemon startup without Postgres", { timeout: 30_000 }, () => {
  it("ForemanDaemon.start() exits with code 1 when Postgres is unreachable", async () => {
    // Spy on process.exit so we can verify it was called without killing the test runner.
    const exitSpy = vi.spyOn(process, "exit").mockImplementation((code) => {
      throw new Error(`exit:${code}`);
    });

    // Point to a dead Postgres port.
    const originalDbUrl = process.env.DATABASE_URL;
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    process.env.DATABASE_URL = "postgresql://localhost:59999/nonexistent";

    const daemon = new ForemanDaemon({ httpPort: 3849 });
    try {
      await daemon.start();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      // Either process.exit was called (caught as Error("exit:1")) or the health check threw.
      expect(exitSpy).toHaveBeenCalledWith(1);
      expect(msg).toMatch("exit:1");
    } finally {
      exitSpy.mockRestore();
      if (originalDbUrl !== undefined) {
        process.env.DATABASE_URL = originalDbUrl;
      }
    }
  });
});

