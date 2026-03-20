/**
 * Tests for TRD-020: AgentMailClient
 *
 * AgentMailClient wraps the Agent Mail HTTP API (port 8765 FastMCP).
 * Key behaviours under test:
 *  - Each method sends the correct HTTP request (method, path, body)
 *  - Network failures are caught silently — methods never throw
 *  - Timeouts (AbortController) result in silent failure
 *  - fetchInbox returns [] on failure
 *  - healthCheck returns true/false based on server response
 *  - Base URL is resolved from constructor config, AGENT_MAIL_URL env var, or default
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Types (imported from implementation) ─────────────────────────────────────
import type { AgentMailMessage, ReservationResult } from "../agent-mail-client.js";

// ── Module under test (imported after mocks are set up) ──────────────────────
// We use a dynamic import inside each test group so vi.spyOn on globalThis.fetch
// is in place before the module executes.
// Alternatively, we spy on fetch before import, which works because fetch is
// looked up at call-time (not captured at import-time).

import { AgentMailClient } from "../agent-mail-client.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Build a minimal Response-like object for vi.spyOn(globalThis, 'fetch') */
function makeFetchResponse(
  body: unknown,
  status = 200,
): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => JSON.stringify(body),
    headers: new Headers(),
    redirected: false,
    statusText: "OK",
    type: "basic",
    url: "",
    clone: () => makeFetchResponse(body, status),
    body: null,
    bodyUsed: false,
    arrayBuffer: async () => new ArrayBuffer(0),
    blob: async () => new Blob(),
    formData: async () => new FormData(),
  } as unknown as Response;
}

/** Make a fetch spy that resolves with the given response */
function mockFetchOk(body: unknown, status = 200) {
  return vi.spyOn(globalThis, "fetch").mockResolvedValue(
    makeFetchResponse(body, status),
  );
}

/** Make a fetch spy that rejects (network error) */
function mockFetchNetworkError(message = "fetch failed") {
  return vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error(message));
}

/** Make a fetch spy that never resolves (simulates timeout) */
function mockFetchHangs() {
  return vi.spyOn(globalThis, "fetch").mockImplementation(
    () => new Promise(() => { /* never resolves */ }),
  );
}

// ── Test suite ────────────────────────────────────────────────────────────────

