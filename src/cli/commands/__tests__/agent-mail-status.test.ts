/**
 * Tests for Agent Mail integration in `foreman status` and `foreman monitor`.
 *
 * TRD-035: Agent Mail Status/Monitor Integration
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Mock AgentMailClient before any imports that use it ───────────────────────

const mockHealthCheck = vi.fn<() => Promise<boolean>>();
const mockFetchInbox = vi.fn<(agent: string) => Promise<{ id: string; from: string; subject: string; body: string; metadata?: Record<string, unknown> }[]>>();

vi.mock("../../../orchestrator/agent-mail-client.js", () => {
  class MockAgentMailClient {
    healthCheck() { return mockHealthCheck(); }
    fetchInbox(agent: string) { return mockFetchInbox(agent); }
  }
  return { AgentMailClient: MockAgentMailClient };
});

// ── Mock other heavy dependencies ─────────────────────────────────────────────

vi.mock("../../../lib/git.js", () => ({
  getRepoRoot: vi.fn().mockResolvedValue("/fake/project"),
}));

vi.mock("../../../lib/beads-rust.js", () => ({
  BeadsRustClient: vi.fn().mockImplementation(() => ({
    list: vi.fn().mockResolvedValue([]),
    ready: vi.fn().mockResolvedValue([]),
  })),
}));

vi.mock("../../../lib/store.js", () => ({
  ForemanStore: {
    forProject: vi.fn().mockReturnValue({
      getProjectByPath: vi.fn().mockReturnValue(null),
      getActiveRuns: vi.fn().mockReturnValue([]),
      getRunProgress: vi.fn().mockReturnValue(null),
      getMetrics: vi.fn().mockReturnValue({ totalCost: 0, totalTokens: 0 }),
      getRunsByStatusSince: vi.fn().mockReturnValue([]),
      close: vi.fn(),
    }),
  },
}));

vi.mock("../../../orchestrator/monitor.js", () => ({
  Monitor: vi.fn().mockImplementation(() => ({
    checkAll: vi.fn().mockResolvedValue({
      active: [],
      completed: [],
      stuck: [],
      failed: [],
    }),
  })),
}));

// ── Import modules under test after mocks are in place ───────────────────────

import { fetchAgentMailStatus } from "../status.js";
import { fetchAgentMailHealth } from "../monitor.js";

// ── Constants ─────────────────────────────────────────────────────────────────

const AGENT_MAILBOXES = [
  "explorer-agent",
  "developer-agent",
  "qa-agent",
  "reviewer-agent",
  "merge-agent",
];

// ── fetchAgentMailStatus tests ────────────────────────────────────────────────

describe("fetchAgentMailStatus", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns online=true with inbox counts when Agent Mail is healthy", async () => {
    mockHealthCheck.mockResolvedValue(true);
    // Return 3 messages for merge-agent, 0 for all others
    mockFetchInbox.mockImplementation(async (agent: string) => {
      if (agent === "merge-agent") {
        return [
          { id: "1", from: "a", subject: "s", body: "b" },
          { id: "2", from: "a", subject: "s", body: "b" },
          { id: "3", from: "a", subject: "s", body: "b" },
        ];
      }
      return [];
    });

    const result = await fetchAgentMailStatus();

    expect(result.online).toBe(true);
    expect(result.inboxCounts).toBeDefined();
    expect(result.inboxCounts!["merge-agent"]).toBe(3);
    expect(result.inboxCounts!["developer-agent"]).toBe(0);
    expect(result.inboxCounts!["qa-agent"]).toBe(0);
    expect(result.inboxCounts!["explorer-agent"]).toBe(0);
    expect(result.inboxCounts!["reviewer-agent"]).toBe(0);

    // fetchInbox should have been called for all 5 agents
    expect(mockFetchInbox).toHaveBeenCalledTimes(AGENT_MAILBOXES.length);
    for (const agent of AGENT_MAILBOXES) {
      expect(mockFetchInbox).toHaveBeenCalledWith(agent);
    }
  });

  it("returns online=false when Agent Mail healthCheck fails", async () => {
    mockHealthCheck.mockResolvedValue(false);

    const result = await fetchAgentMailStatus();

    expect(result.online).toBe(false);
    expect(result.inboxCounts).toBeUndefined();

    // fetchInbox should NOT be called when offline
    expect(mockFetchInbox).not.toHaveBeenCalled();
  });

  it("returns online=false when Agent Mail healthCheck throws", async () => {
    mockHealthCheck.mockRejectedValue(new Error("connection refused"));

    const result = await fetchAgentMailStatus();

    expect(result.online).toBe(false);
    expect(result.inboxCounts).toBeUndefined();
    expect(mockFetchInbox).not.toHaveBeenCalled();
  });

  it("returns online=true with zero counts when all inboxes are empty", async () => {
    mockHealthCheck.mockResolvedValue(true);
    mockFetchInbox.mockResolvedValue([]);

    const result = await fetchAgentMailStatus();

    expect(result.online).toBe(true);
    expect(result.inboxCounts).toBeDefined();
    for (const agent of AGENT_MAILBOXES) {
      expect(result.inboxCounts![agent]).toBe(0);
    }
  });

  it("includes all 5 expected agent mailboxes in inboxCounts", async () => {
    mockHealthCheck.mockResolvedValue(true);
    mockFetchInbox.mockResolvedValue([]);

    const result = await fetchAgentMailStatus();

    expect(result.online).toBe(true);
    expect(result.inboxCounts).toBeDefined();
    const keys = Object.keys(result.inboxCounts!);
    for (const agent of AGENT_MAILBOXES) {
      expect(keys).toContain(agent);
    }
  });
});

// ── fetchAgentMailHealth tests ────────────────────────────────────────────────

describe("fetchAgentMailHealth", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns online=true when Agent Mail healthCheck succeeds", async () => {
    mockHealthCheck.mockResolvedValue(true);

    const result = await fetchAgentMailHealth();

    expect(result.online).toBe(true);
  });

  it("returns online=false when Agent Mail healthCheck fails", async () => {
    mockHealthCheck.mockResolvedValue(false);

    const result = await fetchAgentMailHealth();

    expect(result.online).toBe(false);
  });

  it("returns online=false when Agent Mail healthCheck throws", async () => {
    mockHealthCheck.mockRejectedValue(new Error("network error"));

    const result = await fetchAgentMailHealth();

    expect(result.online).toBe(false);
  });
});

// ── Integration: renderAgentMailStatus output format ─────────────────────────

describe("renderAgentMailStatus output", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("shows online status and non-zero inbox counts in console output", async () => {
    mockHealthCheck.mockResolvedValue(true);
    mockFetchInbox.mockImplementation(async (agent: string) => {
      if (agent === "merge-agent") return [{ id: "1", from: "a", subject: "s", body: "b" }];
      if (agent === "developer-agent") return [{ id: "2", from: "b", subject: "t", body: "c" }, { id: "3", from: "c", subject: "u", body: "d" }];
      return [];
    });

    const { renderAgentMailSection } = await import("../status.js");
    const lines: string[] = [];
    const capture = (line: string) => lines.push(line);

    renderAgentMailSection({ online: true, inboxCounts: { "merge-agent": 1, "developer-agent": 2, "qa-agent": 0, "reviewer-agent": 0, "explorer-agent": 0 } }, capture);

    // Should include online indicator
    const combined = lines.join("\n");
    expect(combined).toMatch(/Agent Mail/);
    expect(combined).toMatch(/Online/i);
    // Should show agents with messages
    expect(combined).toMatch(/merge-agent/);
    expect(combined).toMatch(/developer-agent/);
  });

  it("shows offline message when Agent Mail is not running", async () => {
    const { renderAgentMailSection } = await import("../status.js");
    const lines: string[] = [];
    const capture = (line: string) => lines.push(line);

    renderAgentMailSection({ online: false }, capture);

    const combined = lines.join("\n");
    expect(combined).toMatch(/Agent Mail/);
    expect(combined).toMatch(/Offline/i);
    expect(combined).toMatch(/python -m mcp_agent_mail/);
  });

  it("shows monitor online message when Agent Mail is healthy", async () => {
    const { renderAgentMailMonitorLine } = await import("../monitor.js");
    const lines: string[] = [];
    const capture = (line: string) => lines.push(line);

    renderAgentMailMonitorLine({ online: true }, capture);

    const combined = lines.join("\n");
    expect(combined).toMatch(/Agent Mail/);
    expect(combined).toMatch(/online/i);
  });

  it("shows monitor offline message with suggested command when Agent Mail is down", async () => {
    const { renderAgentMailMonitorLine } = await import("../monitor.js");
    const lines: string[] = [];
    const capture = (line: string) => lines.push(line);

    renderAgentMailMonitorLine({ online: false }, capture);

    const combined = lines.join("\n");
    expect(combined).toMatch(/Agent Mail/);
    expect(combined).toMatch(/offline/i);
    expect(combined).toMatch(/python -m mcp_agent_mail/);
  });
});
