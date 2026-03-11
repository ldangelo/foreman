import { describe, it, expect } from "vitest";
import { leadPrompt, type LeadPromptOptions } from "../lead-prompt.js";

const baseOpts: LeadPromptOptions = {
  beadId: "bead-123",
  beadTitle: "Fix auth module",
  beadDescription: "Fix JWT token refresh logic",
};

describe("leadPrompt", () => {
  it("contains the bead context", () => {
    const prompt = leadPrompt(baseOpts);
    expect(prompt).toContain("bead-123");
    expect(prompt).toContain("Fix auth module");
    expect(prompt).toContain("Fix JWT token refresh logic");
  });

  it("describes the Engineering Lead role", () => {
    const prompt = leadPrompt(baseOpts);
    expect(prompt).toContain("Engineering Lead");
    expect(prompt).toContain("orchestrat");
  });

  it("describes all four team roles", () => {
    const prompt = leadPrompt(baseOpts);
    expect(prompt).toContain("Explorer");
    expect(prompt).toContain("Developer");
    expect(prompt).toContain("QA");
    expect(prompt).toContain("Reviewer");
  });

  it("instructs to use Agent tool for sub-agents", () => {
    const prompt = leadPrompt(baseOpts);
    expect(prompt).toContain("Agent tool");
  });

  it("includes finalize steps (commit, push, close)", () => {
    const prompt = leadPrompt(baseOpts);
    expect(prompt).toContain("git commit");
    expect(prompt).toContain("git push");
    expect(prompt).toContain("bd close");
  });

  it("includes max retry guidance", () => {
    const prompt = leadPrompt(baseOpts);
    expect(prompt).toContain("2 retries");
  });

  it("includes explorer section by default", () => {
    const prompt = leadPrompt(baseOpts);
    expect(prompt).toContain("EXPLORER_REPORT.md");
    expect(prompt).not.toContain("SKIPPED (--skip-explore)");
  });

  it("skips explorer when skipExplore is set", () => {
    const prompt = leadPrompt({ ...baseOpts, skipExplore: true });
    expect(prompt).toContain("SKIPPED (--skip-explore)");
  });

  it("includes reviewer section by default", () => {
    const prompt = leadPrompt(baseOpts);
    expect(prompt).toContain("REVIEW.md");
    expect(prompt).not.toContain("SKIPPED (--skip-review)");
  });

  it("skips reviewer when skipReview is set", () => {
    const prompt = leadPrompt({ ...baseOpts, skipReview: true });
    expect(prompt).toContain("SKIPPED (--skip-review)");
  });

  it("includes instructions for each sub-agent prompt", () => {
    const prompt = leadPrompt(baseOpts);
    // Explorer prompt block
    expect(prompt).toContain("You are an Explorer agent");
    // Developer prompt block
    expect(prompt).toContain("You are a Developer agent");
    // QA prompt block
    expect(prompt).toContain("You are a QA agent");
    // Reviewer prompt block
    expect(prompt).toContain("You are a Code Reviewer");
  });

  it("tells lead not to implement code directly", () => {
    const prompt = leadPrompt(baseOpts);
    expect(prompt).toContain("You orchestrate — you do not implement");
  });

  it("includes report file names for inter-agent communication", () => {
    const prompt = leadPrompt(baseOpts);
    expect(prompt).toContain("EXPLORER_REPORT.md");
    expect(prompt).toContain("QA_REPORT.md");
    expect(prompt).toContain("REVIEW.md");
  });
});
