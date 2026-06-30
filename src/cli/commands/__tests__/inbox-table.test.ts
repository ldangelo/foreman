/**
 * Tests for inbox table formatting.
 *
 * @module src/cli/commands/__tests__/inbox-table.test
 */

import { describe, it, expect } from "vitest";
import {
  adaptDaemonMessage,
  adaptDaemonRun,
  adaptPostgresEvent,
  extractBodyFields,
  formatEventSummary,
  formatMessageTable,
  formatPipelineEvent,
  parseMessageBody,
  renderMessageTable,
  selectRecentMessages,
  truncate,
  wrapText,
  type TableRow,
} from "../inbox.js";

describe("parseMessageBody", () => {
  it("extracts kind, tool, argsPreview from structured JSON payload", () => {
    const body = JSON.stringify({
      phase: "developer",
      status: "completed",
      kind: "agent-error",
      tool: "send_mail",
      argsPreview: "--run-id abc123 --to foreman --subject agent-error",
      seedId: "foreman-c3845",
      runId: "run-xyz",
    });
    const result = parseMessageBody(body);
    expect(result.kind).toBe("agent-error");
    expect(result.tool).toBe("send_mail");
    expect(result.argsPreview).toBe("--run-id abc123 --to foreman --subject agent-error");
    expect(result.seedId).toBe("foreman-c3845");
    expect(result.runId).toBe("run-xyz");
  });

  it("gracefully handles missing fields", () => {
    const body = JSON.stringify({ phase: "explorer", status: "running" });
    const result = parseMessageBody(body);
    expect(result.kind).toBeUndefined();
    expect(result.tool).toBeUndefined();
    expect(result.argsPreview).toBeUndefined();
    expect(result.seedId).toBeUndefined();
    expect(result.runId).toBeUndefined();
  });

  it("gracefully handles non-JSON body", () => {
    const result = parseMessageBody("this is just plain text body");
    expect(result.kind).toBeUndefined();
    expect(result.tool).toBeUndefined();
    expect(result.argsPreview).toBeUndefined();
    expect(result.seedId).toBeUndefined();
    expect(result.runId).toBeUndefined();
  });

  it("gracefully handles empty body", () => {
    const result = parseMessageBody("");
    expect(result.kind).toBeUndefined();
    expect(result.tool).toBeUndefined();
  });

  it("gracefully handles malformed JSON", () => {
    const result = parseMessageBody('{"phase": "developer", broken');
    expect(result.kind).toBeUndefined();
    expect(result.seedId).toBeUndefined();
  });
});

describe("truncate", () => {
  it("returns string unchanged when under max length", () => {
    expect(truncate("hello", 20)).toBe("hello");
  });

  it("truncates strings longer than max length with ellipsis", () => {
    expect(truncate("hello world this is long", 10)).toBe("hello wor…");
  });

  it("prefers a nearby word boundary when truncating", () => {
    expect(truncate("hello world again", 12)).toBe("hello world…");
  });

  it("returns empty string for non-positive maxLen", () => {
    expect(truncate("hello", 0)).toBe("");
  });

  it("returns a single ellipsis for tiny widths", () => {
    expect(truncate("hello", 1)).toBe("…");
    expect(truncate("hello", 3)).toBe("…");
  });

  it("handles exact-length strings", () => {
    expect(truncate("exactly10c", 10)).toBe("exactly10c");
  });

  it("handles empty string", () => {
    expect(truncate("", 10)).toBe("");
  });
});

describe("wrapText", () => {
  it("preserves short lines unchanged", () => {
    expect(wrapText("short line", 20)).toBe("short line");
  });

  it("wraps long lines on word boundaries", () => {
    expect(wrapText("alpha beta gamma delta", 10)).toBe("alpha\nbeta\ngamma\ndelta");
  });

  it("forces breaks when no spaces exist", () => {
    expect(wrapText("abcdefghijkl", 5)).toBe("abcde\nfghij\nkl");
  });
});

