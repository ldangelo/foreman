import { describe, it, expect } from "vitest";
import { workerAgentMd } from "../templates.js";
import type { BeadInfo, ModelSelection } from "../types.js";

const fakeBead: BeadInfo = {
  id: "beads-abc123",
  title: "Implement auth module",
  description: "Add JWT-based authentication",
};

describe("workerAgentMd", () => {
  it("contains the bead ID", () => {
    const md = workerAgentMd(fakeBead, "/tmp/wt", "claude-sonnet-4-6");
    expect(md).toContain("beads-abc123");
  });

  it("contains bd close command with bead ID", () => {
    const md = workerAgentMd(fakeBead, "/tmp/wt", "claude-sonnet-4-6");
    expect(md).toContain("bd close beads-abc123");
  });

  it("contains git push to the correct branch", () => {
    const md = workerAgentMd(fakeBead, "/tmp/wt", "claude-sonnet-4-6");
    expect(md).toContain("git push -u origin foreman/beads-abc123");
  });

  it("produces valid non-empty output for all models", () => {
    const models: ModelSelection[] = ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"];
    for (const model of models) {
      const md = workerAgentMd(fakeBead, "/tmp/wt", model);
      expect(md.length).toBeGreaterThan(0);
      expect(md).toContain(model);
    }
  });
});
