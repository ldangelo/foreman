import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockEnsureCliPostgresPool,
  mockListRegisteredProjects,
  MockPostgresAdapter,
} = vi.hoisted(() => ({
  mockEnsureCliPostgresPool: vi.fn(),
  mockListRegisteredProjects: vi.fn(),
  MockPostgresAdapter: vi.fn(function MockPostgresAdapterImpl() {
    return {
      listPipelineEventsForRun: vi.fn(),
      listProjectPipelineEvents: vi.fn(),
    };
  }),
}));

vi.mock("../commands/project-task-support.js", () => ({
  listRegisteredProjects: (...args: unknown[]) => mockListRegisteredProjects(...args),
  resolveRepoRootProjectPath: vi.fn(),
  requireProjectOrAllInMultiMode: vi.fn(),
  ensureCliPostgresPool: (...args: unknown[]) => mockEnsureCliPostgresPool(...args),
}));

vi.mock("../../lib/db/postgres-adapter.js", () => ({
  PostgresAdapter: MockPostgresAdapter,
}));

import {
  fetchDaemonEvents,
  fetchPostgresEvents,
  formatEventSummary,
  formatPipelineEvent,
  formatPipelineEventTableRow,
  renderPipelineEventsTable,
  renderPipelineEventsTableRows,
  renderEventDetail,
  resolvePostgresInboxProject,
  selectUnseenEvents,
  sortEventsChronologically,
} from "../commands/inbox.js";

