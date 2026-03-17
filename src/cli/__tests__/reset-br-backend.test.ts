/**
 * Tests for reset.ts with BeadsRustClient (br) backend.
 *
 * Covers TRD-008: Update reset.ts to use BeadsRustClient when
 * FOREMAN_TASK_BACKEND=br.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  detectAndFixMismatches,
} from "../commands/reset.js";
import type { IShowUpdateClient } from "../commands/reset.js";
import type { ForemanStore, Run } from "../../lib/store.js";
import type { BrIssueDetail } from "../../lib/beads-rust.js";
import type { UpdateOptions } from "../../lib/task-client.js";

// ── Helpers ─────────────────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "bd-abc",
    agent_type: "claude-sonnet-4-6",
    session_key: null,
    worktree_path: "/tmp/wt",
    status: "completed",
    started_at: new Date().toISOString(),
    completed_at: new Date().toISOString(),
    created_at: new Date().toISOString(),
    progress: null,
    tmux_session: null,
    ...overrides,
  };
}

function makeBrDetail(status: string): BrIssueDetail {
  return {
    id: "bd-abc",
    title: "Some task",
    type: "task",
    priority: "2",
    status,
    assignee: null,
    parent: null,
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-01-01T00:00:00.000Z",
    description: null,
    labels: [],
    estimate_minutes: null,
    dependencies: [],
    children: [],
  };
}

// Type alias for the store pick used by detectAndFixMismatches.
type StoreMock = Pick<ForemanStore, "getRunsByStatus" | "getActiveRuns">;

function makeBrMocks() {
  const storeFn = vi.fn((_status: string, _projectId?: string): Run[] => []);
  const activeRunsFn = vi.fn((_projectId?: string): Run[] => []);
  // Cast the mock store to satisfy StoreMock for the function under test.
  // The vi.fn signature is compatible at runtime; the cast is needed because
  // vi.fn wraps the function in a Mock type.
  const store = {
    getRunsByStatus: storeFn,
    getActiveRuns: activeRunsFn,
  } as unknown as StoreMock & {
    getRunsByStatus: typeof storeFn;
    getActiveRuns: typeof activeRunsFn;
  };
  const brClient = {
    show: vi.fn(async (_id: string): Promise<BrIssueDetail> => makeBrDetail("in_progress")),
    update: vi.fn(async (_id: string, _opts: UpdateOptions): Promise<void> => {}),
  };
  return { store, brClient };
}

// ── detectAndFixMismatches with BeadsRustClient ──────────────────────────

describe("detectAndFixMismatches — br backend (BeadsRustClient)", () => {
  it("detects mismatch when completed run has br issue still in_progress", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    brClient.show.mockResolvedValue(makeBrDetail("in_progress"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(result.mismatches).toHaveLength(1);
    expect(result.mismatches[0]).toMatchObject({
      seedId: "bd-abc",
      runId: "run-1",
      runStatus: "completed",
      actualSeedStatus: "in_progress",
      expectedSeedStatus: "closed",
    });
  });

  it("calls brClient.update to fix a mismatch", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    brClient.show.mockResolvedValue(makeBrDetail("in_progress"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(brClient.update).toHaveBeenCalledWith("bd-abc", { status: "closed" });
    expect(result.fixed).toBe(1);
  });

  it("does not call brClient.update in dry-run mode", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    brClient.show.mockResolvedValue(makeBrDetail("in_progress"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
      { dryRun: true },
    );

    expect(brClient.update).not.toHaveBeenCalled();
    expect(result.fixed).toBe(0);
    expect(result.mismatches).toHaveLength(1);
  });

  it("reports no mismatch when br issue status already matches expected", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    brClient.show.mockResolvedValue(makeBrDetail("closed"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(result.mismatches).toHaveLength(0);
    expect(brClient.update).not.toHaveBeenCalled();
  });

  it("silently skips br issues that are not found", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-missing", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    brClient.show.mockRejectedValue(new Error("Issue not found: bd-missing"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(result.mismatches).toHaveLength(0);
    expect(result.errors).toHaveLength(0);
  });

  it("records error when brClient.show fails with unexpected error", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    brClient.show.mockRejectedValue(new Error("Database connection lost"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("bd-abc");
  });

  it("records error when brClient.update fails, does not count as fixed", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    brClient.show.mockResolvedValue(makeBrDetail("in_progress"));
    brClient.update.mockRejectedValue(new Error("br update failed: permission denied"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(result.mismatches).toHaveLength(1);
    expect(result.fixed).toBe(0);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("bd-abc");
  });

  it("skips br issues already in the resetSeedIds set", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-already-reset", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(["bd-already-reset"]),
    );

    expect(brClient.show).not.toHaveBeenCalled();
    expect(result.mismatches).toHaveLength(0);
  });

  it("handles merged run with br issue in_progress", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "merged" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "merged" ? [run] : [],
    );
    brClient.show.mockResolvedValue(makeBrDetail("in_progress"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(result.mismatches).toHaveLength(1);
    expect(result.mismatches[0].expectedSeedStatus).toBe("closed");
    expect(brClient.update).toHaveBeenCalledWith("bd-abc", { status: "closed" });
  });
});

// ── resetCommand uses br backend when FOREMAN_TASK_BACKEND=br ────────────

describe("reset command — backend selection via getTaskBackend()", () => {
  let originalEnv: string | undefined;

  beforeEach(() => {
    originalEnv = process.env.FOREMAN_TASK_BACKEND;
  });

  afterEach(() => {
    if (originalEnv === undefined) {
      delete process.env.FOREMAN_TASK_BACKEND;
    } else {
      process.env.FOREMAN_TASK_BACKEND = originalEnv;
    }
  });

  it("getTaskBackend() returns 'br' when FOREMAN_TASK_BACKEND=br", async () => {
    process.env.FOREMAN_TASK_BACKEND = "br";
    const { getTaskBackend } = await import("../../lib/feature-flags.js");
    expect(getTaskBackend()).toBe("br");
  });

  // TRD-023: default changed from 'sd' to 'br'
  it("getTaskBackend() returns 'br' when FOREMAN_TASK_BACKEND is unset", async () => {
    delete process.env.FOREMAN_TASK_BACKEND;
    const { getTaskBackend } = await import("../../lib/feature-flags.js");
    expect(getTaskBackend()).toBe("br");
  });

});
