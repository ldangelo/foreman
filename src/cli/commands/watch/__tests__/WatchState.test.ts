/**
 * Unit tests for WatchState.ts
 */

import { describe, it, expect, beforeEach, vi } from "vitest";

const {
  mockListRegisteredProjects,
  mockTasksList,
  mockFetchDaemonDashboardState,
  mockFetchTaskCounts,
} = vi.hoisted(() => ({
  mockListRegisteredProjects: vi.fn(),
  mockTasksList: vi.fn(),
  mockFetchDaemonDashboardState: vi.fn(),
  mockFetchTaskCounts: vi.fn(),
}));

vi.mock("../../project-task-support.js", () => ({
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../../../lib/trpc-client.js", () => ({
  createTrpcClient: () => ({
    tasks: { list: mockTasksList },
    projects: { stats: vi.fn() },
  }),
}));

vi.mock("../../dashboard.js", () => ({
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
  type PanelId,
} from "../WatchState.js";

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

    it("routes failed, stuck, conflict, and blocked rows to needs_attention counts", async () => {
      mockTasksList.mockResolvedValue([
        { id: "t-ready", title: "Ready", status: "ready", priority: 3 },
        { id: "t-failed", title: "Failed", status: "failed", priority: 2 },
        { id: "t-stuck", title: "Stuck", status: "stuck", priority: 1 },
        { id: "t-conflict", title: "Conflict", status: "conflict", priority: 0 },
        { id: "t-blocked", title: "Blocked", status: "blocked", priority: 4 },
        { id: "t-merged", title: "Merged", status: "merged", priority: 2 },
      ]);

      const result = await pollWatchData("/tmp/project");

      expect(result.board.counts.ready).toBe(1);
      expect(result.board.counts.needs_attention).toBe(4);
      expect(result.board.counts.closed).toBe(1);
      expect(result.board.needsAttention.map((task) => task.id)).toEqual([
        "t-conflict",
        "t-stuck",
        "t-failed",
        "t-blocked",
      ]);
    });
  });
});
