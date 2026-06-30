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
  resolvePostgresInboxProject,
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

    expect(mockEnsureCliPostgresPool).toHaveBeenCalledWith("/repo");
    expect(byPath?.projectId).toBe("proj-1");
    expect(byName?.projectId).toBe("proj-2");
    expect(byId?.projectId).toBe("proj-2");
    expect(missing).toBeNull();
  });

  it("fetchPostgresEvents supports run-specific, project-wide, and empty modes", async () => {
    const adapter = {
      listPipelineEventsForRun: vi.fn().mockResolvedValue([
        { id: "evt-1", run_id: "run-1", event_type: "fail", payload: JSON.stringify({ seedId: "task-1" }), created_at: "2026-01-01T00:00:00.000Z" },
      ]),
      listProjectPipelineEvents: vi.fn().mockResolvedValue([
        { id: "evt-2", run_id: null, event_type: "dispatch", payload: { bead_id: "task-2" }, created_at: new Date("2026-01-01T00:01:00.000Z") },
      ]),
    } as any;

    const byRun = await fetchPostgresEvents(adapter, "proj-1", { runId: "run-1", limit: 10 });
    const byProject = await fetchPostgresEvents(adapter, "proj-1", { all: true, limit: 10 });
    const empty = await fetchPostgresEvents(adapter, "proj-1", { limit: 10 });

    expect(adapter.listPipelineEventsForRun).toHaveBeenCalledWith("run-1", 10);
    expect(adapter.listProjectPipelineEvents).toHaveBeenCalledWith("proj-1", 10);
    expect(byRun[0]).toMatchObject({ eventType: "fail", details: { seedId: "task-1" } });
    expect(byProject[0]).toMatchObject({ eventType: "dispatch", details: { bead_id: "task-2" } });
    expect(empty).toEqual([]);
  });

  it("fetchDaemonEvents supports Elixir all/run filtering and node all/run filtering", async () => {
    const elixirDaemon = {
      backend: "elixir",
      projectId: "proj-1",
      client: {
        listEvents: vi.fn().mockImplementation(async ({ runId }: { runId?: string }) => {
          const rows = [
            { event_id: "evt-1", run_id: "run-1", event_type: "dispatch", payload: { bead_id: "task-1" }, occurred_at: "2026-01-01T00:00:00.000Z" },
            { event_id: "evt-2", run_id: "run-2", event_type: "fail", payload: { seedId: "task-2" }, occurred_at: "2026-01-01T00:02:00.000Z" },
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
              { id: "evt-1", run_id: "run-1", event_type: "dispatch", details: JSON.stringify({ bead_id: "task-1" }), created_at: "2026-01-01T00:00:00.000Z" },
            ])
            .mockResolvedValueOnce([
              { id: "evt-2", run_id: "run-2", event_type: "fail", details: JSON.stringify({ seedId: "task-2" }), created_at: "2026-01-01T00:02:00.000Z" },
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