describe("extractBodyFields", () => {
  it("prefers argsPreview when present", () => {
    const result = extractBodyFields(JSON.stringify({ kind: "tool", tool: "bash", argsPreview: "npm test", message: "ignored" }));
    expect(result).toEqual({ kind: "tool", tool: "bash", args: "npm test" });
  });

  it("falls back through message then body", () => {
    expect(extractBodyFields(JSON.stringify({ kind: "note", tool: "read", message: "hello" }))).toEqual({ kind: "note", tool: "read", args: "hello" });
    expect(extractBodyFields(JSON.stringify({ kind: "note", tool: "read", body: "raw body" }))).toEqual({ kind: "note", tool: "read", args: "raw body" });
  });
});

describe("selectRecentMessages", () => {
  it("returns the last N messages in order", () => {
    const messages = [
      { id: "m1" },
      { id: "m2" },
      { id: "m3" },
    ] as Array<any>;

    expect(selectRecentMessages(messages, 2).map((msg) => msg.id)).toEqual(["m2", "m3"]);
  });

  it("returns all messages when limit exceeds length", () => {
    const messages = [{ id: "m1" }, { id: "m2" }] as Array<any>;
    expect(selectRecentMessages(messages, 10).map((msg) => msg.id)).toEqual(["m1", "m2"]);
  });
});

describe("daemon adapters", () => {
  it("adapts daemon messages and preserves read/deleted fields", () => {
    const msg = adaptDaemonMessage({
      id: "msg-1",
      run_id: "run-1",
      sender_agent_type: "developer",
      recipient_agent_type: "foreman",
      subject: "phase-complete",
      body: "{}",
      read: 1,
      created_at: "2026-01-01T00:00:00.000Z",
      deleted_at: "2026-01-02T00:00:00.000Z",
    });

    expect(msg).toEqual({
      id: "msg-1",
      run_id: "run-1",
      sender_agent_type: "developer",
      recipient_agent_type: "foreman",
      subject: "phase-complete",
      body: "{}",
      read: 1,
      created_at: "2026-01-01T00:00:00.000Z",
      deleted_at: "2026-01-02T00:00:00.000Z",
    });
  });

  it("adapts daemon runs across success/failure/cancelled fallback statuses", () => {
    const successRun = adaptDaemonRun({
      id: "run-1",
      bead_id: "task-1",
      status: "success",
      branch: "foreman/task-1",
      queued_at: "2026-01-01T00:00:00.000Z",
      started_at: "2026-01-01T00:01:00.000Z",
      finished_at: "2026-01-01T00:02:00.000Z",
      created_at: "2026-01-01T00:00:00.000Z",
    });
    const cancelledRun = adaptDaemonRun({
      id: "run-2",
      bead_id: "task-2",
      status: "cancelled",
      branch: "foreman/task-2",
      queued_at: "2026-01-01T00:00:00.000Z",
      started_at: null,
      finished_at: null,
      created_at: "2026-01-01T00:00:00.000Z",
    });
    const unknownRun = adaptDaemonRun({
      id: "run-3",
      bead_id: "task-3",
      status: "mystery",
      branch: "foreman/task-3",
      queued_at: "2026-01-01T00:00:00.000Z",
      started_at: null,
      finished_at: null,
      created_at: "2026-01-01T00:00:00.000Z",
    });

    expect(successRun.status).toBe("success");
    expect(successRun.agent_type).toBe("daemon");
    expect(successRun.worktree_path).toBeNull();
    expect(cancelledRun.status).toBe("cancelled");
    expect(cancelledRun.session_key).toBeNull();
    expect(unknownRun.status).toBe("mystery");
  });
});

