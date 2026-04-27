import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { PostgresStore } from "../postgres-store.js";
import type { PostgresAdapter } from "../db/postgres-adapter.js";

describe("PostgresStore event parity", () => {
  const recordPipelineEvent = vi.fn().mockResolvedValue({ id: "event-1" });
  const adapter = { recordPipelineEvent } as unknown as PostgresAdapter;

  beforeEach(() => {
    recordPipelineEvent.mockClear();
  });

  it("passes phase-start and heartbeat through the Postgres event path", async () => {
    const store = new PostgresStore("proj-123", adapter);

    await store.logEvent("proj-123", "phase-start", {
      seedId: "seed-456",
      phase: "developer",
      runId: "run-789",
    }, "run-789");

    await store.logEvent("proj-123", "heartbeat", {
      seedId: "seed-456",
      phase: "developer",
      runId: "run-789",
    }, "run-789");

    expect(recordPipelineEvent).toHaveBeenNthCalledWith(1, {
      projectId: "proj-123",
      runId: "run-789",
      taskId: "seed-456",
      eventType: "phase-start",
      payload: {
        seedId: "seed-456",
        phase: "developer",
        runId: "run-789",
      },
    });

    expect(recordPipelineEvent).toHaveBeenNthCalledWith(2, {
      projectId: "proj-123",
      runId: "run-789",
      taskId: "seed-456",
      eventType: "heartbeat",
      payload: {
        seedId: "seed-456",
        phase: "developer",
        runId: "run-789",
      },
    });
  });

  it("keeps the registered observability migration check aligned", () => {
    const migrationPath = fileURLToPath(
      new URL("../db/migrations/00000000000011-expand-registered-observability-event-types.ts", import.meta.url),
    );
    const migration = readFileSync(migrationPath, "utf8");

    expect(migration).toContain("'phase-start'");
    expect(migration).toContain("'heartbeat'");
  });
});
