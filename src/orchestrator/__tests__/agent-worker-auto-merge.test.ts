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

  it("routes worker runtime task selection through the shared factory using native tasks only", () => {
    expect(source).toContain("createTaskClient");
    expect(source).not.toContain("forceTasksFallback");
  });

  it("creates one shared runtime task client for epic QA hooks and status updates", () => {
    expect(source).toContain("const { taskClient: runtimeTaskClient, backendType: runtimeTaskBackend } = await createTaskClient(");
    expect(source).not.toContain("createEpicTaskClient(");
  });

  it("supports an explicit merge builtin that polls for actual PR merge after enqueueing", () => {
    expect(source).toContain("async function runMergeBuiltinPhase");
    expect(source).toContain('if (phase.name === "merge")');
    // Enqueues to the queue then polls for the PR to actually be merged before returning success.
    expect(source).toContain("operation: \"auto_merge\"");
    expect(source).toContain("PR #${prNumber} merged successfully");
    // Does NOT return success immediately after enqueue — it waits for the merge.
    expect(source).not.toContain("Merge queued for Elixir/refinery processing");
    expect(source).not.toContain("await autoMerge(");
    expect(source).not.toContain("Immediate merge drain result: merged=");
  });

  it("enqueues merge intent with an explicit operation", () => {
    expect(source).toContain("operation: \"auto_merge\"");
    expect(source).toContain("const pr = await refinery.ensurePullRequestForRun");
    expect(source).toContain("MERGE_REPORT.md");
  });

  it("does not use top-level workflow merge strategy gates", () => {
    expect(source).not.toContain("workflowConfig.merge");
    expect(source).not.toContain("Workflow merge strategy is ${mergeStrategy}");
  });

  it("keeps the mail helper fire-and-forget and non-throwing", () => {
    expect(source).toContain("client.sendMessage(to, subject, JSON.stringify(body)).catch");
    expect(source).toContain("log(`[agent-mail] send failed (non-fatal): ${msg}`);");
  });

  it("routes epic QA failure/pass hooks through the shared runtime task client", () => {
    expect(source).toContain("if (!runtimeTaskClient.create) {");
    expect(source).toContain("const bug = await runtimeTaskClient.create(`QA failure: ${taskTitle}`,");
    expect(source).toContain("await runtimeTaskClient.close(bugTaskId, \"QA passed on retry\")");
  });
});

describe("auto-merge.ts — module invariants", () => {
  const source = readFileSync(AUTO_MERGE_SRC, "utf-8");

  it("exports autoMerge function", () => {
    expect(source).toContain("export async function autoMerge(");
  });

  it("exports syncTaskStatusAfterMerge function", () => {
    expect(source).toContain("export async function syncTaskStatusAfterMerge(");
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

  it("does NOT contain the old inline syncTaskStatusAfterMerge", () => {
    expect(runSource).not.toContain("async function syncTaskStatusAfterMerge(");
  });
});

describe("agent-worker.ts — merge phase direct merge fallback", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("polls for PR merge after enqueueing", () => {
    expect(source).toContain("Waiting for PR #${prNumber} to merge");
    expect(source).toContain("MERGE_POLL_INTERVAL_MS");
    expect(source).toContain("MERGE_POLL_TIMEOUT_MS");
  });

  it("falls back to direct gh pr merge --admin --squash when polling times out", () => {
    expect(source).toContain('"pr", "merge", String(prNumber), "--admin", "--squash"');
  });

  it("runs a final pre-failure state check after the post-timeout merge attempt", () => {
    expect(source).toContain("caught on final post-timeout check");
  });

  it("marks the run failed only when polling times out AND the post-timeout merge fails AND the PR is not already merged", () => {
    expect(source).toContain("Merge did not complete within the ${MERGE_POLL_TIMEOUT_MS / 1000}s polling timeout");
  });

  it("does not reference stub queue or 'not implemented' error (the stub path is gone)", () => {
    expect(source).not.toContain("isStubQueue");
    expect(source).not.toContain("Queue is stubbed");
    expect(source).not.toContain("Merge queue is not implemented for this project");
    expect(source).not.toContain('error.includes("not implemented")');
  });

  it("regression: on merge failure, updateTerminalRunStatus is called with status 'failed' (not 'completed')", () => {
    // Bug guard: the failure branch used to write status:"completed" before
    // returning success: false, masking a real merge failure as done.
    // Find the failure-branch update block and ensure its status is "failed".
    const start = source.indexOf("if (!mergeSucceeded)");
    expect(start).toBeGreaterThanOrEqual(0);
    const slice = source.slice(start, start + 1500);
    const updateIdx = slice.indexOf("updateTerminalRunStatus({");
    expect(updateIdx).toBeGreaterThanOrEqual(0);
    // Extract just the updateTerminalRunStatus({...}) block
    const blockStart = start + updateIdx;
    let depth = 0;
    let blockEnd = blockStart;
    for (let i = blockStart; i < source.length; i++) {
      if (source[i] === "{") depth++;
      else if (source[i] === "}") { depth--; if (depth === 0) { blockEnd = i + 1; break; } }
    }
    const block = source.slice(blockStart, blockEnd);
    expect(block).toContain("status: \"failed\"");
    expect(block).not.toContain("status: \"completed\"");
  });
});
