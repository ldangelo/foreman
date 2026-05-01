import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { Run, BeadWriteEntry } from "../../lib/store.js";

const { mockExecFileSync } = vi.hoisted(() => ({
  mockExecFileSync: vi.fn(),
}));

vi.mock("node:child_process", async () => {
  const actual = await vi.importActual<typeof import("node:child_process")>("node:child_process");
  return {
    ...actual,
    execFileSync: mockExecFileSync,
  };
});

import { Dispatcher } from "../dispatcher.js";

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "bd-123",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/wt",
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    base_branch: null,
    ...overrides,
  };
}

function makeEntry(operation: BeadWriteEntry["operation"], payload: Record<string, unknown>): BeadWriteEntry {
  return {
    id: "1",
    sender: "agent-worker",
    operation,
    payload: JSON.stringify(payload),
    created_at: new Date().toISOString(),
    processed_at: null,
  };
}

describe("Dispatcher bead writer terminal-success safety", () => {
  afterEach(() => {
    mockExecFileSync.mockReset();
  });

  it("skips mark-failed for a seed whose latest run is already merged", async () => {
    const projectPath = await mkdtemp(join(tmpdir(), "foreman-dispatcher-bead-writer-"));
    await mkdir(join(projectPath, ".beads"), { recursive: true });

    try {
      const store = {
        getPendingBeadWrites: vi.fn(() => [makeEntry("mark-failed", { seedId: "bd-123" })]),
        markBeadWriteProcessed: vi.fn(),
        getProjectByPath: vi.fn(() => ({ id: "proj-1" })),
        getRunsForSeed: vi.fn(() => [makeRun({ status: "merged" })]),
      } as any;

      const dispatcher = new Dispatcher({} as any, store, projectPath, null);
      await dispatcher.drainBeadWriterInbox();

      expect(mockExecFileSync).not.toHaveBeenCalledWith(
        expect.any(String),
        expect.arrayContaining(["update", "bd-123", "--status", "failed"]),
        expect.anything(),
      );
      expect(store.markBeadWriteProcessed).toHaveBeenCalledWith("1");
    } finally {
      await rm(projectPath, { recursive: true, force: true });
    }
  });

  it("still allows close-seed after terminal success", async () => {
    const projectPath = await mkdtemp(join(tmpdir(), "foreman-dispatcher-bead-writer-"));
    await mkdir(join(projectPath, ".beads"), { recursive: true });

    try {
      const store = {
        getPendingBeadWrites: vi.fn(() => [makeEntry("close-seed", { seedId: "bd-123" })]),
        markBeadWriteProcessed: vi.fn(),
        getProjectByPath: vi.fn(() => ({ id: "proj-1" })),
        getRunsForSeed: vi.fn(() => [makeRun({ status: "merged" })]),
      } as any;

      const dispatcher = new Dispatcher({} as any, store, projectPath, null);
      await dispatcher.drainBeadWriterInbox();

      expect(mockExecFileSync).toHaveBeenCalledWith(
        expect.any(String),
        expect.arrayContaining(["close", "bd-123", "--no-db"]),
        expect.anything(),
      );
    } finally {
      await rm(projectPath, { recursive: true, force: true });
    }
  });
});
