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
  it("createTask throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.createTask(PROJECT_ID, { title: "Test task" }),
      "createTask"
    );
  });

  it("listTasks throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.listTasks(PROJECT_ID),
      "listTasks"
    );
  });

  it("getTask throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.getTask(PROJECT_ID, "task-1"),
      "getTask"
    );
  });

  it("updateTask throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.updateTask(PROJECT_ID, "task-1", { status: "done" }),
      "updateTask"
    );
  });

  it("deleteTask throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.deleteTask(PROJECT_ID, "task-1"),
      "deleteTask"
    );
  });

  it("claimTask throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.claimTask(PROJECT_ID, "task-1", "run-1"),
      "claimTask"
    );
  });

  it("approveTask throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.approveTask(PROJECT_ID, "task-1"),
      "approveTask"
    );
  });

  it("resetTask throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.resetTask(PROJECT_ID, "task-1"),
      "resetTask"
    );
  });

  it("retryTask throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.retryTask(PROJECT_ID, "task-1"),
      "retryTask"
    );
  });

  it("listReadyTasks throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.listReadyTasks(PROJECT_ID),
      "listReadyTasks"
    );
  });

  it("listNeedsHumanTasks throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.listNeedsHumanTasks(PROJECT_ID),
      "listNeedsHumanTasks"
    );
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
