import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

describe("dispatcher task note wiring", () => {
  it("passes native taskId into spawned workers", () => {
    const sourcePath = fileURLToPath(new URL("../dispatcher.ts", import.meta.url));
    const source = readFileSync(sourcePath, "utf8");

    expect(source).toContain("taskId: seed.id,");
    expect(source).toContain("await spawnWorkerProcess({");
    expect(source).toContain("taskMeta: {");
  });

  it("passes the dispatcher-resolved workflow into spawned workers", () => {
    const sourcePath = fileURLToPath(new URL("../dispatcher.ts", import.meta.url));
    const source = readFileSync(sourcePath, "utf8");

    expect(source).toContain("workflowName: resolvedWorkflow,");
    expect(source).toContain("workflowName: pipelineOpts?.workflowName,");
  });

  it("keeps resume workers wired to the same native taskId", () => {
    const sourcePath = fileURLToPath(new URL("../dispatcher.ts", import.meta.url));
    const source = readFileSync(sourcePath, "utf8");
    const resumeBlock = source.slice(source.indexOf("private async resumeAgent"));

    expect(resumeBlock).toContain("taskId: seed.id,");
  });
});
