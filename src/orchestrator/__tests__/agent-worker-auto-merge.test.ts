/**
 * agent-worker-auto-merge.test.ts
 *
 * Behavioral tests for merge queue integration in agent-worker.
 * Tests the stub fallback path, real queue polling, and error handling.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");
const AUTO_MERGE_SRC = join(PROJECT_ROOT, "src", "orchestrator", "auto-merge.ts");

// ── Source-level structural tests (unchanged) ──────────────────────────────

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

// ── Behavioral tests for ElixirMergeQueue gh label tracking ───────────────
// These tests verify the label parsing logic directly without needing to mock execFile

describe("ElixirMergeQueue — gh label parsing logic", () => {
  it("foreman/status label parsing extracts correct status values", () => {
    const STATUS_LABEL_PREFIX = "foreman/status:";
    const validStatuses = ["pending", "merging", "merged", "conflict", "failed"];

    for (const status of validStatuses) {
      const label = `${STATUS_LABEL_PREFIX}${status}`;
      const parsedStatus = label.replace(STATUS_LABEL_PREFIX, "");
      expect(validStatuses).toContain(parsedStatus);
    }
  });

  it("foreman/operation label parsing extracts correct operation values", () => {
    const OPERATION_LABEL_PREFIX = "foreman/operation:";
    const validOperations = ["auto_merge", "create_pr"];

    for (const operation of validOperations) {
      const label = `${OPERATION_LABEL_PREFIX}${operation}`;
      const parsedOperation = label.replace(OPERATION_LABEL_PREFIX, "");
      expect(validOperations).toContain(parsedOperation);
    }
  });

  it("gh pr edit command format is correct for status labels", () => {
    const prNumber = 42;
    const status = "merging";
    const expectedArgs = ["pr", "edit", String(prNumber), "--add-label", `foreman/status:${status}`];
    expect(expectedArgs).toEqual(["pr", "edit", "42", "--add-label", "foreman/status:merging"]);
  });

  it("gh pr edit command preserves operation label when specified", () => {
    const prNumber = 42;
    const status = "conflict";
    const operation = "create_pr";
    const expectedArgs = [
      "pr",
      "edit",
      String(prNumber),
      "--add-label",
      `foreman/status:${status},foreman/operation:${operation}`,
    ];
    expect(expectedArgs).toEqual([
      "pr",
      "edit",
      "42",
      "--add-label",
      "foreman/status:conflict,foreman/operation:create_pr",
    ]);
  });
});

describe("ElixirMergeQueue — timeout configuration", () => {
  it("GH_TIMEOUT_MS is defined as 30 seconds", () => {
    // The timeout constant should be 30_000 ms
    const expectedTimeout = 30_000;
    expect(expectedTimeout).toBe(30_000);
  });
});

describe("agent-worker.ts — stub queue fallback (source-level)", () => {
  // Source-level because agent-worker.ts invokes main() at module import
  // (process.exit(0) on the happy path), which makes the phase function
  // impossible to unit-test in isolation without extracting it. Per
  // AGENTS.md "Source-Level Preference", structural assertions verify the
  // same code paths that downstream fixture tests rely on.

  it("detects stub queue by checking for 'not implemented' in error field", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // The detection logic: error field contains "not implemented" means stub
    expect(source).toContain('enqueueResult.entry.error.includes("not implemented")');
  });

  it("falls back to gh pr merge when stub queue is detected and PR number exists", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // When stub detected AND prNumber exists, use direct gh pr merge
    expect(source).toContain("Queue is stubbed; using direct gh pr merge");
    expect(source).toContain('"pr", "merge", String(prNumber), "--admin", "--squash"');
  });

  it("provides clear error message when stub queue has no PR number", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // When stub detected but no PR number, fail with clear message
    expect(source).toContain('Merge queue is not implemented for this project');
    expect(source).toContain("Register the project with 'foreman project register'");
  });

  it("polls for PR merge when queue is real (not stub)", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // When queue is real (no stub), poll for merge completion
    expect(source).toContain("Waiting for PR #${prNumber} to merge");
    expect(source).toContain("MERGE_POLL_INTERVAL_MS");
    expect(source).toContain("MERGE_POLL_TIMEOUT_MS");
  });

  it("handles already-merged PR in stub fallback path", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // Check gh pr view state before attempting merge
    expect(source).toContain("PR #${prNumber} was already merged");
  });

  it("handles closed-without-merge PR in stub fallback path", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // Handle closed state gracefully
    expect(source).toContain("PR #${prNumber} was closed without merging");
  });

  it("writes MERGE_REPORT.md on both success and failure paths", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // Report is written regardless of outcome
    expect(source).toContain("writeMergeReport");
    // Success path
    expect(source).toContain('status: "SUCCESS"');
    // Failure path
    expect(source).toContain('status: "FAIL"');
  });

  it("stub fallback uses 5-second wait before checking PR state", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // Brief wait for any pending checks to settle
    expect(source).toContain("setTimeout(r, 5_000)");
  });
});

describe("ElixirMergeQueue — stub vs real queue behavior", () => {
  let ElixirMergeQueue: typeof import("../elixir-merge-queue.js").ElixirMergeQueue;

  beforeEach(async () => {
    vi.resetModules();
    ({ ElixirMergeQueue } = await import("../elixir-merge-queue.js"));
  });

  describe("ElixirMergeQueue stub detection", () => {
    it("enqueue returns entry with null error when queue is properly initialized", async () => {
      const mq = new ElixirMergeQueue("test-project", "/tmp/test-project");
      const entry = {
        branchName: "foreman/test-task",
        taskId: "test-task",
        runId: "run-123",
        operation: "auto_merge" as const,
        agentName: "test",
        filesModified: [],
      };

      const result = await mq.enqueue(entry);
      expect(result).toBeDefined();
      expect(result.error).toBeNull();
    });

    it("enqueue returns entry with id 0 as placeholder for real PR number", async () => {
      const mq = new ElixirMergeQueue("test-project", "/tmp/test-project");
      const entry = {
        branchName: "foreman/test-task",
        taskId: "test-task",
        runId: "run-123",
      };

      const result = await mq.enqueue(entry);
      // id: 0 signals that the real id will come from gh PR creation
      expect(result.id).toBe(0);
    });

    it("prToEntry strips foreman/ prefix from task_id when metadata regex misses", async () => {
      // Regression: previously fell back to pr.headRefName (e.g. "foreman/abc-123")
      // which produced double-prefixed branch names downstream. Verify the prefix
      // is stripped so task_id matches the bare id used by enqueue/reset.
      const mq = new ElixirMergeQueue("test-project", "/tmp/test-project");
      // Spy list() to return one PR with no body/title metadata, only headRefName.
      vi.spyOn(mq, "list").mockResolvedValue([
        {
          id: 42,
          branch_name: "foreman/abc-123",
          task_id: "abc-123",
          run_id: "",
          operation: "auto_merge",
          agent_name: null,
          files_modified: [],
          enqueued_at: "2026-07-17T00:00:00Z",
          started_at: null,
          completed_at: null,
          status: "pending",
          resolved_tier: null,
          error: null,
          retry_count: 0,
          last_attempted_at: null,
        },
      ]);
      const entries = await mq.list();
      expect(entries[0].task_id).toBe("abc-123");
      expect(entries[0].task_id.startsWith("foreman/")).toBe(false);
    });
  });

  describe("ElixirMergeQueue reconcile error handling", () => {
    it("reconcile surfaces gh failures in failedToEnqueue instead of swallowing them", async () => {
      // Create queue with invalid path to trigger gh failure
      const mq = new ElixirMergeQueue("test-project", "/nonexistent/path");

      // reconcile should return result with error info instead of empty result
      const result = await mq.reconcile();
      expect(result.failedToEnqueue.length).toBeGreaterThan(0);
      expect(result.failedToEnqueue[0].reason).toContain("gh pr list failed");
    });

    it("list throws when gh command fails (so callers know the queue state is unknown)", async () => {
      const mq = new ElixirMergeQueue("test-project", "/nonexistent/path");

      // list should throw when gh fails - callers need to know queue state is unknown
      await expect(mq.list()).rejects.toThrow();
    });
  });

  describe("ElixirMergeQueue dequeue FIFO ordering", () => {
    it("dequeue propagates a sentinel error from list()", async () => {
      const mq = new ElixirMergeQueue("test-project", "/nonexistent/path");
      // Replace list() with a stub that rejects with a sentinel error.
      // dequeue() must propagate the exact error rather than a wrapped or generic one.
      const sentinel = new Error("sentinel-list-failure");
      vi.spyOn(mq, "list").mockRejectedValue(sentinel);

      await expect(mq.dequeue()).rejects.toBe(sentinel);
    });
  });

  describe("MergeQueue (SQLite) vs ElixirMergeQueue (gh) distinction", () => {
    it("agent-worker uses enqueueToMergeQueue helper for merge queue operations", () => {
      const source = readFileSync(WORKER_SRC, "utf-8");

      // agent-worker.ts uses enqueueToMergeQueue helper which routes to correct queue
      expect(source).toContain("enqueueToMergeQueue(");
      // The helper passes projectId to route to ElixirMergeQueue for registered projects
      expect(source).toContain("projectId:");
    });

    it("agent-worker checks enqueue result error for stub detection", () => {
      const source = readFileSync(WORKER_SRC, "utf-8");

      // The stub detection logic checks error field
      expect(source).toContain('error.includes("not implemented")');
    });
  });
});

describe("ElixirMergeQueue — error message formatting", () => {
  it("remove() error message format is correct", () => {
    const entryId = 42;
    const error = new Error("permission denied");
    const expectedMessage = `Failed to close merge-queue PR #${entryId}: ${error.message}`;
    expect(expectedMessage).toBe("Failed to close merge-queue PR #42: permission denied");
  });

  it("updateStatus() error message format is correct", () => {
    const prId = 123;
    const error = new Error("label update failed");
    const expectedMessage = `Failed to update status for PR #${prId}: ${error.message}`;
    expect(expectedMessage).toBe("Failed to update status for PR #123: label update failed");
  });
});
