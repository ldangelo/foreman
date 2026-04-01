import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

describe("agent-worker finalize mail status handling", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("parses status from finalize phase-complete mail bodies", () => {
    expect(source).toContain('const status = typeof body["status"] === "string" ? body["status"] : "complete"');
  });

  it("only treats finalize phase-complete as success when status is complete/completed", () => {
    expect(source).toContain('finalizeSucceeded = status === "complete" || status === "completed"');
  });

  it("marks deterministic finalize failures as failed without retry", () => {
    expect(source).toContain('const terminalStatus = finalizeRetryable ? "stuck" : "failed"');
    expect(source).toContain('enqueueMarkBeadFailed(store, seedId, "agent-worker-finalize")');
  });

  it("does not assume finalize success when finalize mail is missing", () => {
    expect(source).toContain('No finalize mail found — preserving pipeline success=');
    expect(source).not.toContain('No finalize mail found — assuming success');
  });

  it("skips branch-ready when troubleshooter recovery already landed the branch on target", () => {
    expect(source).toContain('if (troubleshooterResolved)');
    expect(source).toContain('skipMergeQueue = true;');
    expect(source).toContain('Branch already matches ${completionTargetBranch} after troubleshooter recovery');
    expect(source).toContain('enqueueCloseSeed(store, seedId, "agent-worker-finalize")');
  });
});
