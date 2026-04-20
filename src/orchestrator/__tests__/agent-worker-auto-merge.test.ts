/**
 * agent-worker-auto-merge.test.ts
 *
 * Verifies that agent-worker.ts enqueues merge intent after finalize and
 * leaves merge execution to the merge queue processor.
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

describe("agent-worker.ts — merge queue handoff", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("imports the shared task-client factory for runtime backend selection", () => {
    expect(source).toContain('from "../lib/task-client-factory.js"');
    expect(source).toContain("createTaskClient");
  });

  it("does not invoke autoMerge directly from finalize anymore", () => {
    expect(source).not.toContain("await autoMerge(");
    expect(source).not.toContain("autoMerge result: merged=");
  });

  it("enqueues merge intent with an explicit operation", () => {
    expect(source).toContain("operation: mergeStrategy === \"pr\" ? \"create_pr\" : \"auto_merge\"");
  });

  it("skips merge queue enqueue when workflow merge strategy is none", () => {
    expect(source).toContain("mergeStrategy !== \"none\"");
    expect(source).toContain("Workflow merge strategy is none — skipping merge queue enqueue");
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

  it("routes merge behavior by queue operation", () => {
    expect(source).toContain("const mergeOperation = currentEntry.operation");
    expect(source).toContain("mergeOperation === 'create_pr'");
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
