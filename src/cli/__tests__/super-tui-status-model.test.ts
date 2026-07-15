import { describe, expect, it } from "vitest";

import type { InboxTaskSummary } from "../commands/inbox.js";
import { buildWorkflowStatusSummary, dedupeActiveRunsByRunId, normalizeWorkflowEventType } from "../super-tui/status-model.js";

type SummaryEvent = InboxTaskSummary["events"][number];

function workflowEvent(overrides: Partial<SummaryEvent> & { details?: Record<string, unknown> } = {}): SummaryEvent {
  return {
    id: "evt-alpha",
    runId: "run-alpha",
    taskId: "task-alpha",
    eventType: "PhaseStarted",
    details: { phase_id: "developer" },
    createdAt: "2026-01-01T00:00:00.000Z",
    ...overrides,
  } as SummaryEvent;
}

function summary(overrides: Partial<InboxTaskSummary> = {}): InboxTaskSummary {
  const taskId = overrides.taskId ?? "task-alpha";
  const runId = overrides.runId ?? "run-alpha";
  const phase = overrides.phase ?? "developer";
  const runStatus = overrides.runStatus ?? "running";

  // Create a mock run object for tasks with runs (unless explicitly set to undefined for backlog)
  const hasExplicitRun = "run" in overrides;
  const mockRun = hasExplicitRun ? overrides.run : {
    id: runId,
    task_id: taskId,
    project_id: "project-1",
    status: runStatus as never,
    agent_type: phase,
    session_key: null,
    worktree_path: `/tmp/foreman/${taskId}`,
    created_at: "2026-01-01T00:00:00.000Z",
    started_at: null,
    completed_at: null,
    progress: null,
  };

  return {
    taskId,
    runId,
    runStatus,
    phase,
    lastActivityAt: "2026-01-01T00:00:30.000Z",
    lastActivitySource: "event",
    statusText: `${phase} running`,
    attention: false,
    attentionReason: null,
    verdict: "unknown",
    projectId: "project-1",
    worktreePath: `/tmp/foreman/${taskId}`,
    messages: [],
    events: [],
    run: mockRun,
    ...overrides,
  };
}

describe("normalizeWorkflowEventType", () => {
  it.each([
    ["PhaseStarted", "phasestarted"],
    ["PhaseRetried", "phaseretried"],
    ["phase_started", "phasestarted"],
    ["phase-start", "phasestart"],
    ["phase-complete", "phasecomplete"],
    ["phase_completed", "phasecompleted"],
    ["phase-failed", "phasefailed"],
    ["run-progress", "runprogress"],
  ])("normalizes %s event names to the workflow key %s", (eventType, expected) => {
    expect(normalizeWorkflowEventType(eventType)).toBe(expected);
  });
});

