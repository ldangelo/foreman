import { describe, it, expect } from "vitest";
import type { Run, RunProgress } from "../../lib/store.js";
import { renderAgentCard } from "../watch-ui.js";

/**
 * Tests for renderAgentCard in watch-ui.ts — the unified agent display
 * used by both `foreman run` (watch UI) and `foreman status`.
 *
 * Focus areas:
 *  - currentPhase pipeline-phase display (all five roles, colour-coded)
 *  - Correct omission of Phase row when no phase is set
 *  - Tool breakdown and lastToolCall display
 *  - Files changed listing
 */

// ── Fixtures ─────────────────────────────────────────────────────────────

function makeRun(overrides?: Partial<Run>): Run {
  return {
    id: "test-run-id",
    project_id: "test-project",
    seed_id: "foreman-abc1",
    agent_type: "claude-sonnet-4-5",
    session_key: null,
    worktree_path: null,
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    ...overrides,
  };
}

function makeProgress(overrides?: Partial<RunProgress>): RunProgress {
  return {
    toolCalls: 5,
    toolBreakdown: { Bash: 3, Read: 2 },
    filesChanged: [],
    turns: 3,
    costUsd: 0.0012,
    tokensIn: 1000,
    tokensOut: 500,
    lastToolCall: "Bash",
    lastActivity: new Date().toISOString(),
    ...overrides,
  };
}

// ── currentPhase display ─────────────────────────────────────────────────

describe("renderAgentCard — currentPhase display", () => {
  it("shows Phase row when currentPhase is 'explorer'", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: "explorer" }));
    expect(card).toContain("Phase");
    expect(card).toContain("explorer");
  });

  it("shows Phase row when currentPhase is 'developer'", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: "developer" }));
    expect(card).toContain("Phase");
    expect(card).toContain("developer");
  });

  it("shows Phase row when currentPhase is 'qa'", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: "qa" }));
    expect(card).toContain("Phase");
    expect(card).toContain("qa");
  });

  it("shows Phase row when currentPhase is 'reviewer'", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: "reviewer" }));
    expect(card).toContain("Phase");
    expect(card).toContain("reviewer");
  });

  it("shows Phase row when currentPhase is 'finalize'", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: "finalize" }));
    expect(card).toContain("Phase");
    expect(card).toContain("finalize");
  });

  it("omits Phase row when currentPhase is undefined", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: undefined }));
    expect(card).not.toContain("Phase");
  });

  it("still renders Tools row alongside Phase row", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: "qa", toolCalls: 12 }));
    expect(card).toContain("Phase");
    expect(card).toContain("Tools");
  });

  it("shows lastToolCall in the Tools row even when currentPhase is set", () => {
    const card = renderAgentCard(
      makeRun(),
      makeProgress({ currentPhase: "developer", lastToolCall: "Edit" }),
    );
    expect(card).toContain("Phase");
    expect(card).toContain("developer");
    expect(card).toContain("last: Edit");
  });
});

// ── Tool breakdown rendering ─────────────────────────────────────────────

describe("renderAgentCard — tool breakdown", () => {
  it("renders tool breakdown bar chart for top tools", () => {
    const progress = makeProgress({
      toolBreakdown: { Agent: 3, Bash: 10, Read: 5 },
      lastToolCall: "Bash",
    });
    const card = renderAgentCard(makeRun(), progress);
    expect(card).toContain("Agent");
    expect(card).toContain("Bash");
    expect(card).toContain("Read");
  });

  it("shows sub-agent count in breakdown when Agent tool calls exist", () => {
    const progress = makeProgress({
      toolBreakdown: { Agent: 3, Bash: 10 },
      lastToolCall: "Agent",
    });
    const card = renderAgentCard(makeRun(), progress);
    expect(card).toContain("Agent");
    // Count appears in the breakdown bar
    expect(card).toContain("3");
  });

  it("shows lastToolCall annotation in Tools row", () => {
    const progress = makeProgress({ lastToolCall: "Read" });
    const card = renderAgentCard(makeRun(), progress);
    expect(card).toContain("last: Read");
  });

  it("omits lastToolCall annotation when lastToolCall is null", () => {
    const progress = makeProgress({ lastToolCall: null });
    const card = renderAgentCard(makeRun(), progress);
    // Tools row exists but has no "last:" annotation
    expect(card).toContain("Tools");
    expect(card).not.toContain("last:");
  });
});

// ── Files changed rendering ──────────────────────────────────────────────

describe("renderAgentCard — files changed", () => {
  it("shows files changed count", () => {
    const progress = makeProgress({ filesChanged: ["src/foo.ts", "src/bar.ts"] });
    const card = renderAgentCard(makeRun(), progress);
    expect(card).toContain("Files");
    expect(card).toContain("2");
  });

  it("shows individual filenames (up to 5)", () => {
    const progress = makeProgress({ filesChanged: ["src/foo.ts", "src/bar.ts"] });
    const card = renderAgentCard(makeRun(), progress);
    expect(card).toContain("foo.ts");
    expect(card).toContain("bar.ts");
  });

  it("shows '+N more' when more than 5 files changed", () => {
    const progress = makeProgress({
      filesChanged: ["a.ts", "b.ts", "c.ts", "d.ts", "e.ts", "f.ts"],
    });
    const card = renderAgentCard(makeRun(), progress);
    expect(card).toContain("+1 more");
  });
});

// ── Initializing / pending states ────────────────────────────────────────

describe("renderAgentCard — pending / initializing states", () => {
  it("shows 'Initializing...' for a running run with no tool calls yet", () => {
    const card = renderAgentCard(
      makeRun({ status: "running" }),
      makeProgress({ toolCalls: 0 }),
    );
    expect(card).toContain("Initializing");
  });

  it("shows nothing extra for a pending run with no progress", () => {
    const card = renderAgentCard(makeRun({ status: "pending" }), null);
    expect(card).not.toContain("Cost");
    expect(card).not.toContain("Phase");
  });
});