describe("pipeline event formatting", () => {
  it("formats phase and dispatch event summaries from structured details", () => {
    expect(formatEventSummary("phase-start", { phase: "developer" })).toBe("Start: developer");
    expect(formatEventSummary("phase-complete", { phase: "qa" })).toBe("Complete: qa");
    expect(formatEventSummary("dispatch", { bead_id: "task-1" })).toBe("Dispatch: task-1");
  });

  it("falls back through known event detail keys and raw event type", () => {
    expect(formatEventSummary("pr-created", { pr_number: 42 })).toBe("PR #42 created");
    expect(formatEventSummary("stuck", { seedId: "task-9" })).toBe("Stuck: task-9");
    expect(formatEventSummary("merge-queue-fallback", { bead_id: "task-8" })).toBe("merge-queue-fallback: task-8");
    expect(formatEventSummary("merge-cleanup-fallback", { bead_id: "task-7" })).toBe("merge-cleanup-fallback: task-7");
    expect(formatEventSummary("unknown-event", { bead_id: "task-2" })).toBe("unknown-event: task-2");
    expect(formatEventSummary("unknown-event", { seedId: "task-3" })).toBe("unknown-event: task-3");
    expect(formatEventSummary("unknown-event", null)).toBe("unknown-event");
  });

  it("formats full pipeline event lines with timestamps and icons", () => {
    const line = formatPipelineEvent({
      id: "evt-1",
      runId: "run-1",
      eventType: "merge",
      details: { bead_id: "task-3" },
      createdAt: "2026-01-01T00:00:00.000Z",
    });

    expect(line).toContain("merge");
    expect(line).toContain("Merged: task-3");
    expect(line).toMatch(/^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]/);
  });

  it("uses the default bullet icon for unknown pipeline event types", () => {
    const line = formatPipelineEvent({
      id: "evt-unknown",
      runId: "run-1",
      eventType: "unknown-event",
      details: { seedId: "task-3" },
      createdAt: "2026-01-01T00:00:00.000Z",
    });

    expect(line).toContain("] · unknown-event — unknown-event: task-3");
  });

  it("adapts Postgres events from both JSON strings and object payloads", () => {
    const fromString = adaptPostgresEvent({
      id: "evt-2",
      run_id: "run-2",
      event_type: "fail",
      payload: JSON.stringify({ seedId: "task-7" }),
      created_at: "2026-01-01T00:00:00.000Z",
    });
    const fromObject = adaptPostgresEvent({
      id: "evt-3",
      run_id: null,
      event_type: "phase-complete",
      payload: { phase: "reviewer" },
      created_at: new Date("2026-01-01T00:01:00.000Z"),
    });
    const fromScalar = adaptPostgresEvent({
      id: "evt-4",
      run_id: "run-4",
      event_type: "dispatch",
      payload: 7,
      created_at: "2026-01-01T00:02:00.000Z",
    });

    expect(fromString).toMatchObject({ runId: "run-2", eventType: "fail", details: { seedId: "task-7" } });
    expect(fromObject).toMatchObject({ runId: null, eventType: "phase-complete", details: { phase: "reviewer" } });
    expect(fromObject.createdAt).toBe("2026-01-01T00:01:00.000Z");
    expect(fromScalar).toMatchObject({ runId: "run-4", eventType: "dispatch", details: null });
  });
});

