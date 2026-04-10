import { describe, it, expect } from "vitest";
import { existsSync } from "node:fs";
import { workerAgentMd } from "../templates.js";
import type { TaskInfo, ModelSelection } from "../types.js";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const fakeSeed: TaskInfo = {
  id: "seeds-abc123",
  title: "Implement auth module",
  description: "Add JWT-based authentication",
};

// ── workerAgentMd function ────────────────────────────────────────────────

describe("workerAgentMd", () => {
  it("contains the seed ID", () => {
    const md = workerAgentMd(fakeSeed, "/tmp/wt", "anthropic/claude-sonnet-4-6");
    expect(md).toContain("seeds-abc123");
  });

  it("contains the seed title", () => {
    const md = workerAgentMd(fakeSeed, "/tmp/wt", "anthropic/claude-sonnet-4-6");
    expect(md).toContain("Implement auth module");
  });

  it("contains the seed description", () => {
    const md = workerAgentMd(fakeSeed, "/tmp/wt", "anthropic/claude-sonnet-4-6");
    expect(md).toContain("Add JWT-based authentication");
  });

  it("describes the agent team roles", () => {
    const md = workerAgentMd(fakeSeed, "/tmp/wt", "anthropic/claude-sonnet-4-6");
    expect(md).toContain("Explorer");
    expect(md).toContain("Developer");
    expect(md).toContain("QA");
    expect(md).toContain("Reviewer");
    expect(md).toContain("Agent Team");
  });

  it("contains session logging instructions", () => {
    const md = workerAgentMd(fakeSeed, "/tmp/wt", "anthropic/claude-sonnet-4-6");
    expect(md).toContain("Session Logging");
    expect(md).toContain("SessionLogs/session-");
  });

  it("produces valid non-empty output for all models", () => {
    const models: ModelSelection[] = ["anthropic/claude-opus-4-6", "anthropic/claude-sonnet-4-6", "anthropic/claude-haiku-4-5"];
    for (const model of models) {
      const md = workerAgentMd(fakeSeed, "/tmp/wt", model);
      expect(md.length).toBeGreaterThan(0);
      expect(md).toContain(model);
    }
  });

  it("template file exists on disk", () => {
    // When running via tsx (dev/test), import.meta.url resolves to src/orchestrator/__tests__/
    // so the template lives at src/templates/worker-agent.md (two levels up)
    const __dirname = dirname(fileURLToPath(import.meta.url));
    // templates.ts lives at src/orchestrator/templates.ts; this test is at
    // src/orchestrator/__tests__/templates.test.ts — so we need to go up
    // TWO levels (__tests__ → orchestrator → src) to reach src/templates/.
    const templatePath = join(__dirname, "../../templates/worker-agent.md");
    expect(existsSync(templatePath)).toBe(true);
  });

  it("no unresolved placeholders remain in output", () => {
    const md = workerAgentMd(fakeSeed, "/tmp/wt", "anthropic/claude-sonnet-4-6");
    expect(md).not.toMatch(/\{\{\w+\}\}/);
  });

  it("includes Additional Context section when seed.comments is present", () => {
    const seedWithComments: TaskInfo = {
      ...fakeSeed,
      comments: "Please also add rate limiting to the auth endpoints.",
    };
    const md = workerAgentMd(seedWithComments, "/tmp/wt", "anthropic/claude-sonnet-4-6");
    expect(md).toContain("## Additional Context");
    expect(md).toContain("Please also add rate limiting to the auth endpoints.");
  });

  it("does NOT include Additional Context section when seed.comments is undefined", () => {
    const md = workerAgentMd(fakeSeed, "/tmp/wt", "anthropic/claude-sonnet-4-6");
    expect(md).not.toContain("## Additional Context");
  });

  it("does NOT include Additional Context section when seed.comments is null", () => {
    const seedWithNullComments: TaskInfo = {
      ...fakeSeed,
      comments: null,
    };
    const md = workerAgentMd(seedWithNullComments, "/tmp/wt", "anthropic/claude-sonnet-4-6");
    expect(md).not.toContain("## Additional Context");
  });
});
