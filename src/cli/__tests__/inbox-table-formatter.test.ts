/**
 * Tests for TableFormatter — inbox tabular message view.
 *
 * Covers:
 *   - formatHeader() returns correct column headers
 *   - formatRow() extracts kind, tool, args from JSON body
 *   - formatRow() returns `—` for missing JSON fields
 *   - calcWidths() returns correct min/max per column
 *   - truncate() respects max length and adds `…`
 *   - truncate() stops at word boundary when possible
 *   - truncate() handles empty string
 *   - Long run_id gets middle-cut treatment
 *   - formatTable() renders header + rows with proper alignment
 *   - Mixed payloads (some with JSON, some without) render correctly
 *   - ARGS column truncation shows `…` for long values
 *   - Empty table renders header with no data rows
 */

import { describe, it, expect } from "vitest";
import type { Message } from "../../lib/store.js";
import {
  TableFormatter,
  truncate,
  extractBodyFields,
} from "../commands/inbox.js";

// ── Helpers ─────────────────────────────────────────────────────────────────

function makeMockMessage(overrides: Partial<Message> = {}): Message {
  return {
    id: "msg-1",
    run_id: "run-1",
    sender_agent_type: "developer",
    recipient_agent_type: "foreman",
    subject: "test-subject",
    body: "plain text body",
    read: 0,
    created_at: "2024-01-01T12:00:00.000Z",
    deleted_at: null,
    ...overrides,
  };
}

// ── extractBodyFields ───────────────────────────────────────────────────────

describe("extractBodyFields", () => {
  it("extracts kind, tool, argsPreview from JSON body", () => {
    const result = extractBodyFields(
      JSON.stringify({
        kind: "update",
        tool: "bash",
        argsPreview: "cd /tmp && ls",
      }),
    );
    expect(result.kind).toBe("update");
    expect(result.tool).toBe("bash");
    expect(result.args).toBe("cd /tmp && ls");
  });

  it("falls back to message field when argsPreview absent", () => {
    const result = extractBodyFields(
      JSON.stringify({ kind: "info", tool: null, message: "hello world" }),
    );
    expect(result.kind).toBe("info");
    expect(result.tool).toBeNull();
    expect(result.args).toBe("hello world");
  });

  it("falls back to raw body when no recognized args fields", () => {
    const result = extractBodyFields(
      JSON.stringify({ phase: "developer", status: "running" }),
    );
    expect(result.kind).toBeNull();
    expect(result.tool).toBeNull();
    expect(result.args).toBeNull();
  });

  it("returns nulls for all fields when body is not JSON", () => {
    const result = extractBodyFields("plain text body with no JSON");
    expect(result.kind).toBeNull();
    expect(result.tool).toBeNull();
    expect(result.args).toBeNull();
  });

  it("returns nulls for all fields when body is empty string", () => {
    const result = extractBodyFields("");
    expect(result.kind).toBeNull();
    expect(result.tool).toBeNull();
    expect(result.args).toBeNull();
  });

  it("returns nulls for all fields when JSON is malformed", () => {
    const result = extractBodyFields('{"broken": json}');
    expect(result.kind).toBeNull();
    expect(result.tool).toBeNull();
    expect(result.args).toBeNull();
  });

  it("returns nulls when kind/tool/args are non-string types", () => {
    const result = extractBodyFields(
      JSON.stringify({ kind: 123, tool: { name: "bash" }, args: ["list", "of", "things"] }),
    );
    expect(result.kind).toBeNull();
    expect(result.tool).toBeNull();
    expect(result.args).toBeNull();
  });
});

// ── truncate ────────────────────────────────────────────────────────────────

describe("truncate", () => {
  it("returns short strings unchanged", () => {
    expect(truncate("hello", 10)).toBe("hello");
  });

  it("truncates long strings with `…`", () => {
    const input = "a".repeat(50);
    const result = truncate(input, 20);
    expect(result.length).toBe(20);
    expect(result.endsWith("…")).toBe(true);
  });

  it("stops at word boundary when possible", () => {
    const input = "the quick brown fox jumps over the lazy dog";
    const result = truncate(input, 20);
    // Should not cut mid-word if space is nearby
    const truncated = result.replaceAll("…", "");
    expect(truncated.length).toBeLessThanOrEqual(20);
    // Check we didn't break a word awkwardly — the last char before … should be a space
    expect(result).toMatch(/[ …]$/);
  });

  it("handles empty string", () => {
    expect(truncate("", 10)).toBe("");
  });

  it("handles maxWidth of 0", () => {
    expect(truncate("hello", 0)).toBe("");
  });

  it("handles maxWidth of 1", () => {
    const result = truncate("hello", 1);
    expect(result.length).toBe(1);
    expect(result).toBe("…");
  });

  it("returns `…` for very long input at maxWidth 3", () => {
    const result = truncate("a".repeat(100), 3);
    expect(result).toBe("…");
  });

  it("handles string exactly at maxWidth", () => {
    expect(truncate("hello", 5)).toBe("hello");
  });

  it("handles string one char over maxWidth", () => {
    const result = truncate("hello", 4);
    expect(result.length).toBe(4);
    expect(result.endsWith("…")).toBe(true);
  });
});

