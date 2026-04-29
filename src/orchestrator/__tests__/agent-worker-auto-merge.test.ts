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

  it("routes worker runtime task selection through the shared factory even in test mode", () => {
    expect(source).toContain("forceBeadsFallback: runtimeMode === \"test\"");
    expect(source).not.toContain("new NativeTaskClient(");
  });

  it("creates one shared runtime task client for epic QA hooks and status updates", () => {
    expect(source).toContain("const { taskClient: runtimeTaskClient, backendType: runtimeTaskBackend } = await createTaskClient(");
    expect(source).not.toContain("createEpicTaskClient(");
  });

  it("invokes immediate autoMerge after finalize enqueue for auto strategies", () => {
    expect(source).toContain("await autoMerge(");
    expect(source).toContain("Immediate merge drain result: merged=");
    expect(source).toContain("registeredProjectId,");
    expect(source).toContain("readLookup: registeredAutoMergeReadStore");
  });

  it("enqueues merge intent with an explicit operation", () => {
    expect(source).toContain("operation: \"auto_merge\"");
    expect(source).toContain("const pr = await refinery.ensurePullRequestForRun");
  });

  it("publishes a PR and skips merge queue enqueue for non-auto strategies", () => {
    expect(source).toContain("mergeStrategy === \"auto\"");
    expect(source).toContain("Workflow merge strategy is ${mergeStrategy} — PR created, skipping merge queue enqueue");
  });

  it("keeps the mail helper fire-and-forget and non-throwing", () => {
    expect(source).toContain("client.sendMessage(to, subject, JSON.stringify(body)).catch");
    expect(source).toContain("log(`[agent-mail] send failed (non-fatal): ${msg}`);");
  });

  it("routes epic QA failure/pass hooks through the shared runtime task client", () => {
    expect(source).toContain("if (!runtimeTaskClient.create) {");
    expect(source).toContain("const bug = await runtimeTaskClient.create(`QA failure: ${taskTitle}`,");
    expect(source).toContain("await runtimeTaskClient.close(bugBeadId, \"QA passed on retry\")");
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

  it("uses Refinery for mergePullRequest calls", () => {
    expect(source).toContain("new Refinery(");
    expect(source).toContain("refinery.mergePullRequest(");
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