describe("AgentMailClient", () => {
  let client: AgentMailClient;

  beforeEach(() => {
    // Fresh client with known base URL for each test
    client = new AgentMailClient({ baseUrl: "http://localhost:8765", timeoutMs: 500 });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  // ── Constructor / base URL resolution ───────────────────────────────────

  describe("base URL resolution", () => {
    it("uses the provided baseUrl", () => {
      const c = new AgentMailClient({ baseUrl: "http://custom:9999" });
      // We can only verify indirectly by checking which URL fetch is called with
      const spy = mockFetchOk({ ok: true });
      void c.registerAgent("test-agent");
      expect(spy).toHaveBeenCalledWith(
        expect.stringContaining("http://custom:9999"),
        expect.any(Object),
      );
    });

    it("falls back to AGENT_MAIL_URL env var when no baseUrl in config", () => {
      const originalEnv = process.env.AGENT_MAIL_URL;
      process.env.AGENT_MAIL_URL = "http://env-host:1234";
      try {
        const c = new AgentMailClient();
        const spy = mockFetchOk({ ok: true });
        void c.registerAgent("test-agent");
        expect(spy).toHaveBeenCalledWith(
          expect.stringContaining("http://env-host:1234"),
          expect.any(Object),
        );
      } finally {
        if (originalEnv === undefined) {
          delete process.env.AGENT_MAIL_URL;
        } else {
          process.env.AGENT_MAIL_URL = originalEnv;
        }
      }
    });

    it("falls back to http://localhost:8765 when no config or env var", () => {
      const originalEnv = process.env.AGENT_MAIL_URL;
      delete process.env.AGENT_MAIL_URL;
      try {
        const c = new AgentMailClient();
        const spy = mockFetchOk({ ok: true });
        void c.registerAgent("test-agent");
        expect(spy).toHaveBeenCalledWith(
          expect.stringContaining("http://localhost:8765"),
          expect.any(Object),
        );
      } finally {
        if (originalEnv !== undefined) {
          process.env.AGENT_MAIL_URL = originalEnv;
        }
      }
    });
  });

  // ── registerAgent ────────────────────────────────────────────────────────

  describe("registerAgent()", () => {
    it("POSTs to /register_agent with correct body", async () => {
      const spy = mockFetchOk({ ok: true });

      await client.registerAgent("worker-007");

      expect(spy).toHaveBeenCalledTimes(1);
      const [url, init] = spy.mock.calls[0] as [string, RequestInit];
      expect(url).toBe("http://localhost:8765/register_agent");
      expect(init.method).toBe("POST");
      expect(JSON.parse(init.body as string)).toEqual({ name: "worker-007" });
    });

    it("sets Content-Type: application/json header", async () => {
      const spy = mockFetchOk({ ok: true });

      await client.registerAgent("agent-x");

      const [, init] = spy.mock.calls[0] as [string, RequestInit];
      const headers = new Headers(init.headers as HeadersInit);
      expect(headers.get("content-type")).toContain("application/json");
    });

    it("does not throw on network error (silent failure)", async () => {
      mockFetchNetworkError("ECONNREFUSED");

      await expect(client.registerAgent("agent-x")).resolves.toBeUndefined();
    });

    it("does not throw on non-2xx response (silent failure)", async () => {
      mockFetchOk({ error: "already registered" }, 409);

      await expect(client.registerAgent("agent-x")).resolves.toBeUndefined();
    });

    it("does not throw when server is unreachable (silent failure)", async () => {
      mockFetchNetworkError("fetch failed");

      await expect(client.registerAgent("agent-x")).resolves.toBeUndefined();
    });
  });

  // ── sendMessage ──────────────────────────────────────────────────────────

  describe("sendMessage()", () => {
    it("POSTs to /send_message with correct body (no metadata)", async () => {
      const spy = mockFetchOk({ ok: true });

      await client.sendMessage("agent-b", "Hello", "World");

      const [url, init] = spy.mock.calls[0] as [string, RequestInit];
      expect(url).toBe("http://localhost:8765/send_message");
      expect(init.method).toBe("POST");
      expect(JSON.parse(init.body as string)).toEqual({
        to: "agent-b",
        subject: "Hello",
        body: "World",
      });
    });

    it("POSTs to /send_message including metadata when provided", async () => {
      const spy = mockFetchOk({ ok: true });

      await client.sendMessage("agent-b", "Task Done", "Finished", { taskId: "TRD-020" });

      const [, init] = spy.mock.calls[0] as [string, RequestInit];
      expect(JSON.parse(init.body as string)).toEqual({
        to: "agent-b",
        subject: "Task Done",
        body: "Finished",
        metadata: { taskId: "TRD-020" },
      });
    });

    it("does not throw on network error (silent failure)", async () => {
      mockFetchNetworkError();

      await expect(client.sendMessage("a", "s", "b")).resolves.toBeUndefined();
    });

    it("does not throw on non-2xx response (silent failure)", async () => {
      mockFetchOk({ error: "recipient not found" }, 404);

      await expect(client.sendMessage("unknown", "hi", "msg")).resolves.toBeUndefined();
    });
  });

  // ── fetchInbox ───────────────────────────────────────────────────────────

  describe("fetchInbox()", () => {
    const sampleMessages: AgentMailMessage[] = [
      {
        id: "msg-001",
        from: "agent-a",
        to: "agent-b",
        subject: "Hello",
        body: "World",
        receivedAt: "2026-01-01T00:00:00Z",
        acknowledged: false,
      },
    ];

    it("GETs /fetch_inbox with agent query param", async () => {
      const spy = mockFetchOk(sampleMessages);

      await client.fetchInbox("agent-b");

      const [url] = spy.mock.calls[0] as [string, RequestInit];
      expect(url).toContain("/fetch_inbox");
      expect(url).toContain("agent=agent-b");
    });

    it("includes limit param when provided", async () => {
      const spy = mockFetchOk(sampleMessages);

      await client.fetchInbox("agent-b", { limit: 10 });

      const [url] = spy.mock.calls[0] as [string];
      expect(url).toContain("limit=10");
    });

    it("includes unread_only param when unreadOnly=true", async () => {
      const spy = mockFetchOk(sampleMessages);

      await client.fetchInbox("agent-b", { unreadOnly: true });

      const [url] = spy.mock.calls[0] as [string];
      expect(url).toContain("unread_only=true");
    });

    it("returns parsed messages array on success", async () => {
      mockFetchOk(sampleMessages);

      const result = await client.fetchInbox("agent-b");

      expect(result).toEqual(sampleMessages);
    });

    it("returns [] on network error (silent failure)", async () => {
      mockFetchNetworkError();

      const result = await client.fetchInbox("agent-b");

      expect(result).toEqual([]);
    });

    it("returns [] on non-2xx response (silent failure)", async () => {
      mockFetchOk({ error: "not found" }, 404);

      const result = await client.fetchInbox("agent-b");

      expect(result).toEqual([]);
    });

    it("returns [] when JSON parsing fails (silent failure)", async () => {
      vi.spyOn(globalThis, "fetch").mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => { throw new SyntaxError("bad json"); },
      } as unknown as Response);

      const result = await client.fetchInbox("agent-b");

      expect(result).toEqual([]);
    });
  });

  // ── fileReservation ──────────────────────────────────────────────────────

  describe("fileReservation()", () => {
    it("POSTs to /file_reservation_paths with correct body", async () => {
      const spy = mockFetchOk({ success: true } satisfies ReservationResult);

      await client.fileReservation(["src/foo.ts", "src/bar.ts"], {
        agent: "worker-1",
        durationMs: 30000,
      });

      const [url, init] = spy.mock.calls[0] as [string, RequestInit];
      expect(url).toBe("http://localhost:8765/file_reservation_paths");
      expect(init.method).toBe("POST");
      expect(JSON.parse(init.body as string)).toEqual({
        paths: ["src/foo.ts", "src/bar.ts"],
        agent: "worker-1",
        duration_ms: 30000,
      });
    });

    it("omits duration_ms when not provided", async () => {
      const spy = mockFetchOk({ success: true } satisfies ReservationResult);

      await client.fileReservation(["src/foo.ts"], { agent: "worker-1" });

      const [, init] = spy.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as Record<string, unknown>;
      expect(body).not.toHaveProperty("duration_ms");
    });

    it("returns parsed ReservationResult on success", async () => {
      const result: ReservationResult = {
        success: false,
        conflicts: [{ path: "src/foo.ts", heldBy: "worker-2", expiresAt: "2026-01-01T01:00:00Z" }],
      };
      mockFetchOk(result);

      const r = await client.fileReservation(["src/foo.ts"], { agent: "worker-1" });

      expect(r).toEqual(result);
    });

    it("returns { success: false } on network error (silent failure)", async () => {
      mockFetchNetworkError();

      const r = await client.fileReservation(["src/foo.ts"], { agent: "worker-1" });

      expect(r.success).toBe(false);
    });

    it("returns { success: false } on non-2xx response (silent failure)", async () => {
      mockFetchOk({ error: "conflict" }, 409);

      const r = await client.fileReservation(["src/foo.ts"], { agent: "worker-1" });

      expect(r.success).toBe(false);
    });
  });

  // ── releaseReservation ───────────────────────────────────────────────────

  describe("releaseReservation()", () => {
    it("POSTs to /release_reservation with correct body", async () => {
      const spy = mockFetchOk({ ok: true });

      await client.releaseReservation(["src/foo.ts", "src/bar.ts"]);

      const [url, init] = spy.mock.calls[0] as [string, RequestInit];
      expect(url).toBe("http://localhost:8765/release_reservation");
      expect(init.method).toBe("POST");
      expect(JSON.parse(init.body as string)).toEqual({
        paths: ["src/foo.ts", "src/bar.ts"],
      });
    });

    it("does not throw on network error (silent failure)", async () => {
      mockFetchNetworkError();

      await expect(client.releaseReservation(["src/foo.ts"])).resolves.toBeUndefined();
    });

    it("does not throw on non-2xx response (silent failure)", async () => {
      mockFetchOk({ error: "not reserved" }, 404);

      await expect(client.releaseReservation(["src/foo.ts"])).resolves.toBeUndefined();
    });
  });

  // ── healthCheck ──────────────────────────────────────────────────────────

  describe("healthCheck()", () => {
    it("GETs /health and returns true when server responds { status: 'ok' }", async () => {
      mockFetchOk({ status: "ok" });

      const result = await client.healthCheck();

      expect(result).toBe(true);
    });

    it("returns true when response is 2xx regardless of body", async () => {
      mockFetchOk({ anything: "goes" });

      const result = await client.healthCheck();

      expect(result).toBe(true);
    });

    it("returns false when server is down (network error)", async () => {
      mockFetchNetworkError("ECONNREFUSED");

      const result = await client.healthCheck();

      expect(result).toBe(false);
    });

    it("returns false on non-2xx response", async () => {
      mockFetchOk({ error: "internal server error" }, 500);

      const result = await client.healthCheck();

      expect(result).toBe(false);
    });

    it("GETs the correct URL", async () => {
      const spy = mockFetchOk({ status: "ok" });

      await client.healthCheck();

      const [url] = spy.mock.calls[0] as [string];
      expect(url).toBe("http://localhost:8765/health");
    });
  });

  // ── Timeout (AbortController) ────────────────────────────────────────────

  describe("Timeout / AbortController", () => {
    it("passes an AbortSignal to every fetch call", async () => {
      const spy = mockFetchOk({ ok: true });

      await client.registerAgent("agent-x");

      const [, init] = spy.mock.calls[0] as [string, RequestInit];
      expect(init.signal).toBeDefined();
    });

    it("healthCheck returns false when fetch is aborted (AbortError)", async () => {
      vi.spyOn(globalThis, "fetch").mockRejectedValue(
        Object.assign(new Error("The operation was aborted."), { name: "AbortError" }),
      );

      const result = await client.healthCheck();

      expect(result).toBe(false);
    });

    it("registerAgent does not throw when fetch is aborted (AbortError)", async () => {
      vi.spyOn(globalThis, "fetch").mockRejectedValue(
        Object.assign(new Error("The operation was aborted."), { name: "AbortError" }),
      );

      await expect(client.registerAgent("agent-x")).resolves.toBeUndefined();
    });

    it("fetchInbox returns [] when fetch is aborted (AbortError)", async () => {
      vi.spyOn(globalThis, "fetch").mockRejectedValue(
        Object.assign(new Error("The operation was aborted."), { name: "AbortError" }),
      );

      const result = await client.fetchInbox("agent-x");

      expect(result).toEqual([]);
    });
  });
});
