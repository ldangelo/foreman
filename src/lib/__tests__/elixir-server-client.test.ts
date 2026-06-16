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
