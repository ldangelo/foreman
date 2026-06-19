import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");
const PIPELINE_SRC = join(PROJECT_ROOT, "src", "orchestrator", "pipeline-executor.ts");

describe("agent-worker cli-review builtin wiring", () => {
  const source = readFileSync(WORKER_SRC, "utf8");
  const pipelineSource = readFileSync(PIPELINE_SRC, "utf8");

  it("imports the CodeRabbit CLI review helper", () => {
    expect(source).toContain('import { runCodeRabbitCliReview } from "./coderabbit-cli-review.js";');
  });

  it("routes cli-review through a builtin phase handler", () => {
    expect(source).toContain('if (phase.name === "cli-review")');
    expect(source).toContain("runCliReviewBuiltinPhase");
  });

  it("uses the task target branch or detected default branch for review base", () => {
    expect(source).toContain("args.config.targetBranch");
    expect(source).toContain("detectDefaultBranch(args.pipelineProjectPath)");
  });

  it("treats skipped cli-review results as phase failure", () => {
    expect(source).toContain("success: review.status === \"passed\"");
  });

  it("classifies rate limit errors case-insensitively", () => {
    expect(source).toContain("const reasonLower = reason.toLowerCase();");
    expect(source).toContain("reasonLower.includes(\"rate limit\")");
  });

  it("does not route rate-limit phase failures through retryWith feedback loops", () => {
    const rateLimitIdx = pipelineSource.indexOf("if (isRateLimitError(errorMsg))");
    const retryWithIdx = pipelineSource.indexOf("if (phase.retryWith)", rateLimitIdx);
    expect(rateLimitIdx).toBeGreaterThan(-1);
    expect(retryWithIdx).toBeGreaterThan(rateLimitIdx);
  });
});