describe("buildWorkflowStatusSummary", () => {
  it("records a failed QA phase retrying back through repair with retry metadata", () => {
    const status = buildWorkflowStatusSummary(summary({
      runStatus: "running",
      phase: "qa",
      statusText: "repair running",
      lastActivityAt: "2026-01-01T00:00:00.000Z",
      events: [
        workflowEvent({
          id: "evt-developer-completed",
          eventType: "PhaseCompleted",
          details: { phase: "developer", verdict: "pass" },
          createdAt: "2026-01-01T00:01:00.000Z",
        }),
        workflowEvent({
          id: "evt-qa-failed",
          eventType: "PhaseFailed",
          details: {
            phase: "qa",
            error: "QA rejected the fix",
            artifactPath: "reports/qa-failure.md",
            verdict: "fail",
          },
          createdAt: "2026-01-01T00:02:00.000Z",
        }),
        workflowEvent({
          id: "evt-qa-retried",
          eventType: "PhaseRetried",
          details: {
            phase: "qa",
            retryTarget: "repair",
            attempt: 2,
            maxRetries: 3,
            reason: "Send back to repair",
          },
          createdAt: "2026-01-01T00:03:00.000Z",
        }),
        workflowEvent({
          id: "evt-repair-started",
          eventType: "PhaseStarted",
          details: { phase: "repair", attempt: 2, maxRetries: 3 },
          createdAt: "2026-01-01T00:04:00.000Z",
        }),
      ],
    }));

    expect(status.retryEdges).toEqual([
      { from: "qa", to: "repair", attempt: 2, maxRetries: 3, createdAt: "2026-01-01T00:03:00.000Z" },
    ]);
    expect(status.failure).toBe("QA rejected the fix");
    expect(status.artifactPaths).toEqual(["reports/qa-failure.md"]);
    expect(status.currentPhase).toBe("repair");
    expect(status.activeAgent).toMatchObject({ phase: "repair", lastActivityAt: "2026-01-01T00:04:00.000Z" });
    expect(status.phases).toEqual(expect.arrayContaining([
      expect.objectContaining({ phase: "developer", status: "completed", verdict: "pass" }),
      expect.objectContaining({ phase: "qa", status: "retried", attempt: 2, maxRetries: 3, verdict: "retrying" }),
      expect.objectContaining({ phase: "repair", status: "running", attempt: 2, maxRetries: 3 }),
    ]));
  });

  it("uses phase-only Elixir events as current phase and last activity without RunProgress", () => {
    const status = buildWorkflowStatusSummary(summary({
      phase: "qa",
      lastActivityAt: null,
      statusText: "waiting for status",
      events: [
        workflowEvent({
          id: "evt-dev-started",
          eventType: "phase_started",
          details: { phase_id: "developer" },
          createdAt: "2026-01-01T00:01:00.000Z",
        }),
        workflowEvent({
          id: "evt-dev-completed",
          eventType: "phase_completed",
          details: { phase_id: "developer", verdict: "passed" },
          createdAt: "2026-01-01T00:02:00.000Z",
        }),
        workflowEvent({
          id: "evt-qa-started",
          eventType: "phase_started",
          details: { phase_id: "qa" },
          createdAt: "2026-01-01T00:03:00.000Z",
        }),
      ],
    }));

    expect(status.currentPhase).toBe("qa");
    expect(status.lastActivityAt).toBe("2026-01-01T00:03:00.000Z");
    expect(status.lastActivity).toBe("qa: phasestarted");
    expect(status.activeAgent).toMatchObject({
      phase: "qa",
      lastActivityAt: "2026-01-01T00:03:00.000Z",
      lastActivity: "qa: phasestarted",
    });
    expect(status.phases).toEqual(expect.arrayContaining([
      expect.objectContaining({ phase: "developer", status: "completed", verdict: "pass" }),
      expect.objectContaining({ phase: "qa", status: "running" }),
    ]));
  });

  it("does not rewind fresher message activity from an older legacy phase-started event", () => {
    const status = buildWorkflowStatusSummary(summary({
      phase: "qa",
      lastActivityAt: "2026-01-01T00:10:00.000Z",
      lastActivitySource: "message",
      statusText: "operator replied after QA started",
      events: [
        workflowEvent({
          id: "evt-legacy-qa-started",
          eventType: "phase-start",
          details: { phase: "qa", message: "QA started" },
          createdAt: "2026-01-01T00:03:00.000Z",
        }),
      ],
    }));

    expect(status.currentPhase).toBe("qa");
    expect(status.lastActivityAt).toBe("2026-01-01T00:10:00.000Z");
    expect(status.lastActivity).toBe("operator replied after QA started");
    expect(status.activeAgent).toMatchObject({
      phase: "qa",
      lastActivityAt: "2026-01-01T00:10:00.000Z",
      lastActivity: "operator replied after QA started",
    });
    expect(status.phases).toEqual([
      expect.objectContaining({ phase: "qa", status: "running", startedAt: "2026-01-01T00:03:00.000Z" }),
    ]);
  });
});

describe("dedupeActiveRunsByRunId", () => {
  it("collapses duplicate active run projections by run id and keeps the newest row", () => {
    const deduped = dedupeActiveRunsByRunId([
      {
        id: "run-dup",
        runId: "run-dup",
        taskId: "task-old",
        status: "pending",
        createdAt: "2026-01-01T00:01:00.000Z",
      },
      {
        id: "run-other",
        runId: "run-other",
        taskId: "task-other",
        status: "running",
        createdAt: "2026-01-01T00:03:00.000Z",
      },
      {
        id: "run-dup",
        runId: "run-dup",
        taskId: "task-new",
        status: "running",
        startedAt: "2026-01-01T00:04:00.000Z",
      },
      {
        run_id: "run-snake",
        task_id: "task-snake",
        status: "running",
        queued_at: "2026-01-01T00:02:00.000Z",
      },
    ]);

    expect(deduped).toEqual([
      expect.objectContaining({ id: "run-dup", taskId: "task-new", startedAt: "2026-01-01T00:04:00.000Z" }),
      expect.objectContaining({ id: "run-other", taskId: "task-other" }),
      expect.objectContaining({ run_id: "run-snake", task_id: "task-snake" }),
    ]);
  });
});
