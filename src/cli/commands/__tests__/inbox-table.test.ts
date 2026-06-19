/**
 * Tests for inbox table formatting.
 *
 * @module src/cli/commands/__tests__/inbox-table.test
 */

import { describe, it, expect } from "vitest";
import {
  formatMessageTable,
  parseMessageBody,
  renderMessageTable,
  truncate,
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

  it("handles exact-length strings", () => {
    expect(truncate("exactly10c", 10)).toBe("exactly10c");
  });

  it("handles empty string", () => {
    expect(truncate("", 10)).toBe("");
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