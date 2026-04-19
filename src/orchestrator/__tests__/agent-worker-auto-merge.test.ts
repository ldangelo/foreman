/**
 * agent-worker-auto-merge.test.ts
 *
 * Verifies that agent-worker.ts triggers autoMerge() immediately after
 * a successful pipeline finalize (fixing bd-0qv2: merges sat in the queue
 * until foreman run was manually run again).
 *
 * These are structural/source-level tests that verify the wiring without
 * spawning real subprocesses or making API calls.
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");
const AUTO_MERGE_SRC = join(PROJECT_ROOT, "src", "orchestrator", "auto-merge.ts");

describe("agent-worker.ts — autoMerge integration (bd-0qv2)", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("imports autoMerge from auto-merge.js", () => {
    expect(source).toContain('from "./auto-merge.js"');
    expect(source).toContain("autoMerge");
  });

  it("imports the shared task-client factory for runtime backend selection", () => {
    expect(source).toContain('from "../lib/task-client-factory.js"');
    expect(source).toContain("createTaskClient");
  });

  it("calls autoMerge inside onPipelineComplete after successful enqueue", () => {
    // The autoMerge call must happen inside the success branch (after enqueueResult.success check)
    expect(source).toContain("await autoMerge(");
  });

  it("creates a runtime task client helper for the autoMerge task client", () => {
    expect(source).toContain("createRuntimeTaskClient(pipelineProjectPath)");
  });

  it("logs the autoMerge result", () => {
    expect(source).toContain("autoMerge result: merged=");
  });

  it("treats autoMerge failures as non-fatal (catch block)", () => {
    // Must have a try/catch around the autoMerge call so failures don't block pipeline
    expect(source).toContain("autoMerge failed (non-fatal):");
  });

  it("passes the existing store to autoMerge (fixes race condition)", () => {
    // Should use the existing `store` instance to avoid SQLite connection isolation issues.
    // The race condition: creating a new ForemanStore opened a separate SQLite connection,
    // and the 'completed' status written by `store.updateRun()` was not visible to the
    // new connection's reconcile query — causing "No completed run found" errors.
    expect(source).toContain("store: store");
  });

  it("does NOT create a separate mergeStore for autoMerge", () => {
    // Using a separate mergeStore caused race conditions with SQLite connection isolation.
    // The fix is to use the existing store that already wrote the 'completed' status.
    expect(source).not.toContain("const mergeStore = ForemanStore.forProject");
  });
});

describe("auto-merge.ts — module invariants", () => {
  const source = readFileSync(AUTO_MERGE_SRC, "utf-8");

  it("exports autoMerge function", () => {
    expect(source).toContain("export async function autoMerge(");
  });

  it("exports syncBeadStatusAfterMerge function", () => {
    expect(source).toContain("export async function syncBeadStatusAfterMerge(");
  });

  it("exports AutoMergeOpts interface", () => {
    expect(source).toContain("export interface AutoMergeOpts");
  });

  it("exports AutoMergeResult interface", () => {
    expect(source).toContain("export interface AutoMergeResult");
  });

  it("uses Refinery for mergeCompleted calls", () => {
    expect(source).toContain("new Refinery(");
    expect(source).toContain("refinery.mergeCompleted(");
  });

  it("reconciles queue before draining", () => {
    expect(source).toContain("mq.reconcile(");
    expect(source).toContain("mq.dequeue()");
  });

  it("contains doc comment about being called from agent-worker (bd-0qv2 fix)", () => {
    expect(source).toContain("agent-worker");
    expect(source).toContain("onPipelineComplete");
  });
});

describe("run.ts — still exports autoMerge (backwards compat)", () => {
  const RUN_SRC = join(PROJECT_ROOT, "src", "cli", "commands", "run.ts");
  const runSource = readFileSync(RUN_SRC, "utf-8");

  it("re-exports autoMerge from auto-merge.js", () => {
    expect(runSource).toContain('export { autoMerge }');
    expect(runSource).toContain("auto-merge.js");
  });

  it("re-exports AutoMergeOpts type from auto-merge.js", () => {
    expect(runSource).toContain("AutoMergeOpts");
  });

  it("does NOT contain the old inline autoMerge implementation", () => {
    // The function definition should not be here; only an import/re-export
    expect(runSource).not.toContain("export async function autoMerge(");
  });

  it("does NOT contain the old inline syncBeadStatusAfterMerge", () => {
    expect(runSource).not.toContain("async function syncBeadStatusAfterMerge(");
  });
});