describe("inbox event helpers", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("resolvePostgresInboxProject matches by normalized path or selector", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "proj", path: "/repo/." },
      { id: "proj-2", name: "other", path: "/other" },
    ]);

    const byPath = await resolvePostgresInboxProject("/repo");
    const byName = await resolvePostgresInboxProject("/nope", "other");
    const byId = await resolvePostgresInboxProject("/nope", "proj-2");
    const missing = await resolvePostgresInboxProject("/missing");

    expect(mockEnsureCliPostgresPool).not.toHaveBeenCalled();
    expect(byPath?.projectId).toBe("proj-1");
    expect(byName?.projectId).toBe("proj-2");
    expect(byId?.projectId).toBe("proj-2");
    expect(missing).toBeNull();
  });

  it("fetchPostgresEvents supports run-specific, project-wide, and empty modes", async () => {
    const adapter = {
      listPipelineEventsForRun: vi.fn().mockResolvedValue([
        { id: "evt-1", run_id: "run-1", event_type: "fail", payload: JSON.stringify({ taskId: "task-1" }), created_at: "2026-01-01T00:00:00.000Z" },
      ]),
      listProjectPipelineEvents: vi.fn().mockResolvedValue([
        { id: "evt-2", run_id: null, event_type: "dispatch", payload: { task_id: "task-2" }, created_at: new Date("2026-01-01T00:01:00.000Z") },
      ]),
    } as any;

    const byRun = await fetchPostgresEvents(adapter, "proj-1", { runId: "run-1", limit: 10 });
    const byProject = await fetchPostgresEvents(adapter, "proj-1", { all: true, limit: 10 });
    const empty = await fetchPostgresEvents(adapter, "proj-1", { limit: 10 });

    expect(adapter.listPipelineEventsForRun).toHaveBeenCalledWith("run-1", 10);
    expect(adapter.listProjectPipelineEvents).toHaveBeenCalledWith("proj-1", 10);
    expect(byRun[0]).toMatchObject({ eventType: "fail", details: { taskId: "task-1" } });
    expect(byProject[0]).toMatchObject({ eventType: "dispatch", details: { task_id: "task-2" } });
    expect(empty).toEqual([]);
  });

  it.each([
    ["phase-start", {}, "phase-start"],
    ["phase-start", { phase: "developer" }, "Start: developer"],
    ["phase-complete", { phase: "qa" }, "Complete: qa"],
    ["dispatch", {}, "Dispatch"],
    ["complete", {}, "Complete"],
    ["fail", {}, "Failed"],
    ["merge", {}, "Merged"],
    ["pr-created", {}, "PR created"],
    ["merge-queue-fallback", { task_id: "bd-1" }, "merge-queue-fallback: bd-1"],
    ["merge-cleanup-fallback", {}, "merge-cleanup-fallback"],
    ["conflict", { task_id: "bd-2" }, "conflict: bd-2"],
    ["test-fail", {}, "test-fail"],
    ["stuck", {}, "Stuck"],
    ["custom", { taskId: "task-1" }, "custom: task-1"],
    ["custom", {}, "custom"],
    ["anything", null, "anything"],
  ])("formatEventSummary covers %s fallback branches", (eventType, details, expected) => {
    expect(formatEventSummary(eventType, details as Record<string, unknown> | null)).toBe(expected);
  });

  it("renders live event rows without repeating the table header", () => {
    const output = renderPipelineEventsTableRows([
      { id: "evt-1", runId: "run-1", eventType: "WorkerHeartbeat", createdAt: "2026-01-01T00:00:00.000Z", details: { task_id: "task-1", phase_id: "qa" } },
    ] as any);

    expect(output).toContain("task-1");
    expect(output).toContain("WorkerHeartbeat");
    expect(output).not.toContain("TIME");
    expect(output).not.toContain("────");
  });

  it("formats Elixir domain events with useful task, run, and phase context", () => {
    expect(formatEventSummary("TaskUpdated", { task_id: "foreman-1", status: "in_progress", run_id: "run-1" }))
      .toBe("Updated task foreman-1 → in_progress (run run-1)");
    expect(formatEventSummary("PhaseStarted", { task_id: "foreman-1", phase_id: "developer", run_id: "run-1" }))
      .toBe("Start developer for task foreman-1");
    expect(formatEventSummary("WorkerLaunchRequested", { task_id: "foreman-1", workflow: "bug" }))
      .toBe("Worker launch requested for task foreman-1 (bug)");
    expect(formatEventSummary("PhaseCompleted", { task_id: "foreman-1", phase_id: "qa", status: "completed" }))
      .toBe("Complete qa for task foreman-1 → completed");
    expect(formatEventSummary("PhaseRetried", { task_id: "foreman-1", phase_id: "qa", retryTarget: "developer", attempt: 1, maxRetries: 2, reason: "FAIL verdict" }))
      .toBe("Retry qa via developer (1/2) for task foreman-1: FAIL verdict");
    expect(formatEventSummary("PhaseSkipped", { task_id: "foreman-1", phase_id: "developer", reason: "retryOnly" }))
      .toBe("Skipped developer for task foreman-1: retryOnly");
    expect(formatEventSummary("PhaseVerdict", { task_id: "foreman-1", phase_id: "qa", verdict: "fail" }))
      .toBe("qa verdict: fail for task foreman-1");
    expect(formatEventSummary("PhaseReportProduced", { task_id: "foreman-1", phase_id: "qa", outcome: "retry", verdict: "FAIL", retryTarget: "developer" }))
      .toBe("Report qa for task foreman-1 → retry (FAIL); steer developer");
    const formatted = formatPipelineEvent({ id: "evt-1", runId: "run-1", taskId: "foreman-1", eventType: "RunFailed", details: { phase_id: "qa" }, createdAt: "2026-01-01T00:00:00.000Z" });
    expect(formatted).toContain("] foreman-1 ✗ RunFailed");
    expect(formatted).toContain("RunFailed — Failed task foreman-1 at qa");
    const report = formatPipelineEvent({ id: "evt-2", runId: "run-1", taskId: "foreman-1", eventType: "PhaseReportProduced", details: { phase_id: "qa", outcome: "retry", retryTarget: "developer" }, createdAt: "2026-01-01T00:00:01.000Z" });
    expect(report).toContain("☰ PhaseReportProduced");
    expect(report).toContain("Report qa for task foreman-1 → retry; steer developer");
  });

  it("renders pipeline events as an operator-friendly table", () => {
    const events = [
      {
        id: "evt-2",
        runId: "run-1",
        taskId: "foreman-1",
        projectId: "proj-1",
        eventType: "PhaseCompleted",
        details: { phase_id: "qa", turns: 12, status: "completed" },
        createdAt: "2026-01-01T00:02:00.000Z",
      },
      {
        id: "evt-1",
        runId: "run-1",
        taskId: "foreman-1",
        projectId: "proj-1",
        eventType: "PhaseStarted",
        details: { phase_id: "qa" },
        createdAt: "2026-01-01T00:01:00.000Z",
      },
      {
        id: "evt-3",
        runId: "run-1",
        taskId: "foreman-1",
        projectId: "proj-1",
        eventType: "RunFailed",
        details: { phase_id: "qa", reason: "bad" },
        createdAt: "2026-01-01T00:03:00.000Z",
      },
    ];

    expect(formatPipelineEventTableRow(events[0] as any)).toMatchObject({
      task: "foreman-1",
      phase: "qa",
      turns: "12",
      project: "proj-1",
      event: "stop",
    });
    const table = renderPipelineEventsTable(events as any, 60);
    expect(table).toContain("TIME");
    expect(table).toContain("TASK");
    expect(table).toContain("PHASE");
    expect(table).toContain("TURNS");
    expect(table).toContain("PROJECT");
    expect(table).toContain("EVENT");
    expect(table).toContain("MESSAGE");
    expect(table.indexOf("Start qa")).toBeLessThan(table.indexOf("Complete qa"));
    expect(table).toContain("error");
  });

  it("falls back to event.projectId when details is null", () => {
    const event = {
      id: "evt-1",
      runId: "run-1",
      taskId: "foreman-1",
      projectId: "proj-1",
      eventType: "RunStarted",
      details: null,
      createdAt: "2026-01-01T00:01:00.000Z",
    };

    const typedEvent: Parameters<typeof formatPipelineEventTableRow>[0] = event;
    const row = formatPipelineEventTableRow(typedEvent);
    expect(row.project).toBe("proj-1");
  });

  it("renders event detail with structured JSON payload", () => {
    const event = {
      id: "evt-1",
      runId: "run-1",
      taskId: "foreman-1",
      projectId: "proj-1",
      eventType: "PhaseStarted",
      details: { phase_id: "developer", turns: 5, status: "running" },
      createdAt: "2026-01-01T00:01:00.000Z",
    };

    const detail = renderEventDetail(event as any);
    expect(detail).toContain("EVENT DETAIL");
    expect(detail).toContain("id:");
    expect(detail).toContain("runId:");
    expect(detail).toContain("taskId:");
    expect(detail).toContain("projectId:");
    expect(detail).toContain("type:");
    expect(detail).toContain("createdAt:");
    expect(detail).toContain("PAYLOAD:");
    expect(detail).toContain("phase_id");
    expect(detail).toContain("developer");
  });

  it("renders event detail without payload when details are null", () => {
    const event = {
      id: "evt-1",
      runId: "run-1",
      taskId: "foreman-1",
      eventType: "RunStarted",
      details: null,
      createdAt: "2026-01-01T00:01:00.000Z",
    };

    const detail = renderEventDetail(event as any);
    expect(detail).toContain("EVENT DETAIL");
    expect(detail).toContain("No payload details available");
  });

  it("sortEventsChronologically returns a new oldest-to-newest array", () => {
    const events = [
      { id: "evt-3", runId: "run-1", eventType: "TaskUpdated", details: null, createdAt: "2026-01-01T00:03:00.000Z" },
      { id: "evt-1", runId: "run-1", eventType: "TaskCreated", details: null, createdAt: "2026-01-01T00:01:00.000Z" },
      { id: "evt-2", runId: "run-1", eventType: "RunStarted", details: null, createdAt: "2026-01-01T00:02:00.000Z" },
    ];

    expect(sortEventsChronologically(events).map((event) => event.id)).toEqual(["evt-1", "evt-2", "evt-3"]);
    expect(events.map((event) => event.id)).toEqual(["evt-3", "evt-1", "evt-2"]);
  });

  it("selectUnseenEvents returns chronological events that watch mode has not printed", () => {
    const seen = new Set(["evt-1"]);
    const events = [
      { id: "evt-3", runId: "run-1", eventType: "TaskUpdated", details: null, createdAt: "2026-01-01T00:03:00.000Z" },
      { id: "evt-1", runId: "run-1", eventType: "TaskCreated", details: null, createdAt: "2026-01-01T00:01:00.000Z" },
      { id: "evt-2", runId: "run-1", eventType: "RunStarted", details: null, createdAt: "2026-01-01T00:02:00.000Z" },
    ];

    expect(selectUnseenEvents(events, seen).map((event) => event.id)).toEqual(["evt-2", "evt-3"]);
  });

  it("fetchDaemonEvents maps Elixir fallback event fields", async () => {
    const daemon = {
      backend: "elixir",
      projectId: "proj-1",
      client: {
        listEvents: vi.fn().mockResolvedValue([
          { run_id: null, type: "custom", payload: null, created_at: "2026-01-01T00:00:00.000Z" },
          { run_id: "run-1", payload: "not-json", occurred_at: "2026-01-01T00:01:00.000Z" },
        ]),
      },
    } as any;

    const events = await fetchDaemonEvents(daemon, { all: true, limit: 10 });

    expect(events).toEqual([
      expect.objectContaining({ id: "run-1-event", runId: "run-1", eventType: "event", details: null, createdAt: "2026-01-01T00:01:00.000Z" }),
      expect.objectContaining({ id: "run-custom", runId: null, eventType: "custom", details: null, createdAt: "2026-01-01T00:00:00.000Z" }),
    ]);
  });

  it("normalizes mixed live event timestamps before ordering newest first", async () => {
    const dateTimeLike = { toISO: () => "2026-01-01T00:02:00.000Z" };
    const daemon = {
      backend: "elixir",
      projectId: "proj-1",
      client: {
        listEvents: vi.fn().mockResolvedValue([
          { event_id: "evt-datetime", run_id: "run-1", event_type: "PhaseStarted", payload: { task_id: "task-1" }, occurred_at: dateTimeLike },
          { event_id: "evt-created-at", run_id: "run-1", event_type: "PhaseCompleted", payload: { task_id: "task-1" }, created_at: "2026-01-01T00:03:00.000Z" },
          { event_id: "evt-string", run_id: "run-1", event_type: "RunStarted", payload: { task_id: "task-1" }, occurred_at: "2026-01-01T00:01:00.000Z" },
        ]),
      },
    } as unknown as Parameters<typeof fetchDaemonEvents>[0]; // Test double implements the Elixir event method this helper consumes.

    const events = await fetchDaemonEvents(daemon, { all: true, limit: 10 });

    expect(events.map((event) => event.id)).toEqual(["evt-created-at", "evt-datetime", "evt-string"]);
    expect(events.map((event) => event.createdAt)).toEqual([
      "2026-01-01T00:03:00.000Z",
      "2026-01-01T00:02:00.000Z",
      "2026-01-01T00:01:00.000Z",
    ]);
  });

  it("fetchDaemonEvents supports Elixir all/run filtering and node all/run filtering", async () => {
    const elixirDaemon = {
      backend: "elixir",
      projectId: "proj-1",
      client: {
        listEvents: vi.fn().mockImplementation(async ({ runId }: { runId?: string }) => {
          const rows = [
            { event_id: "evt-1", run_id: "run-1", event_type: "dispatch", payload: { task_id: "task-1" }, occurred_at: "2026-01-01T00:00:00.000Z" },
            { event_id: "evt-2", run_id: "run-2", event_type: "fail", payload: { taskId: "task-2" }, occurred_at: "2026-01-01T00:02:00.000Z" },
          ];
          return rows.filter((row) => (runId ? row.run_id === runId : true));
        }),
      },
    } as any;
    const nodeDaemon = {
      backend: "node",
      projectId: "proj-1",
      client: {
        runs: {
          list: vi.fn().mockResolvedValue([
            { id: "run-1" },
            { id: "run-2" },
          ]),
          listEvents: vi.fn()
            .mockResolvedValueOnce([
              { id: "evt-1", run_id: "run-1", event_type: "dispatch", details: JSON.stringify({ task_id: "task-1" }), created_at: "2026-01-01T00:00:00.000Z" },
            ])
            .mockResolvedValueOnce([
              { id: "evt-2", run_id: "run-2", event_type: "fail", details: JSON.stringify({ taskId: "task-2" }), created_at: "2026-01-01T00:02:00.000Z" },
            ])
            .mockResolvedValueOnce([
              { id: "evt-3", run_id: "run-2", event_type: "phase-complete", details: JSON.stringify({ phase: "developer" }), created_at: "2026-01-01T00:03:00.000Z" },
            ]),
        },
      },
    } as any;

    const elixirAll = await fetchDaemonEvents(elixirDaemon, { all: true, limit: 1 });
    const elixirRun = await fetchDaemonEvents(elixirDaemon, { runId: "run-1", limit: 10 });
    const nodeAll = await fetchDaemonEvents(nodeDaemon, { all: true, limit: 2 });
    const nodeRun = await fetchDaemonEvents(nodeDaemon, { runId: "run-2", limit: 10 });
    const nodeEmpty = await fetchDaemonEvents(nodeDaemon, { limit: 10 });

    expect(elixirDaemon.client.listEvents).toHaveBeenCalledWith({ projectId: "proj-1", runId: undefined, limit: 1000 });
    expect(elixirAll).toHaveLength(1);
    expect(elixirAll[0]?.eventType).toBe("fail");
    expect(elixirRun[0]?.runId).toBe("run-1");
    expect(nodeDaemon.client.runs.list).toHaveBeenCalledWith({ projectId: "proj-1", limit: 100 });
    expect(nodeAll).toHaveLength(2);
    expect(nodeAll[0]?.eventType).toBe("fail");
    expect(nodeRun[0]?.eventType).toBe("phase-complete");
    expect(nodeEmpty).toEqual([]);
  });
});
