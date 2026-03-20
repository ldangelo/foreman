/**
 * Tests for Pi RPC Stats section in `foreman status`.
 *
 * TRD-019 / bd-ay61: foreman status Pi RPC Stats
 *
 * Verifies that:
 * 1. Pi RPC runs with RunProgress data show the Pi RPC Stats section.
 * 2. Non-Pi runs do not show the Pi RPC Stats section.
 * 3. Pi runs with no RunProgress yet show no stats (graceful).
 * 4. Token and turn counts are displayed correctly.
 * 5. Last tool call relative time is displayed.
 */

import { describe, it, expect, vi } from "vitest";

// Mock AgentMailClient (imported transitively via status.ts)
vi.mock("../../../orchestrator/agent-mail-client.js", () => {
  class MockAgentMailClient {
    healthCheck() { return Promise.resolve(false); }
    fetchInbox() { return Promise.resolve([]); }
  }
  return { AgentMailClient: MockAgentMailClient };
});

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

import type { Run, RunProgress } from "../../../lib/store.js";
import {
  hasPiRpcProgress,
  formatNumber,
  formatRelativeTime,
  renderPiRpcStatsSection,
} from "../status.js";

// ── Helpers ────────────────────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-abc123",
    project_id: "proj-1",
    seed_id: "bd-test",
    agent_type: "worker",
    session_key: null,
    worktree_path: "/fake/worktree",
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    tmux_session: null,
    ...overrides,
  };
}

function makeProgress(overrides: Partial<RunProgress> = {}): RunProgress {
  return {
    toolCalls: 5,
    toolBreakdown: { Edit: 3, Read: 2 },
    filesChanged: [],
    turns: 12,
    costUsd: 0.05,
    tokensIn: 30000,
    tokensOut: 15230,
    lastToolCall: "Edit",
    lastActivity: new Date(Date.now() - 23_000).toISOString(), // 23s ago
    currentPhase: "developer",
    maxTurns: 80,
    maxTokens: 500_000,
    model: "claude-sonnet-4-6",
    ...overrides,
  };
}

// ── hasPiRpcProgress tests ─────────────────────────────────────────────────

describe("hasPiRpcProgress", () => {
  it("returns true when session_key starts with foreman:pi-rpc:", () => {
    const run = makeRun({ session_key: "foreman:pi-rpc:claude-sonnet-4-6:run-1:session-abc" });
    expect(hasPiRpcProgress(run, null)).toBe(true);
  });

  it("returns true when RunProgress.lastToolCall is set", () => {
    const run = makeRun();
    const progress = makeProgress({ lastToolCall: "Edit", currentPhase: undefined });
    expect(hasPiRpcProgress(run, progress)).toBe(true);
  });

  it("returns true when RunProgress.currentPhase is set", () => {
    const run = makeRun();
    const progress = makeProgress({ lastToolCall: null, currentPhase: "developer" });
    expect(hasPiRpcProgress(run, progress)).toBe(true);
  });

  it("returns false for non-Pi run with no progress", () => {
    const run = makeRun({ session_key: null });
    expect(hasPiRpcProgress(run, null)).toBe(false);
  });

  it("returns false for non-Pi run with progress that lacks Pi fields", () => {
    const run = makeRun({ session_key: "some-other-key" });
    const progress = makeProgress({ lastToolCall: null, currentPhase: undefined });
    expect(hasPiRpcProgress(run, progress)).toBe(false);
  });
});

// ── formatNumber tests ─────────────────────────────────────────────────────

describe("formatNumber", () => {
  it("formats zero correctly", () => {
    expect(formatNumber(0)).toBe("0");
  });

  it("formats small number without comma", () => {
    expect(formatNumber(999)).toBe("999");
  });

  it("formats thousands with comma", () => {
    expect(formatNumber(45230)).toBe("45,230");
  });

  it("formats large number with multiple commas", () => {
    expect(formatNumber(1_000_000)).toBe("1,000,000");
  });

  it("formats 500000 correctly", () => {
    expect(formatNumber(500_000)).toBe("500,000");
  });
});

// ── formatRelativeTime tests ───────────────────────────────────────────────

