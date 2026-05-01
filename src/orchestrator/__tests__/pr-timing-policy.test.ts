import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

describe("PR timing policy wiring", () => {
  it("pipeline-executor publishes draft PRs after developer when configured", () => {
    const source = readFileSync(join(import.meta.dirname, "..", "pipeline-executor.ts"), "utf-8");
    expect(source).toContain('workflowConfig.pr?.timing ?? "create-at-finalize"');
    expect(source).toContain('phaseName !== "developer"');
    expect(source).toContain('draft: true');
    expect(source).toContain('strategy: "draft-after-developer"');
  });

  it("agent-worker skips finalize PR publication when pr timing is never", () => {
    const source = readFileSync(join(import.meta.dirname, "..", "agent-worker.ts"), "utf-8");
    expect(source).toContain('const prTiming = workflowConfig.pr?.timing ?? "create-at-finalize"');
    expect(source).toContain('Workflow PR timing is never — skipping PR publication');
    expect(source).toContain('Workflow PR timing is never — skipping failure PR publication');
  });
});
