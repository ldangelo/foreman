import { afterEach, describe, expect, it, vi } from "vitest";

import { ElixirServerClient, type ForemanServerCommand } from "../elixir-server-client.js";

const originalFetch = globalThis.fetch;
const fetchMock = vi.fn();

function mockJsonResponse(status: number, body: unknown): void {
  fetchMock.mockResolvedValueOnce({
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as Response);
}

afterEach(() => {
  fetchMock.mockReset();
  globalThis.fetch = originalFetch;
});

describe("ElixirServerClient", () => {
  it("sends commands with auth, default envelopes, and correlation headers", async () => {
    globalThis.fetch = fetchMock;
    mockJsonResponse(200, { ok: true, events: ["evt-1"], projection_version: 3, correlation_id: "corr-1" });
    const client = new ElixirServerClient("http://server.test", "token-1");
    const command: ForemanServerCommand = {
      command_id: "cmd-1",
      command_type: "task.create",
      payload: { title: "Do it" },
      metadata: { correlation_id: "corr-1" },
    };

    await expect(client.sendCommand(command)).resolves.toMatchObject({ ok: true, events: ["evt-1"] });

    expect(fetchMock).toHaveBeenCalledWith(new URL("/api/v1/commands", "http://server.test"), {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer token-1",
        "x-correlation-id": "corr-1",
      },
      body: JSON.stringify({ schema_version: 1, payload: { title: "Do it" }, metadata: { correlation_id: "corr-1" }, ...command }),
    });
  });

  it("keeps structured command errors and wraps unexpected HTTP statuses", async () => {
    globalThis.fetch = fetchMock;
    const command = { command_id: "cmd-2", command_type: "task.close", metadata: { correlation_id: "corr-2" } };
    const structuredError = {
      ok: false,
      error: { code: "VALIDATION_FAILED", message: "bad task", details: {}, retryable: false, correlation_id: "corr-2" },
    } as const;
    mockJsonResponse(400, structuredError);
    mockJsonResponse(500, { ok: true, events: [], projection_version: 0, correlation_id: "corr-2" });
    const client = new ElixirServerClient("http://server.test");

    await expect(client.sendCommand(command)).resolves.toEqual(structuredError);
    await expect(client.sendCommand(command)).resolves.toMatchObject({
      ok: false,
      error: { code: "INTERNAL", message: "unexpected Foreman server status 500", correlation_id: "corr-2" },
    });
  });

  it("reads project, task, run, inbox, event, log, report, debug, and scheduler projections", async () => {
    globalThis.fetch = fetchMock;
    mockJsonResponse(200, { ok: true, projects: [{ id: "proj-1", path: "/repo" }] });
    mockJsonResponse(200, { ok: true, tasks: [{ id: "task-1", title: "Task" }] });
    mockJsonResponse(200, { ok: true, task: { id: "task-1" } });
    mockJsonResponse(200, { ok: true, runs: [{ id: "run-1" }] });
    mockJsonResponse(200, { ok: true, scheduler: { launched: 1 } });
    mockJsonResponse(200, { ok: true, inbox: [{ message_id: "msg-1" }] });
    mockJsonResponse(200, { ok: true, events: [{ event_id: "evt-1" }] });
    mockJsonResponse(200, { ok: true, logs: [{ line: "hello" }] });
    mockJsonResponse(200, { ok: true, report: { verdict: "PASS" } });
    mockJsonResponse(200, { ok: true, debug: { phases: [] } });
    const client = new ElixirServerClient("http://server.test");

    await expect(client.listProjects()).resolves.toEqual([{ id: "proj-1", path: "/repo" }]);
    await expect(client.listTasks()).resolves.toEqual([{ id: "task-1", title: "Task" }]);
    await expect(client.getTask("task/1")).resolves.toEqual({ id: "task-1" });
    await expect(client.listRuns({ projectId: "proj-1" })).resolves.toEqual([{ id: "run-1" }]);
    await expect(client.schedulerTick()).resolves.toEqual({ launched: 1 });
    await expect(client.listInbox({ runId: "run-1", projectId: "proj-1", limit: 5, unread: true })).resolves.toEqual([{ message_id: "msg-1" }]);
    await expect(client.listEvents({ runId: "run-1", projectId: "proj-1", limit: 10 })).resolves.toEqual([{ event_id: "evt-1" }]);
    await expect(client.getRunLogs("run/1", "raw")).resolves.toEqual([{ line: "hello" }]);
    await expect(client.getRunReport("run/1")).resolves.toEqual({ verdict: "PASS" });
    await expect(client.getDebugTimeline("run/1")).resolves.toEqual({ phases: [] });

    const urls = fetchMock.mock.calls.map((call) => String(call[0]));
    expect(urls).toContain("http://server.test/api/v1/tasks/task%2F1");
    expect(urls).toContain("http://server.test/api/v1/runs?project_id=proj-1");
    expect(urls).toContain("http://server.test/api/v1/inbox?run_id=run-1&project_id=proj-1&limit=5&unread=true");
    expect(urls).toContain("http://server.test/api/v1/runs/run%2F1/logs?view=raw");
  });

  it("returns null for missing tasks and throws server error messages for failed reads", async () => {
    globalThis.fetch = fetchMock;
    const errorBody = { ok: false, error: { code: "INTERNAL", message: "boom", details: {}, retryable: false } };
    mockJsonResponse(404, errorBody);
    mockJsonResponse(500, errorBody);
    mockJsonResponse(500, errorBody);
    const client = new ElixirServerClient("http://server.test");

    await expect(client.getTask("missing")).resolves.toBeNull();
    await expect(client.getTask("bad")).rejects.toThrow("boom");
    await expect(client.listProjects()).rejects.toThrow("boom");
  });
});
