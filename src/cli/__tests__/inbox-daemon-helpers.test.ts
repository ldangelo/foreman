import { describe, expect, it } from "vitest";

import { fetchDaemonMessages, listDaemonRuns, resolveDaemonRunId } from "../commands/inbox.js";

describe("inbox daemon helper functions", () => {
  it("resolveDaemonRunId prefers explicit run id", async () => {
    const daemon = {
      backend: "node",
      projectId: "proj-1",
      client: { runs: { list: async () => [] } },
    } as any;

    await expect(resolveDaemonRunId(daemon, { run: "run-explicit", task: "task-1" })).resolves.toBe("run-explicit");
  });

  it("resolveDaemonRunId resolves node daemon runs by task id or latest fallback", async () => {
    const daemon = {
      backend: "node",
      projectId: "proj-1",
      client: {
        runs: {
          list: async () => [
            { id: "run-1", bead_id: "task-1" },
            { id: "run-2", bead_id: "task-2" },
          ],
        },
      },
    } as any;

    await expect(resolveDaemonRunId(daemon, { task: "task-2" })).resolves.toBe("run-2");
    await expect(resolveDaemonRunId(daemon, {})).resolves.toBe("run-1");
  });

  it("resolveDaemonRunId resolves Elixir runs by task/bead and latest fallback", async () => {
    const daemon = {
      backend: "elixir",
      projectId: "proj-1",
      client: {
        listRuns: async () => [
          { id: "run-1", run_id: "run-1", project_id: "proj-1", task_id: "task-1" },
          { id: "run-2", run_id: "run-2", project_id: "proj-1", task_id: "task-2" },
          { id: "run-other", run_id: "run-other", project_id: "proj-2", task_id: "task-x" },
        ],
      },
    } as any;

    await expect(resolveDaemonRunId(daemon, { bead: "task-2" })).resolves.toBe("run-2");
    await expect(resolveDaemonRunId(daemon, {})).resolves.toBe("run-1");
  });

  it("fetchDaemonMessages filters unread and agent in node all-run mode", async () => {
    const daemon = {
      backend: "node",
      projectId: "proj-1",
      client: {
        mail: {
          listGlobal: async () => [
            {
              id: "msg-1",
              run_id: "run-1",
              sender_agent_type: "dev",
              recipient_agent_type: "qa",
              subject: "one",
              body: "{}",
              read: 0,
              created_at: "2026-01-01T00:00:00.000Z",
              deleted_at: null,
            },
            {
              id: "msg-2",
              run_id: "run-2",
              sender_agent_type: "dev",
              recipient_agent_type: "foreman",
              subject: "two",
              body: "{}",
              read: 1,
              created_at: "2026-01-01T00:01:00.000Z",
              deleted_at: null,
            },
          ],
        },
      },
    } as any;

    const messages = await fetchDaemonMessages(daemon, { all: true, agent: "qa", unread: true, limit: 50 });
    expect(messages).toHaveLength(1);
    expect(messages[0]?.id).toBe("msg-1");
  });

  it("fetchDaemonMessages uses node run-scoped mail.list and recent message limiting", async () => {
    const daemon = {
      backend: "node",
      projectId: "proj-1",
      client: {
        mail: {
          list: async () => [
            {
              id: "msg-1",
              run_id: "run-1",
              sender_agent_type: "dev",
              recipient_agent_type: "qa",
              subject: "one",
              body: "{}",
              read: 0,
              created_at: "2026-01-01T00:00:00.000Z",
              deleted_at: null,
            },
            {
              id: "msg-2",
              run_id: "run-1",
              sender_agent_type: "dev",
              recipient_agent_type: "qa",
              subject: "two",
              body: "{}",
              read: 0,
              created_at: "2026-01-01T00:01:00.000Z",
              deleted_at: null,
            },
          ],
        },
      },
    } as any;

    const messages = await fetchDaemonMessages(daemon, { runId: "run-1", agent: "qa", unread: false, limit: 1 });
    expect(messages).toHaveLength(1);
    expect(messages[0]?.id).toBe("msg-2");
  });

  it("fetchDaemonMessages adapts Elixir inbox rows and preserves all-run ordering", async () => {
    const daemon = {
      backend: "elixir",
      projectId: "proj-1",
      client: {
        listInbox: async ({ runId, unread }: { runId?: string; unread?: boolean }) => {
          const rows = [
            {
              message_id: "msg-1",
              run_id: "run-1",
              sender_agent_type: "developer",
              recipient_agent_type: "foreman",
              subject: "phase-complete",
              body: { ok: true },
              unread: true,
              created_at: "2026-01-01T00:00:00.000Z",
            },
            {
              message_id: "msg-2",
              run_id: "run-2",
              sender_agent_type: "qa",
              recipient_agent_type: "foreman",
              subject: "agent-error",
              body: "raw-body",
              unread: false,
              created_at: "2026-01-01T00:01:00.000Z",
            },
          ];
          return rows.filter((row) => (runId ? row.run_id === runId : true)).filter((row) => (unread === true ? row.unread === true : true));
        },
      },
    } as any;

    const allMessages = await fetchDaemonMessages(daemon, { all: true, agent: undefined, unread: undefined, limit: 50 });
    expect(allMessages).toHaveLength(2);
    expect(allMessages[0]?.body).toContain('"ok":true');
    expect(allMessages[1]?.read).toBe(1);

    const filtered = await fetchDaemonMessages(daemon, { all: false, runId: "run-1", agent: "foreman", unread: true, limit: 1 });
    expect(filtered).toHaveLength(1);
    expect(filtered[0]?.id).toBe("msg-1");
  });

  it("listDaemonRuns adapts both Elixir and node daemon runs", async () => {
    const elixirDaemon = {
      backend: "elixir",
      projectId: "proj-1",
      client: {
        listRuns: async () => [
          { id: "run-1", run_id: "run-1", project_id: "proj-1", task_id: "task-1", status: "completed", created_at: "2026-01-01T00:00:00.000Z" },
          { id: "run-other", run_id: "run-other", project_id: "proj-2", task_id: "task-x", status: "running", created_at: "2026-01-01T00:00:00.000Z" },
        ],
      },
    } as any;
    const nodeDaemon = {
      backend: "node",
      projectId: "proj-1",
      client: {
        runs: {
          list: async () => [
            {
              id: "run-2",
              bead_id: "task-2",
              status: "success",
              branch: "foreman/task-2",
              queued_at: "2026-01-01T00:00:00.000Z",
              started_at: "2026-01-01T00:00:00.000Z",
              finished_at: "2026-01-01T00:01:00.000Z",
              created_at: "2026-01-01T00:00:00.000Z",
            },
          ],
        },
      },
    } as any;

    const elixirRuns = await listDaemonRuns(elixirDaemon);
    const nodeRuns = await listDaemonRuns(nodeDaemon);

    expect(elixirRuns).toHaveLength(1);
    expect(elixirRuns[0]?.seed_id).toBe("task-1");
    expect(nodeRuns).toHaveLength(1);
    expect(nodeRuns[0]?.seed_id).toBe("task-2");
  });
});
