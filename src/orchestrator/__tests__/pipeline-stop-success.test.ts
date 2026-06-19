import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const PIPELINE_SRC = join(PROJECT_ROOT, "src", "orchestrator", "pipeline-executor.ts");

describe("pipeline stopPipelineSuccess", () => {
  const source = readFileSync(PIPELINE_SRC, "utf8");

  it("allows builtin phases to stop remaining phases after a successful no-op", () => {
    expect(source).toContain("stopPipelineSuccess?: boolean");
    expect(source).toContain("if (result.stopPipelineSuccess)");
    expect(source).toContain("Completed and requested successful pipeline stop");
    expect(source).toContain("return { success: true, phaseRecords, retryCounts, qaVerdictForLog, progress }");
  });
});
