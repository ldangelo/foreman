import { describe, expect, it, vi } from "vitest";

import { fetchPostgresMessages, resolvePostgresRunId } from "../commands/inbox.js";

describe("inbox Postgres helper functions", () => {
  it("resolvePostgresRunId prefers explicit run ids", async () => {
    const adapter = { listRuns: vi.fn() } as any;
    await expect(resolvePostgresRunId(adapter, "proj-1", { run: "run-explicit", task: "task-1" })).resolves.toBe("run-explicit");
    expect(adapter.listRuns).not.toHaveBeenCalled();
  });

  it("resolvePostgresRunId resolves latest and task/task selectors", async () => {
    const adapter = {
      listRuns: vi.fn().mockResolvedValue([
        { id: "run-2", task_id: "task-2" },
        { id: "run-1", task_id: "task-1" },
      ]),
    } as any;

    await expect(resolvePostgresRunId(adapter, "proj-1", { task: "task-1" })).resolves.toBe("run-1");
    await expect(resolvePostgresRunId(adapter, "proj-1", { task: "task-2" })).resolves.toBe("run-2");
    await expect(resolvePostgresRunId(adapter, "proj-1", {})).resolves.toBe("run-2");
  });

  it("fetchPostgresMessages filters all-run rows by agent and unread", async () => {
    const adapter = {
      getAllMessagesGlobal: vi.fn().mockResolvedValue([
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
      ]),
    } as any;

    const messages = await fetchPostgresMessages(adapter, "proj-1", { all: true, agent: "qa", unread: true, limit: 50 });
    expect(messages).toHaveLength(1);
    expect(messages[0]?.id).toBe("msg-1");
  });

  it("fetchPostgresMessages returns [] when no runId is provided for single-run mode", async () => {
    const adapter = {
      getMessages: vi.fn(),
      getAllMessages: vi.fn(),
    } as any;

    await expect(fetchPostgresMessages(adapter, "proj-1", { agent: "qa", unread: false, limit: 10 })).resolves.toEqual([]);
    expect(adapter.getMessages).not.toHaveBeenCalled();
    expect(adapter.getAllMessages).not.toHaveBeenCalled();
  });

  it("fetchPostgresMessages uses agent-scoped getMessages with recent selection", async () => {
    const adapter = {
      getMessages: vi.fn().mockResolvedValue([
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
      ]),
    } as any;

    const messages = await fetchPostgresMessages(adapter, "proj-1", { runId: "run-1", agent: "qa", unread: false, limit: 1 });
    expect(adapter.getMessages).toHaveBeenCalledWith("proj-1", "run-1", "qa", false);
    expect(messages).toHaveLength(1);
    expect(messages[0]?.id).toBe("msg-2");
  });

  it("fetchPostgresMessages uses getAllMessages and local unread filtering without agent", async () => {
    const adapter = {
      getAllMessages: vi.fn().mockResolvedValue([
        {
          id: "msg-1",
          run_id: "run-1",
          sender_agent_type: "dev",
          recipient_agent_type: "qa",
          subject: "one",
          body: "{}",
          read: 1,
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
      ]),
    } as any;

    const messages = await fetchPostgresMessages(adapter, "proj-1", { runId: "run-1", unread: true, limit: 10 });
    expect(adapter.getAllMessages).toHaveBeenCalledWith("run-1");
    expect(messages).toHaveLength(1);
    expect(messages[0]?.id).toBe("msg-2");
  });
});