describe("formatRelativeTime", () => {
  it("returns undefined for null input", () => {
    expect(formatRelativeTime(null)).toBeUndefined();
  });

  it("returns undefined for undefined input", () => {
    expect(formatRelativeTime(undefined)).toBeUndefined();
  });

  it("returns seconds ago for recent timestamp", () => {
    const ts = new Date(Date.now() - 23_000).toISOString();
    expect(formatRelativeTime(ts)).toBe("23s ago");
  });

  it("returns minutes ago for older timestamp", () => {
    const ts = new Date(Date.now() - 5 * 60_000).toISOString();
    expect(formatRelativeTime(ts)).toBe("5m ago");
  });

  it("returns hours ago for very old timestamp", () => {
    const ts = new Date(Date.now() - 2 * 60 * 60_000).toISOString();
    expect(formatRelativeTime(ts)).toBe("2h ago");
  });

  it("returns 'just now' for future timestamps (clock skew)", () => {
    const ts = new Date(Date.now() + 5_000).toISOString();
    expect(formatRelativeTime(ts)).toBe("just now");
  });
});

// ── renderPiRpcStatsSection tests ──────────────────────────────────────────

describe("renderPiRpcStatsSection", () => {
  it("renders Pi RPC Stats section for a Pi run with progress", () => {
    const run = makeRun({ session_key: "foreman:pi-rpc:claude-sonnet-4-6:run-abc:session-xyz" });
    const progress = makeProgress();
    const lines: string[] = [];

    renderPiRpcStatsSection(run, progress, (line) => lines.push(line));

    const combined = lines.join("\n");
    // Should include section header
    expect(combined).toMatch(/Pi RPC Stats/);
    // Should show model
    expect(combined).toMatch(/claude-sonnet-4-6/);
    // Should show phase
    expect(combined).toMatch(/developer/);
    // Should show turns as "12 / 80"
    expect(combined).toMatch(/12 \/ 80/);
    // Should show tokens (45230 combined) formatted
    expect(combined).toMatch(/45,230/);
    // Should show max tokens formatted
    expect(combined).toMatch(/500,000/);
    // Should show last tool call
    expect(combined).toMatch(/Edit/);
    // Should show relative time
    expect(combined).toMatch(/\d+s ago/);
  });

  it("renders nothing for non-Pi run with no progress", () => {
    const run = makeRun({ session_key: null });
    const lines: string[] = [];

    renderPiRpcStatsSection(run, null, (line) => lines.push(line));

    expect(lines).toHaveLength(0);
  });

  it("renders nothing for Pi run with null progress (no data yet)", () => {
    // Even if session_key signals Pi, if there is no RunProgress don't render
    const run = makeRun({ session_key: "foreman:pi-rpc:claude-sonnet-4-6:run-abc:session-xyz" });
    const lines: string[] = [];

    renderPiRpcStatsSection(run, null, (line) => lines.push(line));

    expect(lines).toHaveLength(0);
  });

  it("renders turn count without max when maxTurns is absent", () => {
    const run = makeRun({ session_key: "foreman:pi-rpc:x:y:session-z" });
    const progress = makeProgress({ maxTurns: undefined });
    const lines: string[] = [];

    renderPiRpcStatsSection(run, progress, (line) => lines.push(line));

    const combined = lines.join("\n");
    // Should show turns without "/" separator
    expect(combined).toMatch(/Turns:\s+12/);
    expect(combined).not.toMatch(/12 \//);
  });

  it("renders token count without max when maxTokens is absent", () => {
    const run = makeRun({ session_key: "foreman:pi-rpc:x:y:session-z" });
    const progress = makeProgress({ maxTokens: undefined });
    const lines: string[] = [];

    renderPiRpcStatsSection(run, progress, (line) => lines.push(line));

    const combined = lines.join("\n");
    expect(combined).toMatch(/45,230/);
    expect(combined).not.toMatch(/45,230 \//);
  });

  it("does not render Last tool line when lastToolCall is null", () => {
    const run = makeRun({ session_key: "foreman:pi-rpc:x:y:session-z" });
    const progress = makeProgress({ lastToolCall: null });
    const lines: string[] = [];

    renderPiRpcStatsSection(run, progress, (line) => lines.push(line));

    const combined = lines.join("\n");
    expect(combined).not.toMatch(/Last tool/);
  });

  it("renders for Pi run detected via currentPhase (session_key not yet set)", () => {
    const run = makeRun({ session_key: null });
    const progress = makeProgress({ currentPhase: "explorer" });
    const lines: string[] = [];

    renderPiRpcStatsSection(run, progress, (line) => lines.push(line));

    const combined = lines.join("\n");
    expect(combined).toMatch(/Pi RPC Stats/);
    expect(combined).toMatch(/explorer/);
  });

  it("shows unknown model gracefully when model field is absent", () => {
    const run = makeRun({ session_key: "foreman:pi-rpc:x:y:session-z" });
    const progress = makeProgress({ model: undefined });
    const lines: string[] = [];

    renderPiRpcStatsSection(run, progress, (line) => lines.push(line));

    const combined = lines.join("\n");
    expect(combined).toMatch(/unknown/i);
  });
});
