/**
 * TRD-026-TEST: Audit CLI Agent Mail Tests
 *
 * Tests for the Agent Mail FTS5 search integration in `foreman audit`:
 * 1. When Agent Mail is available: --search delegates to Agent Mail fetchInbox
 * 2. When Agent Mail is down: --search falls back to local JSONL path
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import type { AgentMailMessage } from "../../../orchestrator/agent-mail-client.js";
import type { AuditEntry } from "../../../lib/audit-reader.js";

// ── Mock AgentMailClient ───────────────────────────────────────────────────────

const mockHealthCheck = vi.fn<() => Promise<boolean>>();
const mockFetchInbox = vi.fn<() => Promise<AgentMailMessage[]>>();

vi.mock("../../../orchestrator/agent-mail-client.js", () => {
  class MockAgentMailClient {
    healthCheck = mockHealthCheck;
    fetchInbox = mockFetchInbox;
  }
  return { AgentMailClient: MockAgentMailClient };
});

// ── Mock readAuditEntries (local JSONL fallback) ────────────────────────────

const mockReadAuditEntries = vi.fn<() => Promise<AuditEntry[]>>();

vi.mock("../../../lib/audit-reader.js", () => ({
  readAuditEntries: (...args: unknown[]) => mockReadAuditEntries(...(args as [])),
}));

// Import after mocks
import { auditCommand } from "../audit.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeAuditMessage(entry: Record<string, unknown>, id = "msg-1"): AgentMailMessage {
  return {
    id,
    from: "foreman-audit",
    to: "audit-log",
    subject: "tool_call",
    body: JSON.stringify(entry),
    receivedAt: new Date().toISOString(),
    acknowledged: false,
  };
}

function makeAuditEntry(overrides: Record<string, unknown> = {}): AuditEntry {
  return {
    timestamp: "2026-03-20T00:00:00.000Z",
    runId: "run-test-1",
    seedId: "seed-test",
    phase: "developer",
    eventType: "tool_call",
    toolName: "Read",
    blocked: false,
    ...overrides,
  };
}

// Run the command and capture console output
async function runAuditCommand(args: string[]): Promise<{ stdout: string }> {
  const lines: string[] = [];
  const origLog = console.log;
  console.log = (...a: unknown[]) => lines.push(a.join(" "));
  try {
    await auditCommand.parseAsync(["node", "audit", ...args]);
  } finally {
    console.log = origLog;
  }
  return { stdout: lines.join("\n") };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("foreman audit — Agent Mail FTS5 search integration", () => {
  beforeEach(() => {
    mockHealthCheck.mockReset();
    mockFetchInbox.mockReset();
    mockReadAuditEntries.mockReset().mockResolvedValue([]);
  });

  it("uses Agent Mail results when available and --search is provided", async () => {
    const entry = makeAuditEntry({ toolName: "Write" });
    mockHealthCheck.mockResolvedValue(true);
    mockFetchInbox.mockResolvedValue([
      makeAuditMessage(entry, "msg-1"),
      // A message that does NOT match the search term
      makeAuditMessage({ ...entry, toolName: "Glob" }, "msg-2"),
    ]);

    const { stdout } = await runAuditCommand(["seed-test", "--search", "Write", "--json"]);

    // readAuditEntries should NOT have been called (Agent Mail took precedence)
    expect(mockReadAuditEntries).not.toHaveBeenCalled();

    // Output should contain only the Write entry
    const parsed = JSON.parse(stdout) as Array<Record<string, unknown>>;
    expect(parsed.length).toBe(1);
    expect(parsed[0]["toolName"]).toBe("Write");
  });

  it("falls back to local JSONL when Agent Mail healthCheck returns false", async () => {
    mockHealthCheck.mockResolvedValue(false);

    const localEntry = makeAuditEntry({ toolName: "Grep" });
    mockReadAuditEntries.mockResolvedValue([localEntry]);

    const { stdout } = await runAuditCommand(["seed-test", "--search", "Grep", "--json"]);

    // readAuditEntries SHOULD have been called (fallback path)
    expect(mockReadAuditEntries).toHaveBeenCalledOnce();

    const parsed = JSON.parse(stdout) as Array<Record<string, unknown>>;
    expect(parsed.length).toBe(1);
    expect(parsed[0]["toolName"]).toBe("Grep");
  });

  it("falls back to local JSONL when Agent Mail fetchInbox throws", async () => {
    mockHealthCheck.mockResolvedValue(true);
    mockFetchInbox.mockRejectedValue(new Error("network error"));

    const localEntry = makeAuditEntry({ toolName: "Glob" });
    mockReadAuditEntries.mockResolvedValue([localEntry]);

    const { stdout } = await runAuditCommand(["seed-test", "--search", "Glob", "--json"]);

    expect(mockReadAuditEntries).toHaveBeenCalledOnce();

    const parsed = JSON.parse(stdout) as Array<Record<string, unknown>>;
    expect(parsed.length).toBe(1);
    expect(parsed[0]["toolName"]).toBe("Glob");
  });

  it("does not consult Agent Mail when --search flag is absent", async () => {
    // No --search flag → Agent Mail is never consulted
    const localEntries = [makeAuditEntry({ toolName: "Read" }), makeAuditEntry({ toolName: "Write" })];
    mockReadAuditEntries.mockResolvedValue(localEntries);

    await runAuditCommand(["seed-test", "--json"]);

    // healthCheck must NOT be called (Agent Mail path not triggered)
    expect(mockHealthCheck).not.toHaveBeenCalled();
    expect(mockReadAuditEntries).toHaveBeenCalledOnce();
  });

  it("applies case-insensitive search to Agent Mail messages", async () => {
    mockHealthCheck.mockResolvedValue(true);
    const writeEntry = makeAuditEntry({ toolName: "Write" });
    const readEntry = makeAuditEntry({ toolName: "Read" });
    mockFetchInbox.mockResolvedValue([
      makeAuditMessage(writeEntry, "m1"),
      makeAuditMessage(readEntry, "m2"),
    ]);

    // Uppercase search term
    const { stdout } = await runAuditCommand(["seed-test", "--search", "WRITE", "--json"]);

    const parsed = JSON.parse(stdout) as Array<Record<string, unknown>>;
    expect(parsed.length).toBe(1);
    expect(parsed[0]["toolName"]).toBe("Write");
  });

  it("skips malformed Agent Mail message bodies gracefully", async () => {
    mockHealthCheck.mockResolvedValue(true);
    const validEntry = makeAuditEntry({ toolName: "Read" });
    mockFetchInbox.mockResolvedValue([
      {
        id: "bad-1",
        from: "foreman-audit",
        to: "audit-log",
        subject: "tool_call",
        body: "{ not valid JSON ]]]",
        receivedAt: new Date().toISOString(),
        acknowledged: false,
      },
      makeAuditMessage(validEntry, "good-1"),
    ]);

    const { stdout } = await runAuditCommand(["seed-test", "--search", "Read", "--json"]);

    const parsed = JSON.parse(stdout) as Array<Record<string, unknown>>;
    expect(parsed.length).toBe(1);
    expect(parsed[0]["toolName"]).toBe("Read");
  });

  it("includes (via Agent Mail FTS5) note in tabular output when using Agent Mail", async () => {
    const entry = makeAuditEntry({ toolName: "Read", seedId: "seed-test" });
    mockHealthCheck.mockResolvedValue(true);
    mockFetchInbox.mockResolvedValue([makeAuditMessage(entry, "m1")]);

    const { stdout } = await runAuditCommand(["seed-test", "--search", "Read"]);

    // Header line should mention Agent Mail FTS5
    expect(stdout).toContain("Agent Mail FTS5");
  });
});
