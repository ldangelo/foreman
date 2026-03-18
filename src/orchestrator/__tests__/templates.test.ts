import { describe, it, expect } from "vitest";
import { workerAgentMd } from "../templates.js";
import type { SeedInfo, ModelSelection } from "../types.js";

const fakeSeed: SeedInfo = {
  id: "seeds-abc123",
  title: "Implement auth module",
  description: "Add JWT-based authentication",
};

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

  it("contains session logging instructions", () => {
    const md = workerAgentMd(fakeSeed, "/tmp/wt", "claude-sonnet-4-6");
    expect(md).toContain("Session Logging");
    expect(md).toContain("SessionLogs/session-");
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
