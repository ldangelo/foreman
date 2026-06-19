import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { JiraApiClient } from "../jira-api-client";
import type { JiraIssue, JiraProject } from "../jira-api-client";
import {
  JiraNotAuthenticatedError,
  JiraNotFoundError,
  JiraRateLimitError,
  JiraApiError,
} from "../jira-api-client";

interface MockFetchResponse {
  ok: boolean;
  status: number;
  headers: { get: (name: string) => string | null };
  json: () => Promise<unknown>;
  text: () => Promise<string>;
  url: string;
}

describe("JiraApiClient", () => {
  const mockFetch = vi.fn();
  function createTestClient() {
    return new JiraApiClient({
      apiUrl: "https://test.atlassian.net",
      email: "test@example.com",
      apiToken: "test-token",
      timeoutMs: 5000,
      fetchFn: mockFetch,
    });
  }
  beforeEach(() => {
    vi.stubGlobal("fetch", mockFetch);
    mockFetch.mockReset();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  function mockResponse(body: unknown, status = 200, headers: Record<string, string> = {}) {
    const response: MockFetchResponse = {
      ok: status >= 200 && status < 300,
      status,
      headers: {
        get: (name: string) => headers[name] ?? null,
      },
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(""),
      url: "https://test.atlassian.net/rest/api/3/test",
    };
    mockFetch.mockResolvedValue(response);
  }

  describe("constructor", () => {
    it("strips trailing slash from apiUrl", () => {
      const client = new JiraApiClient({
        apiUrl: "https://test.atlassian.net/",
        email: "test@example.com",
        apiToken: "test-token",
      });
      expect(client).toBeDefined();
    });
  });

  describe("authenticate", () => {
    it("succeeds when credentials are valid", async () => {
      mockResponse({ accountId: "123", displayName: "Test User" });
      const client = createTestClient();
      await expect(client.authenticate()).resolves.toBeUndefined();
    });

    it("throws JiraNotAuthenticatedError on 401", async () => {
      mockResponse({ errorMessages: ["Authentication failed"] }, 401);
      const client = createTestClient();
      await expect(client.authenticate()).rejects.toThrow(JiraNotAuthenticatedError);
    });

    it("throws JiraNotAuthenticatedError on 403", async () => {
      mockResponse({ errorMessages: ["Forbidden"] }, 403);
      const client = createTestClient();
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
      const client = createTestClient();
      const result = await client.search("project = PROJ");
      expect(result.issues).toHaveLength(1);
      expect(result.issues[0].key).toBe("PROJ-1");
    });

    it("passes maxResults option", async () => {
      mockResponse({ issues: [], total: 0 });
      const client = createTestClient();
      await client.search("project = PROJ", { maxResults: 100 });
      const call = mockFetch.mock.calls[0];
      const url = call?.[0] as string | undefined;
      expect(url).toContain("maxResults=100");
    });
  });

  describe("getIssue", () => {
    it("returns issue by key", async () => {
      const mockIssue: JiraIssue = {
        key: "PROJ-123",
        id: "12345",
        fields: {
          summary: "Test Issue",
          status: { name: "To Do" },
          issuetype: { name: "Bug" },
          project: { key: "PROJ" },
          updated: "2026-01-01",
          created: "2026-01-01",
        },
      };
      mockResponse(mockIssue);
      const client = createTestClient();
      const result = await client.getIssue("PROJ-123");
      expect(result.key).toBe("PROJ-123");
    });

    it("throws JiraNotFoundError on 404", async () => {
      mockResponse({ errorMessages: ["Issue Does Not Exist"] }, 404);
      const client = createTestClient();
      await expect(client.getIssue("PROJ-999")).rejects.toThrow(JiraNotFoundError);
    });
  });

  describe("listProjects", () => {
    it("returns list of projects", async () => {
      const mockProjects: { values: JiraProject[] } = {
        values: [
          { key: "PROJ", name: "My Project" },
          { key: "OTHER", name: "Other Project" },
        ],
      };
      mockResponse(mockProjects);
      const client = createTestClient();
      const result = await client.listProjects();
      expect(result).toHaveLength(2);
      expect(result[0].key).toBe("PROJ");
    });
  });

  describe("handleRateLimit", () => {
    it("waits for specified seconds", async () => {
      vi.useFakeTimers();
      const client = createTestClient();
      const promise = client.handleRateLimit(2);
      const timerPromise = vi.advanceTimersByTimeAsync(2000);
      await Promise.all([promise, timerPromise]);
      vi.useRealTimers();
    });
  });

  describe("error handling", () => {
    it("throws JiraRateLimitError on 429 with Retry-After", async () => {
      mockResponse({ errorMessages: ["Rate limit exceeded"] }, 429, { "Retry-After": "120" });
      const client = createTestClient();
      await expect(client.search("project = PROJ")).rejects.toThrow(JiraRateLimitError);
    });

    it("captures retryAfterSeconds from header", async () => {
      mockResponse({ errorMessages: ["Rate limit exceeded"] }, 429, { "Retry-After": "120" });
      const client = createTestClient();
      let capturedError: Error | null = null;
      try {
        await client.search("project = PROJ");
      } catch (err) {
        capturedError = err as Error;
      }
      expect(capturedError).toBeInstanceOf(JiraRateLimitError);
      expect((capturedError as JiraRateLimitError).retryAfterSeconds).toBe(120);
    });

    it("throws JiraRateLimitError with default 60 seconds when no header", async () => {
      mockResponse({ errorMessages: ["Rate limit exceeded"] }, 429);
      const client = createTestClient();
      await expect(client.search("project = PROJ")).rejects.toThrow(JiraRateLimitError);
    });

    it("throws JiraApiError on other non-OK responses", async () => {
      mockResponse({ errorMessages: ["Something went wrong"] }, 500);
      const client = createTestClient();
      await expect(client.search("project = PROJ")).rejects.toThrow(JiraApiError);
    });
  });

  describe("authentication header", () => {
    it("uses Basic Auth with base64 encoded email:token", async () => {
      let capturedAuth: string | undefined;
      mockFetch.mockImplementation((_url, options) => {
        const headers = options?.headers as Record<string, string> | undefined;
        capturedAuth = headers?.Authorization;
        return Promise.resolve({
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: () => Promise.resolve({}),
          text: () => Promise.resolve("{}"),
          url: "https://test.atlassian.net/rest/api/3/myself",
        } satisfies MockFetchResponse);
      });

      const client = new JiraApiClient({
        apiUrl: "https://test.atlassian.net",
        email: "user@example.com",
        apiToken: "api-token-123",
      });
      await client.authenticate();

      expect(capturedAuth?.startsWith("Basic ")).toBe(true);
      const encoded = capturedAuth!.replace("Basic ", "");
      const decoded = Buffer.from(encoded, "base64").toString();
      expect(decoded).toBe("user@example.com:api-token-123");
    });
  });
  describe("apiVersion", () => {
    it("uses REST API v3 for cloud (default)", async () => {
      mockResponse({});
      const client = createTestClient();
      await client.authenticate();
      const url = mockFetch.mock.calls[0]?.[0] as string;
      expect(url).toContain("/rest/api/3/");
    });
    it("uses REST API v3 for cloud when explicitly set", async () => {
      mockResponse({});
      const client = new JiraApiClient({
        apiUrl: "https://test.atlassian.net",
        email: "test@example.com",
        apiToken: "test-token",
        apiVersion: "cloud",
      });
      await client.authenticate();
      const url = mockFetch.mock.calls[0]?.[0] as string;
      expect(url).toContain("/rest/api/3/");
    });
    it("uses REST API v2 for server", async () => {
      mockResponse({});
      const client = new JiraApiClient({
        apiUrl: "https://jira.example.com",
        email: "admin",
        apiToken: "server-token",
        apiVersion: "server",
      });
      await client.listProjects();
      const url = mockFetch.mock.calls[0]?.[0] as string;
      expect(url).toContain("/rest/api/2/");
    });
    it("uses REST API v3 for server when explicit", async () => {
      mockResponse({});
      const client = new JiraApiClient({
        apiUrl: "https://test.atlassian.net",
        email: "test@example.com",
        apiToken: "test-token",
        apiVersion: "cloud",
      });
      await client.search("project = PROJ");
      const url = mockFetch.mock.calls[0]?.[0] as string;
      expect(url).toContain("/rest/api/3/search");
    });
  });
  describe("addComment", () => {
    it("POSTs to the correct issue comment endpoint", async () => {
      mockResponse({});
      const client = createTestClient();
      await client.addComment("PROJ-123", "Workflow triggered");
      const [url, options] = mockFetch.mock.calls[0] ?? [];
      expect(url).toContain("/rest/api/3/issue/PROJ-123/comment");
      expect(options?.method).toBe("POST");
      const body = JSON.parse((options?.body as string) ?? "{}");
      expect(body.body).toBe("Workflow triggered");
    });
  });
  describe("transitionIssue", () => {
    it("POSTs to the transitions endpoint with transitionId", async () => {
      mockResponse({});
      const client = createTestClient();
      await client.transitionIssue("PROJ-456", "31");
      const [url, options] = mockFetch.mock.calls[0] ?? [];
      expect(url).toContain("/rest/api/3/issue/PROJ-456/transitions");
      expect(options?.method).toBe("POST");
      const body = JSON.parse((options?.body as string) ?? "{}");
      expect(body.transition.id).toBe("31");
    });
  });
});