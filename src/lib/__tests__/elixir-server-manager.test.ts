import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ElixirServerManager } from "../elixir-server-manager.js";

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  delete process.env.FOREMAN_SERVER_AUTH_TOKEN;
});

describe("ElixirServerManager", () => {
  it("reports stopped status when no pid file exists", () => {
    const tmp = mkdtempSync(join(tmpdir(), "foreman-elixir-manager-"));
    try {
      const manager = new ElixirServerManager({ port: 4901, pidPath: join(tmp, "server.pid") });
      expect(manager.status()).toMatchObject({ running: false, url: "http://127.0.0.1:4901" });
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it("checks /api/v1/health on the configured port", async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ ok: true, active_projects: [] }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const manager = new ElixirServerManager({ port: 4902 });
    await expect(manager.health()).resolves.toEqual({ ok: true, body: { ok: true, active_projects: [] } });
    const calls = fetchMock.mock.calls as unknown as [[URL]];
    expect(String(calls[0][0])).toBe("http://127.0.0.1:4902/api/v1/health");
  });

  it("checks /api/v1/doctor on the configured port without auth when no token is configured", async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ ok: true, doctor: { ok: true } }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const manager = new ElixirServerManager({ port: 4903 });
    await expect(manager.doctor()).resolves.toEqual({ ok: true, body: { ok: true, doctor: { ok: true } } });
    const calls = fetchMock.mock.calls as unknown as [[URL, RequestInit | undefined]];
    expect(String(calls[0][0])).toBe("http://127.0.0.1:4903/api/v1/doctor");
    expect(calls[0][1]).toBeUndefined();
  });

  it("sends bearer auth for protected reads when token is configured", async () => {
    process.env.FOREMAN_SERVER_AUTH_TOKEN = "manager-secret";
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ ok: true }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const manager = new ElixirServerManager({ port: 4904 });
    await expect(manager.doctor()).resolves.toEqual({ ok: true, body: { ok: true } });
    await expect(manager.metrics()).resolves.toEqual({ ok: true, body: { ok: true } });

    const calls = fetchMock.mock.calls as unknown as Array<[URL, RequestInit]>;
    expect(String(calls[0]![0])).toBe("http://127.0.0.1:4904/api/v1/doctor");
    expect(calls[0]![1].headers).toEqual({ Authorization: "Bearer manager-secret" });
    expect(String(calls[1]![0])).toBe("http://127.0.0.1:4904/api/v1/metrics");
    expect(calls[1]![1].headers).toEqual({ Authorization: "Bearer manager-secret" });
  });

  it("pipelineMetrics calls GET /api/v1/pipeline-metrics and returns the response body", async () => {
    const fakePipelineMetrics = {
      ok: true,
      pipeline_metrics: {
        phases: {
          explorer: { pass_rate: 0.75, fail_count: 1, timed_out_count: 0, retry_count: 0, avg_turns: 3.0, avg_cost: 0.15, total_runs: 4, phases_started: 4, phases_completed: 3 },
          developer: { pass_rate: 1.0, fail_count: 0, timed_out_count: 0, retry_count: 2, avg_turns: 8.0, avg_cost: 0.50, total_runs: 3, phases_started: 3, phases_completed: 3 },
        },
        top_failure_reasons: [{ reason: "timeout", phase: "explorer", count: 1 }],
        stuck_by_reason: [],
        recent_bottlenecks: [{ phase_id: "explorer-abc", run_id: "run-xyz", started_at: "2026-01-01T00:00:00Z" }],
        emitted_at: "2026-01-01T12:00:00Z",
      },
    };
    const fetchMock = vi.fn(async () => new Response(JSON.stringify(fakePipelineMetrics), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const manager = new ElixirServerManager({ port: 4905 });
    const result = await manager.pipelineMetrics();

    expect(result.ok).toBe(true);
    const body = result.body as typeof fakePipelineMetrics;
    expect(body.pipeline_metrics.phases).toHaveProperty("explorer");
    expect(body.pipeline_metrics.phases).toHaveProperty("developer");
    // Smoke: pass rates are in [0, 1]
    expect(body.pipeline_metrics.phases.explorer.pass_rate).toBeGreaterThanOrEqual(0);
    expect(body.pipeline_metrics.phases.explorer.pass_rate).toBeLessThanOrEqual(1);
    // Smoke: counts are non-negative
    expect(body.pipeline_metrics.phases.explorer.fail_count).toBeGreaterThanOrEqual(0);
    expect(body.pipeline_metrics.phases.explorer.total_runs).toBeGreaterThanOrEqual(0);
    // Smoke: bottleneck has required fields
    expect(body.pipeline_metrics.recent_bottlenecks[0]).toHaveProperty("phase_id");
    expect(body.pipeline_metrics.recent_bottlenecks[0]).toHaveProperty("run_id");

    const calls = fetchMock.mock.calls as unknown as [[URL]];
    expect(String(calls[0][0])).toBe("http://127.0.0.1:4905/api/v1/pipeline-metrics");
  });

  it("treats stale pid files as stopped", () => {
    const tmp = mkdtempSync(join(tmpdir(), "foreman-elixir-manager-"));
    const pidPath = join(tmp, "server.pid");
    try {
      writeFileSync(pidPath, "99999999", "utf8");
      const manager = new ElixirServerManager({ pidPath });
      expect(manager.status().running).toBe(false);
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });
});
