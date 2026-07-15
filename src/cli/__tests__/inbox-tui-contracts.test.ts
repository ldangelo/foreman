import { createElement } from "react";
import { renderToString } from "ink";
import { describe, expect, it } from "vitest";

import type { Message } from "../../lib/store.js";
import type { InboxTaskSummary } from "../commands/inbox.js";
import { renderInboxTaskSummaryTable, renderTaskDetail } from "../commands/inbox.js";
import { buildInboxTimeline } from "../inbox/timeline.js";
import { InboxDashboard, buildInboxDashboardActions, selectedIndexForRun, tabTimelineItems } from "../inbox/tui.js";

function message(overrides: Partial<Message> = {}): Message {
  return {
    id: "msg-1",
    run_id: "run-1",
    sender_agent_type: "developer",
    recipient_agent_type: "foreman",
    subject: "implementation note",
    body: "ready for review",
    read: 0,
    created_at: "2026-01-01T00:01:00.000Z",
    deleted_at: null,
    ...overrides,
  };
}

function event(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "evt-1",
    runId: "run-1",
    taskId: "task-1",
    eventType: "PhaseStarted",
    details: { phase_id: "developer" },
    createdAt: "2026-01-01T00:00:00.000Z",
    ...overrides,
  };
}

function summary(overrides: Partial<InboxTaskSummary> = {}): InboxTaskSummary {
  const taskId = overrides.taskId ?? "task-1";
  const runId = overrides.runId ?? "run-1";
  const phase = overrides.phase ?? "developer";
  const runStatus = overrides.runStatus ?? "running";

  // Create a mock run object for tasks with runs (unless explicitly set to undefined for backlog)
  const hasExplicitRun = "run" in overrides;
  const mockRun = hasExplicitRun ? overrides.run : {
    id: runId,
    task_id: taskId,
    project_id: "proj-1",
    status: runStatus as never,
    agent_type: phase,
    session_key: null,
    worktree_path: "/tmp/worktree",
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
    lastActivityAt: "2026-01-01T00:02:00.000Z",
    lastActivitySource: "message",
    statusText: "running",
    attention: false,
    attentionReason: null,
    verdict: "unknown",
    projectId: "proj-1",
    worktreePath: "/tmp/worktree",
    messages: [message()],
    events: [event() as never],
    run: mockRun,
    ...overrides,
  };
}

function contractText(value: unknown): string {
  if (Array.isArray(value)) return value.map(contractText).join("\n");
  if (value && typeof value === "object") {
    return Object.values(value as Record<string, unknown>).map(contractText).join(" ");
  }
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") return String(value);
  return "";
}