describe("formatMessageTable", () => {
  // Helper to get a date string in local time matching formatMessage's output
  const localTs = (isoStr: string): string => {
    const d = new Date(isoStr);
    const pad = (n: number): string => String(n).padStart(2, "0");
    return (
      `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
      `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
    );
  };

  it("formats a basic message row with all fields", () => {
    const createdAt = "2026-04-30T14:23:45.000Z";
    const msg = {
      id: "msg-001",
      run_id: "run-abc",
      sender_agent_type: "developer",
      recipient_agent_type: "foreman",
      subject: "agent-error",
      body: JSON.stringify({
        kind: "agent-error",
        tool: "send_mail",
        argsPreview: "--run-id abc123 --to foreman",
        seedId: "foreman-c3845",
        runId: "run-abc",
      }),
      read: 0,
      created_at: createdAt,
      deleted_at: null,
    };
    const row = formatMessageTable(msg);
    expect(row.date).toBe(localTs(createdAt));
    expect(row.ticket).toBe("foreman-c3845");
    expect(row.sender).toBe("developer");
    expect(row.receiver).toBe("foreman");
    expect(row.kind).toBe("agent-error");
    expect(row.tool).toBe("send_mail");
    expect(row.args).toBe("--run-id abc123 --to foreman");
    expect(row.runId).toBe("run-abc");
    expect(row.isRead).toBe(false);
  });

  it("gracefully degrades when body is not JSON", () => {
    const createdAt = "2026-04-30T10:00:00.000Z";
    const msg = {
      id: "msg-002",
      run_id: "run-xyz",
      sender_agent_type: "explorer",
      recipient_agent_type: "developer",
      subject: "phase-started",
      body: "plain text notification",
      read: 1,
      created_at: createdAt,
      deleted_at: null,
    };
    const row = formatMessageTable(msg);
    expect(row.date).toBe(localTs(createdAt));
    expect(row.ticket).toBe("run-xyz"); // falls back to run_id
    expect(row.sender).toBe("explorer");
    expect(row.receiver).toBe("developer");
    expect(row.kind).toBeUndefined();
    expect(row.tool).toBeUndefined();
    expect(row.args).toBeUndefined();
    expect(row.runId).toBe("run-xyz");
    expect(row.isRead).toBe(true);
  });

  it("gracefully degrades when body is missing structured fields", () => {
    const msg = {
      id: "msg-003",
      run_id: "run-xyz",
      sender_agent_type: "qa",
      recipient_agent_type: "developer",
      subject: "feedback",
      body: JSON.stringify({ phase: "developer", status: "running" }),
      read: 0,
      created_at: "2026-04-29T08:00:00.000Z",
      deleted_at: null,
    };
    const row = formatMessageTable(msg);
    expect(row.ticket).toBe("run-xyz"); // falls back to run_id
    expect(row.kind).toBeUndefined();
    expect(row.tool).toBeUndefined();
    expect(row.args).toBeUndefined();
  });

  it("truncates long args safely", () => {
    const longArgs = "--run-id abc123 --to foreman --subject agent-error --body '{\"phase\":\"developer\",\"error\":\"something went wrong with the task execution\"}'";
    const msg = {
      id: "msg-004",
      run_id: "run-abc",
      sender_agent_type: "developer",
      recipient_agent_type: "foreman",
      subject: "agent-error",
      body: JSON.stringify({
        kind: "agent-error",
        tool: "send_mail",
        argsPreview: longArgs,
        seedId: "foreman-c3845",
        runId: "run-abc",
      }),
      read: 0,
      created_at: "2026-04-30T14:23:45.000Z",
      deleted_at: null,
    };
    const row = formatMessageTable(msg, 40);
    expect(row.args).toBeDefined();
    expect(row.args?.length).toBeLessThanOrEqual(43); // 40 + "…"
    expect(row.args?.endsWith("…")).toBe(true);
  });

  it("uses seedId as ticket when available", () => {
    const msg = {
      id: "msg-005",
      run_id: "run-abc",
      sender_agent_type: "developer",
      recipient_agent_type: "foreman",
      subject: "agent-error",
      body: JSON.stringify({
        seedId: "foreman-c3845",
        runId: "run-abc",
        kind: "agent-error",
        tool: "bash",
        argsPreview: "npm test",
      }),
      read: 0,
      created_at: "2026-04-30T14:23:45.000Z",
      deleted_at: null,
    };
    const row = formatMessageTable(msg);
    expect(row.ticket).toBe("foreman-c3845");
  });

  it("falls back to run_id when seedId is absent", () => {
    const msg = {
      id: "msg-006",
      run_id: "run-abc",
      sender_agent_type: "developer",
      recipient_agent_type: "foreman",
      subject: "agent-error",
      body: JSON.stringify({
        runId: "run-abc",
        kind: "agent-error",
        tool: "bash",
        argsPreview: "npm test",
      }),
      read: 0,
      created_at: "2026-04-30T14:23:45.000Z",
      deleted_at: null,
    };
    const row = formatMessageTable(msg);
    expect(row.ticket).toBe("run-abc");
  });
});

