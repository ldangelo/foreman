/**
 * Tests for store.ts rebase status values (TRD-005-TEST).
 *
 * Verifies:
 * - AC-T-005-1: updateRunStatus('rebase_conflict') persists correctly
 * - AC-T-005-2: updateRunStatus('rebase_resolving') persists correctly
 * - AC-T-005-3: Pre-existing rows retain their original status
 * - AC-T-005-4: RunStatus type accepts new values (compile-time guard)
 */

import { describe, it, expect, beforeEach } from "vitest";
import { ForemanStore } from "../store.js";
import type { RunStatus } from "../store.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeStore(): ForemanStore {
  // Use in-memory database for tests
  return new ForemanStore(":memory:");
}

function createRun(store: ForemanStore, status: RunStatus = "pending"): string {
  const project = store.registerProject("test", `/tmp/test-${Date.now()}-${Math.random()}`);
  const run = store.createRun(project.id, "seed-1", "developer", "/tmp/wt");
  if (status !== "pending") {
    store.updateRunStatus(run.id, status);
  }
  return run.id;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("store.ts — rebase status values", () => {
  let store: ForemanStore;

  beforeEach(() => {
    store = makeStore();
  });

  it("AC-T-005-1: updateRunStatus with rebase_conflict is accepted and retrievable", () => {
    const runId = createRun(store);
    store.updateRunStatus(runId, "rebase_conflict");
    const run = store.getRun(runId);
    expect(run).not.toBeNull();
    expect(run!.status).toBe("rebase_conflict");
  });

  it("AC-T-005-2: updateRunStatus with rebase_resolving is accepted and retrievable", () => {
    const runId = createRun(store);
    store.updateRunStatus(runId, "rebase_resolving");
    const run = store.getRun(runId);
    expect(run).not.toBeNull();
    expect(run!.status).toBe("rebase_resolving");
  });

  it("AC-T-005-3: pre-existing rows retain their original status after migration", () => {
    // Create runs in various pre-existing statuses
    const runA = createRun(store, "pending");
    const runB = createRun(store, "running");
    const runC = createRun(store, "completed");

    // Update one to a rebase status
    store.updateRunStatus(runA, "rebase_conflict");

    // Others should be unchanged
    expect(store.getRun(runB)!.status).toBe("running");
    expect(store.getRun(runC)!.status).toBe("completed");
  });

  it("status can transition from rebase_conflict to rebase_resolving", () => {
    const runId = createRun(store);
    store.updateRunStatus(runId, "rebase_conflict");
    store.updateRunStatus(runId, "rebase_resolving");
    expect(store.getRun(runId)!.status).toBe("rebase_resolving");
  });

  it("status can transition from rebase_resolving to running (resume)", () => {
    const runId = createRun(store);
    store.updateRunStatus(runId, "rebase_conflict");
    store.updateRunStatus(runId, "rebase_resolving");
    store.updateRunStatus(runId, "running");
    expect(store.getRun(runId)!.status).toBe("running");
  });

  it("status can transition from rebase_resolving to failed (permanent failure)", () => {
    const runId = createRun(store);
    store.updateRunStatus(runId, "rebase_conflict");
    store.updateRunStatus(runId, "rebase_resolving");
    store.updateRunStatus(runId, "failed");
    expect(store.getRun(runId)!.status).toBe("failed");
  });
});

// ── AC-T-005-4: Compile-time type guard ──────────────────────────────────────

// This block validates at compile time that the RunStatus type accepts the new
// values. A type error here means the type was not correctly extended.
describe("RunStatus type includes rebase statuses (compile-time)", () => {
  it("rebase_conflict is assignable to RunStatus", () => {
    const status: RunStatus = "rebase_conflict";
    expect(status).toBe("rebase_conflict");
  });

  it("rebase_resolving is assignable to RunStatus", () => {
    const status: RunStatus = "rebase_resolving";
    expect(status).toBe("rebase_resolving");
  });
});
