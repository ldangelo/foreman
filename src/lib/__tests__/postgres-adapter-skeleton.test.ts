/**
 * TRD-003-TEST | Verifies: TRD-003 | Tests: PostgresAdapter throws "not implemented" on all methods
 * PRD: docs/PRD/PRD-2026-010-multi-project-orchestrator.md
 * TRD: docs/TRD/TRD-2026-011-multi-project-orchestrator.md#trd-003
 */

import { describe, it, expect } from "vitest";
import { PostgresAdapter } from "../db/postgres-adapter.js";

const PROJECT_ID = "proj-test123";

const adapter = new PostgresAdapter();

const NOT_IMPLEMENTED = "not implemented";

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
// Project operations
// ---------------------------------------------------------------------------

describe("PostgresAdapter project operations", () => {
  it("createProject throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.createProject({ name: "test", path: "/tmp" }),
      "createProject"
    );
  });

  it("listProjects throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.listProjects(),
      "listProjects"
    );
  });

  it("getProject throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.getProject(PROJECT_ID),
      "getProject"
    );
  });

  it("updateProject throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.updateProject(PROJECT_ID, { name: "newname" }),
      "updateProject"
    );
  });

  it("removeProject throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.removeProject(PROJECT_ID),
      "removeProject"
    );
  });

  it("syncProject throws 'not implemented'", async () => {
    await assertNotImplemented(
      () => adapter.syncProject(PROJECT_ID),
      "syncProject"
    );
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
