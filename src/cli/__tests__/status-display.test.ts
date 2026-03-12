import { describe, it, expect } from "vitest";
import type { Run, RunProgress } from "../../lib/store.js";
import { renderAgentCard, renderAgentCardSummary } from "../watch-ui.js";

/**
 * Tests for the unified agent status display helpers in watch-ui.ts.
 *
 * Covers `renderAgentCard` (expanded) and `renderAgentCardSummary` (collapsed),
 * focusing on the `currentPhase` pipeline-phase display that is shared between
 * `foreman run` (watch UI) and `foreman status`.
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

// ── renderAgentCard (expanded) — currentPhase display ────────────────────

describe("renderAgentCard (expanded) — currentPhase display", () => {
  it("shows Phase row when currentPhase is 'explorer'", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: "explorer" }), true);
    expect(card).toContain("Phase");
    expect(card).toContain("explorer");
  });

  it("shows Phase row when currentPhase is 'developer'", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: "developer" }), true);
    expect(card).toContain("Phase");
    expect(card).toContain("developer");
  });

  it("shows Phase row when currentPhase is 'qa'", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: "qa" }), true);
    expect(card).toContain("Phase");
    expect(card).toContain("qa");
  });

  it("shows Phase row when currentPhase is 'reviewer'", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: "reviewer" }), true);
    expect(card).toContain("Phase");
    expect(card).toContain("reviewer");
  });

  it("shows Phase row when currentPhase is 'finalize'", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: "finalize" }), true);
    expect(card).toContain("Phase");
    expect(card).toContain("finalize");
  });

  it("omits Phase row when currentPhase is undefined", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: undefined }), true);
    expect(card).not.toContain("Phase");
  });

  it("still renders Tools row alongside the Phase row", () => {
    const card = renderAgentCard(makeRun(), makeProgress({ currentPhase: "qa", toolCalls: 12 }), true);
    expect(card).toContain("Phase");
    expect(card).toContain("Tools");
  });

  it("shows lastToolCall in the Tools row even when currentPhase is set", () => {
    const card = renderAgentCard(
      makeRun(),
      makeProgress({ currentPhase: "developer", lastToolCall: "Edit" }),
      true,
    );
    expect(card).toContain("Phase");
    expect(card).toContain("developer");
    expect(card).toContain("last: Edit");
  });
});

// ── renderAgentCard (collapsed / summary) — currentPhase display ─────────

describe("renderAgentCardSummary — currentPhase display", () => {
  it("shows [phase] bracket notation when currentPhase is set", () => {
    const summary = renderAgentCardSummary(makeRun(), makeProgress({ currentPhase: "reviewer" }));
    expect(summary).toContain("[reviewer]");
  });

  it("shows 'last: <tool>' when currentPhase is absent", () => {
    const summary = renderAgentCardSummary(
      makeRun(),
      makeProgress({ currentPhase: undefined, lastToolCall: "Read" }),
    );
    expect(summary).toContain("last: Read");
  });

  it("currentPhase takes priority over lastToolCall in summary", () => {
    const summary = renderAgentCardSummary(
      makeRun(),
      makeProgress({ currentPhase: "finalize", lastToolCall: "Bash" }),
    );
    expect(summary).toContain("[finalize]");
    expect(summary).not.toContain("last: Bash");
  });

  it("shows all five pipeline phases correctly", () => {
    const phases = ["explorer", "developer", "qa", "reviewer", "finalize"] as const;
    for (const phase of phases) {
      const summary = renderAgentCardSummary(makeRun(), makeProgress({ currentPhase: phase }));
      expect(summary).toContain(`[${phase}]`);
    }
  });
});

// ── renderAgentCard — delegating to summary when collapsed ───────────────

describe("renderAgentCard — collapsed delegates to summary", () => {
  it("collapsed card contains phase bracket notation same as summary", () => {
    const run = makeRun();
    const progress = makeProgress({ currentPhase: "explorer" });
    const collapsed = renderAgentCard(run, progress, false);
    const summary = renderAgentCardSummary(run, progress);
    expect(collapsed).toBe(summary);
  });
});

// ── renderAgentCard — tool breakdown rendering ───────────────────────────

describe("renderAgentCard (expanded) — tool breakdown", () => {
  it("renders tool breakdown bar chart for top tools", () => {
    const progress = makeProgress({
      toolBreakdown: { Agent: 3, Bash: 10, Read: 5 },
      lastToolCall: "Bash",
    });
    const card = renderAgentCard(makeRun(), progress, true);
    expect(card).toContain("Agent");
    expect(card).toContain("Bash");
    expect(card).toContain("Read");
  });

  it("shows files changed count", () => {
    const progress = makeProgress({
      filesChanged: ["src/foo.ts", "src/bar.ts"],
    });
    const card = renderAgentCard(makeRun(), progress, true);
    expect(card).toContain("Files");
    expect(card).toContain("2");
  });
});
