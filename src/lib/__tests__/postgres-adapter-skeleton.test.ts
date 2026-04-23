/**
 * TRD-003-TEST | Verifies: TRD-003 | Tests: PostgresAdapter throws "not implemented" on all methods
 * PRD: docs/PRD/PRD-2026-010-multi-project-orchestrator.md
 * TRD: docs/TRD/TRD-2026-011-multi-project-orchestrator.md#trd-003
 *
 * Note: Project methods are fully implemented (TRD-011). The project operation
 * tests below use a mock pool. Non-project methods still throw "not implemented".
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { PostgresAdapter } from "../db/postgres-adapter.js";
import { initPool, destroyPool, type PoolLike } from "../db/pool-manager.js";

const PROJECT_ID = "proj-test123";

const adapter = new PostgresAdapter();
const NOT_IMPLEMENTED = "not implemented";

// ---------------------------------------------------------------------------
// Mock pool factory
// ---------------------------------------------------------------------------

function makeMockPool(responses: Array<{ sqlPattern: RegExp; rows?: unknown[]; rowCount?: number }>): PoolLike {
  return {
    query: vi.fn(async (text: string) => {
      for (const r of responses) {
        if (r.sqlPattern.test(text)) {
          return { rows: (r.rows ?? []) as never, rowCount: (r.rowCount ?? r.rows?.length ?? 0) as never };
        }
      }
      return { rows: [], rowCount: 0 };
    }),
    connect: vi.fn(),
    end: vi.fn(),
    on: vi.fn(),
  };
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

/**
 * Asserts that calling the given method with the given args throws Error("not implemented").
 */
async function assertNotImplemented(
  fn: () => Promise<unknown>,
  label: string
): Promise<void> {
  await expect(fn()).rejects.toThrow(NOT_IMPLEMENTED);
}

// ---------------------------------------------------------------------------
// Project operations (implemented — use mock pool)
// ---------------------------------------------------------------------------

describe("PostgresAdapter project operations", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("createProject inserts and returns the project row", async () => {
    const mockRows = [
      {
        id: "proj-001",
        name: "Test Project",
        path: "/tmp/test",
        github_url: null,
        default_branch: null,
        status: "active",
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      },
    ];
    const mockPool = makeMockPool([
      { sqlPattern: /INSERT INTO projects/, rows: mockRows },
    ]);
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.createProject({ name: "Test Project", path: "/tmp/test" });
      expect(result.id).toBe("proj-001");
      expect(result.name).toBe("Test Project");
    } finally {
      await destroyPool();
    }
  });

  it("listProjects returns rows from the database", async () => {
    const mockRows = [
      { id: "proj-001", name: "Project A", path: "/a", github_url: null, default_branch: null, status: "active", created_at: "", updated_at: "" },
      { id: "proj-002", name: "Project B", path: "/b", github_url: null, default_branch: null, status: "paused", created_at: "", updated_at: "" },
    ];
    const mockPool = makeMockPool([
      { sqlPattern: /SELECT \* FROM projects/, rows: mockRows },
    ]);
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.listProjects();
      expect(result).toHaveLength(2);
      expect(result[0].id).toBe("proj-001");
    } finally {
      await destroyPool();
    }
  });

  it("listProjects filters by status", async () => {
    const mockPool = makeMockPool([
      { sqlPattern: /SELECT \* FROM projects WHERE status = \$1/, rows: [{ id: "proj-001", name: "Active", path: "/a", github_url: null, default_branch: null, status: "active", created_at: "", updated_at: "" }] },
    ]);
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.listProjects({ status: "active" });
      expect(result).toHaveLength(1);
    } finally {
      await destroyPool();
    }
  });

  it("getProject returns a project by id", async () => {
    const mockRows = [
      { id: PROJECT_ID, name: "Test", path: "/tmp", github_url: null, default_branch: null, status: "active", created_at: "", updated_at: "" },
    ];
    const mockPool = makeMockPool([
      { sqlPattern: /SELECT \* FROM projects WHERE id = \$1/, rows: mockRows },
    ]);
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.getProject(PROJECT_ID);
      expect(result?.id).toBe(PROJECT_ID);
    } finally {
      await destroyPool();
    }
  });

  it("getProject returns null when not found", async () => {
    const mockPool = makeMockPool([{ sqlPattern: /SELECT \* FROM projects WHERE id = \$1/, rows: [] }]);
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.getProject("nonexistent");
      expect(result).toBeNull();
    } finally {
      await destroyPool();
    }
  });

  it("updateProject executes UPDATE with correct parameters", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([
      {
        sqlPattern: /UPDATE projects SET/,
        rows: [],
        rowCount: 1,
      },
    ]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.updateProject(PROJECT_ID, { name: "New Name" });
      expect(capturedSql).toContain("UPDATE projects SET");
      expect(capturedSql).toContain("name");
    } finally {
      await destroyPool();
    }
  });

  it("removeProject soft-deletes (archives) by default", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([
      {
        sqlPattern: /UPDATE projects SET status = 'archived'/,
        rows: [],
        rowCount: 1,
      },
    ]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.removeProject(PROJECT_ID);
      expect(capturedSql).toContain("archived");
    } finally {
      await destroyPool();
    }
  });

  it("removeProject hard-deletes when force=true", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([
      { sqlPattern: /DELETE FROM projects/, rows: [], rowCount: 1 },
    ]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.removeProject(PROJECT_ID, { force: true });
      expect(capturedSql).toContain("DELETE FROM projects");
    } finally {
      await destroyPool();
    }
  });

  it("syncProject updates last_sync_at and updated_at", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([
      { sqlPattern: /UPDATE projects SET last_sync_at/, rows: [], rowCount: 1 },
    ]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.syncProject(PROJECT_ID);
      expect(capturedSql).toContain("last_sync_at");
      expect(capturedSql).toContain("updated_at");
    } finally {
      await destroyPool();
    }
  });
});

