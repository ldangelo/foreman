/**
 * Tests for the session-log invocation in agent-worker.ts pipeline.
 *
 * Covers:
 * 1. buildSessionLogPrompt() — correct prompt structure and content
 * 2. SessionLogData interface shape — all required fields present
 * 3. Prompt includes /ensemble:sessionlog command prefix
 * 4. Prompt includes save-to-SessionLogs instruction
 * 5. All metadata fields are embedded in the prompt
 * 6. Skip-phase variants produce the correct "phases" value
 */

import { describe, it, expect } from "vitest";
import { buildSessionLogPrompt, type SessionLogData } from "../agent-worker-session-log.js";

// ── Helpers ───────────────────────────────────────────────────────────────

function makeSessionLogData(overrides?: Partial<SessionLogData>): SessionLogData {
  return {
    seedId: "bd-abc1",
    seedTitle: "Add rate limiting to API",
    status: "completed",
    phases: "explore→dev→qa→review→finalize",
    costUsd: 3.1415,
    turns: 42,
    toolCalls: 120,
    filesChanged: 7,
    devRetries: 1,
    qaVerdict: "pass",
    ...overrides,
  };
}

// ── buildSessionLogPrompt() ───────────────────────────────────────────────

describe("buildSessionLogPrompt()", () => {
  it("starts with /ensemble:sessionlog command", () => {
    const prompt = buildSessionLogPrompt(makeSessionLogData());
    expect(prompt).toMatch(/^\/ensemble:sessionlog /);
  });

  it("includes instruction to save to SessionLogs/ directory", () => {
    const prompt = buildSessionLogPrompt(makeSessionLogData());
    expect(prompt).toContain("SessionLogs/");
    expect(prompt).toContain("Save the session log");
  });

  it("embeds the seed ID", () => {
    const prompt = buildSessionLogPrompt(makeSessionLogData({ seedId: "bd-xyz9" }));
    expect(prompt).toContain("bd-xyz9");
  });

  it("embeds the seed title", () => {
    const data = makeSessionLogData({ seedTitle: "Implement webhook delivery" });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("Implement webhook delivery");
  });

  it("embeds the status", () => {
    const prompt = buildSessionLogPrompt(makeSessionLogData({ status: "completed" }));
    expect(prompt).toContain("Status: completed");
  });

  it("embeds failed status", () => {
    const prompt = buildSessionLogPrompt(makeSessionLogData({ status: "failed" }));
    expect(prompt).toContain("Status: failed");
  });

  it("embeds stuck status", () => {
    const prompt = buildSessionLogPrompt(makeSessionLogData({ status: "stuck" }));
    expect(prompt).toContain("Status: stuck");
  });

  it("embeds the phases string", () => {
    const data = makeSessionLogData({ phases: "explore→dev→qa→review→finalize" });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("Phases: explore→dev→qa→review→finalize");
  });

  it("embeds skip-explore phases variant", () => {
    const data = makeSessionLogData({ phases: "dev→qa→review→finalize" });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("Phases: dev→qa→review→finalize");
  });

  it("embeds skip-review phases variant", () => {
    const data = makeSessionLogData({ phases: "explore→dev→qa→finalize" });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("Phases: explore→dev→qa→finalize");
  });

  it("embeds skip-explore-and-skip-review phases variant", () => {
    const data = makeSessionLogData({ phases: "dev→qa→finalize" });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("Phases: dev→qa→finalize");
  });

  it("embeds the cost formatted to 4 decimal places", () => {
    const data = makeSessionLogData({ costUsd: 1.2345678 });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("Cost: $1.2346");
  });

  it("embeds the turn count", () => {
    const data = makeSessionLogData({ turns: 77 });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("Turns: 77");
  });

  it("embeds the tool call count", () => {
    const data = makeSessionLogData({ toolCalls: 200 });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("Tool calls: 200");
  });

  it("embeds the files-changed count", () => {
    const data = makeSessionLogData({ filesChanged: 13 });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("Files changed: 13");
  });

  it("embeds the dev-retry count", () => {
    const data = makeSessionLogData({ devRetries: 2 });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("Dev retries: 2");
  });

  it("embeds the QA verdict", () => {
    const data = makeSessionLogData({ qaVerdict: "fail" });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("QA verdict: fail");
  });

  it("embeds unknown QA verdict", () => {
    const data = makeSessionLogData({ qaVerdict: "unknown" });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("QA verdict: unknown");
  });

  it("returns a non-empty string for any valid input", () => {
    const data = makeSessionLogData();
    const prompt = buildSessionLogPrompt(data);
    expect(prompt.length).toBeGreaterThan(50);
  });

  it("produces consistent output for the same input", () => {
    const data = makeSessionLogData();
    const p1 = buildSessionLogPrompt(data);
    const p2 = buildSessionLogPrompt(data);
    expect(p1).toBe(p2);
  });

  it("zero-cost run formats as $0.0000", () => {
    const data = makeSessionLogData({ costUsd: 0 });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("Cost: $0.0000");
  });

  it("zero retries embeds correctly", () => {
    const data = makeSessionLogData({ devRetries: 0 });
    const prompt = buildSessionLogPrompt(data);
    expect(prompt).toContain("Dev retries: 0");
  });
});

// ── SessionLogData interface ──────────────────────────────────────────────

describe("SessionLogData — required fields", () => {
  it("accepts all required fields with no TypeScript error", () => {
    // This test is a compile-time guard: if SessionLogData changes, this breaks
    const data: SessionLogData = {
      seedId: "bd-t01",
      seedTitle: "Test task",
      status: "completed",
      phases: "explore→dev→qa→review→finalize",
      costUsd: 0.5,
      turns: 10,
      toolCalls: 30,
      filesChanged: 2,
      devRetries: 0,
      qaVerdict: "pass",
    };
    expect(data.seedId).toBe("bd-t01");
  });

  it("status union accepts 'completed' | 'failed' | 'stuck'", () => {
    const statuses: Array<SessionLogData["status"]> = ["completed", "failed", "stuck"];
    for (const status of statuses) {
      const data = makeSessionLogData({ status });
      expect(buildSessionLogPrompt(data)).toContain(`Status: ${status}`);
    }
  });
});
