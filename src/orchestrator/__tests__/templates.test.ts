import { describe, it, expect } from "vitest";
import { workerAgentMd } from "../templates.js";
import type { BeadInfo, RuntimeSelection } from "../types.js";

const fakeBead: BeadInfo = {
  id: "beads-abc123",
  title: "Implement auth module",
  description: "Add JWT-based authentication",
};

describe("workerAgentMd", () => {
  it("contains the bead ID", () => {
    const md = workerAgentMd(fakeBead, "/tmp/wt", "claude-code");
    expect(md).toContain("beads-abc123");
  });

  it("contains bd close command with bead ID", () => {
    const md = workerAgentMd(fakeBead, "/tmp/wt", "claude-code");
    expect(md).toContain("bd close beads-abc123");
  });

  it("contains git push to the correct branch", () => {
    const md = workerAgentMd(fakeBead, "/tmp/wt", "claude-code");
    expect(md).toContain("git push -u origin foreman/beads-abc123");
  });

  it("produces valid non-empty output for all runtimes", () => {
    const runtimes: RuntimeSelection[] = ["claude-code", "pi", "codex"];
    for (const runtime of runtimes) {
      const md = workerAgentMd(fakeBead, "/tmp/wt", runtime);
      expect(md.length).toBeGreaterThan(0);
      expect(md).toContain(runtime);
    }
  });
});
