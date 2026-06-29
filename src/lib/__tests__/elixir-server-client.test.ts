import { afterEach, describe, expect, it, vi } from "vitest";
import { ElixirServerClient } from "../elixir-server-client.js";

afterEach(() => {
  vi.restoreAllMocks();
});

describe("ElixirServerClient", () => {
  it("posts authenticated command envelopes to the Elixir server", async () => {
    const fetchMock = vi.fn(async (_url: URL, _init: RequestInit) =>
      new Response(
        JSON.stringify({ ok: true, events: ["event-1"], projection_version: 1, correlation_id: "corr-1" }),
        { status: 202, headers: { "content-type": "application/json" } },
      ),
    );
    vi.stubGlobal("fetch", fetchMock);

    const client = new ElixirServerClient("http://127.0.0.1:4000", "secret");
    const result = await client.sendCommand({
      command_id: "cmd-1",
      command_type: "task.create",
      payload: { task_id: "task-1" },
      metadata: { correlation_id: "corr-1" },
    });

    expect(result).toEqual({ ok: true, events: ["event-1"], projection_version: 1, correlation_id: "corr-1" });
    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, init] = fetchMock.mock.calls[0] as [URL, RequestInit];
    expect(url.toString()).toBe("http://127.0.0.1:4000/api/v1/commands");
    expect(init.method).toBe("POST");
    expect(init.headers).toMatchObject({
      authorization: "Bearer secret",
      "content-type": "application/json",
      "x-correlation-id": "corr-1",
    });
    expect(JSON.parse(init.body as string)).toMatchObject({
      command_id: "cmd-1",
      command_type: "task.create",
      schema_version: 1,
      payload: { task_id: "task-1" },
      metadata: { correlation_id: "corr-1" },
    });
  });

  it("reads authenticated project and task projections", async () => {
    const fetchMock = vi.fn(async (url: URL, _init: RequestInit) => {
      const body = url.pathname.endsWith("/projects")
        ? { ok: true, projects: [{ project_id: "p1", path: "/repo" }] }
        : { ok: true, tasks: [{ task_id: "t1", project_id: "p1", title: "Task" }] };
      return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
    });
    vi.stubGlobal("fetch", fetchMock);

    const client = new ElixirServerClient("http://127.0.0.1:4000", "secret");
    await expect(client.listProjects()).resolves.toEqual([{ project_id: "p1", path: "/repo" }]);
    await expect(client.listTasks()).resolves.toEqual([{ task_id: "t1", project_id: "p1", title: "Task" }]);
    expect(fetchMock).toHaveBeenCalledWith(expect.any(URL), expect.objectContaining({
      method: "GET",
      headers: expect.objectContaining({ authorization: "Bearer secret" }),
    }));
  });

  it("sends run archive and purge commands", async () => {
    const fetchMock = vi.fn(async (_url: URL, _init: RequestInit) =>
      new Response(
        JSON.stringify({ ok: true, events: ["event-1"], projection_version: 1, correlation_id: "corr-1" }),
        { status: 202, headers: { "content-type": "application/json" } },
      ),
    );
    vi.stubGlobal("fetch", fetchMock);

    const client = new ElixirServerClient("http://127.0.0.1:4000", "secret");
    await expect(client.archiveRun("run-1", "stale")).resolves.toMatchObject({ ok: true });
    await expect(client.purgeRun("run-2", "stale")).resolves.toMatchObject({ ok: true });

    const archiveBody = JSON.parse((fetchMock.mock.calls[0]![1] as RequestInit).body as string);
    const purgeBody = JSON.parse((fetchMock.mock.calls[1]![1] as RequestInit).body as string);
    expect(archiveBody).toMatchObject({ command_type: "run.archive", payload: { run_id: "run-1", reason: "stale" } });
    expect(purgeBody).toMatchObject({ command_type: "run.purge", payload: { run_id: "run-2", reason: "stale" } });
  });

  it("reads run attach requests from the Elixir server", async () => {
    const fetchMock = vi.fn(async () =>
      new Response(
        JSON.stringify({ ok: true, attach: { status: "ready", run_id: "run-1", session_id: "sess-1" } }),
        { status: 200, headers: { "content-type": "application/json" } },
      ),
    );
    vi.stubGlobal("fetch", fetchMock);

    const client = new ElixirServerClient("http://127.0.0.1:4000", "secret");
    await expect(client.getRunAttach("run-1", "worker-1")).resolves.toMatchObject({
      status: "ready",
      session_id: "sess-1",
    });
    const [url, init] = fetchMock.mock.calls[0] as unknown as [URL, RequestInit];
    expect(url.toString()).toBe("http://127.0.0.1:4000/api/v1/runs/run-1/attach?worker_id=worker-1");
    expect(init.headers).toMatchObject({ authorization: "Bearer secret" });
  });

  it("returns server error envelopes without throwing", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(
          JSON.stringify({
            ok: false,
            error: { code: "UNAUTHORIZED", message: "nope", details: {}, retryable: false },
          }),
          { status: 401, headers: { "content-type": "application/json" } },
        ),
      ),
    );

    const client = new ElixirServerClient("http://127.0.0.1:4000");
    await expect(client.sendCommand({ command_id: "cmd-1", command_type: "task.create" })).resolves.toMatchObject({
      ok: false,
      error: { code: "UNAUTHORIZED" },
    });
  });
});
