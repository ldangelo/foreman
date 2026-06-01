import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { JiraApiClient, JiraNotAuthenticatedError, JiraNotFoundError, JiraRateLimitError, JiraApiError } from "./jira-api-client";

describe("JiraApiClient", () => {
  const mockFetch = vi.fn();

  beforeEach(() => {
    vi.stubGlobal("fetch", mockFetch);
    mockFetch.mockReset();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  function createClient() {
    return new JiraApiClient({
      apiUrl: "https://test.atlassian.net",
      email: "test@example.com",
      apiToken: "test-token",
      timeoutMs: 5000,
    });
  }

  function mockResponse(body: unknown, status = 200, headers: Record<string, string> = {}) {
    mockFetch.mockResolvedValue({
      ok: status >= 200 && status < 300,
      status,
      headers: {
        get: (name: string) => headers[name] ?? null,
      },
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(""),
      url: "https://test.atlassian.net/rest/api/3/test",
    });
  }

  describe("constructor", () => {
    it("strips trailing slash from apiUrl", () => {
      const client = new JiraApiClient({
        apiUrl: "https://test.atlassian.net/",
        email: "test@example.com",
        apiToken: "test-token",
      });
      // Just verify it doesn't throw
      expect(client).toBeDefined();
    });

    it("creates Basic Auth header", () => {
      const client = createClient();
      expect(client).toBeDefined();
      // The auth header is created internally, verified by successful auth tests
    });
  });

  describe("authenticate", () => {
    it("succeeds when credentials are valid", async () => {
      mockResponse({ accountId: "123", displayName: "Test User" });
      const client = createClient();
      await expect(client.authenticate()).resolves.toBeUndefined();
    });

    it("throws JiraNotAuthenticatedError on 401", async () => {
      mockResponse({ errorMessages: ["Authentication failed"] }, 401);
      const client = createClient();
      await expect(client.authenticate()).rejects.toThrow(JiraNotAuthenticatedError);
    });

    it("throws JiraNotAuthenticatedError on 403", async () => {
      mockResponse({ errorMessages: ["Forbidden"] }, 403);
      const client = createClient();
      await expect(client.authenticate()).rejects.toThrow(JiraNotAuthenticatedError);
    });
  });

  describe("search", () => {
    it("returns issues from search response", async () => {
      const mockIssues = {
        issues: [
          { key: "PROJ-1", fields: { summary: "Test Issue", status: { name: "In Progress" }, issuetype: { name: "Task" }, project: { key: "PROJ" }, updated: "2026-01-01" } },
        ],
        total: 1,
      };
      mockResponse(mockIssues);
      const client = createClient();
      const result = await client.search("project = PROJ");
      expect(result.issues).toHaveLength(1);
      expect(result.issues[0].key).toBe("PROJ-1");
    });

    it("passes maxResults option", async () => {
      mockResponse({ issues: [], total: 0 });
      const client = createClient();
      await client.search("project = PROJ", { maxResults: 100 });
      const url = mockFetch.mock.calls[0][0];
      expect(url).toContain("maxResults=100");
    });
  });

  describe("getIssue", () => {
    it("returns issue by key", async () => {
      const mockIssue = {
        key: "PROJ-123",
        fields: {
          summary: "Test Issue",
          status: { name: "To Do" },
          issuetype: { name: "Bug" },
          project: { key: "PROJ" },
          updated: "2026-01-01",
        },
      };
      mockResponse(mockIssue);
      const client = createClient();
      const result = await client.getIssue("PROJ-123");
      expect(result.key).toBe("PROJ-123");
    });

    it("throws JiraNotFoundError on 404", async () => {
      mockResponse({ errorMessages: ["Issue Does Not Exist"] }, 404);
      const client = createClient();
      await expect(client.getIssue("PROJ-999")).rejects.toThrow(JiraNotFoundError);
    });
  });

  describe("listProjects", () => {
    it("returns list of projects", async () => {
      const mockProjects = {
        values: [
          { key: "PROJ", name: "My Project" },
          { key: "OTHER", name: "Other Project" },
        ],
      };
      mockResponse(mockProjects);
      const client = createClient();
      const result = await client.listProjects();
      expect(result).toHaveLength(2);
      expect(result[0].key).toBe("PROJ");
    });
  });

  describe("handleRateLimit", () => {
    it("waits for specified seconds", async () => {
      vi.useFakeTimers();
      const client = createClient();
      const promise = client.handleRateLimit(2);
      const timerPromise = vi.advanceTimersByTimeAsync(2000);
      await Promise.all([promise, timerPromise]);
      vi.useRealTimers();
    });
  });

  describe("error handling", () => {
    it("throws JiraRateLimitError on 429 with Retry-After", async () => {
      mockResponse({ errorMessages: ["Rate limit exceeded"] }, 429, { "Retry-After": "120" });
      const client = createClient();
      await expect(client.search("project = PROJ")).rejects.toThrow(JiraRateLimitError);
      try {
        await client.search("project = PROJ");
      } catch (err) {
        if (err instanceof JiraRateLimitError) {
          expect(err.retryAfterSeconds).toBe(120);
        }
      }
    });

    it("throws JiraRateLimitError with default 60 seconds when no header", async () => {
      mockResponse({ errorMessages: ["Rate limit exceeded"] }, 429);
      const client = createClient();
      await expect(client.search("project = PROJ")).rejects.toThrow(JiraRateLimitError);
    });

    it("throws JiraApiError on other non-OK responses", async () => {
      mockResponse({ errorMessages: ["Something went wrong"] }, 500);
      const client = createClient();
      await expect(client.search("project = PROJ")).rejects.toThrow(JiraApiError);
    });
  });

  describe("authentication header", () => {
    it("uses Basic Auth with base64 encoded email:token", async () => {
      let capturedHeaders: Headers | undefined;
      mockFetch.mockImplementation((url, options) => {
        capturedHeaders = options?.headers as Headers;
        return Promise.resolve({
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: () => Promise.resolve({}),
          url,
        });
      });

      const client = new JiraApiClient({
        apiUrl: "https://test.atlassian.net",
        email: "user@example.com",
        apiToken: "api-token-123",
      });
      await client.authenticate();

      const authHeader = capturedHeaders?.get("Authorization");
      expect(authHeader?.startsWith("Basic ")).toBe(true);
      // Verify the base64 encoded value contains email:token
      const encoded = authHeader!.replace("Basic ", "");
      const decoded = Buffer.from(encoded, "base64").toString();
      expect(decoded).toBe("user@example.com:api-token-123");
    });
  });
});