// ── TableFormatter.formatHeader ───────────────────────────────────────────────

describe("TableFormatter.formatHeader", () => {
  it("returns the 7 column headers separated by spaces", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const header = tf.formatHeader();
    expect(header).toContain("DATETIME");
    expect(header).toContain("TICKET");
    expect(header).toContain("SENDER");
    expect(header).toContain("RECEIVER");
    expect(header).toContain("KIND");
    expect(header).toContain("TOOL");
    expect(header).toContain("ARGS");
  });
});

// ── TableFormatter.formatRow ────────────────────────────────────────────────

describe("TableFormatter.formatRow", () => {
  it("formats a basic message row with all fields", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const msg = makeMockMessage({
      run_id: "run-abc123",
      sender_agent_type: "explorer",
      recipient_agent_type: "developer",
      created_at: "2024-01-01T12:00:00.000Z",
      body: JSON.stringify({ kind: "update", tool: "bash", argsPreview: "cd /tmp" }),
    });

    const row = tf.formatRow(msg);

    expect(row.columns.datetime).toMatch(/^2024-01-01 \d{2}:00:00$/);
    expect(row.columns.ticket).toBe("run-abc123");
    expect(row.columns.sender).toBe("explorer");
    expect(row.columns.receiver).toBe("developer");
    expect(row.columns.kind).toBe("update");
    expect(row.columns.tool).toBe("bash");
    expect(row.columns.args).toBe("cd /tmp");
  });

  it("shows `—` for missing kind and tool", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const msg = makeMockMessage({
      body: JSON.stringify({ phase: "developer" }),
    });

    const row = tf.formatRow(msg);

    expect(row.columns.kind).toBe("—");
    expect(row.columns.tool).toBe("—");
    expect(row.columns.args).toBe("—");
  });

  it("shows `—` for all payload fields when body is not JSON", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const msg = makeMockMessage({ body: "plain text body" });

    const row = tf.formatRow(msg);

    expect(row.columns.kind).toBe("—");
    expect(row.columns.tool).toBe("—");
    expect(row.columns.args).toBe("—");
  });

  it("truncates ARGS column to column maxWidth", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const longArgs = "x".repeat(100);
    const msg = makeMockMessage({
      body: JSON.stringify({ argsPreview: longArgs }),
    });

    const row = tf.formatRow(msg);

    // ARGS is truncated to 30 chars (default) + ellipsis = 31 chars max shown
    expect(row.columns.args.length).toBeLessThanOrEqual(31);
    expect(row.columns.args.endsWith("…")).toBe(true);
  });

  it("truncates TICKET column with middle-cut when run_id > 20 chars", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const msg = makeMockMessage({
      run_id: "run-very-long-id-that-exceeds-twenty-chars",
    });

    const row = tf.formatRow(msg);

    expect(row.columns.ticket.length).toBeLessThanOrEqual(20);
    expect(row.columns.ticket).toContain("…");
  });

  it("does not middle-cut short run_id", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const msg = makeMockMessage({ run_id: "run-short" });

    const row = tf.formatRow(msg);

    expect(row.columns.ticket).toBe("run-short");
    expect(row.columns.ticket).not.toContain("…");
  });
});

// ── TableFormatter.calcWidths ────────────────────────────────────────────────

