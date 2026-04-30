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

function makeCapturePool(
  onQuery: (text: string, params?: unknown[]) => { rows: unknown[]; rowCount: number }
): PoolLike {
  return {
    query: async (text: string, params?: unknown[]) => onQuery(text, params) as never,
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
      { sqlPattern: /SELECT t\.\*, r\.pr_state, r\.pr_url, r\.pr_head_sha/, rows: [{ ...TASK_ROW, pr_state: null, pr_url: null, pr_head_sha: null }] },
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
      { sqlPattern: /SELECT t\.\*, r\.pr_state, r\.pr_url, r\.pr_head_sha/, rows: [{ ...TASK_ROW, pr_state: null, pr_url: null, pr_head_sha: null }] },
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
  it("createRun inserts a pending run row", async () => {
    const mockPool = makeMockPool([
      {
        sqlPattern: /INSERT INTO runs/,
        rows: [{
          id: "run-1",
          project_id: PROJECT_ID,
          seed_id: "seed-1",
          agent_type: "developer",
          session_key: null,
          worktree_path: "/tmp/worktree",
          status: "pending",
          started_at: null,
          completed_at: null,
          created_at: "2026-01-01T00:00:00Z",
          progress: null,
        }],
      },
    ]);
    await initPool({ poolOverride: mockPool });
    try {
      const result = await adapter.createRun(PROJECT_ID, "seed-1", "developer", {
        worktreePath: "/tmp/worktree",
      });
      expect(result.id).toBe("run-1");
      expect(result.status).toBe("pending");
    } finally {
      await destroyPool();
    }
  });

  it("listRuns maps pipeline statuses back to legacy statuses", async () => {
    const mockPool = makeMockPool([
      {
        sqlPattern: /FROM runs[\s\S]+ORDER BY created_at DESC/,
        rows: [{
          id: "run-1",
          project_id: PROJECT_ID,
          seed_id: "seed-1",
          agent_type: "developer",
          session_key: null,
          worktree_path: null,
          status: "success",
          started_at: null,
          completed_at: null,
          created_at: "2026-01-01T00:00:00Z",
          progress: null,
          base_branch: null,
          merge_strategy: null,
        }],
      },
    ]);
    await initPool({ poolOverride: mockPool });
    try {
      const result = await adapter.listRuns(PROJECT_ID, { status: ["completed"], limit: 5 });
      expect(result).toHaveLength(1);
      expect(result[0].status).toBe("completed");
    } finally {
      await destroyPool();
    }
  });

  it("getRun returns a mapped legacy run row", async () => {
    const mockPool = makeMockPool([
      {
        sqlPattern: /WHERE project_id = \$1 AND id = \$2 LIMIT 1/,
        rows: [{
          id: "run-1",
          project_id: PROJECT_ID,
          seed_id: "seed-1",
          agent_type: "developer",
          session_key: null,
          worktree_path: null,
          status: "failure",
          started_at: null,
          completed_at: null,
          created_at: "2026-01-01T00:00:00Z",
          progress: null,
          base_branch: null,
          merge_strategy: null,
        }],
      },
    ]);
    await initPool({ poolOverride: mockPool });
    try {
      const result = await adapter.getRun(PROJECT_ID, "run-1");
      expect(result?.id).toBe("run-1");
      expect(result?.status).toBe("failed");
    } finally {
      await destroyPool();
    }
  });

  it("updateRun writes mapped status updates", async () => {
    let capturedSql = "";
    let capturedParams: unknown[] = [];
    const mockPool = makeMockPool([{ sqlPattern: /UPDATE runs SET/, rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string, params?: unknown[]) => {
      capturedSql = text;
      capturedParams = params ?? [];
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      await adapter.updateRun(PROJECT_ID, "run-1", { status: "completed" });
      expect(capturedSql).toContain("UPDATE runs SET");
      expect(capturedParams).toContain("success");
    } finally {
      await destroyPool();
    }
  });

  it("listActiveRuns excludes running runs whose task row is closed", async () => {
    let sql = "";
    const mockPool = makeCapturePool((text) => {
      sql = text;
      return { rows: [], rowCount: 0 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const result = await adapter.listActiveRuns(PROJECT_ID);
      expect(sql).toContain("status IN ('pending','running')");
      expect(sql).toContain("NOT EXISTS");
      expect(sql).toContain("t.id = r.bead_id");
      expect(sql).toContain("t.status IN ('closed','merged')");
      expect(result).toHaveLength(0);
    } finally {
      await destroyPool();
    }
  });

  it("listActiveRuns excludes running runs whose task row is merged", async () => {
    let sql = "";
    const mockPool = makeCapturePool((text) => {
      sql = text;
      return { rows: [], rowCount: 0 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const result = await adapter.listActiveRuns(PROJECT_ID);
      expect(sql).toContain("status IN ('pending','running')");
      expect(sql).toContain("NOT EXISTS");
      expect(sql).toContain("t.id = r.bead_id");
      expect(sql).toContain("t.status IN ('closed','merged')");
      expect(result).toHaveLength(0);
    } finally {
      await destroyPool();
    }
  });

  it("listActiveRuns returns running runs when no matching task row exists", async () => {
    let sql = "";
    const mockPool = makeCapturePool((text) => {
      sql = text;
      return {
        rows: [{
          id: "run-1",
          project_id: PROJECT_ID,
          seed_id: "seed-1",
          agent_type: "developer",
          session_key: null,
          worktree_path: null,
          status: "running",
          started_at: null,
          completed_at: null,
          created_at: "2026-01-01T00:00:00Z",
          progress: null,
          base_branch: null,
          merge_strategy: null,
        }],
        rowCount: 1,
      };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const result = await adapter.listActiveRuns(PROJECT_ID);
      expect(sql).toContain("status IN ('pending','running')");
      expect(sql).toContain("NOT EXISTS");
      expect(sql).toContain("t.id = r.bead_id");
      expect(sql).toContain("t.status IN ('closed','merged')");
      expect(result).toHaveLength(1);
      expect(result[0].status).toBe("running");
    } finally {
      await destroyPool();
    }
  });

  it("hasActiveOrPendingRun returns true when a matching run exists", async () => {
    const mockPool = makeMockPool([
      { sqlPattern: /SELECT 1 as found FROM runs/, rows: [{ found: 1 }] },
    ]);
    await initPool({ poolOverride: mockPool });
    try {
      await expect(adapter.hasActiveOrPendingRun(PROJECT_ID, "seed-1")).resolves.toBe(true);
    } finally {
      await destroyPool();
    }
  });

  it("updateRunProgress merges JSON progress through getRun and updateRun", async () => {
    const calls: Array<{ text: string; params?: unknown[] }> = [];
    const mockPool = makeMockPool([
      {
        sqlPattern: /WHERE project_id = \$1 AND id = \$2 LIMIT 1/,
        rows: [{
          id: "run-1",
          project_id: PROJECT_ID,
          seed_id: "seed-1",
          agent_type: "developer",
          session_key: null,
          worktree_path: null,
          status: "running",
          started_at: null,
          completed_at: null,
          created_at: "2026-01-01T00:00:00Z",
          progress: JSON.stringify({ costUsd: 1.5 }),
          base_branch: null,
          merge_strategy: null,
        }],
      },
      { sqlPattern: /UPDATE runs SET/, rowCount: 1 },
    ]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string, params?: unknown[]) => {
      calls.push({ text, params });
      if (/WHERE project_id = \$1 AND id = \$2 LIMIT 1/.test(text)) {
        return {
          rows: [{
            id: "run-1",
            project_id: PROJECT_ID,
            seed_id: "seed-1",
            agent_type: "developer",
            session_key: null,
            worktree_path: null,
            status: "running",
            started_at: null,
            completed_at: null,
            created_at: "2026-01-01T00:00:00Z",
            progress: JSON.stringify({ costUsd: 1.5 }),
            base_branch: null,
            merge_strategy: null,
          }],
          rowCount: 1,
        };
      }
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      await adapter.updateRunProgress(PROJECT_ID, "run-1", { phase: "developer" });
      const updateCall = calls.find((call) => /UPDATE runs SET/.test(call.text));
      expect(updateCall).toBeDefined();
      expect(updateCall?.params).toContain(JSON.stringify({ costUsd: 1.5, phase: "developer" }));
    } finally {
      await destroyPool();
    }
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
  it("logEvent writes a pipeline event payload", async () => {
    let capturedParams: unknown[] = [];
    const mockPool = makeMockPool([
      { sqlPattern: /INSERT INTO events/, rows: [{ id: "evt-1" }] },
    ]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (_text: string, params?: unknown[]) => {
      capturedParams = params ?? [];
      return { rows: [{ id: "evt-1" }], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      await adapter.logEvent(PROJECT_ID, "run-1", "phase_start", "explorer started");
      expect(capturedParams[0]).toBe(PROJECT_ID);
      expect(capturedParams[1]).toBe("run-1");
      expect(capturedParams[3]).toBe("phase_start");
      expect(capturedParams[4]).toBe(JSON.stringify({ details: "explorer started" }));
    } finally {
      await destroyPool();
    }
  });

  it("logRateLimitEvent inserts a rate limit row", async () => {
    let capturedParams: unknown[] = [];
    const mockPool = makeMockPool([{ sqlPattern: /INSERT INTO rate_limit_events/, rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (_text: string, params?: unknown[]) => {
      capturedParams = params ?? [];
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      await adapter.logRateLimitEvent(PROJECT_ID, "run-1", "claude-sonnet", "developer", "rate limit hit", 60);
      expect(capturedParams).toEqual([PROJECT_ID, "run-1", "claude-sonnet", "developer", "rate limit hit", 60]);
    } finally {
      await destroyPool();
    }
  });
});

// ---------------------------------------------------------------------------
// Message operations
// ---------------------------------------------------------------------------

describe("PostgresAdapter message operations", () => {
  it("sendMessage inserts and returns the message row", async () => {
    const mockPool = makeMockPool([
      {
        sqlPattern: /INSERT INTO agent_messages/,
        rows: [{
          id: "msg-1",
          project_id: PROJECT_ID,
          run_id: "run-1",
          sender_agent_type: "developer",
          recipient_agent_type: "reviewer",
          subject: "phase-complete",
          body: "Hello",
          read: 0,
          created_at: "",
          deleted_at: null,
        }],
      },
    ]);
    await initPool({ poolOverride: mockPool });
    try {
      const result = await adapter.sendMessage(
        PROJECT_ID,
        "run-1",
        "developer",
        "reviewer",
        "phase-complete",
        "Hello",
      );
      expect(result.id).toBe("msg-1");
      expect(result.recipient_agent_type).toBe("reviewer");
    } finally {
      await destroyPool();
    }
  });

  it("markMessageRead returns true when a row was updated", async () => {
    const mockPool = makeMockPool([{ sqlPattern: /SET read = 1/, rowCount: 1 }]);
    await initPool({ poolOverride: mockPool });
    try {
      await expect(adapter.markMessageRead(PROJECT_ID, "msg-1")).resolves.toBe(true);
    } finally {
      await destroyPool();
    }
  });

  it("markAllMessagesRead updates unread messages for an agent", async () => {
    let capturedParams: unknown[] = [];
    const mockPool = makeMockPool([{ sqlPattern: /recipient_agent_type = \$3/, rowCount: 2 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (_text: string, params?: unknown[]) => {
      capturedParams = params ?? [];
      return { rows: [], rowCount: 2 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      await adapter.markAllMessagesRead(PROJECT_ID, "run-1", "developer");
      expect(capturedParams).toEqual([PROJECT_ID, "run-1", "developer"]);
    } finally {
      await destroyPool();
    }
  });

  it("deleteMessage soft-deletes a message", async () => {
    const mockPool = makeMockPool([{ sqlPattern: /SET deleted_at = now\(\)/, rowCount: 1 }]);
    await initPool({ poolOverride: mockPool });
    try {
      await expect(adapter.deleteMessage(PROJECT_ID, "msg-1")).resolves.toBe(true);
    } finally {
      await destroyPool();
    }
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
  it("upsertSentinelConfig writes the configured sentinel row", async () => {
    let capturedParams: unknown[] = [];
    const mockPool = makeMockPool([{ sqlPattern: /INSERT INTO sentinel_configs/, rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (_text: string, params?: unknown[]) => {
      capturedParams = params ?? [];
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      await adapter.upsertSentinelConfig(PROJECT_ID, {
        branch: "dev",
        test_command: "npm test",
        interval_minutes: 5,
        failure_threshold: 3,
        enabled: 1,
        pid: 1234,
      });
      expect(capturedParams[0]).toBe(PROJECT_ID);
      expect(capturedParams[1]).toBe("dev");
      expect(capturedParams[2]).toBe("npm test");
    } finally {
      await destroyPool();
    }
  });

  it("recordSentinelRun inserts the run payload", async () => {
    let capturedParams: unknown[] = [];
    const mockPool = makeMockPool([{ sqlPattern: /INSERT INTO sentinel_runs/, rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (_text: string, params?: unknown[]) => {
      capturedParams = params ?? [];
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      await adapter.recordSentinelRun(PROJECT_ID, {
        id: "sr-1",
        branch: "main",
        status: "running",
        test_command: "npm test",
        started_at: "2026-01-01T00:00:00Z",
      });
      expect(capturedParams[0]).toBe("sr-1");
      expect(capturedParams[1]).toBe(PROJECT_ID);
      expect(capturedParams[2]).toBe("main");
    } finally {
      await destroyPool();
    }
  });

  it("updateSentinelRun updates provided fields", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /UPDATE sentinel_runs SET/, rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      await adapter.updateSentinelRun(PROJECT_ID, "sr-1", { status: "done", failure_count: 1 });
      expect(capturedSql).toContain("UPDATE sentinel_runs SET");
      expect(capturedSql).toContain("status = $1");
      expect(capturedSql).toContain("failure_count = $2");
    } finally {
      await destroyPool();
    }
  });
});