// ---------------------------------------------------------------------------
// Task operations
// ---------------------------------------------------------------------------

describe("PostgresAdapter task operations", () => {
  beforeEach(() => { vi.restoreAllMocks(); });
  afterEach(() => { vi.restoreAllMocks(); });

  const TASK_ID = "bd-task-001";
  const RUN_ID = "run-001";
  const TASK_ROW = {
    id: TASK_ID,
    project_id: PROJECT_ID,
    title: "Test Task",
    description: null,
    type: "task",
    priority: 2,
    status: "backlog",
    run_id: null,
    branch: null,
    external_id: null,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    approved_at: null,
    closed_at: null,
  };

  it("createTask inserts and returns the task row", async () => {
    const mockPool = makeMockPool([
      { sqlPattern: /INSERT INTO tasks/, rows: [TASK_ROW] },
    ]);
    await initPool({ poolOverride: mockPool as PoolLike });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.createTask(PROJECT_ID, { id: TASK_ID, title: "Test Task" });
      expect(result.id).toBe(TASK_ID);
      expect(result.project_id).toBe(PROJECT_ID);
      expect(result.status).toBe("backlog");
    } finally {
      await destroyPool();
    }
  });

  it("listTasks returns rows from the database", async () => {
    const mockPool = makeMockPool([
      { sqlPattern: /SELECT \* FROM tasks/, rows: [TASK_ROW] },
    ]);
    await initPool({ poolOverride: mockPool as PoolLike });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.listTasks(PROJECT_ID);
      expect(result).toHaveLength(1);
      expect(result[0].id).toBe(TASK_ID);
    } finally {
      await destroyPool();
    }
  });

  it("listTasks filters by status", async () => {
    const mockPool = makeMockPool([
      { sqlPattern: /SELECT \* FROM tasks WHERE project_id = \$1 AND status IN/, rows: [TASK_ROW] },
    ]);
    await initPool({ poolOverride: mockPool as PoolLike });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.listTasks(PROJECT_ID, { status: ["backlog", "ready"] });
      expect(result).toHaveLength(1);
    } finally {
      await destroyPool();
    }
  });

  it("getTask returns a task by id", async () => {
    const mockPool = makeMockPool([
      { sqlPattern: /SELECT \* FROM tasks WHERE id = \$1 AND project_id = \$2/, rows: [TASK_ROW] },
    ]);
    await initPool({ poolOverride: mockPool as PoolLike });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.getTask(PROJECT_ID, TASK_ID);
      expect(result?.id).toBe(TASK_ID);
    } finally {
      await destroyPool();
    }
  });

  it("getTask returns null when not found", async () => {
    const mockPool = makeMockPool([
      { sqlPattern: /SELECT \* FROM tasks WHERE id = \$1 AND project_id = \$2/, rows: [] },
    ]);
    await initPool({ poolOverride: mockPool as PoolLike });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.getTask(PROJECT_ID, "nonexistent");
      expect(result).toBeNull();
    } finally {
      await destroyPool();
    }
  });

  it("updateTask executes UPDATE with correct parameters", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([
      { sqlPattern: /UPDATE tasks SET/, rows: [] },
    ]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 0 };
    });
    await initPool({ poolOverride: mockPool as PoolLike });
    try {
      const adapter = new PostgresAdapter();
      await adapter.updateTask(PROJECT_ID, TASK_ID, { status: "ready" });
      expect(capturedSql).toContain("UPDATE tasks SET");
      expect(capturedSql).toContain("status");
    } finally {
      await destroyPool();
    }
  });

  it("deleteTask executes DELETE", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([
      { sqlPattern: /DELETE FROM tasks/, rows: [] },
    ]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool as PoolLike });
    try {
      const adapter = new PostgresAdapter();
      await adapter.deleteTask(PROJECT_ID, TASK_ID);
      expect(capturedSql).toContain("DELETE FROM tasks");
    } finally {
      await destroyPool();
    }
  });

  it("listReadyTasks returns only ready tasks", async () => {
    const mockPool = makeMockPool([
      { sqlPattern: /SELECT\s+\*\s+FROM\s+tasks\s+WHERE\s+project_id\s+=\s+\$1\s+AND\s+status\s+=\s+'ready'/, rows: [TASK_ROW] },
    ]);
    await initPool({ poolOverride: mockPool as PoolLike });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.listReadyTasks(PROJECT_ID);
      expect(result).toHaveLength(1);
    } finally {
      await destroyPool();
    }
  });

  it("listNeedsHumanTasks returns backlog/conflict/failed/stuck/blocked", async () => {
    const mockPool = makeMockPool([
      { sqlPattern: /SELECT\s+\*\s+FROM\s+tasks\s+WHERE\s+project_id\s+=\s+\$1\s+AND\s+status\s+IN/, rows: [TASK_ROW] },
    ]);
    await initPool({ poolOverride: mockPool as PoolLike });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.listNeedsHumanTasks(PROJECT_ID);
      expect(result).toHaveLength(1);
    } finally {
      await destroyPool();
    }
  });
});

