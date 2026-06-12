/**
 * Unit tests for WatchState.ts
 */

import { describe, it, expect, beforeEach, vi } from "vitest";

const {
  mockListRegisteredProjects,
  mockTasksList,
  mockFetchDaemonDashboardState,
  mockFetchTaskCounts,
  mockProjectStats,
} = vi.hoisted(() => ({
  mockListRegisteredProjects: vi.fn(),
  mockTasksList: vi.fn(),
  mockFetchDaemonDashboardState: vi.fn(),
  mockFetchTaskCounts: vi.fn(),
  mockProjectStats: vi.fn(),
}));

vi.mock("../../project-task-support.js", () => ({
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../../../lib/trpc-client.js", () => ({
  createTrpcClient: () => ({
    tasks: { list: mockTasksList },
    projects: { stats: mockProjectStats },
  }),
}));

vi.mock("../../../dashboard-state.js", () => ({
  fetchDaemonDashboardState: mockFetchDaemonDashboardState,
}));

vi.mock("../../../../lib/task-client-factory.js", () => ({
  fetchTaskCounts: mockFetchTaskCounts,
}));

import {
  initialWatchState,
  nextPanel,
  handleWatchKey,
  pollWatchData,
  type WatchState,
} from "../WatchState.js";
import type { DashboardState } from "../../../dashboard-state.js";
import type { Run, RunProgress } from "../../../../lib/store.js";

