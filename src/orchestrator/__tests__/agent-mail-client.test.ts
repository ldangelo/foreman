import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { AgentMailClient, DEFAULT_AGENT_MAIL_CONFIG } from "../agent-mail-client.js";

// ── Mock fetch globally ───────────────────────────────────────────────────────

const mockFetch = vi.fn<typeof fetch>();

beforeEach(() => {
  vi.stubGlobal("fetch", mockFetch);
  mockFetch.mockReset();
});

afterEach(() => {
  vi.unstubAllGlobals();
  // Clean up env vars set during tests
  delete process.env.AGENT_MAIL_URL;
  delete process.env.AGENT_MAIL_TOKEN;
  delete process.env.AGENT_MAIL_PROJECT;
});

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Build a successful JSON-RPC Response wrapping a JSON-encoded payload. */
function mcpOkResponse(payload: unknown): Response {
  const text = typeof payload === "string" ? payload : JSON.stringify(payload);
  return new Response(
    JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      result: {
        content: [{ type: "text", text }],
      },
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

/** Build an error JSON-RPC Response (isError=true). */
function mcpErrorResponse(message: string): Response {
  return new Response(
    JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      result: {
        content: [{ type: "text", text: message }],
        isError: true,
      },
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

/** Build a 2xx health response. */
function healthOkResponse(): Response {
  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("AgentMailClient", () => {
  describe("mcpCall — JSON-RPC envelope", () => {
    it("sends correct JSON-RPC 2.0 envelope to POST /mcp", async () => {
      // ensureProject makes 2 MCP calls: ensure_project + register_agent (ensureAgentRegistered)
      mockFetch.mockResolvedValueOnce(mcpOkResponse({ ok: true }));
      mockFetch.mockResolvedValueOnce(mcpOkResponse({ name: "TestAgent" }));

      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      // Use ensureProject to trigger an mcpCall
      await client.ensureProject("/some/project");

      // Verify both calls happened; inspect the first one for envelope structure
      expect(mockFetch).toHaveBeenCalledTimes(2);
      const [url, init] = mockFetch.mock.calls[0] as [string, RequestInit];
      expect(url).toBe("http://localhost:8766/mcp");
      expect(init.method).toBe("POST");

      const body = JSON.parse(init.body as string) as Record<string, unknown>;
      expect(body["jsonrpc"]).toBe("2.0");
      expect(typeof body["id"]).toBe("number");
      expect(body["method"]).toBe("tools/call");
      expect((body["params"] as Record<string, unknown>)["name"]).toBe("ensure_project");
    });

    it("includes Authorization header when bearerToken is set", async () => {
      mockFetch.mockResolvedValueOnce(mcpOkResponse({}));

      const client = new AgentMailClient({
        baseUrl: "http://localhost:8766",
        bearerToken: "secret-token",
      });
      await client.ensureProject("/some/project");

      const [, init] = mockFetch.mock.calls[0] as [string, RequestInit];
      expect((init.headers as Record<string, string>)["Authorization"]).toBe("Bearer secret-token");
    });

    it("does not include Authorization header when no token set", async () => {
      mockFetch.mockResolvedValueOnce(mcpOkResponse({}));
      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      await client.ensureProject("/some/project");

      const [, init] = mockFetch.mock.calls[0] as [string, RequestInit];
      const headers = (init.headers ?? {}) as Record<string, string>;
      expect(headers["Authorization"]).toBeUndefined();
    });
  });

  describe("ensureProject", () => {
    it("sends human_key (not project_key) as the argument", async () => {
      mockFetch.mockResolvedValueOnce(mcpOkResponse({}));

      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      await client.ensureProject("/Users/ldangelo/Development/Fortium/foreman");

      const [, init] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as Record<string, unknown>;
      const params = body["params"] as Record<string, unknown>;
      const args = params["arguments"] as Record<string, unknown>;

      expect(args["human_key"]).toBe("/Users/ldangelo/Development/Fortium/foreman");
      expect(args["project_key"]).toBeUndefined();
    });

    it("updates projectKey so subsequent calls use the absolute path", async () => {
      // First call: ensureProject succeeds
      mockFetch.mockResolvedValueOnce(mcpOkResponse({}));
      // Second call: sendMessage — should use the absolute path as project_key
      mockFetch.mockResolvedValueOnce(mcpOkResponse({}));

      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      await client.ensureProject("/Users/ldangelo/Development/Fortium/foreman");
      await client.sendMessage("agent-x", "Hello", "body");

      const [, sendInit] = mockFetch.mock.calls[1] as [string, RequestInit];
      const body = JSON.parse(sendInit.body as string) as Record<string, unknown>;
      const params = body["params"] as Record<string, unknown>;
      const args = params["arguments"] as Record<string, unknown>;
      expect(args["project_key"]).toBe("/Users/ldangelo/Development/Fortium/foreman");
    });

    it("does not throw on network error (silent failure)", async () => {
      mockFetch.mockRejectedValueOnce(new Error("connection refused"));
      const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
      await expect(client.ensureProject("/some/path")).resolves.toBeUndefined();
    });

    it("does not throw on server isError response", async () => {
      mockFetch.mockResolvedValueOnce(mcpErrorResponse("project not found"));
      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      await expect(client.ensureProject("/some/path")).resolves.toBeUndefined();
    });
  });

  describe("sendMessage", () => {
    it("maps args correctly: body_md, sender_name, to as array", async () => {
      mockFetch.mockResolvedValueOnce(mcpOkResponse({}));

      const client = new AgentMailClient({
        baseUrl: "http://localhost:8766",
        projectKey: "myproject",
      });
      // Agent Mail uses auto-generated adjective+noun names; set the sender name
      // directly to simulate a registered agent (as ensureAgentRegistered() would do).
      client.agentName = "MossyFox";
      await client.sendMessage("agent-x", "Hello", "World body");

      const [, init] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as Record<string, unknown>;
      const params = body["params"] as Record<string, unknown>;
      const args = params["arguments"] as Record<string, unknown>;

      expect(args["project_key"]).toBe("myproject");
      expect(args["sender_name"]).toBe("MossyFox");
      expect(args["to"]).toEqual(["agent-x"]);
      expect(args["subject"]).toBe("Hello");
      expect(args["body_md"]).toBe("World body");
      // No 4th metadata argument
      expect(Object.keys(args)).not.toContain("metadata");
    });

    it("does not throw on network error", async () => {
      mockFetch.mockRejectedValueOnce(new Error("timeout"));
      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      await expect(client.sendMessage("agent", "subj", "body")).resolves.toBeUndefined();
    });
  });

  describe("fetchInbox", () => {
    it("maps server response fields to AgentMailMessage interface", async () => {
      const serverMessages = [
        {
          id: 42,
          sender_name: "orchestrator",
          recipients: ["developer-bd-abc1"],
          subject: "Phase complete",
          body_md: "## Done\nAll tests pass.",
          received_at: "2026-01-01T10:00:00Z",
          acknowledged: false,
        },
        {
          id: 99,
          sender_name: "qa-agent",
          recipients: ["developer-bd-abc1", "foreman"],
          subject: "QA Report",
          body_md: "PASS",
          created_at: "2026-01-01T11:00:00Z",
          acknowledged: true,
        },
      ];
      mockFetch.mockResolvedValueOnce(mcpOkResponse(serverMessages));

      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      const messages = await client.fetchInbox("developer-bd-abc1");

      expect(messages).toHaveLength(2);

      const [first, second] = messages;
      expect(first.id).toBe("42");
      expect(first.from).toBe("orchestrator");
      expect(first.to).toBe("developer-bd-abc1");
      expect(first.subject).toBe("Phase complete");
      expect(first.body).toBe("## Done\nAll tests pass.");
      expect(first.receivedAt).toBe("2026-01-01T10:00:00Z");
      expect(first.acknowledged).toBe(false);

      // Second message: falls back to created_at
      expect(second.id).toBe("99");
      expect(second.from).toBe("qa-agent");
      expect(second.to).toBe("developer-bd-abc1");
      expect(second.receivedAt).toBe("2026-01-01T11:00:00Z");
      expect(second.acknowledged).toBe(true);
    });

    it("sends include_bodies=true and agent_name", async () => {
      mockFetch.mockResolvedValueOnce(mcpOkResponse([]));

      const client = new AgentMailClient({
        baseUrl: "http://localhost:8766",
        projectKey: "foreman",
      });
      await client.fetchInbox("my-agent", { limit: 5 });

      const [, init] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as Record<string, unknown>;
      const params = body["params"] as Record<string, unknown>;
      const args = params["arguments"] as Record<string, unknown>;

      expect(args["agent_name"]).toBe("my-agent");
      expect(args["include_bodies"]).toBe(true);
      expect(args["limit"]).toBe(5);
    });

    it("returns [] on network error", async () => {
      mockFetch.mockRejectedValueOnce(new Error("connection refused"));
      const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
      const result = await client.fetchInbox("agent");
      expect(result).toEqual([]);
    });

    it("returns [] when server returns isError", async () => {
      mockFetch.mockResolvedValueOnce(mcpErrorResponse("agent not found"));
      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      const result = await client.fetchInbox("nonexistent-agent");
      expect(result).toEqual([]);
    });
  });

  describe("releaseReservation", () => {
    it("passes agentName as agent_name field", async () => {
      mockFetch.mockResolvedValueOnce(mcpOkResponse({}));

      const client = new AgentMailClient({
        baseUrl: "http://localhost:8766",
        projectKey: "foreman",
      });
      await client.releaseReservation(
        ["/path/to/file.ts", "/path/to/other.ts"],
        "developer-bd-xyz9",
      );

      const [, init] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as Record<string, unknown>;
      const params = body["params"] as Record<string, unknown>;
      const args = params["arguments"] as Record<string, unknown>;

      expect(args["agent_name"]).toBe("developer-bd-xyz9");
      expect(args["paths"]).toEqual(["/path/to/file.ts", "/path/to/other.ts"]);
      expect(args["project_key"]).toBe("foreman");
    });

    it("does not throw on network error", async () => {
      mockFetch.mockRejectedValueOnce(new Error("timeout"));
      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      await expect(
        client.releaseReservation(["/file.ts"], "agent-name"),
      ).resolves.toBeUndefined();
    });
  });

  describe("fileReservation", () => {
    it("sends correct arguments for exclusive reservation", async () => {
      mockFetch.mockResolvedValueOnce(mcpOkResponse({ success: true }));

      const client = new AgentMailClient({
        baseUrl: "http://localhost:8766",
        projectKey: "foreman",
      });
      await client.fileReservation(["/src/main.ts"], {
        agent: "developer-bd-test",
        durationMs: 60_000,
      });

      const [, init] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as Record<string, unknown>;
      const params = body["params"] as Record<string, unknown>;
      const args = params["arguments"] as Record<string, unknown>;

      expect(args["agent_name"]).toBe("developer-bd-test");
      expect(args["paths"]).toEqual(["/src/main.ts"]);
      expect(args["ttl_seconds"]).toBe(60);
      expect(args["exclusive"]).toBe(true);
      expect(args["reason"]).toBe("foreman-phase-reservation");
    });

    it("returns { success: true } on successful reservation", async () => {
      mockFetch.mockResolvedValueOnce(mcpOkResponse({ success: true }));
      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      const result = await client.fileReservation(["/file.ts"], { agent: "agent" });
      expect(result.success).toBe(true);
    });

    it("returns { success: false } on network error", async () => {
      mockFetch.mockRejectedValueOnce(new Error("timeout"));
      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      const result = await client.fileReservation(["/file.ts"], { agent: "agent" });
      expect(result).toEqual({ success: false });
    });

    it("includes conflicts when server reports them", async () => {
      const serverResponse = {
        success: false,
        conflicts: [
          {
            path: "/src/main.ts",
            held_by: "developer-bd-other",
            expires_at: "2026-01-01T12:00:00Z",
          },
        ],
      };
      mockFetch.mockResolvedValueOnce(mcpOkResponse(serverResponse));

      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      const result = await client.fileReservation(["/src/main.ts"], { agent: "agent" });

      expect(result.success).toBe(false);
      expect(result.conflicts).toHaveLength(1);
      expect(result.conflicts![0].path).toBe("/src/main.ts");
      expect(result.conflicts![0].heldBy).toBe("developer-bd-other");
      expect(result.conflicts![0].expiresAt).toBe("2026-01-01T12:00:00Z");
    });
  });

  describe("healthCheck", () => {
    it("hits GET /health and returns true on 2xx", async () => {
      mockFetch.mockResolvedValueOnce(healthOkResponse());

      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      const result = await client.healthCheck();

      expect(result).toBe(true);
      expect(mockFetch).toHaveBeenCalledOnce();
      const [url, init] = mockFetch.mock.calls[0] as [string, RequestInit];
      expect(url).toBe("http://localhost:8766/health");
      expect(init.method).toBe("GET");
    });

    it("returns false on 4xx/5xx response", async () => {
      mockFetch.mockResolvedValueOnce(
        new Response("Service Unavailable", { status: 503 }),
      );
      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      expect(await client.healthCheck()).toBe(false);
    });

    it("returns false on network error", async () => {
      mockFetch.mockRejectedValueOnce(new Error("connection refused"));
      const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
      expect(await client.healthCheck()).toBe(false);
    });
  });

  describe("Config resolution", () => {
    it("uses DEFAULT_AGENT_MAIL_CONFIG defaults when nothing is provided", () => {
      const client = new AgentMailClient();
      // We can't access private fields directly, but we can verify via behaviour:
      // healthCheck will use the default baseUrl
      expect(DEFAULT_AGENT_MAIL_CONFIG.baseUrl).toBe("http://localhost:8766");
      // projectKey defaults to process.cwd() (not a hardcoded slug)
      expect(DEFAULT_AGENT_MAIL_CONFIG.projectKey).toBe(process.cwd());
      expect(DEFAULT_AGENT_MAIL_CONFIG.timeoutMs).toBe(3000);
      void client; // suppress unused variable warning
    });

    it("AGENT_MAIL_URL env var overrides default baseUrl", async () => {
      process.env.AGENT_MAIL_URL = "http://custom-host:9999";
      mockFetch.mockResolvedValueOnce(healthOkResponse());

      const client = new AgentMailClient();
      await client.healthCheck();

      const [url] = mockFetch.mock.calls[0] as [string, RequestInit];
      expect(url).toBe("http://custom-host:9999/health");
    });

    it("AGENT_MAIL_TOKEN env var sets bearer token", async () => {
      process.env.AGENT_MAIL_TOKEN = "env-token";
      mockFetch.mockResolvedValueOnce(mcpOkResponse({}));

      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      await client.ensureProject("/some/path");

      const [, init] = mockFetch.mock.calls[0] as [string, RequestInit];
      expect((init.headers as Record<string, string>)["Authorization"]).toBe("Bearer env-token");
    });

    it("AGENT_MAIL_PROJECT env var sets project key", async () => {
      process.env.AGENT_MAIL_PROJECT = "env-project";
      mockFetch.mockResolvedValueOnce(mcpOkResponse({}));

      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      // sendMessage requires agentName to be set (returns early otherwise)
      client.agentName = "TestSender";
      await client.sendMessage("agent", "subj", "body");

      const [, init] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as Record<string, unknown>;
      const params = body["params"] as Record<string, unknown>;
      const args = params["arguments"] as Record<string, unknown>;
      expect(args["project_key"]).toBe("env-project");
    });

    it("constructor arg takes highest priority over env var", async () => {
      process.env.AGENT_MAIL_URL = "http://env-host:1111";
      mockFetch.mockResolvedValueOnce(healthOkResponse());

      const client = new AgentMailClient({ baseUrl: "http://constructor-host:2222" });
      await client.healthCheck();

      const [url] = mockFetch.mock.calls[0] as [string, RequestInit];
      expect(url).toBe("http://constructor-host:2222/health");
    });
  });

  describe("registerAgent", () => {
    it("calls register_agent with correct fields (no name — auto-generated by server)", async () => {
      mockFetch.mockResolvedValueOnce(mcpOkResponse({ name: "CalmDuck" }));

      const client = new AgentMailClient({
        baseUrl: "http://localhost:8766",
        projectKey: "foreman",
      });
      await client.registerAgent("developer-bd-test");

      const [, init] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as Record<string, unknown>;
      const params = body["params"] as Record<string, unknown>;
      const args = params["arguments"] as Record<string, unknown>;

      expect(args["project_key"]).toBe("foreman");
      expect(args["program"]).toBe("foreman");
      expect(args["model"]).toBe("claude-sonnet-4-6");
      // name is intentionally omitted — Agent Mail auto-generates adjective+noun names
      expect(Object.keys(args)).not.toContain("name");
    });

    it("does not throw on network error", async () => {
      mockFetch.mockRejectedValueOnce(new Error("connection refused"));
      const client = new AgentMailClient({ baseUrl: "http://localhost:9999" });
      await expect(client.registerAgent("agent")).resolves.toBeUndefined();
    });
  });

  describe("acknowledgeMessage", () => {
    it("calls acknowledge_message with correct fields", async () => {
      mockFetch.mockResolvedValueOnce(mcpOkResponse({}));

      const client = new AgentMailClient({
        baseUrl: "http://localhost:8766",
        projectKey: "foreman",
      });
      await client.acknowledgeMessage("developer-bd-abc1", 42);

      const [, init] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as Record<string, unknown>;
      const params = body["params"] as Record<string, unknown>;
      const args = params["arguments"] as Record<string, unknown>;

      expect(args["project_key"]).toBe("foreman");
      expect(args["agent_name"]).toBe("developer-bd-abc1");
      expect(args["message_id"]).toBe(42);
    });

    it("does not throw on network error", async () => {
      mockFetch.mockRejectedValueOnce(new Error("timeout"));
      const client = new AgentMailClient({ baseUrl: "http://localhost:8766" });
      await expect(client.acknowledgeMessage("agent", 1)).resolves.toBeUndefined();
    });
  });
});
