import { describe, it, expect } from "vitest";
import { leadPrompt, type LeadPromptOptions } from "../lead-prompt.js";

/**
 * Integration tests for agent-worker.ts team mode path.
 *
 * The agent-worker team mode (pipeline === true) does:
 *   1. Dynamically imports lead-prompt.js
 *   2. Calls leadPrompt() with seed info and skip options
 *   3. Replaces config.prompt with the generated lead prompt
 *   4. Falls through to the standard single-agent SDK query loop
 *
 * Since agent-worker.ts reads from argv and exits, we test the leadPrompt
 * function integration with the config shape used by agent-worker, and
 * verify the prompt transformation logic that the team mode path relies on.
 */

/** Matches the WorkerConfig interface from agent-worker.ts */
interface WorkerConfig {
  runId: string;
  projectId: string;
  seedId: string;
  seedTitle: string;
  seedDescription?: string;
  model: string;
  worktreePath: string;
  prompt: string;
  env: Record<string, string>;
  resume?: string;
  pipeline?: boolean;
  skipExplore?: boolean;
  skipReview?: boolean;
}

function makeConfig(overrides?: Partial<WorkerConfig>): WorkerConfig {
  return {
    runId: "run-team-001",
    projectId: "proj-001",
    seedId: "seed-42",
    seedTitle: "Add rate limiting to API",
    seedDescription: "Implement per-user rate limiting with sliding window",
    model: "claude-sonnet-4-6",
    worktreePath: "/tmp/worktree",
    prompt: "Original user prompt that should be replaced",
    env: {},
    pipeline: true,
    ...overrides,
  };
}

/**
 * Simulates the team mode prompt transformation from agent-worker.ts lines 87-106:
 *
 *   if (pipeline) {
 *     const { leadPrompt } = await import("./lead-prompt.js");
 *     const teamPrompt = leadPrompt({ seedId, seedTitle, ... });
 *     config.prompt = teamPrompt;
 *   }
 */
function simulateTeamModeTransform(config: WorkerConfig): string {
  if (!config.pipeline) return config.prompt;

  const teamPrompt = leadPrompt({
    seedId: config.seedId,
    seedTitle: config.seedTitle,
    seedDescription: config.seedDescription ?? "(no description)",
    skipExplore: config.skipExplore,
    skipReview: config.skipReview,
  });

  // This is what agent-worker does: replace config.prompt
  config.prompt = teamPrompt;
  return config.prompt;
}

describe("agent-worker team mode: prompt transformation", () => {
  it("replaces config.prompt with the lead prompt when pipeline=true", () => {
    const config = makeConfig();
    const originalPrompt = config.prompt;

    const result = simulateTeamModeTransform(config);

    expect(result).not.toBe(originalPrompt);
    expect(config.prompt).not.toContain("Original user prompt");
    expect(config.prompt).toContain("Engineering Lead");
  });

  it("preserves config.prompt when pipeline is not set", () => {
    const config = makeConfig({ pipeline: false });
    const originalPrompt = config.prompt;

    const result = simulateTeamModeTransform(config);

    expect(result).toBe(originalPrompt);
    expect(config.prompt).toBe("Original user prompt that should be replaced");
  });

  it("includes seed context in the generated prompt", () => {
    const config = makeConfig({
      seedId: "seed-99",
      seedTitle: "Implement webhook system",
      seedDescription: "Create a reliable webhook delivery system with retries",
    });

    const prompt = simulateTeamModeTransform(config);

    expect(prompt).toContain("seed-99");
    expect(prompt).toContain("Implement webhook system");
    expect(prompt).toContain("Create a reliable webhook delivery system with retries");
  });

  it("uses '(no description)' fallback when seedDescription is missing", () => {
    const config = makeConfig({ seedDescription: undefined });

    const prompt = simulateTeamModeTransform(config);

    expect(prompt).toContain("(no description)");
  });

  it("passes skipExplore through to leadPrompt", () => {
    const config = makeConfig({ skipExplore: true });

    const prompt = simulateTeamModeTransform(config);

    expect(prompt).toContain("SKIPPED (--skip-explore)");
    // Explorer agent instructions should NOT be present
    expect(prompt).not.toContain("You are an Explorer agent");
  });

  it("passes skipReview through to leadPrompt", () => {
    const config = makeConfig({ skipReview: true });

    const prompt = simulateTeamModeTransform(config);

    expect(prompt).toContain("SKIPPED (--skip-review)");
    // Reviewer agent instructions should NOT be present
    expect(prompt).not.toContain("You are a Code Reviewer");
  });

  it("includes both skip markers when both options are set", () => {
    const config = makeConfig({ skipExplore: true, skipReview: true });

    const prompt = simulateTeamModeTransform(config);

    expect(prompt).toContain("SKIPPED (--skip-explore)");
    expect(prompt).toContain("SKIPPED (--skip-review)");
  });

  it("includes full team when no skip options are set", () => {
    const config = makeConfig({ skipExplore: false, skipReview: false });

    const prompt = simulateTeamModeTransform(config);

    expect(prompt).toContain("You are an Explorer agent");
    expect(prompt).toContain("You are a Developer agent");
    expect(prompt).toContain("You are a QA agent");
    expect(prompt).toContain("You are a Code Reviewer");
    expect(prompt).not.toContain("SKIPPED");
  });
});

describe("agent-worker team mode: prompt is suitable for SDK query()", () => {
  it("generated prompt instructs the lead to use Agent tool for sub-agents", () => {
    const config = makeConfig();
    const prompt = simulateTeamModeTransform(config);

    // The SDK query() receives this prompt; the lead needs to know to use Agent tool
    expect(prompt).toContain("Agent tool");
    expect(prompt).toContain("sub-agent");
  });

  it("generated prompt includes orchestration workflow phases", () => {
    const config = makeConfig();
    const prompt = simulateTeamModeTransform(config);

    // The prompt should guide the lead through a structured workflow
    expect(prompt).toContain("Explorer");
    expect(prompt).toContain("Developer");
    expect(prompt).toContain("QA");
    expect(prompt).toContain("Reviewer");
    expect(prompt).toContain("Finalize");
  });

  it("generated prompt includes inter-agent report files", () => {
    const config = makeConfig();
    const prompt = simulateTeamModeTransform(config);

    expect(prompt).toContain("EXPLORER_REPORT.md");
    expect(prompt).toContain("QA_REPORT.md");
    expect(prompt).toContain("REVIEW.md");
  });

  it("generated prompt includes finalize steps (bug scan, commit, push, close)", () => {
    const config = makeConfig();
    const prompt = simulateTeamModeTransform(config);

    expect(prompt).toContain("tsc --noEmit");
    expect(prompt).toContain("git commit");
    expect(prompt).toContain("git push");
    expect(prompt).toContain("sd close");
  });

  it("does not alter model selection (model stays as configured)", () => {
    const config = makeConfig({ model: "claude-opus-4-6" });

    simulateTeamModeTransform(config);

    // agent-worker comment: "Don't override model — let the dispatcher's model selection stand"
    expect(config.model).toBe("claude-opus-4-6");
  });
});
