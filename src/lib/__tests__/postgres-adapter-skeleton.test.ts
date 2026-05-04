/**
 * TRD-003-TEST | Verifies: TRD-003 | Tests: PostgresAdapter legacy compatibility APIs
 * PRD: docs/PRD/PRD-2026-010-multi-project-orchestrator.md
 * TRD: docs/TRD/TRD-2026-011-multi-project-orchestrator.md#trd-003
 *
 * Note: Project, task, legacy compatibility, and pipeline-specific adapter
 * methods covered here are implemented.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { PostgresAdapter } from "../db/postgres-adapter.js";
import { initPool, destroyPool, type PoolLike } from "../db/pool-manager.js";

const PROJECT_ID = "proj-test123";

const adapter = new PostgresAdapter();

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
  beforeEach(() => { vi.restoreAllMocks(); });
  afterEach(() => { vi.restoreAllMocks(); });

  it("createRun inserts and returns a run row", async () => {
    const runRow = {
      id: "run-1",
      project_id: PROJECT_ID,
      seed_id: "seed-1",
      agent_type: "developer",
      session_key: null,
      worktree_path: "/tmp/wt",
      status: "pending",
      started_at: null,
      completed_at: null,
      created_at: new Date().toISOString(),
      progress: null,
      bead_id: "seed-1",
      run_number: 1,
      branch: "seed-1",
      trigger: "bead",
    };
    const mockPool = makeMockPool([{ sqlPattern: /INSERT INTO runs/, rows: [runRow] }]);
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.createRun(PROJECT_ID, "seed-1", "developer", { worktreePath: "/tmp/wt" });
      expect(result).toEqual(runRow);
    } finally {
      await destroyPool();
    }
  });

  it("listRuns filters by project and status", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /SELECT \* FROM runs/, rows: [] }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 0 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.listRuns(PROJECT_ID, { status: ["running"], limit: 10 });
      expect(capturedSql).toContain("project_id = $1");
      expect(capturedSql).toContain("seed_id IS NOT NULL");
      expect(capturedSql).toContain("status IN ($2)");
      expect(capturedSql).toContain("LIMIT $3");
    } finally {
      await destroyPool();
    }
  });

  it("getRun returns null when no matching run exists", async () => {
    const mockPool = makeMockPool([{ sqlPattern: /SELECT \* FROM runs WHERE id = \$1/, rows: [] }]);
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.getRun(PROJECT_ID, "run-missing");
      expect(result).toBeNull();
    } finally {
      await destroyPool();
    }
  });

  it("updateRun updates only the requested fields", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /UPDATE runs SET/, rows: [], rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.updateRun(PROJECT_ID, "run-1", { status: "running", worktree_path: "/tmp/wt" });
      expect(capturedSql).toContain("status = $1");
      expect(capturedSql).toContain("worktree_path = $2");
      expect(capturedSql).toContain("updated_at = now()");
    } finally {
      await destroyPool();
    }
  });

  it("listActiveRuns returns pending and running runs", async () => {
    const rows = [
      {
        id: "run-1",
        project_id: PROJECT_ID,
        seed_id: "seed-1",
        agent_type: "developer",
        session_key: null,
        worktree_path: null,
        status: "running",
        started_at: null,
        completed_at: null,
        created_at: new Date().toISOString(),
        progress: null,
      },
    ];
    const mockPool = makeMockPool([{ sqlPattern: /status IN \('pending', 'running'\)/, rows }]);
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.listActiveRuns(PROJECT_ID);
      expect(result).toEqual(rows);
    } finally {
      await destroyPool();
    }
  });

  it("hasActiveOrPendingRun returns true when a matching row exists", async () => {
    const mockPool = makeMockPool([{ sqlPattern: /SELECT 1 AS present FROM runs/, rows: [{ present: 1 }] }]);
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await expect(adapter.hasActiveOrPendingRun(PROJECT_ID, "seed-1")).resolves.toBe(true);
    } finally {
      await destroyPool();
    }
  });

  it("updateRunProgress merges partial progress into existing JSON", async () => {
    let calls: Array<{ text: string; params?: unknown[] }> = [];
    const mockPool = makeMockPool([]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string, params?: unknown[]) => {
      calls.push({ text, params });
      if (/SELECT \* FROM runs WHERE id = \$1/.test(text)) {
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
            created_at: new Date().toISOString(),
            progress: JSON.stringify({ toolCalls: 2, currentPhase: "explorer" }),
          }],
          rowCount: 1,
        };
      }
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.updateRunProgress(PROJECT_ID, "run-1", { phase: "developer", tokensIn: 42 });
      const update = calls.find((call) => /UPDATE runs\s+SET progress = \$1/.test(call.text));
      expect(update).toBeDefined();
      expect(JSON.parse(String(update?.params?.[0]))).toEqual({
        toolCalls: 2,
        currentPhase: "developer",
        tokensIn: 42,
      });
    } finally {
      await destroyPool();
    }
  });

  it("purgeOldRuns deletes only old terminal legacy runs", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /DELETE FROM runs/, rows: [], rowCount: 3 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 3 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await expect(adapter.purgeOldRuns(PROJECT_ID, "2024-01-01")).resolves.toBe(3);
      expect(capturedSql).toContain("seed_id IS NOT NULL");
      expect(capturedSql).toContain("status IN ('failed', 'merged', 'test-failed', 'conflict')");
    } finally {
      await destroyPool();
    }
  });

  it("deleteRun deletes only project-scoped legacy runs", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /DELETE FROM runs/, rows: [], rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await expect(adapter.deleteRun(PROJECT_ID, "run-1")).resolves.toBe(true);
      expect(capturedSql).toContain("project_id = $2");
      expect(capturedSql).toContain("seed_id IS NOT NULL");
    } finally {
      await destroyPool();
    }
  });
});

// ---------------------------------------------------------------------------
// Cost recording
// ---------------------------------------------------------------------------

describe("PostgresAdapter cost operations", () => {
  beforeEach(() => { vi.restoreAllMocks(); });
  afterEach(() => { vi.restoreAllMocks(); });

  it("recordCost inserts a cost row", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /INSERT INTO costs/, rows: [], rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.recordCost(PROJECT_ID, "run-1", {
        tokensIn: 1000,
        tokensOut: 500,
        cacheRead: 200,
        estimatedCost: 0.05,
      });
      expect(capturedSql).toContain("INSERT INTO costs");
      expect(capturedSql).toContain("tokens_in");
      expect(capturedSql).toContain("estimated_cost");
    } finally {
      await destroyPool();
    }
  });
});

// ---------------------------------------------------------------------------
// Event operations
// ---------------------------------------------------------------------------

describe("PostgresAdapter event operations", () => {
  beforeEach(() => { vi.restoreAllMocks(); });
  afterEach(() => { vi.restoreAllMocks(); });

  it("logEvent inserts an event row", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /INSERT INTO events/, rows: [], rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.logEvent(PROJECT_ID, "run-1", "phase_start", "explorer started");
      expect(capturedSql).toContain("INSERT INTO events");
      expect(capturedSql).toContain("details");
    } finally {
      await destroyPool();
    }
  });

  it("logRateLimitEvent inserts a rate-limit row", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /INSERT INTO rate_limit_events/, rows: [], rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.logRateLimitEvent(PROJECT_ID, "run-1", "developer", "rate limit hit");
      expect(capturedSql).toContain("INSERT INTO rate_limit_events");
      expect(capturedSql).toContain("model");
      expect(capturedSql).toContain("error");
    } finally {
      await destroyPool();
    }
  });
});

// ---------------------------------------------------------------------------
// Message operations
// ---------------------------------------------------------------------------

describe("PostgresAdapter message operations", () => {
  beforeEach(() => { vi.restoreAllMocks(); });
  afterEach(() => { vi.restoreAllMocks(); });

  it("sendMessage inserts a compatibility mail row", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /INSERT INTO messages/, rows: [], rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.sendMessage(PROJECT_ID, "run-1", "developer", "Hello");
      expect(capturedSql).toContain("INSERT INTO messages");
      expect(capturedSql).toContain("sender_agent_type");
      expect(capturedSql).toContain("recipient_agent_type");
      expect(capturedSql).toContain("subject");
    } finally {
      await destroyPool();
    }
  });

  it("markMessageRead updates a single message", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /UPDATE messages AS m/, rows: [], rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await expect(adapter.markMessageRead(PROJECT_ID, "msg-1")).resolves.toBe(true);
      expect(capturedSql).toContain("SET read = 1");
      expect(capturedSql).toContain("project_id = $2");
    } finally {
      await destroyPool();
    }
  });

  it("markAllMessagesRead updates run/recipient scoped messages", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /UPDATE messages AS m/, rows: [], rowCount: 2 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 2 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.markAllMessagesRead(PROJECT_ID, "run-1", "developer");
      expect(capturedSql).toContain("recipient_agent_type = $2");
      expect(capturedSql).toContain("deleted_at IS NULL");
    } finally {
      await destroyPool();
    }
  });

  it("deleteMessage soft-deletes a message", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /UPDATE messages AS m/, rows: [], rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await expect(adapter.deleteMessage(PROJECT_ID, "msg-1")).resolves.toBe(true);
      expect(capturedSql).toContain("SET deleted_at = now()");
    } finally {
      await destroyPool();
    }
  });
});

// ---------------------------------------------------------------------------
// Bead write queue
// ---------------------------------------------------------------------------

describe("PostgresAdapter bead write queue operations", () => {
  beforeEach(() => { vi.restoreAllMocks(); });
  afterEach(() => { vi.restoreAllMocks(); });

  it("enqueueBeadWrite inserts a queued entry", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /INSERT INTO bead_write_queue/, rows: [], rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.enqueueBeadWrite(PROJECT_ID, "sentinel", "upsert", { id: "1" });
      expect(capturedSql).toContain("INSERT INTO bead_write_queue");
      expect(capturedSql).toContain("project_id");
      expect(capturedSql).toContain("payload");
    } finally {
      await destroyPool();
    }
  });

  it("markBeadWriteProcessed timestamps a queued entry", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /UPDATE bead_write_queue/, rows: [], rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await expect(adapter.markBeadWriteProcessed(PROJECT_ID, "bw-1")).resolves.toBe(true);
      expect(capturedSql).toContain("SET processed_at = now()");
      expect(capturedSql).toContain("project_id = $2");
    } finally {
      await destroyPool();
    }
  });
});

// ---------------------------------------------------------------------------
// Sentinel operations
// ---------------------------------------------------------------------------

describe("PostgresAdapter sentinel operations", () => {
  beforeEach(() => { vi.restoreAllMocks(); });
  afterEach(() => { vi.restoreAllMocks(); });

  it("upsertSentinelConfig inserts and returns config rows", async () => {
    const calls: Array<{ text: string; params?: unknown[] }> = [];
    const row = {
      id: 1,
      project_id: PROJECT_ID,
      branch: "main",
      test_command: "npm test",
      interval_minutes: 30,
      failure_threshold: 2,
      enabled: 1,
      pid: 123,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };
    const mockPool = makeMockPool([]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string, params?: unknown[]) => {
      calls.push({ text, params });
      if (/SELECT \* FROM sentinel_configs WHERE project_id = \$1/.test(text)) {
        return { rows: calls.length === 1 ? [] : [row], rowCount: calls.length === 1 ? 0 : 1 };
      }
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.upsertSentinelConfig(PROJECT_ID, { pid: 123 });
      expect(result).toEqual(row);
      expect(calls.some((call) => /INSERT INTO sentinel_configs/.test(call.text))).toBe(true);
    } finally {
      await destroyPool();
    }
  });

  it("getSentinelConfig returns null when missing", async () => {
    const mockPool = makeMockPool([{ sqlPattern: /SELECT \* FROM sentinel_configs WHERE project_id = \$1/, rows: [] }]);
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await expect(adapter.getSentinelConfig(PROJECT_ID)).resolves.toBeNull();
    } finally {
      await destroyPool();
    }
  });

  it("recordSentinelRun inserts a run row", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /INSERT INTO sentinel_runs/, rows: [], rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.recordSentinelRun(PROJECT_ID, {
        id: "sr-1",
        branch: "main",
        commit_hash: null,
        status: "running",
        test_command: "npm test",
        output: null,
        started_at: new Date().toISOString(),
        completed_at: null,
      });
      expect(capturedSql).toContain("INSERT INTO sentinel_runs");
      expect(capturedSql).toContain("failure_count");
    } finally {
      await destroyPool();
    }
  });

  it("updateSentinelRun updates provided fields only", async () => {
    let capturedSql = "";
    const mockPool = makeMockPool([{ sqlPattern: /UPDATE sentinel_runs AS sr/, rows: [], rowCount: 1 }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows: [], rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      await adapter.updateSentinelRun(PROJECT_ID, "sr-1", { status: "failed", failure_count: 2 });
      expect(capturedSql).toContain("status = $1");
      expect(capturedSql).toContain("failure_count = $2");
      expect(capturedSql).toContain("project_id = $4");
    } finally {
      await destroyPool();
    }
  });

  it("getSentinelRuns scopes by project and applies limit", async () => {
    let capturedSql = "";
    const rows = [{
      id: "sr-1",
      project_id: PROJECT_ID,
      branch: "main",
      commit_hash: null,
      status: "passed",
      test_command: "npm test",
      output: null,
      failure_count: 0,
      started_at: new Date().toISOString(),
      completed_at: null,
    }];
    const mockPool = makeMockPool([{ sqlPattern: /SELECT \* FROM sentinel_runs/, rows }]);
    (mockPool.query as ReturnType<typeof vi.fn>).mockImplementation(async (text: string) => {
      capturedSql = text;
      return { rows, rowCount: 1 };
    });
    await initPool({ poolOverride: mockPool });
    try {
      const adapter = new PostgresAdapter();
      const result = await adapter.getSentinelRuns(PROJECT_ID, 5);
      expect(result).toEqual(rows);
      expect(capturedSql).toContain("project_id = $1");
      expect(capturedSql).toContain("ORDER BY started_at DESC");
      expect(capturedSql).toContain("LIMIT $2");
    } finally {
      await destroyPool();
    }
  });
});
