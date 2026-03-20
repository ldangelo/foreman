/**
 * Tests for TRD-020: AgentMailClient
 *
 * AgentMailClient wraps the Agent Mail FastMCP server via JSON-RPC 2.0 POST /mcp.
 * Key behaviours under test:
 *  - Each method sends a correct JSON-RPC 2.0 POST to /mcp
 *  - Network failures are caught silently — methods never throw
 *  - Timeouts (AbortController) result in silent failure
 *  - fetchInbox returns [] on failure, and maps the raw server shape to AgentMailMessage
 *  - fileReservation returns { success: false } on failure
 *  - healthCheck returns true/false based on GET /health response
 *  - Base URL is resolved from constructor config, AGENT_MAIL_URL env var, or default
 *  - Project key is resolved from constructor config, AGENT_MAIL_PROJECT env var, or "foreman"
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

import type { AgentMailMessage, ReservationResult } from "../agent-mail-client.js";
import { AgentMailClient } from "../agent-mail-client.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Build a minimal Response-like object for vi.spyOn(globalThis, 'fetch') */
function makeFetchResponse(body: unknown, status = 200): Response {
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

/**
 * Build a valid JSON-RPC 2.0 response wrapping `toolResult` as the
 * `result.content[0].text` JSON string — the shape FastMCP returns.
 */
function makeJsonRpcResponse(toolResult: unknown, status = 200): Response {
  const rpc = {
    jsonrpc: "2.0",
    id: 1,
    result: {
      content: [{ type: "text", text: JSON.stringify(toolResult) }],
    },
  };
  return makeFetchResponse(rpc, status);
}

/** Make a fetch spy that resolves with a JSON-RPC response wrapping toolResult */
function mockMcpOk(toolResult: unknown) {
  return vi.spyOn(globalThis, "fetch").mockResolvedValue(makeJsonRpcResponse(toolResult));
}

/** Make a fetch spy that rejects (network error) */
function mockFetchNetworkError(message = "fetch failed") {
  return vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error(message));
}

/** Make a fetch spy that returns a plain (non-RPC) response for healthCheck */
function mockHealthResponse(status = 200) {
  return vi.spyOn(globalThis, "fetch").mockResolvedValue(
    makeFetchResponse({ status: "ok" }, status),
  );
}

/** Parse the JSON-RPC request body from a spy call */
function parseRpcBody(spy: ReturnType<typeof vi.spyOn>, callIndex = 0) {
  const [, init] = spy.mock.calls[callIndex] as [string, RequestInit];
  return JSON.parse(init.body as string) as {
    jsonrpc: string;
    id: number;
    method: string;
    params: { name: string; arguments: Record<string, unknown> };
  };
}

// ── Test suite ────────────────────────────────────────────────────────────────

