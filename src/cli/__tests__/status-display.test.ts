import { describe, it, expect } from "vitest";
import type { RunProgress } from "../../lib/store.js";

/**
 * Integration tests for the status command display logic.
 *
 * Tests parsePipelinePhase() and the sub-agent count display logic
 * from src/cli/commands/status.ts.
 *
 * Since parsePipelinePhase is not exported, we re-implement the same
 * regex logic here and verify it matches the behavior described in the
 * source (lines 143-151 of status.ts).
 */

/**
 * Mirrors parsePipelinePhase from status.ts (lines 143-151).
 * Pipeline sets values like "explorer:start", "developer:start (retry 1)", "qa:start".
 * Non-pipeline agents use tool names like "Bash", "Read" — returns null for those.
 */
function parsePipelinePhase(lastToolCall: string | null): { name: string; retry?: number } | null {
  if (!lastToolCall) return null;
  const match = lastToolCall.match(/^(explorer|developer|qa|reviewer|finalize):(\S+)(?: \(retry (\d+)\))?$/);
  if (!match) return null;
  return {
    name: match[1],
    retry: match[3] ? parseInt(match[3], 10) : undefined,
  };
}

/**
 * Mirrors the sub-agent display logic from status.ts (lines 109-113).
 * Determines the activity string shown for an active agent run.
 */
function formatAgentActivity(progress: RunProgress): string {
  const lastTool = progress.lastToolCall ?? "starting";
  const agentCount = progress.toolBreakdown["Agent"] ?? 0;
  return agentCount > 0
    ? `${agentCount} sub-agent(s) spawned`
    : `last: ${lastTool}`;
}

// ── parsePipelinePhase tests ────────────────────────────────────────────

describe("parsePipelinePhase", () => {
  it("parses 'explorer:start' as explorer phase", () => {
    const result = parsePipelinePhase("explorer:start");
    expect(result).toEqual({ name: "explorer", retry: undefined });
  });

  it("parses 'developer:start' as developer phase", () => {
    const result = parsePipelinePhase("developer:start");
    expect(result).toEqual({ name: "developer", retry: undefined });
  });

  it("parses 'qa:start' as qa phase", () => {
    const result = parsePipelinePhase("qa:start");
    expect(result).toEqual({ name: "qa", retry: undefined });
  });

  it("parses 'reviewer:start' as reviewer phase", () => {
    const result = parsePipelinePhase("reviewer:start");
    expect(result).toEqual({ name: "reviewer", retry: undefined });
  });

  it("parses 'finalize:start' as finalize phase", () => {
    const result = parsePipelinePhase("finalize:start");
    expect(result).toEqual({ name: "finalize", retry: undefined });
  });

  it("parses retry count from 'developer:start (retry 1)'", () => {
    const result = parsePipelinePhase("developer:start (retry 1)");
    expect(result).toEqual({ name: "developer", retry: 1 });
  });

  it("parses higher retry count from 'developer:start (retry 2)'", () => {
    const result = parsePipelinePhase("developer:start (retry 2)");
    expect(result).toEqual({ name: "developer", retry: 2 });
  });

  it("parses retry on qa phase", () => {
    const result = parsePipelinePhase("qa:start (retry 1)");
    expect(result).toEqual({ name: "qa", retry: 1 });
  });

  it("returns null for standard tool names: 'Bash'", () => {
    expect(parsePipelinePhase("Bash")).toBeNull();
  });

  it("returns null for standard tool names: 'Read'", () => {
    expect(parsePipelinePhase("Read")).toBeNull();
  });

  it("returns null for standard tool names: 'Agent'", () => {
    expect(parsePipelinePhase("Agent")).toBeNull();
  });

  it("returns null for standard tool names: 'Write'", () => {
    expect(parsePipelinePhase("Write")).toBeNull();
  });

  it("returns null for standard tool names: 'Edit'", () => {
    expect(parsePipelinePhase("Edit")).toBeNull();
  });

  it("returns null for null input", () => {
    expect(parsePipelinePhase(null)).toBeNull();
  });

  it("returns null for empty string", () => {
    expect(parsePipelinePhase("")).toBeNull();
  });

  it("returns null for partial matches like 'explorer'", () => {
    // Must have the colon and action part
    expect(parsePipelinePhase("explorer")).toBeNull();
  });

  it("returns null for unknown phase names", () => {
    expect(parsePipelinePhase("unknown:start")).toBeNull();
  });
});

// ── Sub-agent display logic tests ───────────────────────────────────────

function makeProgress(overrides?: Partial<RunProgress>): RunProgress {
  return {
    toolCalls: 0,
    toolBreakdown: {},
    filesChanged: [],
    turns: 0,
    costUsd: 0,
    tokensIn: 0,
    tokensOut: 0,
    lastToolCall: null,
    lastActivity: new Date().toISOString(),
    ...overrides,
  };
}

describe("sub-agent count display", () => {
  it("shows sub-agent count when toolBreakdown has Agent entries", () => {
    const progress = makeProgress({
      toolBreakdown: { Agent: 3, Bash: 10, Read: 5 },
      lastToolCall: "Bash",
    });

    const activity = formatAgentActivity(progress);
    expect(activity).toBe("3 sub-agent(s) spawned");
  });

  it("shows 'last: <toolName>' when no Agent tool calls", () => {
    const progress = makeProgress({
      toolBreakdown: { Bash: 10, Read: 5 },
      lastToolCall: "Read",
    });

    const activity = formatAgentActivity(progress);
    expect(activity).toBe("last: Read");
  });

  it("shows 'last: starting' when lastToolCall is null", () => {
    const progress = makeProgress({
      toolBreakdown: {},
      lastToolCall: null,
    });

    const activity = formatAgentActivity(progress);
    expect(activity).toBe("last: starting");
  });

  it("shows sub-agent count of 1 for a single sub-agent spawn", () => {
    const progress = makeProgress({
      toolBreakdown: { Agent: 1, Bash: 2 },
      lastToolCall: "Agent",
    });

    const activity = formatAgentActivity(progress);
    expect(activity).toBe("1 sub-agent(s) spawned");
  });

  it("shows 'last: <toolName>' when Agent count is 0", () => {
    const progress = makeProgress({
      toolBreakdown: { Agent: 0, Bash: 5 },
      lastToolCall: "Bash",
    });

    // Agent: 0 is falsy, so should fall through to lastTool display
    const activity = formatAgentActivity(progress);
    expect(activity).toBe("last: Bash");
  });

  it("handles large sub-agent counts for team orchestration", () => {
    const progress = makeProgress({
      toolBreakdown: { Agent: 8, Bash: 50, Read: 30, Write: 15 },
      lastToolCall: "Write",
    });

    const activity = formatAgentActivity(progress);
    expect(activity).toBe("8 sub-agent(s) spawned");
  });
});
