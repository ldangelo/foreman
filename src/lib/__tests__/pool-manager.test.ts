/**
 * TRD-002-TEST | Verifies: TRD-002 | Tests: PoolManager singleton, pool.query works
 * PRD: docs/PRD/PRD-2026-010-multi-project-orchestrator.md
 * TRD: docs/TRD/TRD-2026-011-multi-project-orchestrator.md#trd-002
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  initPool,
  destroyPool,
  query,
  execute,
  healthCheck,
  acquireClient,
  releaseClient,
  getPoolConfig,
  isPoolInitialised,
  PoolExhaustedError,
  DatabaseError,
  type PoolLike,
} from "../db/pool-manager.js";

// ---------------------------------------------------------------------------
// Mock pool — injected via poolOverride to avoid pg module mocking complexity
// ---------------------------------------------------------------------------

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function createMockPool(): PoolLike {
  const query = vi.fn() as any;
  const connect = vi.fn() as any;
  const end = vi.fn().mockResolvedValue(undefined) as any;
  const on = vi.fn().mockReturnThis() as any;
  return { query, connect, end, on };
}

// Helpers to set up mock responses without TypeScript seeing the mock methods.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const mockQuery = (pool: PoolLike, resolved: any) =>
  (pool.query as any).mockResolvedValue(resolved);
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const mockQueryError = (pool: PoolLike, rejected: any) =>
  (pool.query as any).mockRejectedValue(rejected);
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const mockConnect = (pool: PoolLike, resolved: any) =>
  (pool.connect as any).mockResolvedValue(resolved);

// ---------------------------------------------------------------------------
// beforeEach / afterEach — reset singleton between tests
// ---------------------------------------------------------------------------

beforeEach(async () => {
  await destroyPool(); // idempotent — clears any stale _pool
});

afterEach(async () => {
  await destroyPool();
});

// ---------------------------------------------------------------------------
// init / destroy lifecycle
// ---------------------------------------------------------------------------

describe("PoolManager.init / destroy lifecycle", () => {
  it("marks pool as initialised after init", async () => {
    const mockPool = createMockPool();
    initPool({ poolOverride: mockPool });
    expect(isPoolInitialised()).toBe(true);
  });

  it("throws if called twice without destroy", async () => {
    const mockPool = createMockPool();
    initPool({ poolOverride: mockPool });
    expect(() => initPool({ poolOverride: mockPool })).toThrow(
      "already initialised"
    );
  });

  it("marks pool as not initialised after destroy", async () => {
    const mockPool = createMockPool();
    initPool({ poolOverride: mockPool });
    expect(isPoolInitialised()).toBe(true);
    await destroyPool();
    expect(isPoolInitialised()).toBe(false);
  });

  it("destroyPool is idempotent", async () => {
    const mockPool = createMockPool();
    initPool({ poolOverride: mockPool });
    await destroyPool();
    await destroyPool(); // must not throw
  });

  it("defaults to postgresql://localhost/foreman", async () => {
    const mockPool = createMockPool();
    initPool({ poolOverride: mockPool });
    expect(getPoolConfig()?.connectionString).toBe(
      "postgresql://localhost/foreman"
    );
  });

  it("uses DATABASE_URL env var when set", async () => {
    const prev = process.env.DATABASE_URL;
    process.env.DATABASE_URL = "postgresql://user:pass@host/db";
    try {
      const mockPool = createMockPool();
      initPool({ poolOverride: mockPool });
      expect(getPoolConfig()?.connectionString).toBe(
        "postgresql://user:pass@host/db"
      );
    } finally {
      process.env.DATABASE_URL = prev;
    }
  });

  it("respects poolSize override", async () => {
    const mockPool = createMockPool();
    initPool({ poolOverride: mockPool, poolSize: 15 });
    expect(getPoolConfig()?.max).toBe(15);
  });

  it("respects idleTimeoutMs override", async () => {
    const mockPool = createMockPool();
    initPool({ poolOverride: mockPool, idleTimeoutMs: 45_000 });
    expect(getPoolConfig()?.idleTimeoutMillis).toBe(45_000);
  });

  it("respects connectionTimeoutMs override", async () => {
    const mockPool = createMockPool();
    initPool({ poolOverride: mockPool, connectionTimeoutMs: 8_000 });
    expect(getPoolConfig()?.connectionTimeoutMillis).toBe(8_000);
  });

  it("sets pool_size=20 by default", async () => {
    const mockPool = createMockPool();
    initPool({ poolOverride: mockPool });
    expect(getPoolConfig()?.max).toBe(20);
  });

  it("sets idle_timeout_ms=30000 by default", async () => {
    const mockPool = createMockPool();
    initPool({ poolOverride: mockPool });
    expect(getPoolConfig()?.idleTimeoutMillis).toBe(30_000);
  });

  it("sets connection_timeout_ms=5000 by default", async () => {
    const mockPool = createMockPool();
    initPool({ poolOverride: mockPool });
    expect(getPoolConfig()?.connectionTimeoutMillis).toBe(5_000);
  });
});

// ---------------------------------------------------------------------------
// query helper
// ---------------------------------------------------------------------------

describe("query helper", () => {
  it("calls pool.query with SQL and params", async () => {
    const mockPool = createMockPool();
    mockQuery(mockPool, {
      rows: [{ id: 1, name: "test" }],
      rowCount: 1,
    });

    initPool({ poolOverride: mockPool });
    const rows = await query("SELECT * FROM projects WHERE id = $1", [1]);

    expect(mockPool.query).toHaveBeenCalledOnce();
    expect(mockPool.query).toHaveBeenCalledWith(
      "SELECT * FROM projects WHERE id = $1",
      [1]
    );
    expect(rows).toEqual([{ id: 1, name: "test" }]);
  });

  it("returns empty array when no rows match", async () => {
    const mockPool = createMockPool();
    mockQuery(mockPool, { rows: [], rowCount: 0 });

    initPool({ poolOverride: mockPool });
    const rows = await query("SELECT * FROM projects WHERE id = $1", [999]);

    expect(rows).toEqual([]);
  });

  it("throws DatabaseError with pg error code on failure", async () => {
    const mockPool = createMockPool();
    mockQueryError(
      mockPool,
      Object.assign(new Error("syntax error"), { code: "42601" })
    );

    initPool({ poolOverride: mockPool });

    try {
      await query("INVALID SQL");
      expect.fail("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(DatabaseError);
      expect((err as { code: string }).code).toBe("42601");
    }
  });

  it("captures the original error as cause", async () => {
    const mockPool = createMockPool();
    const pgError = Object.assign(new Error("boom"), { code: "P0001" });
    mockQueryError(mockPool, pgError);

    initPool({ poolOverride: mockPool });

    try {
      await query("SELECT 1");
      expect.fail("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(DatabaseError);
      expect((err as { cause: unknown }).cause).toBe(pgError);
    }
  });
});

// ---------------------------------------------------------------------------
// execute helper
// ---------------------------------------------------------------------------

describe("execute helper", () => {
  it("returns rowCount from pg result", async () => {
    const mockPool = createMockPool();
    mockQuery(mockPool, { rows: [], rowCount: 5 });

    initPool({ poolOverride: mockPool });
    const count = await execute("UPDATE projects SET name = $1", ["new"]);

    expect(count).toBe(5);
  });

  it("returns 0 when rowCount is null", async () => {
    const mockPool = createMockPool();
    mockQuery(mockPool, { rows: [], rowCount: null });

    initPool({ poolOverride: mockPool });
    const count = await execute("DELETE FROM projects WHERE id = $1", [99]);

    expect(count).toBe(0);
  });

  it("throws DatabaseError on foreign key violation", async () => {
    const mockPool = createMockPool();
    mockQueryError(
      mockPool,
      Object.assign(new Error("violates foreign key"), { code: "23503" })
    );

    initPool({ poolOverride: mockPool });

    try {
      await execute("DELETE FROM projects WHERE id = $1", [1]);
      expect.fail("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(DatabaseError);
      expect((err as { code: string }).code).toBe("23503");
    }
  });
});

// ---------------------------------------------------------------------------
// healthCheck
// ---------------------------------------------------------------------------

describe("healthCheck", () => {
  it("calls pool.query with SELECT 1", async () => {
    const mockPool = createMockPool();
    mockQuery(mockPool, {
      rows: [{ "?column?": 1 }],
      rowCount: 1,
    });

    initPool({ poolOverride: mockPool });
    await healthCheck();

    expect(mockPool.query).toHaveBeenCalledWith("SELECT 1");
  });

  it("throws DatabaseError when connection refused", async () => {
    const mockPool = createMockPool();
    mockQueryError(
      mockPool,
      Object.assign(new Error("connect ECONNREFUSED"), {
        code: "ECONNREFUSED",
      })
    );

    initPool({ poolOverride: mockPool });

    try {
      await healthCheck();
      expect.fail("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(DatabaseError);
      expect((err as { code: string }).code).toBe("ECONNREFUSED");
    }
  });
});

// ---------------------------------------------------------------------------
// acquireClient / releaseClient
// ---------------------------------------------------------------------------

describe("acquireClient / releaseClient", () => {
  it("acquires a client from the pool", async () => {
    const mockPool = createMockPool();
    const fakeClient = { release: vi.fn() };
    mockConnect(mockPool, fakeClient);

    initPool({ poolOverride: mockPool });
    const client = await acquireClient();

    expect(mockPool.connect).toHaveBeenCalledTimes(1);
    expect(client).toBe(fakeClient);
  });

  it("releases client back to pool", async () => {
    const mockPool = createMockPool();
    const fakeClient = { release: vi.fn() };
    mockConnect(mockPool, fakeClient);

    initPool({ poolOverride: mockPool });
    const client = await acquireClient();
    releaseClient(client as never);

    expect(fakeClient.release).toHaveBeenCalledTimes(1);
  });
});

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

describe("PoolExhaustedError", () => {
  it("has code POOL_EXHAUSTED", () => {
    const err = new PoolExhaustedError();
    expect(err.code).toBe("POOL_EXHAUSTED");
    expect(err.name).toBe("PoolExhaustedError");
  });

  it("accepts custom message", () => {
    const err = new PoolExhaustedError("Custom pool message");
    expect(err.message).toBe("Custom pool message");
  });
});

describe("DatabaseError", () => {
  it("captures code and cause", () => {
    const cause = new Error("original");
    const err = new DatabaseError("Query failed", "42P01", cause);
    expect(err.code).toBe("42P01");
    expect(err.cause).toBe(cause);
    expect(err.name).toBe("DatabaseError");
  });
});

// ---------------------------------------------------------------------------
// PoolManager named export
// ---------------------------------------------------------------------------

describe("PoolManager named export", () => {
  it("PoolManager.init is initPool", async () => {
    const { PoolManager } = await import("../db/pool-manager.js");
    expect(PoolManager.init).toBe(initPool);
  });

  it("PoolManager.destroy is destroyPool", async () => {
    const { PoolManager } = await import("../db/pool-manager.js");
    expect(PoolManager.destroy).toBe(destroyPool);
  });

  it("PoolManager.query is the query helper", async () => {
    const { PoolManager } = await import("../db/pool-manager.js");
    expect(PoolManager.query).toBe(query);
  });

  it("PoolManager.execute is the execute helper", async () => {
    const { PoolManager } = await import("../db/pool-manager.js");
    expect(PoolManager.execute).toBe(execute);
  });

  it("PoolManager.healthCheck is the healthCheck helper", async () => {
    const { PoolManager } = await import("../db/pool-manager.js");
    expect(PoolManager.healthCheck).toBe(healthCheck);
  });

  it("PoolManager.PoolExhaustedError is PoolExhaustedError", async () => {
    const { PoolManager } = await import("../db/pool-manager.js");
    expect(PoolManager.PoolExhaustedError).toBe(PoolExhaustedError);
  });

  it("PoolManager.DatabaseError is DatabaseError", async () => {
    const { PoolManager } = await import("../db/pool-manager.js");
    expect(PoolManager.DatabaseError).toBe(DatabaseError);
  });
});
