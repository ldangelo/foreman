import { describe, expect, it } from "vitest";
import { PostgresAdapter } from "../db/postgres-adapter.js";
import { initPool, destroyPool, type PoolLike } from "../db/pool-manager.js";

function makeCapturePool(assertSql: (text: string, params?: unknown[]) => void): PoolLike {
  return {
    query: async (text: string, params?: unknown[]) => {
      assertSql(text, params);
      return { rows: [{ id: "row-1" }] as never, rowCount: 1 };
    },
    connect: async () => ({ release: () => undefined }) as never,
    end: async () => undefined,
    on: () => undefined,
  };
}

describe("PostgresAdapter timestamp source", () => {
  it("stamps pipeline runs at statement time", async () => {
    let sql = "";
    await initPool({ poolOverride: makeCapturePool((text) => { sql = text; }) });
    try {
      const adapter = new PostgresAdapter();
      await adapter.createPipelineRun({
        projectId: "proj-1",
        beadId: "bead-1",
        runNumber: 1,
        branch: "main",
      });
      expect(sql).toContain("queued_at, created_at, updated_at");
      expect(sql).toContain("clock_timestamp(), clock_timestamp(), clock_timestamp()");
    } finally {
      await destroyPool();
    }
  });

  it("stamps agent messages at statement time", async () => {
    let sql = "";
    await initPool({ poolOverride: makeCapturePool((text) => { sql = text; }) });
    try {
      const adapter = new PostgresAdapter();
      await adapter.sendMessage("proj-1", "run-1", "developer", "qa", "subject", "body");
      expect(sql).toContain("INSERT INTO agent_messages");
      expect(sql).toContain("created_at");
      expect(sql).toContain("clock_timestamp()");
    } finally {
      await destroyPool();
    }
  });

  it("stamps pipeline events at statement time", async () => {
    let sql = "";
    await initPool({ poolOverride: makeCapturePool((text) => { sql = text; }) });
    try {
      const adapter = new PostgresAdapter();
      await adapter.recordPipelineEvent({
        projectId: "proj-1",
        runId: "run-1",
        eventType: "run:queued",
      });
      expect(sql).toContain("INSERT INTO events");
      expect(sql).toContain("created_at");
      expect(sql).toContain("clock_timestamp()");
    } finally {
      await destroyPool();
    }
  });

  it("stamps appended messages at statement time", async () => {
    let sql = "";
    await initPool({ poolOverride: makeCapturePool((text) => { sql = text; }) });
    try {
      const adapter = new PostgresAdapter();
      await adapter.appendMessage({
        runId: "run-1",
        stream: "stdout",
        chunk: "hello",
        lineNumber: 1,
      });
      expect(sql).toContain("INSERT INTO messages");
      expect(sql).toContain("created_at");
      expect(sql).toContain("clock_timestamp()");
    } finally {
      await destroyPool();
    }
  });
});
