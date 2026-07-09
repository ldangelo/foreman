import { createElement } from "react";
import { renderToString } from "ink";
import { describe, expect, it } from "vitest";

import type { Message } from "../../lib/store.js";
import type { InboxTaskSummary } from "../commands/inbox.js";
import { renderInboxTaskSummaryTable } from "../commands/inbox.js";
import { buildInboxTimeline } from "../inbox/timeline.js";
import { InboxDashboard, buildInboxDashboardActions, selectedIndexForRun } from "../inbox/tui.js";

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
  return {
    taskId: "task-1",
    runId: "run-1",
    runStatus: "running",
    phase: "developer",
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
  it("merges messages and events newest-first without dropping either source", () => {
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

    expect(items.map((item) => item.kind)).toEqual(["message", "event", "message", "event"]);
    expect(items.map((item) => item.createdAt)).toEqual([
      "2026-01-01T00:04:00.000Z",
      "2026-01-01T00:03:00.000Z",
      "2026-01-01T00:01:00.000Z",
      "2026-01-01T00:00:30.000Z",
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
    expect(items.map((item) => item.kind)).toEqual(["message", "event"]);
    expect(items.map((item) => item.createdAt)).toEqual([
      "2026-01-01T00:04:00.000Z",
      "2026-01-01T00:03:00.000Z",
    ]);
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