describe("inbox TUI timeline contracts", () => {
  it("merges messages and events oldest-first without dropping either source", () => {
    const items = buildInboxTimeline(summary({
      messages: [
        message({ id: "msg-old", subject: "old message", created_at: "2026-01-01T00:01:00.000Z" }),
        message({ id: "msg-new", subject: "new message", body: "{\"message\":\"new message\"}", created_at: "2026-01-01T00:04:00.000Z" }),
      ],
      events: [
        event({ id: "evt-middle", eventType: "PhaseCompleted", details: { phase_id: "developer" }, createdAt: "2026-01-01T00:03:00.000Z" }) as never,
        event({ id: "evt-oldest", eventType: "RunStarted", details: { task_id: "task-1" }, createdAt: "2026-01-01T00:00:30.000Z" }) as never,
      ],
    }));

    expect(items.map((item) => item.kind)).toEqual(["event", "message", "event", "message"]);
    expect(items.map((item) => item.createdAt)).toEqual([
      "2026-01-01T00:00:30.000Z",
      "2026-01-01T00:01:00.000Z",
      "2026-01-01T00:03:00.000Z",
      "2026-01-01T00:04:00.000Z",
    ]);
    expect(items.map((item) => `${item.label} ${item.detail ?? ""}`).join("\n")).toContain("new message");
    expect(items.find((item) => item.id === "event:evt-middle")).toMatchObject({
      kind: "event",
      label: "stop",
      detail: expect.stringContaining("Complete"),
    });
  });

  it("honors the timeline limit after merging both event and message sources", () => {
    const items = buildInboxTimeline(summary({
      messages: [message({ id: "msg-new", created_at: "2026-01-01T00:04:00.000Z" })],
      events: [
        event({ id: "evt-middle", eventType: "PhaseCompleted", details: { phase_id: "developer" }, createdAt: "2026-01-01T00:03:00.000Z" }) as never,
        event({ id: "evt-old", eventType: "RunStarted", createdAt: "2026-01-01T00:02:00.000Z" }) as never,
      ],
    }), { limit: 2 });

    expect(items).toHaveLength(2);
    expect(items.map((item) => item.kind)).toEqual(["event", "message"]);
    expect(items.map((item) => item.createdAt)).toEqual([
      "2026-01-01T00:03:00.000Z",
      "2026-01-01T00:04:00.000Z",
    ]);
  });

  it("messages tab shows newest messages in chronological order", () => {
    const items = tabTimelineItems(summary({
      messages: [
        message({ id: "msg-oldest", subject: "oldest message", created_at: "2026-01-01T00:01:00.000Z" }),
        message({ id: "msg-old", subject: "old message", created_at: "2026-01-01T00:02:00.000Z" }),
        message({ id: "msg-new", subject: "new message", created_at: "2026-01-01T00:03:00.000Z" }),
        message({ id: "msg-newest", subject: "newest message", created_at: "2026-01-01T00:04:00.000Z" }),
      ],
      events: [],
    }), "messages", 3, 0);

    // Should show the 3 newest messages in chronological order
    expect(items).toHaveLength(3);
    expect(items.map((item) => item.id)).toEqual([
      "message:msg-old",
      "message:msg-new",
      "message:msg-newest",
    ]);
    expect(items[0].detail).toContain("old message");
    expect(items[2].detail).toContain("newest message");
  });

  it("events tab shows newest events in chronological order", () => {
    const items = tabTimelineItems(summary({
      messages: [],
      events: [
        event({ id: "evt-oldest", eventType: "RunStarted", createdAt: "2026-01-01T00:01:00.000Z" }) as never,
        event({ id: "evt-old", eventType: "PhaseStarted", createdAt: "2026-01-01T00:02:00.000Z" }) as never,
        event({ id: "evt-new", eventType: "PhaseCompleted", createdAt: "2026-01-01T00:03:00.000Z" }) as never,
        event({ id: "evt-newest", eventType: "RunCompleted", createdAt: "2026-01-01T00:04:00.000Z" }) as never,
      ],
    }), "events", 0, 3);

    // Should show the 3 newest events in chronological order
    expect(items).toHaveLength(3);
    expect(items.map((item) => item.id)).toEqual([
      "event:evt-old",
      "event:evt-new",
      "event:evt-newest",
    ]);
  });

  it("messages and events tabs return empty lists for zero limits", () => {
    const data = summary({
      messages: [message({ id: "msg-zero" })],
      events: [event({ id: "evt-zero" }) as never],
    });

    expect(tabTimelineItems(data, "messages", 0, 1)).toEqual([]);
    expect(tabTimelineItems(data, "events", 1, 0)).toEqual([]);
  });
});

