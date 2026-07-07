import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ElixirServerManager } from "../elixir-server-manager.js";

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  delete process.env.FOREMAN_SERVER_AUTH_TOKEN;
  delete process.env.FOREMAN_SERVER_URL;
  delete process.env.FOREMAN_SERVER_HTTP_PORT;
  delete process.env.MIX_ENV;
  delete process.env.FOREMAN_SERVER_EVENT_LOG;
  delete process.env.FOREMAN_SERVER_PROJECT_STORE;
  delete process.env.FOREMAN_ALLOW_TEST_PORT_COLLISION;
  delete process.env.FOREMAN_ALLOW_TEST_PERSISTENT_STORAGE;
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

  it("uses isolated test port and pid path when MIX_ENV=test", () => {
    process.env.MIX_ENV = "test";
    const manager = new ElixirServerManager();
    expect(manager.port).toBe(14766);
    expect(manager.pidPath).toContain(join(".foreman", "test", "elixir-server.pid"));
  });

  it("refuses to start MIX_ENV=test on the user port without explicit override", () => {
    const tmp = mkdtempSync(join(tmpdir(), "foreman-elixir-manager-"));
    try {
      process.env.MIX_ENV = "test";
      const manager = new ElixirServerManager({ port: 4766, pidPath: join(tmp, "server.pid") });
      expect(() => manager.start()).toThrow(/MIX_ENV=test on user HTTP port 4766/);
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it("refuses to start MIX_ENV=test with non-temp storage paths", () => {
    const tmp = mkdtempSync(join(tmpdir(), "foreman-elixir-manager-"));
    try {
      process.env.MIX_ENV = "test";
      process.env.FOREMAN_SERVER_EVENT_LOG = join(process.cwd(), ".foreman", "events.term.log");
      const manager = new ElixirServerManager({ port: 14766, pidPath: join(tmp, "server.pid") });
      expect(() => manager.start()).toThrow(/non-temp event log path/);
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it("prefers FOREMAN_SERVER_URL over FOREMAN_SERVER_HTTP_PORT", async () => {
    process.env.FOREMAN_SERVER_URL = "http://127.0.0.1:4999";
    process.env.FOREMAN_SERVER_HTTP_PORT = "0";
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ ok: true }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const manager = new ElixirServerManager();
    await expect(manager.health()).resolves.toEqual({ ok: true, body: { ok: true } });
    const calls = fetchMock.mock.calls as unknown as [[URL]];
    expect(String(calls[0][0])).toBe("http://127.0.0.1:4999/api/v1/health");
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
