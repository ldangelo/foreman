import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { workerAgentMd } from "../templates.js";
import type { SeedInfo, ModelSelection } from "../types.js";

const fakeSeed: SeedInfo = {
  id: "seeds-abc123",
  title: "Implement auth module",
  description: "Add JWT-based authentication",
};

// ── TRD-014-TEST: worker-agent.md template has no sd references ──────────

describe("TRD-014: templates/worker-agent.md br migration", () => {
  const templatePath = join(process.cwd(), "templates", "worker-agent.md");
  let content: string;

  content = readFileSync(templatePath, "utf-8");

  it("contains no 'sd ' references (sd CLI removed)", () => {
    // Allow 'description' etc — match word-boundary sd followed by space
    const sdMatches = content.match(/\bsd\s/g) ?? [];
    expect(sdMatches).toHaveLength(0);
  });

  it("contains 'br update' for claiming tasks", () => {
    expect(content).toContain("br update");
  });

  it("contains 'br close' for completing tasks", () => {
    expect(content).toContain("br close");
  });

  it("does not contain 'sd update' or 'sd close'", () => {
    expect(content).not.toContain("sd update");
    expect(content).not.toContain("sd close");
  });
});

// ── workerAgentMd function ────────────────────────────────────────────────

describe("workerAgentMd", () => {
  it("contains the seed ID", () => {
    const md = workerAgentMd(fakeSeed, "/tmp/wt", "claude-sonnet-4-6");
    expect(md).toContain("seeds-abc123");
  });

  it("contains the seed title", () => {
    const md = workerAgentMd(fakeSeed, "/tmp/wt", "claude-sonnet-4-6");
    expect(md).toContain("Implement auth module");
  });

  it("contains the seed description", () => {
    const md = workerAgentMd(fakeSeed, "/tmp/wt", "claude-sonnet-4-6");
    expect(md).toContain("Add JWT-based authentication");
  });

  it("describes the agent team roles", () => {
    const md = workerAgentMd(fakeSeed, "/tmp/wt", "claude-sonnet-4-6");
    expect(md).toContain("Explorer");
    expect(md).toContain("Developer");
    expect(md).toContain("QA");
    expect(md).toContain("Reviewer");
    expect(md).toContain("Agent Team");
  });

  it("produces valid non-empty output for all models", () => {
    const models: ModelSelection[] = ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"];
    for (const model of models) {
      const md = workerAgentMd(fakeSeed, "/tmp/wt", model);
      expect(md.length).toBeGreaterThan(0);
      expect(md).toContain(model);
    }
  });
});