describe("AgentMailClient", () => {
  let client: AgentMailClient;

  beforeEach(() => {
    client = new AgentMailClient({
      baseUrl: "http://localhost:8765",
      timeoutMs: 500,
      projectKey: "test-project",
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  // ── Constructor / base URL resolution ───────────────────────────────────

  describe("base URL resolution", () => {
    it("uses the provided baseUrl", () => {
      const c = new AgentMailClient({ baseUrl: "http://custom:9999" });
      const spy = mockMcpOk({ ok: true });
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
        const spy = mockMcpOk({ ok: true });
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
        const spy = mockMcpOk({ ok: true });
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

  // ── Project key resolution ───────────────────────────────────────────────

  describe("project key resolution", () => {
    it("uses the provided projectKey", async () => {
      const spy = mockMcpOk({ ok: true });
      await client.registerAgent("agent-x");
      const body = parseRpcBody(spy);
      expect(body.params.arguments["project_key"]).toBe("test-project");
    });

    it("falls back to AGENT_MAIL_PROJECT env var when no projectKey in config", async () => {
      const originalEnv = process.env.AGENT_MAIL_PROJECT;
      process.env.AGENT_MAIL_PROJECT = "env-project";
      try {
        const c = new AgentMailClient({ baseUrl: "http://localhost:8765", timeoutMs: 500 });
        const spy = mockMcpOk({ ok: true });
        await c.registerAgent("agent-x");
        const body = parseRpcBody(spy);
        expect(body.params.arguments["project_key"]).toBe("env-project");
      } finally {
        if (originalEnv === undefined) {
          delete process.env.AGENT_MAIL_PROJECT;
        } else {
          process.env.AGENT_MAIL_PROJECT = originalEnv;
        }
      }
    });

    it("defaults to 'foreman' when no config or env var", async () => {
      const originalEnv = process.env.AGENT_MAIL_PROJECT;
      delete process.env.AGENT_MAIL_PROJECT;
      try {
        const c = new AgentMailClient({ baseUrl: "http://localhost:8765", timeoutMs: 500 });
        const spy = mockMcpOk({ ok: true });
        await c.registerAgent("agent-x");
        const body = parseRpcBody(spy);
        expect(body.params.arguments["project_key"]).toBe("foreman");
      } finally {
        if (originalEnv !== undefined) {
          process.env.AGENT_MAIL_PROJECT = originalEnv;
        }
      }
    });
  });

  // ── MCP transport ────────────────────────────────────────────────────────

  describe("MCP transport", () => {
    it("POSTs to /mcp with JSON-RPC 2.0 envelope", async () => {
      const spy = mockMcpOk({ ok: true });
      await client.registerAgent("agent-x");
      const [url, init] = spy.mock.calls[0] as [string, RequestInit];
      expect(url).toBe("http://localhost:8765/mcp");
      expect(init.method).toBe("POST");
      const body = parseRpcBody(spy);
      expect(body.jsonrpc).toBe("2.0");
      expect(body.method).toBe("tools/call");
    });

    it("sends Content-Type: application/json header", async () => {
      const spy = mockMcpOk({ ok: true });
      await client.registerAgent("agent-x");
      const [, init] = spy.mock.calls[0] as [string, RequestInit];
      const headers = new Headers(init.headers as HeadersInit);
      expect(headers.get("content-type")).toContain("application/json");
    });

    it("adds Authorization header when bearerToken is set", async () => {
      const c = new AgentMailClient({
        baseUrl: "http://localhost:8765",
        timeoutMs: 500,
        bearerToken: "my-secret-token",
      });
      const spy = mockMcpOk({ ok: true });
      await c.registerAgent("agent-x");
      const [, init] = spy.mock.calls[0] as [string, RequestInit];
      const headers = new Headers(init.headers as HeadersInit);
      expect(headers.get("authorization")).toBe("Bearer my-secret-token");
    });

    it("passes an AbortSignal to every fetch call", async () => {
      const spy = mockMcpOk({ ok: true });
      await client.registerAgent("agent-x");
      const [, init] = spy.mock.calls[0] as [string, RequestInit];
      expect(init.signal).toBeDefined();
    });
  });

  // ── ensureProject ────────────────────────────────────────────────────────

  describe("ensureProject()", () => {
    it("calls ensure_project tool with project_key", async () => {
      const spy = mockMcpOk({ ok: true });
      await client.ensureProject();
      const body = parseRpcBody(spy);
      expect(body.params.name).toBe("ensure_project");
      expect(body.params.arguments["project_key"]).toBe("test-project");
    });

    it("does not throw on network error (silent failure)", async () => {
      mockFetchNetworkError();
      await expect(client.ensureProject()).resolves.toBeUndefined();
    });
  });

  // ── registerAgent ────────────────────────────────────────────────────────

  describe("registerAgent()", () => {
    it("calls register_agent tool with correct arguments", async () => {
      const spy = mockMcpOk({ ok: true });
      await client.registerAgent("worker-007");
      const body = parseRpcBody(spy);
      expect(body.params.name).toBe("register_agent");
      expect(body.params.arguments).toMatchObject({
        project_key: "test-project",
        name: "worker-007",
        program: "foreman",
        model: "claude-sonnet-4-6",
      });
    });

    it("does not throw on network error (silent failure)", async () => {
      mockFetchNetworkError("ECONNREFUSED");
      await expect(client.registerAgent("agent-x")).resolves.toBeUndefined();
    });

    it("does not throw on non-2xx response (silent failure)", async () => {
      vi.spyOn(globalThis, "fetch").mockResolvedValue(makeFetchResponse({ error: "already registered" }, 409));
      await expect(client.registerAgent("agent-x")).resolves.toBeUndefined();
    });

    it("does not throw when fetch is aborted (AbortError)", async () => {
      vi.spyOn(globalThis, "fetch").mockRejectedValue(
        Object.assign(new Error("The operation was aborted."), { name: "AbortError" }),
      );
      await expect(client.registerAgent("agent-x")).resolves.toBeUndefined();
    });
  });

  // ── sendMessage ──────────────────────────────────────────────────────────

  describe("sendMessage()", () => {
    it("calls send_message tool with correct arguments", async () => {
      const spy = mockMcpOk({ ok: true });
      await client.sendMessage("agent-b", "Hello", "World");
      const body = parseRpcBody(spy);
      expect(body.params.name).toBe("send_message");
      expect(body.params.arguments).toMatchObject({
        project_key: "test-project",
        sender_name: "foreman",
        to: ["agent-b"],
        subject: "Hello",
        body_md: "World",
      });
    });

    it("does not throw on network error (silent failure)", async () => {
      mockFetchNetworkError();
      await expect(client.sendMessage("a", "s", "b")).resolves.toBeUndefined();
    });

    it("does not throw on non-2xx response (silent failure)", async () => {
      vi.spyOn(globalThis, "fetch").mockResolvedValue(makeFetchResponse({ error: "recipient not found" }, 404));
      await expect(client.sendMessage("unknown", "hi", "msg")).resolves.toBeUndefined();
    });
  });

  // ── fetchInbox ───────────────────────────────────────────────────────────

  describe("fetchInbox()", () => {
    const rawServerMessages = [
      {
        id: 42,
        sender_name: "agent-a",
        recipients: ["agent-b"],
        subject: "Hello",
        body_md: "World",
        received_at: "2026-01-01T00:00:00Z",
        acknowledged: false,
      },
    ];

    const expectedMessages: AgentMailMessage[] = [
      {
        id: "42",
        from: "agent-a",
        to: "agent-b",
        subject: "Hello",
        body: "World",
        receivedAt: "2026-01-01T00:00:00Z",
        acknowledged: false,
      },
    ];

    it("calls fetch_inbox tool with correct arguments", async () => {
      const spy = mockMcpOk(rawServerMessages);
      await client.fetchInbox("agent-b");
      const body = parseRpcBody(spy);
      expect(body.params.name).toBe("fetch_inbox");
      expect(body.params.arguments).toMatchObject({
        project_key: "test-project",
        agent_name: "agent-b",
        include_bodies: true,
      });
    });

    it("passes limit option when provided", async () => {
      const spy = mockMcpOk(rawServerMessages);
      await client.fetchInbox("agent-b", { limit: 10 });
      const body = parseRpcBody(spy);
      expect(body.params.arguments["limit"]).toBe(10);
    });

    it("maps unreadOnly option to urgent_only", async () => {
      const spy = mockMcpOk(rawServerMessages);
      await client.fetchInbox("agent-b", { unreadOnly: true });
      const body = parseRpcBody(spy);
      expect(body.params.arguments["urgent_only"]).toBe(true);
    });

    it("maps raw server message shape to AgentMailMessage interface", async () => {
      mockMcpOk(rawServerMessages);
      const result = await client.fetchInbox("agent-b");
      expect(result).toEqual(expectedMessages);
    });

    it("maps numeric id to string id", async () => {
      mockMcpOk(rawServerMessages);
      const result = await client.fetchInbox("agent-b");
      expect(typeof result[0]?.id).toBe("string");
      expect(result[0]?.id).toBe("42");
    });

    it("returns [] on network error (silent failure)", async () => {
      mockFetchNetworkError();
      const result = await client.fetchInbox("agent-b");
      expect(result).toEqual([]);
    });

    it("returns [] on non-2xx response (silent failure)", async () => {
      vi.spyOn(globalThis, "fetch").mockResolvedValue(makeFetchResponse({ error: "not found" }, 404));
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

    it("returns [] when fetch is aborted (AbortError)", async () => {
      vi.spyOn(globalThis, "fetch").mockRejectedValue(
        Object.assign(new Error("The operation was aborted."), { name: "AbortError" }),
      );
      const result = await client.fetchInbox("agent-x");
      expect(result).toEqual([]);
    });
  });

  // ── fileReservation ──────────────────────────────────────────────────────

  describe("fileReservation()", () => {
    it("calls file_reservation_paths tool with correct arguments", async () => {
      const spy = mockMcpOk({ success: true } satisfies ReservationResult);
      await client.fileReservation(["src/foo.ts", "src/bar.ts"], {
        agent: "worker-1",
        durationMs: 30000,
      });
      const body = parseRpcBody(spy);
      expect(body.params.name).toBe("file_reservation_paths");
      expect(body.params.arguments).toMatchObject({
        project_key: "test-project",
        agent_name: "worker-1",
        paths: ["src/foo.ts", "src/bar.ts"],
        ttl_seconds: 30,
        exclusive: true,
        reason: "foreman-phase-reservation",
      });
    });

    it("uses default ttl_seconds of 3600 when durationMs not provided", async () => {
      const spy = mockMcpOk({ success: true } satisfies ReservationResult);
      await client.fileReservation(["src/foo.ts"], { agent: "worker-1" });
      const body = parseRpcBody(spy);
      expect(body.params.arguments["ttl_seconds"]).toBe(3600);
    });

    it("rounds up fractional ttl_seconds", async () => {
      const spy = mockMcpOk({ success: true } satisfies ReservationResult);
      await client.fileReservation(["src/foo.ts"], { agent: "worker-1", durationMs: 1500 });
      const body = parseRpcBody(spy);
      expect(body.params.arguments["ttl_seconds"]).toBe(2);
    });

    it("returns parsed ReservationResult on success", async () => {
      const result: ReservationResult = {
        success: false,
        conflicts: [{ path: "src/foo.ts", heldBy: "worker-2", expiresAt: "2026-01-01T01:00:00Z" }],
      };
      mockMcpOk(result);
      const r = await client.fileReservation(["src/foo.ts"], { agent: "worker-1" });
      expect(r).toEqual(result);
    });

    it("returns { success: false } on network error (silent failure)", async () => {
      mockFetchNetworkError();
      const r = await client.fileReservation(["src/foo.ts"], { agent: "worker-1" });
      expect(r.success).toBe(false);
    });

    it("returns { success: false } on non-2xx response (silent failure)", async () => {
      vi.spyOn(globalThis, "fetch").mockResolvedValue(makeFetchResponse({ error: "conflict" }, 409));
      const r = await client.fileReservation(["src/foo.ts"], { agent: "worker-1" });
      expect(r.success).toBe(false);
    });
  });

  // ── releaseReservation ───────────────────────────────────────────────────

  describe("releaseReservation()", () => {
    it("calls release_file_reservations tool with correct arguments", async () => {
      const spy = mockMcpOk({ ok: true });
      await client.releaseReservation(["src/foo.ts", "src/bar.ts"], "worker-1");
      const body = parseRpcBody(spy);
      expect(body.params.name).toBe("release_file_reservations");
      expect(body.params.arguments).toMatchObject({
        project_key: "test-project",
        agent_name: "worker-1",
        paths: ["src/foo.ts", "src/bar.ts"],
      });
    });

    it("does not throw on network error (silent failure)", async () => {
      mockFetchNetworkError();
      await expect(client.releaseReservation(["src/foo.ts"], "worker-1")).resolves.toBeUndefined();
    });

    it("does not throw on non-2xx response (silent failure)", async () => {
      vi.spyOn(globalThis, "fetch").mockResolvedValue(makeFetchResponse({ error: "not reserved" }, 404));
      await expect(client.releaseReservation(["src/foo.ts"], "worker-1")).resolves.toBeUndefined();
    });
  });

  // ── healthCheck ──────────────────────────────────────────────────────────

  describe("healthCheck()", () => {
    it("GETs /health and returns true when server responds 2xx", async () => {
      mockHealthResponse(200);
      const result = await client.healthCheck();
      expect(result).toBe(true);
    });

    it("returns true when response is 2xx regardless of body", async () => {
      mockHealthResponse(200);
      const result = await client.healthCheck();
      expect(result).toBe(true);
    });

    it("returns false when server is down (network error)", async () => {
      mockFetchNetworkError("ECONNREFUSED");
      const result = await client.healthCheck();
      expect(result).toBe(false);
    });

    it("returns false on non-2xx response", async () => {
      mockHealthResponse(500);
      const result = await client.healthCheck();
      expect(result).toBe(false);
    });

    it("GETs the correct URL", async () => {
      const spy = mockHealthResponse();
      await client.healthCheck();
      const [url] = spy.mock.calls[0] as [string];
      expect(url).toBe("http://localhost:8765/health");
    });

    it("uses GET method for /health", async () => {
      const spy = mockHealthResponse();
      await client.healthCheck();
      const [, init] = spy.mock.calls[0] as [string, RequestInit];
      expect(init.method).toBe("GET");
    });

    it("returns false when fetch is aborted (AbortError)", async () => {
      vi.spyOn(globalThis, "fetch").mockRejectedValue(
        Object.assign(new Error("The operation was aborted."), { name: "AbortError" }),
      );
      const result = await client.healthCheck();
      expect(result).toBe(false);
    });
  });

  // ── Timeout (AbortController) ────────────────────────────────────────────

  describe("Timeout / AbortController", () => {
    it("passes an AbortSignal to MCP calls", async () => {
      const spy = mockMcpOk({ ok: true });
      await client.registerAgent("agent-x");
      const [, init] = spy.mock.calls[0] as [string, RequestInit];
      expect(init.signal).toBeDefined();
    });

    it("passes an AbortSignal to healthCheck", async () => {
      const spy = mockHealthResponse();
      await client.healthCheck();
      const [, init] = spy.mock.calls[0] as [string, RequestInit];
      expect(init.signal).toBeDefined();
    });
  });
});