describe("WatchState", () => {
  describe("initialWatchState", () => {
    it("returns a valid initial state", () => {
      const state = initialWatchState();
      expect(state.dashboard).toBeNull();
      expect(state.agents).toEqual([]);
      expect(state.board).toBeNull();
      expect(state.inbox).toBeNull();
      expect(state.events).toBeNull();
      expect(state.focusedPanel).toBe("agents");
      expect(state.expandedAgentIndices.size).toBe(0);
      expect(state.selectedTaskIndex).toBe(-1);
      expect(state.showHelp).toBe(false);
      expect(state.errorMessage).toBeNull();
      expect(state.agentsOffline).toBe(false);
      expect(state.boardOffline).toBe(false);
      expect(state.inboxOffline).toBe(false);
      expect(state.eventsOffline).toBe(false);
    });
  });

  describe("nextPanel", () => {
    it("cycles agents → board → inbox → events → agents", () => {
      expect(nextPanel("agents")).toBe("board");
      expect(nextPanel("board")).toBe("inbox");
      expect(nextPanel("inbox")).toBe("events");
      expect(nextPanel("events")).toBe("agents");
    });
  });

  describe("handleWatchKey", () => {
    let state: WatchState;

    beforeEach(() => {
      state = initialWatchState();
      state.agents = [];
      state.board = null;
    });

    it("quits on q", () => {
      const result = handleWatchKey(state, "q");
      expect(result.quit).toBe(true);
      expect(result.none).toBe(false);
    });

    it("quits on Q", () => {
      const result = handleWatchKey(state, "Q");
      expect(result.quit).toBe(true);
    });

    it("quits on ESC", () => {
      const result = handleWatchKey(state, "\u001B");
      expect(result.quit).toBe(true);
    });

    it("toggles help on ?", () => {
      expect(state.showHelp).toBe(false);
      let result = handleWatchKey(state, "?");
      expect(result.render).toBe(true);
      expect(state.showHelp).toBe(true);
      result = handleWatchKey(state, "?");
      expect(result.render).toBe(true);
      expect(state.showHelp).toBe(false);
    });

    it("cycles focus on Tab", () => {
      expect(state.focusedPanel).toBe("agents");
      let result = handleWatchKey(state, "\t");
      expect(result.render).toBe(true);
      expect(state.focusedPanel).toBe("board");

      result = handleWatchKey(state, "\t");
      expect(result.render).toBe(true);
      expect(state.focusedPanel).toBe("inbox");

      result = handleWatchKey(state, "\t");
      expect(result.render).toBe(true);
      expect(state.focusedPanel).toBe("events");

      result = handleWatchKey(state, "\t");
      expect(result.render).toBe(true);
      expect(state.focusedPanel).toBe("agents");
    });

    it("returns none for unrecognized keys", () => {
      const result = handleWatchKey(state, "z");
      expect(result.none).toBe(true);
      expect(result.quit).toBe(false);
      expect(result.render).toBe(false);
    });

    it("sets board focus on Tab in agents panel", () => {
      state.focusedPanel = "agents";
      const result = handleWatchKey(state, "\t");
      expect(result.render).toBe(true);
      expect(state.focusedPanel).toBe("board");
    });
  });

  describe("pollWatchData", () => {
    beforeEach(() => {
      mockListRegisteredProjects.mockReset();
      mockTasksList.mockReset();
      mockFetchDaemonDashboardState.mockReset();
      mockFetchTaskCounts.mockReset();
      mockProjectStats.mockReset();

      mockListRegisteredProjects.mockResolvedValue([
        { id: "proj-1", name: "foreman", path: "/tmp/project" },
      ]);
      mockFetchDaemonDashboardState.mockResolvedValue(null);
      mockFetchTaskCounts.mockResolvedValue({
        total: 7,
        ready: 1,
        inProgress: 0,
        completed: 1,
        blocked: 4,
      });
    });

    it("routes failed, stuck, conflict, blocked, and review rows to needs_attention counts", async () => {
      mockTasksList.mockResolvedValue([
        { id: "t-ready", title: "Ready", status: "ready", priority: 3 },
        { id: "t-failed", title: "Failed", status: "failed", priority: 2 },
        { id: "t-stuck", title: "Stuck", status: "stuck", priority: 1 },
        { id: "t-conflict", title: "Conflict", status: "conflict", priority: 0 },
        { id: "t-blocked", title: "Blocked", status: "blocked", priority: 4 },
        { id: "t-review", title: "Review", status: "review", priority: 2 },
        { id: "t-merged", title: "Merged", status: "merged", priority: 2 },
      ]);

      const result = await pollWatchData("/tmp/project");

      expect(result.board.counts).toEqual({
        backlog: 0,
        ready: 1,
        in_progress: 0,
        needs_attention: 5,
        closed: 1,
      });
      expect(result.board.total).toBe(7);
      expect(result.board.ready).toBe(1);
      expect(result.board.needsAttention.map((task) => task.id)).toEqual([
        "t-conflict",
        "t-stuck",
        "t-failed",
        "t-review",
        "t-blocked",
      ]);
      expect(result.taskCounts).toEqual({
        total: 7,
        ready: 1,
        inProgress: 0,
        completed: 1,
        blocked: 4,
      });
    });

    it("normalizes hyphenated statuses before routing", async () => {
      mockTasksList.mockResolvedValue([
        { id: "t-working", title: "Working", status: "in-progress", priority: 2 },
        { id: "t-needs", title: "Needs Attention", status: "needs-attention", priority: 1 },
        { id: "t-unknown", title: "Unknown", status: "waiting-on-user", priority: 3 },
      ]);

      const result = await pollWatchData("/tmp/project");

      expect(result.board.counts.in_progress).toBe(1);
      expect(result.board.counts.needs_attention).toBe(1);
      expect(result.board.counts.closed).toBe(1);
      expect(result.board.needsAttention).toEqual([]);
    });

    it("returns an empty board when the project is not registered", async () => {
      mockListRegisteredProjects.mockResolvedValue([
        { id: "other", name: "other", path: "/tmp/other" },
      ]);
      mockTasksList.mockResolvedValue([
        { id: "t-ready", title: "Ready", status: "ready", priority: 3 },
      ]);

      const result = await pollWatchData("/tmp/project");

      expect(result.board).toEqual({
        counts: {
          backlog: 0,
          ready: 0,
          in_progress: 0,
          needs_attention: 0,
          closed: 0,
        },
        total: 0,
        ready: 0,
        needsAttention: [],
      });
      expect(mockTasksList).not.toHaveBeenCalled();
    });

    it("returns an empty board when registered project lookup fails", async () => {
      mockListRegisteredProjects.mockRejectedValue(new Error("daemon unavailable"));

      const result = await pollWatchData("/tmp/project");

      expect(result.board.total).toBe(0);
      expect(result.board.needsAttention).toEqual([]);
      expect(mockTasksList).not.toHaveBeenCalled();
    });

    it("populates agents and task counts from dashboard data", async () => {
      const run: Run = {
        id: "run-1",
        project_id: "proj-1",
        seed_id: "seed-1",
        agent_type: "developer",
        session_key: null,
        worktree_path: "/tmp/worktree",
        status: "running",
        started_at: "2026-01-01T00:00:00.000Z",
        completed_at: null,
        created_at: "2026-01-01T00:00:00.000Z",
        progress: null,
      };
      const progress: RunProgress = {
        toolCalls: 2,
        toolBreakdown: { read: 1, edit: 1 },
        filesChanged: ["src/file.ts"],
        turns: 3,
        costUsd: 0.05,
        tokensIn: 100,
        tokensOut: 50,
        lastToolCall: "edit",
        lastActivity: "2026-01-01T00:01:00.000Z",
      };
      const dashboard: DashboardState = {
        projects: [{
          id: "proj-1",
          name: "foreman",
          path: "/tmp/project",
          status: "active",
          created_at: "2026-01-01T00:00:00.000Z",
          updated_at: "2026-01-01T00:00:00.000Z",
        }],
        activeRuns: new Map([["proj-1", [run]]]),
        completedRuns: new Map(),
        progresses: new Map([["run-1", progress]]),
        metrics: new Map(),
        events: new Map(),
        lastUpdated: new Date("2026-01-01T00:02:00.000Z"),
      };
      mockFetchDaemonDashboardState.mockResolvedValue(dashboard);
      mockTasksList.mockResolvedValue([]);
      mockProjectStats.mockResolvedValue({
        tasks: { total: 9, ready: 2, inProgress: 3, merged: 1, closed: 2, backlog: 1 },
      });

      const result = await pollWatchData("/tmp/project");

      expect(result.dashboard).toBe(dashboard);
      expect(result.agents).toEqual([{ run, progress }]);
      expect(result.taskCounts).toEqual({
        total: 9,
        ready: 2,
        inProgress: 3,
        completed: 3,
        blocked: 1,
      });
      expect(mockFetchTaskCounts).not.toHaveBeenCalled();
    });
  });
});
