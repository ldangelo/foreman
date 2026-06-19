import { describe, expect, it } from "vitest";
import { PostgresAdapter } from "../db/postgres-adapter.js";
import { initPool, destroyPool, type PoolLike } from "../db/pool-manager.js";

const PROJECT_ID = "proj-test123";

function makeMockPool(): PoolLike {
  return {
    query: async (text: string, params?: unknown[]) => {
      expect(text).toContain("INSERT INTO rate_limit_events");
      expect(params).toEqual([
        PROJECT_ID,
        "run-1",
        "developer",
        "qa",
        "rate limit hit",
        42,
      ]);
      return { rows: [], rowCount: 1 };
    },
    connect: async () => ({ release: () => undefined }) as never,
    end: async () => undefined,
    on: () => undefined,
  };
}

describe("PostgresAdapter rate-limit telemetry", () => {
  it("inserts the registered worker telemetry shape", async () => {
    await initPool({ poolOverride: makeMockPool() });
    try {
      const adapter = new PostgresAdapter();
      await adapter.logRateLimitEvent(PROJECT_ID, "run-1", "developer", "qa", "rate limit hit", 42);
    } finally {
      await destroyPool();
    }
  });
});
