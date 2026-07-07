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

  it("treats finalize phase-complete success/completed values as success", () => {
    expect(source).toContain('finalizeSucceeded = status === "complete" || status === "completed" || status === "success"');
  });

  it("prefers non-retryable finalize agent errors over later phase-complete mail", () => {
    expect(source).toContain('const nonRetryableError = finalizeMsgs.find');
    expect(source).toContain('if (nonRetryableError)');
    expect(source).toContain('finalizeSucceeded = false;');
    expect(source).toContain('non-retryable agent-error mail received');
  });

  it("marks deterministic finalize failures via Elixir task status helper", () => {
    expect(source).toContain('const terminalStatus = finalizeRetryable ? "stuck" : "failed"');
    expect(source).toContain('await updateTaskStatusViaElixir(pipelineProjectPath, registeredProjectId, taskId, "failed", "agent-worker-finalize");');
    expect(source).not.toContain('enqueueMarkTaskFailed(store, taskId, "agent-worker-finalize")');
  });

  it("does not assume finalize success when finalize mail is missing", () => {
    expect(source).toContain('No finalize mail found — preserving pipeline success=');
    expect(source).not.toContain('No finalize mail found — assuming success');
  });

  it("skips branch-ready when troubleshooter recovery already landed the branch on target", () => {
    expect(source).toContain('if (troubleshooterResolved)');
    expect(source).toContain('skipMergeQueue = true;');
    expect(source).toContain('Branch already matches ${completionTargetBranch} after troubleshooter recovery');
    expect(source).toContain('await updateTaskStatusViaElixir(pipelineProjectPath, registeredProjectId, taskId, "closed", "agent-worker-finalize");');
  });

  it("treats non-retryable pre-existing test failures as merged when the branch already landed", () => {
    expect(source).toContain('finalizeFailureReason === "tests_failed_pre_existing_issues"');
    expect(source).toContain('await updateTerminalRunStatus({');
    expect(source).toContain('status: "merged"');
    expect(source).toContain('Pre-existing test failures but branch already matches ${completionTargetBranch}');
    expect(source).toContain('await updateTaskStatusViaElixir(pipelineProjectPath, registeredProjectId, taskId, "closed", "agent-worker-finalize");');
  });

  it("skips troubleshooter for non-retryable pre-existing finalize test failures", () => {
    expect(source).toContain('const shouldSkipTroubleshooter =');
    expect(source).toContain('finalizeFailureReason === "tests_failed_pre_existing_issues"');
    expect(source).toContain('Skipping for non-retryable pre-existing finalize test failures');
    expect(source).toContain('!!workflowConfig.onFailure && !shouldSkipTroubleshooter');
  });

  it("routes normal registered finalize terminal events through Elixir worker events", () => {
    expect(source).toContain('const writeFinalizeTerminalEvent = async (');
    expect(source).toContain('await registeredObservabilityWriter?.logEvent?.(eventType === "complete" ? "run-completed" : "run-failed", {');
    expect(source).not.toContain('await registeredReadStore.logEvent(registeredProjectId, eventType, data, runId);');
    expect(source).not.toContain('store.logEvent(projectId, eventType, data, runId);');
    expect(source).toContain('await writeFinalizeTerminalEvent(finalizeSucceeded ? "complete" : (finalizeRetryable ? "stuck" : "fail"), terminalPayload);');
  });

  it("threads registered project context into Refinery during finalize PR creation", () => {
    // After refactoring, the fallback logic is in deriveFallbackRefineryOptions helper
    // so we check that it's called with the right parameters and the result is passed to Refinery
    expect(source).toContain('deriveFallbackRefineryOptions(');
    expect(source).toContain('registeredProjectId,');
    expect(source).toContain('registeredReadStore,');
    expect(source).toContain('pipelineProjectPath,');
    expect(source).toContain('config.projectId,');
    expect(source).toContain('log,');
    // The derived options are passed to Refinery
    expect(source).toContain('const refinery = new Refinery(');
    expect(source).toContain('runtimeTaskClient,');
    expect(source).toContain('registeredRefineryOptions,');
  });

  it("keeps finalize mail, queue, and terminal status side effects unchanged", () => {
    expect(source).toContain('sendMail(agentMailClient, "foreman", "pr-created", {');
    expect(source).toContain('sendMail(agentMailClient, "refinery", "branch-ready", {');
    expect(source).toContain('await updateTerminalRunStatus({');
    expect(source).toContain('enqueueToMergeQueue({');
    expect(source).toContain('await updateTaskStatusViaElixir(pipelineProjectPath, registeredProjectId, taskId, "closed", "agent-worker-finalize");');
    expect(source).not.toContain('enqueueCloseTask(store, taskId, "agent-worker-finalize")');
  });

  it("keeps tool-policy worker sequences isolated from pipeline observability", () => {
    expect(source).toContain('workerId: `node-pipeline-policy:${config.taskId}:${role}`');
    expect(source).toContain('worker_id: `node-pipeline-policy:${config.taskId}:${role}`');
    expect(source).toContain('const workerId = `node-pipeline:${config.taskId}`;');
  });

  it("routes finalize terminal statuses through the helper", () => {
    expect(source).toContain('status: "completed"');
    expect(source).toContain('status: terminalStatus');
    expect(source).toContain('await updateTerminalRunStatus({');
  });
});
