/**
 * Unit tests for WatchState.ts
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

const {
  mockListRegisteredProjects,
  mockTasksList,
  mockFetchDaemonDashboardState,
  mockFetchTaskCounts,
  mockProjectStats,
  mockCreateTrpcClient,
  mockEnsureRunning,
  mockElixirListTasks,
  mockElixirListInbox,
  mockElixirListEvents,
  mockRunsListMessages,
  mockRunsListEvents,
} = vi.hoisted(() => ({
  mockListRegisteredProjects: vi.fn(),
  mockTasksList: vi.fn(),
  mockFetchDaemonDashboardState: vi.fn(),
  mockFetchTaskCounts: vi.fn(),
  mockProjectStats: vi.fn(),
  mockCreateTrpcClient: vi.fn(),
  mockEnsureRunning: vi.fn(),
  mockElixirListTasks: vi.fn(),
  mockElixirListInbox: vi.fn(),
  mockElixirListEvents: vi.fn(),
  mockRunsListMessages: vi.fn(),
  mockRunsListEvents: vi.fn(),
}));

vi.mock("../../project-task-support.js", () => ({
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

vi.mock("../../../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return { ensureRunning: mockEnsureRunning };
  }),
}));

vi.mock("../../../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn().mockImplementation(function MockElixirServerClient() {
    return {
      listTasks: mockElixirListTasks,
      listInbox: mockElixirListInbox,
      listEvents: mockElixirListEvents,
    };
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
  pollInboxData,
  pollPipelineEvents,
  pollWatchData,
  renderHelpOverlay,
  type WatchState,
} from "../WatchState.js";
import type { DashboardState } from "../../../dashboard-state.js";
import type { Run, RunProgress } from "../../../../lib/store.js";

describe("WatchState", () => {
  beforeEach(() => {
    process.env.FOREMAN_BACKEND = "node";
  });

  afterEach(() => {
    delete process.env.FOREMAN_BACKEND;
  });
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

    it("toggles expanded agents with number keys and expand-all", () => {
      state.agents = [{ run: { id: "run-1" } }, { run: { id: "run-2" } }] as any;

      let result = handleWatchKey(state, "a");
      expect(result.render).toBe(true);
      expect([...state.expandedAgentIndices]).toEqual([0, 1]);

      result = handleWatchKey(state, "1");
      expect(result.render).toBe(true);
      expect(state.expandedAgentIndices.has(0)).toBe(false);
      expect(state.expandedAgentIndices.has(1)).toBe(true);

      result = handleWatchKey(state, "a");
      expect(result.render).toBe(true);
      expect(state.expandedAgentIndices.size).toBe(0);
    });

    it("navigates board selection and returns wake actions for approve/retry", () => {
      state.focusedPanel = "board";
      state.agents = [{ run: { id: "run-1" } }] as any;
      state.board = {
        counts: { backlog: 0, ready: 0, in_progress: 0, needs_attention: 2, closed: 0 },
        total: 2,
        ready: 0,
        needsAttention: [{ id: "task-1" }, { id: "task-2" }],
      } as any;
      state.selectedTaskIndex = 0;

      let result = handleWatchKey(state, "j");
      expect(result.render).toBe(true);
      expect(state.selectedTaskIndex).toBe(1);

      result = handleWatchKey(state, "k");
      expect(result.render).toBe(true);
      expect(state.selectedTaskIndex).toBe(0);

      result = handleWatchKey(state, "a");
      expect(result.wake).toBe(true);
      expect(result.render).toBe(true);

      result = handleWatchKey(state, "r");
      expect(result.wake).toBe(true);
      expect(result.render).toBe(true);
    });

    it("cycles inbox focus onward to events on Tab", () => {
      state.focusedPanel = "inbox";
      const result = handleWatchKey(state, "\t");
      expect(result.render).toBe(true);
      expect(state.focusedPanel).toBe("events");
    });
  });

  describe("pollInboxData", () => {
    it("loads local-store inbox messages sorted newest-first and marks only a new head entry", async () => {
      const store = {
        getAllMessages: vi.fn((runId: string) => runId === "run-1"
          ? [
              { id: "msg-1", run_id: "run-1", sender_agent_type: "developer", recipient_agent_type: "foreman", subject: "older", body: "{}", read: 0, created_at: "2026-01-01T00:00:00.000Z", deleted_at: null },
              { id: "msg-2", run_id: "run-1", sender_agent_type: "qa", recipient_agent_type: "foreman", subject: "newer", body: "{}", read: 0, created_at: "2026-01-01T00:01:00.000Z", deleted_at: null },
            ]
          : []),
      } as any;

      const result = await pollInboxData(store, "msg-1", 5, ["run-1"]);

      expect(result.totalCount).toBe(2);
      expect(result.newestId).toBe("msg-2");
      expect(result.messages.map((entry) => entry.message.id)).toEqual(["msg-2", "msg-1"]);
      expect(result.messages.map((entry) => entry.isNew)).toEqual([true, false]);
    });

    it("loads Elixir inbox messages without using tRPC in Elixir mode", async () => {
      process.env.FOREMAN_BACKEND = "elixir";
      mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
      mockListRegisteredProjects.mockResolvedValue([
        { id: "proj-1", name: "foreman", path: "/tmp/project" },
      ]);
      mockElixirListInbox.mockResolvedValue([
        { message_id: "msg-1", run_id: "run-1", sender: "developer", recipient: "foreman", subject: "phase-complete", body: { ok: true }, unread: true, created_at: "2026-01-01T00:01:00.000Z" },
        { message_id: "msg-2", run_id: "run-2", sender_agent_type: "qa", recipient_agent_type: "foreman", subject: "ignored", body: "{}", unread: false, created_at: "2026-01-01T00:00:00.000Z" },
      ]);

      const result = await pollInboxData({ getAllMessages: vi.fn() } as any, null, 5, ["run-1"], "/tmp/project");

      expect(mockCreateTrpcClient).not.toHaveBeenCalled();
      expect(result.totalCount).toBe(1);
      expect(result.messages[0]?.message.id).toBe("msg-1");
      expect(result.messages[0]?.message.body).toBe('{"ok":true}');
      expect(result.messages[0]?.message.read).toBe(0);
      delete process.env.FOREMAN_BACKEND;
    });
  });

  describe("pollPipelineEvents", () => {
    it("loads local-store pipeline events sorted newest-first and marks only a new head entry", async () => {
      const store = {
        getRunEvents: vi.fn((runId: string) => runId === "run-1"
          ? [
              { id: "evt-1", run_id: "run-1", event_type: "dispatch", details: JSON.stringify({ bead_id: "task-1" }), created_at: "2026-01-01T00:00:00.000Z" },
              { id: "evt-2", run_id: "run-1", event_type: "fail", details: JSON.stringify({ seedId: "task-1" }), created_at: "2026-01-01T00:01:00.000Z" },
            ]
          : []),
      } as any;

      const result = await pollPipelineEvents(store, "evt-1", 5, ["run-1"]);

      expect(result.totalCount).toBe(2);
      expect(result.newestId).toBe("evt-2");
      expect(result.events.map((entry) => entry.id)).toEqual(["evt-2", "evt-1"]);
      expect(result.events.map((entry) => entry.isNew)).toEqual([true, false]);
    });

    it("loads Elixir pipeline events without using tRPC in Elixir mode", async () => {
      process.env.FOREMAN_BACKEND = "elixir";
      mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
      mockListRegisteredProjects.mockResolvedValue([
        { id: "proj-1", name: "foreman", path: "/tmp/project" },
      ]);
      mockElixirListEvents.mockResolvedValue([
        { event_id: "evt-1", run_id: "run-1", event_type: "phase-complete", payload: { phase: "developer" }, occurred_at: "2026-01-01T00:01:00.000Z" },
        { event_id: "evt-2", run_id: "run-2", event_type: "dispatch", payload: { bead_id: "task-2" }, occurred_at: "2026-01-01T00:00:00.000Z" },
      ]);

      const result = await pollPipelineEvents({ getRunEvents: vi.fn() } as any, null, 5, ["run-1"], "/tmp/project");

      expect(mockCreateTrpcClient).not.toHaveBeenCalled();
      expect(result.totalCount).toBe(1);
      expect(result.events[0]).toMatchObject({ id: "evt-1", eventType: "phase-complete", runId: "run-1", details: { phase: "developer" } });
      delete process.env.FOREMAN_BACKEND;
    });
  });

  describe("renderHelpOverlay", () => {
    it("renders watch help text", () => {
      const rendered = renderHelpOverlay(120);
      expect(rendered).toContain("HELP");
      expect(rendered).toContain("Cycle focus");
      expect(rendered).toContain("Open full board");
    });
  });

  describe("pollWatchData", () => {
    beforeEach(() => {
      mockListRegisteredProjects.mockReset();
      mockTasksList.mockReset();
      mockFetchDaemonDashboardState.mockReset();
      mockFetchTaskCounts.mockReset();
      mockProjectStats.mockReset();
      mockCreateTrpcClient.mockClear();
      mockElixirListTasks.mockReset();

      mockCreateTrpcClient.mockReturnValue({
        tasks: { list: mockTasksList },
        projects: { stats: mockProjectStats },
        runs: {
          listMessages: mockRunsListMessages,
          listEvents: mockRunsListEvents,
        },
      });
       mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
+      mockElixirListInbox.mockResolvedValue([]);
+      mockElixirListEvents.mockResolvedValue([]);
+      mockRunsListMessages.mockResolvedValue([]);
+      mockRunsListEvents.mockResolvedValue([]);
      mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
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

    it("loads board/task counts from Elixir without creating a tRPC client in Elixir mode", async () => {
      process.env.FOREMAN_BACKEND = "elixir";
      mockFetchDaemonDashboardState.mockResolvedValue({
        projects: [{
          id: "proj-1",
          name: "foreman",
          path: "/tmp/project",
          status: "active",
          created_at: "2026-01-01T00:00:00.000Z",
          updated_at: "2026-01-01T00:00:00.000Z",
        }],
        activeRuns: new Map(),
        completedRuns: new Map(),
        progresses: new Map(),
        metrics: new Map(),
        events: new Map(),
        lastUpdated: new Date("2026-01-01T00:02:00.000Z"),
      });
      mockElixirListTasks.mockResolvedValue([
        { task_id: "t-ready", project_id: "proj-1", status: "ready", priority: 2, title: "Ready" },
        { task_id: "t-failed", project_id: "proj-1", status: "failed", priority: 1, title: "Failed" },
        { task_id: "t-merged", project_id: "proj-1", status: "merged", priority: 3, title: "Merged" },
      ]);

      const result = await pollWatchData("/tmp/project");

      expect(mockCreateTrpcClient).not.toHaveBeenCalled();
      expect(result.board.counts).toEqual({
        backlog: 0,
        ready: 1,
        in_progress: 0,
        needs_attention: 1,
        closed: 1,
      });
      expect(result.taskCounts).toEqual({
        total: 3,
        ready: 1,
        inProgress: 0,
        completed: 1,
        blocked: 1,
      });
      delete process.env.FOREMAN_BACKEND;
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