describe("renderMessageTable", () => {
  const localTs = (isoStr: string): string => {
    const d = new Date(isoStr);
    const pad = (n: number): string => String(n).padStart(2, "0");
    return (
      `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
      `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
    );
  };

  const makeRow = (overrides: Partial<TableRow> & { id: string; created_at: string }): TableRow => ({
    date: localTs(overrides.created_at),
    ticket: overrides.ticket ?? "seed-001",
    sender: overrides.sender ?? "developer",
    receiver: overrides.receiver ?? "foreman",
    kind: overrides.kind,
    tool: overrides.tool,
    args: overrides.args,
    runId: overrides.runId ?? "run-001",
    isRead: overrides.isRead ?? false,
    ...overrides,
  });

  it("renders empty string when given no rows", () => {
    expect(renderMessageTable([])).toBe("");
  });

  it("renders a header row with column labels", () => {
    const rows = [
      makeRow({
        id: "msg-001",
        created_at: "2026-04-30T14:23:45.000Z",
        ticket: "foreman-c3845",
        sender: "developer",
        receiver: "foreman",
        kind: "agent-error",
        tool: "send_mail",
        args: "--run-id abc",
      }),
    ];
    const output = renderMessageTable(rows);
    expect(output).toContain("DATE");
    expect(output).toContain("TICKET");
    expect(output).toContain("SENDER");
    expect(output).toContain("RECEIVER");
    expect(output).toContain("KIND");
    expect(output).toContain("TOOL");
    expect(output).toContain("ARGS");
    expect(output).toContain("│"); // column separators
  });

  it("renders multiple rows with data", () => {
    const rows = [
      makeRow({
        id: "msg-001",
        created_at: "2026-04-30T14:23:45.000Z",
        ticket: "foreman-c3845",
        sender: "developer",
        receiver: "foreman",
        kind: "agent-error",
        tool: "send_mail",
        args: "--run-id abc",
      }),
      makeRow({
        id: "msg-002",
        created_at: "2026-04-30T14:25:00.000Z",
        ticket: "foreman-c3846",
        sender: "qa",
        receiver: "developer",
        kind: "phase-complete",
        tool: "bash",
        args: "npm test",
      }),
    ];
    const output = renderMessageTable(rows);
    // Both rows should appear
    expect(output).toContain("foreman-c3845");
    expect(output).toContain("foreman-c3846");
    expect(output).toContain("developer");
    expect(output).toContain("qa");
    expect(output).toContain("agent-error");
    expect(output).toContain("send_mail");
    expect(output).toContain("npm test");
  });

  it("uses '-' for undefined kind/tool/args", () => {
    const rows = [
      makeRow({
        id: "msg-001",
        created_at: "2026-04-30T14:23:45.000Z",
        ticket: "run-xyz",
        sender: "explorer",
        receiver: "developer",
      }),
    ];
    const output = renderMessageTable(rows);
    expect(output).toContain(" - ");
    expect(output).toContain("explorer");
    expect(output).toContain("developer");
  });

  it("respects argsWidth override", () => {
    const rows = [
      makeRow({
        id: "msg-001",
        created_at: "2026-04-30T14:23:45.000Z",
        ticket: "foreman-c3845",
        sender: "developer",
        receiver: "foreman",
        kind: "agent-error",
        tool: "send_mail",
        args: "--run-id abc123 --to foreman --subject agent-error",
      }),
    ];
    const output = renderMessageTable(rows, 20);
    // args should contain truncated form ending in "…"
    expect(output).toContain("--run-id abc123 --t…");
  });

  it("computes ticket column width from content", () => {
    const rows = [
      makeRow({
        id: "msg-001",
        created_at: "2026-04-30T14:23:45.000Z",
        ticket: "foreman-c3845",
        sender: "dev",
        receiver: "foreman",
        kind: "err",
        tool: "send",
        args: "x",
      }),
      makeRow({
        id: "msg-002",
        created_at: "2026-04-30T14:23:46.000Z",
        ticket: "foreman-c99999999", // longer ticket
        sender: "dev",
        receiver: "foreman",
        kind: "err",
        tool: "send",
        args: "x",
      }),
    ];
    const output = renderMessageTable(rows);
    // Both ticket values should fit without truncation
    expect(output).toContain("foreman-c3845");
    expect(output).toContain("foreman-c99999999");
  });
});