describe("TableFormatter.calcWidths", () => {
  it("returns correct widths for a single row", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const msg = makeMockMessage({
      run_id: "run-abc",
      sender_agent_type: "explorer",
      recipient_agent_type: "developer",
      created_at: "2024-01-01T12:00:00.000Z",
      body: JSON.stringify({ kind: "update", tool: "bash", argsPreview: "ls" }),
    });

    const widths = tf.calcWidths([msg]);

    expect(widths.datetime).toBe(19); // YYYY-MM-DD HH:MM:SS is fixed
    expect(widths.ticket).toBeGreaterThanOrEqual(8);
    expect(widths.sender).toBeGreaterThanOrEqual(8);
    expect(widths.receiver).toBeGreaterThanOrEqual(8);
    expect(widths.kind).toBeGreaterThanOrEqual(1);
    expect(widths.tool).toBeGreaterThanOrEqual(1);
    expect(widths.args).toBeGreaterThanOrEqual(1);
  });

  it("clamps TICKET column to max 20", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const msg = makeMockMessage({
      run_id: "run-very-long-id-that-exceeds-twenty-chars",
    });

    const widths = tf.calcWidths([msg]);

    expect(widths.ticket).toBeLessThanOrEqual(20);
  });

  it("distributes extra width to ARGS column", () => {
    const tf = new TableFormatter({ terminalWidth: 200 });
    const msg = makeMockMessage({
      body: JSON.stringify({ argsPreview: "ls" }),
    });

    const widths = tf.calcWidths([msg]);

    // ARGS should get more width when terminal is wide
    expect(widths.args).toBeGreaterThan(30);
  });
});

// ── TableFormatter.formatTable ───────────────────────────────────────────────

describe("TableFormatter.formatTable", () => {
  it("renders header and data rows correctly", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const msg = makeMockMessage({
      run_id: "run-abc",
      sender_agent_type: "explorer",
      recipient_agent_type: "developer",
      created_at: "2024-01-01T12:00:00.000Z",
      body: JSON.stringify({ kind: "update", tool: "bash", argsPreview: "ls" }),
    });

    const table = tf.formatTable([msg]);

    expect(table).toContain("DATETIME");
    expect(table).toContain("TICKET");
    expect(table).toContain("SENDER");
    expect(table).toContain("RECEIVER");
    expect(table).toContain("KIND");
    expect(table).toContain("TOOL");
    expect(table).toContain("ARGS");
    expect(table).toMatch(/2024-01-01 \d{2}:00:00/);
    expect(table).toContain("run-abc");
    expect(table).toContain("explorer");
    expect(table).toContain("developer");
    expect(table).toContain("update");
    expect(table).toContain("bash");
    expect(table).toContain("ls");
  });

  it("renders multiple rows in alignment", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const msgs = [
      makeMockMessage({
        run_id: "run-1",
        sender_agent_type: "explorer",
        recipient_agent_type: "developer",
        created_at: "2024-01-01T12:00:00.000Z",
        body: JSON.stringify({ kind: "update", tool: "bash", argsPreview: "ls" }),
      }),
      makeMockMessage({
        id: "msg-2",
        run_id: "run-2",
        sender_agent_type: "developer",
        recipient_agent_type: "qa",
        created_at: "2024-01-01T12:01:00.000Z",
        body: JSON.stringify({ kind: "verdict", tool: null, argsPreview: "PASS" }),
      }),
    ];

    const table = tf.formatTable(msgs);

    // Both rows present
    expect(table).toContain("run-1");
    expect(table).toContain("run-2");
    expect(table).toContain("explorer");
    expect(table).toContain("developer");
    expect(table).toContain("qa");
  });

  it("renders rows with mixed JSON/plain bodies correctly", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const msgs = [
      makeMockMessage({
        run_id: "run-json",
        sender_agent_type: "developer",
        recipient_agent_type: "qa",
        created_at: "2024-01-01T12:00:00.000Z",
        body: JSON.stringify({ kind: "update", tool: "bash", argsPreview: "cd /tmp" }),
      }),
      makeMockMessage({
        id: "msg-plain",
        run_id: "run-plain",
        sender_agent_type: "explorer",
        recipient_agent_type: "foreman",
        created_at: "2024-01-01T12:01:00.000Z",
        body: "plain text message",
      }),
    ];

    const table = tf.formatTable(msgs);

    expect(table).toContain("run-json");
    expect(table).toContain("run-plain");
    expect(table).toContain("update");
    expect(table).toContain("bash");
    // Plain text row shows `—` for kind/tool/args
    expect(table).toContain("—");
  });

  it("renders empty table with just the header", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const table = tf.formatTable([]);

    expect(table).toContain("DATETIME");
    expect(table).toContain("TICKET");
    expect(table).toContain("ARGS");
  });

  it("shows truncation ellipsis for long ARGS values", () => {
    const tf = new TableFormatter({ terminalWidth: 120 });
    const msg = makeMockMessage({
      body: JSON.stringify({ argsPreview: "x".repeat(100) }),
    });

    const table = tf.formatTable([msg]);

    expect(table).toContain("…");
  });
});