// ---------------------------------------------------------------------------
// Run operations
// ---------------------------------------------------------------------------

describe("PostgresAdapter run operations", () => {
  it("createRun throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.createRun(PROJECT_ID, "seed-1", "developer"),
      "createRun"
    );
  });

  it("listRuns throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.listRuns(PROJECT_ID),
      "listRuns"
    );
  });

  it("getRun throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.getRun(PROJECT_ID, "run-1"),
      "getRun"
    );
  });

  it("updateRun throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.updateRun(PROJECT_ID, "run-1", { status: "running" }),
      "updateRun"
    );
  });

  it("listActiveRuns throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.listActiveRuns(PROJECT_ID),
      "listActiveRuns"
    );
  });

  it("hasActiveOrPendingRun throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.hasActiveOrPendingRun(PROJECT_ID, "seed-1"),
      "hasActiveOrPendingRun"
    );
  });

  it("updateRunProgress throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.updateRunProgress(PROJECT_ID, "run-1", { phase: "developer" }),
      "updateRunProgress"
    );
  });

  it("purgeOldRuns throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.purgeOldRuns(PROJECT_ID, "2024-01-01"),
      "purgeOldRuns"
    );
  });

  it("deleteRun throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.deleteRun(PROJECT_ID, "run-1"),
      "deleteRun"
    );
  });
});

// ---------------------------------------------------------------------------
// Cost recording
// ---------------------------------------------------------------------------

describe("PostgresAdapter cost operations", () => {
  it("recordCost throws 'not implemented'", async () => {
    await assertNotImplemented(
      () =>
        adapter.recordCost(PROJECT_ID, "run-1", {
          tokensIn: 1000,
          tokensOut: 500,
          cacheRead: 200,
          estimatedCost: 0.05,
        }),
      "recordCost"
    );
  });
});

// ---------------------------------------------------------------------------
// Event operations
// ---------------------------------------------------------------------------

describe("PostgresAdapter event operations", () => {
  it("logEvent throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.logEvent(PROJECT_ID, "run-1", "phase_start", "explorer started"),
      "logEvent"
    );
  });

  it("logRateLimitEvent throws 'not implemented'", async () => {
    await assertNotImplemented(
      () =>
        adapter.logRateLimitEvent(PROJECT_ID, "run-1", "developer", "rate limit hit"),
      "logRateLimitEvent"
    );
  });
});

// ---------------------------------------------------------------------------
// Message operations
// ---------------------------------------------------------------------------

describe("PostgresAdapter message operations", () => {
  it("sendMessage throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.sendMessage(PROJECT_ID, "run-1", "developer", "Hello"),
      "sendMessage"
    );
  });

  it("markMessageRead throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.markMessageRead(PROJECT_ID, "msg-1"),
      "markMessageRead"
    );
  });

  it("markAllMessagesRead throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.markAllMessagesRead(PROJECT_ID, "run-1", "developer"),
      "markAllMessagesRead"
    );
  });

  it("deleteMessage throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.deleteMessage(PROJECT_ID, "msg-1"),
      "deleteMessage"
    );
  });
});

// ---------------------------------------------------------------------------
// Bead write queue
// ---------------------------------------------------------------------------

describe("PostgresAdapter bead write queue operations", () => {
  it("enqueueBeadWrite throws 'not implemented'", async () => {
    await assertNotImplemented(
      () =>
        adapter.enqueueBeadWrite(PROJECT_ID, "sentinel", "upsert", { id: "1" }),
      "enqueueBeadWrite"
    );
  });

  it("markBeadWriteProcessed throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.markBeadWriteProcessed(PROJECT_ID, "bw-1"),
      "markBeadWriteProcessed"
    );
  });
});

// ---------------------------------------------------------------------------
// Sentinel operations
// ---------------------------------------------------------------------------

describe("PostgresAdapter sentinel operations", () => {
  it("upsertSentinelConfig throws 'not implemented'", async () => {
    await assertNotImplemented(
      () =>
        adapter.upsertSentinelConfig(PROJECT_ID, {
          schedule: "*/5 * * * *",
        }),
      "upsertSentinelConfig"
    );
  });

  it("recordSentinelRun throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.recordSentinelRun(PROJECT_ID, { id: "sr-1" }),
      "recordSentinelRun"
    );
  });

  it("updateSentinelRun throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.updateSentinelRun(PROJECT_ID, "sr-1", { status: "done" }),
      "updateSentinelRun"
    );
  });
});