describe("inbox TUI render contracts", () => {
  it("renders cockpit labels, selected task context, timeline content, and shortcut hints", () => {
    const output = renderToString(createElement(InboxDashboard, {
      summaries: [summary({
        taskId: "bd-123",
        runId: "run-123",
        phase: "qa",
        messages: [message({ id: "msg-render", subject: "review needed", sender_agent_type: "qa", recipient_agent_type: "foreman" })],
        events: [event({ id: "evt-render", eventType: "PhaseVerdict", details: { phase_id: "qa", verdict: "fail" }, createdAt: "2026-01-01T00:02:00.000Z" }) as never],
      })],
      projectLabel: "Fortium Foreman",
      limit: 10,
      eventsLimit: 10,
    }), { columns: 140 });

    expect(output).toContain("FOREMAN INBOX");
    expect(output).toContain("Fortium Foreman");
    expect(output).toContain("Tasks");
    expect(output).toContain("Timeline");
    expect(output).toContain("Details");
    expect(output).toContain("bd-123");
    expect(output).toContain("run-123");
    expect(output).toContain("review needed");
    expect(output).toContain("PhaseVerdict");
    expect(output).toContain("q/Esc quit");
    expect(output).toContain("j/k select");
    expect(output).toContain("s/m/e/l/r/f tabs");
    expect(output).toMatch(/\brefresh\b/i);
    expect(output).toMatch(/\bactions?\b/i);
  });

  it("renders newest detail rows in chronological order after applying limits", () => {
    const output = renderTaskDetail(summary({
      messages: [
        message({ id: "msg-oldest", subject: "oldest message", body: "oldest message", created_at: "2026-01-01T00:01:00.000Z" }),
        message({ id: "msg-old", subject: "old message", body: "old message", created_at: "2026-01-01T00:02:00.000Z" }),
        message({ id: "msg-new", subject: "new message", body: "new message", created_at: "2026-01-01T00:03:00.000Z" }),
      ],
      events: [
        event({ id: "evt-oldest", eventType: "RunStarted", details: { phase_id: "oldest-phase" }, createdAt: "2026-01-01T00:01:30.000Z" }) as never,
        event({ id: "evt-old", eventType: "PhaseStarted", details: { phase_id: "old-phase" }, createdAt: "2026-01-01T00:02:30.000Z" }) as never,
        event({ id: "evt-new", eventType: "PhaseCompleted", details: { phase_id: "new-phase" }, createdAt: "2026-01-01T00:03:30.000Z" }) as never,
      ],
    }), {
      messages: true,
      events: true,
      limit: 2,
      eventsLimit: 2,
    });

    expect(output).not.toContain("oldest message");
    expect(output).not.toContain("oldest-phase");
    expect(output).toContain("old-phase");
    expect(output).toContain("old message");
    expect(output.indexOf("old-phase")).toBeLessThan(output.indexOf("new-phase"));
    expect(output.indexOf("old message")).toBeLessThan(output.indexOf("new message"));
  });

  it("builds a safe action palette for the selected task and run", () => {
    const actions = buildInboxDashboardActions(summary({
      taskId: "bd-action",
      runId: "run-action",
      runStatus: "failed",
      phase: "reviewer",
      statusText: "needs human review",
    }), "Fortium Foreman");
    const text = contractText(actions);

    expect(text).toMatch(/\blogs?\b/i);
    expect(text).toMatch(/\bdrill\s*down\b|\bdetail\b/i);
    expect(text).toMatch(/\btask status\b|\btask show\b/i);
    expect(text).toContain("bd-action");
    expect(text).toContain("run-action");
    expect(text).toContain("foreman inbox task bd-action");
    expect(text).toContain("foreman logs bd-action");
    expect(text).toMatch(/foreman inbox run run-action\b[\s\S]*--logs/);
    expect(text).toContain("foreman task show bd-action");
    expect(text).not.toMatch(/\b(?:delete|kill|purge|reset|rm|retry|stop)\b/i);
  });

  it("resolves the selected run index across refreshed summaries", () => {
    const refreshed = [
      summary({ taskId: "bd-first", runId: "run-first" }),
      summary({ taskId: "bd-stable", runId: "run-stable" }),
      summary({ taskId: "bd-last", runId: "run-last" }),
    ];

    expect(selectedIndexForRun(refreshed, "run-stable")).toBe(1);
    expect(selectedIndexForRun(refreshed, "run-missing")).toBe(0);
    expect(selectedIndexForRun([], "run-stable")).toBe(-1);
  });

  it("keeps non-interactive summary tables scriptable instead of rendering TUI chrome", () => {
    const output = renderInboxTaskSummaryTable([summary({ taskId: "bd-script", runId: "run-script", phase: "review" })]);

    expect(output).toContain("bd-script");
    expect(output).toContain("run-script");
    expect(output).toContain("review");
    expect(output).not.toContain("Timeline");
    expect(output).not.toContain("q/Esc quit");
    expect(output).not.toContain("j/k select");
  });
});
