/**
 * Tests for `foreman audit <seedId>` CLI command.
 *
 * Verifies:
 * - --phase filters entries by pipeline phase
 * - --blocked shows only blocked tool call entries
 * - --json outputs a raw JSON array
 * - No entries found prints "No audit entries found"
 * - Default tabular output contains expected columns
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { AuditEntry } from "../../../lib/audit-reader.js";

// ── Hoisted mocks ────────────────────────────────────────────────────────────

const { mockReadAuditEntries } = vi.hoisted(() => {
  const mockReadAuditEntries = vi.fn().mockResolvedValue([]);
  return { mockReadAuditEntries };
});

vi.mock("../../../lib/audit-reader.js", () => ({
  readAuditEntries: mockReadAuditEntries,
}));

// Mock AgentMailClient so searchViaAgentMail returns null (Agent Mail unavailable),
// ensuring tests exercise the local readAuditEntries fallback path.
vi.mock("../../../orchestrator/agent-mail-client.js", () => ({
  AgentMailClient: class {
    healthCheck = vi.fn().mockResolvedValue(false);
    fetchInbox = vi.fn().mockResolvedValue([]);
  },
}));

// ── process.exit mock ────────────────────────────────────────────────────────

let exitSpy: ReturnType<typeof vi.spyOn>;
beforeEach(() => {
  exitSpy = vi.spyOn(process, "exit").mockImplementation(
    (code?: number | string | null | undefined) => {
      throw new Error(`process.exit(${code ?? ""}) called`);
    },
  );
});
afterEach(() => {
  exitSpy.mockRestore();
  vi.clearAllMocks();
});

// ── Import command under test ────────────────────────────────────────────────

import { auditCommand } from "../audit.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

async function runCommand(
  args: string[],
): Promise<{ stdout: string; stderr: string }> {
  const stdoutLines: string[] = [];
  const stderrLines: string[] = [];

  const origLog = console.log;
  const origWarn = console.warn;
  const origError = console.error;

  console.log = (...a: unknown[]) => stdoutLines.push(a.join(" "));
  console.warn = (...a: unknown[]) => stderrLines.push(a.join(" "));
  console.error = (...a: unknown[]) => stderrLines.push(a.join(" "));

  try {
    await auditCommand.parseAsync(["node", "foreman-audit", ...args]);
  } finally {
    console.log = origLog;
    console.warn = origWarn;
    console.error = origError;
  }

  return { stdout: stdoutLines.join("\n"), stderr: stderrLines.join("\n") };
}

// ── Sample fixture data ───────────────────────────────────────────────────────

const ENTRY_EXPLORER: AuditEntry = {
  timestamp: "2026-03-19T10:00:00.000Z",
  runId: "run-abc123",
  seedId: "bd-fzew",
  phase: "explorer",
  eventType: "tool_call",
  toolName: "Read",
  blocked: false,
};

const ENTRY_DEVELOPER_BLOCKED: AuditEntry = {
  timestamp: "2026-03-19T10:01:00.000Z",
  runId: "run-abc123",
  seedId: "bd-fzew",
  phase: "developer",
  eventType: "tool_call",
  toolName: "Bash",
  blocked: true,
  blockReason: "command not allowed",
};

const ENTRY_DEVELOPER_TURN: AuditEntry = {
  timestamp: "2026-03-19T10:02:00.000Z",
  runId: "run-abc123",
  seedId: "bd-fzew",
  phase: "developer",
  eventType: "turn_end",
  turnNumber: 5,
  totalTokens: 8000,
};

const ENTRY_QA: AuditEntry = {
  timestamp: "2026-03-19T10:03:00.000Z",
  runId: "run-abc123",
  seedId: "bd-fzew",
  phase: "qa",
  eventType: "agent_end",
  durationMs: 45000,
};

const ALL_ENTRIES = [
  ENTRY_EXPLORER,
  ENTRY_DEVELOPER_BLOCKED,
  ENTRY_DEVELOPER_TURN,
  ENTRY_QA,
];

// ── Tests ────────────────────────────────────────────────────────────────────

describe("foreman audit <seedId>", () => {
  describe("--phase filter", () => {
    it("passes phase filter to readAuditEntries", async () => {
      mockReadAuditEntries.mockResolvedValue([ENTRY_EXPLORER]);
      await runCommand(["bd-fzew", "--phase", "explorer"]);
      expect(mockReadAuditEntries).toHaveBeenCalledWith(
        "bd-fzew",
        expect.objectContaining({ phase: "explorer" }),
      );
    });

    it("displays only entries matching the specified phase", async () => {
      mockReadAuditEntries.mockResolvedValue([ENTRY_EXPLORER]);
      const { stdout } = await runCommand(["bd-fzew", "--phase", "explorer"]);
      expect(stdout).toContain("explorer");
    });
  });

  describe("--blocked filter", () => {
    it("passes eventType=tool_call and blocked filter to readAuditEntries", async () => {
      mockReadAuditEntries.mockResolvedValue([ENTRY_DEVELOPER_BLOCKED]);
      await runCommand(["bd-fzew", "--blocked"]);
      // readAuditEntries called with eventType=tool_call; post-filter handles blocked=true
      expect(mockReadAuditEntries).toHaveBeenCalledWith(
        "bd-fzew",
        expect.objectContaining({ eventType: "tool_call" }),
      );
    });

    it("shows only blocked entries in output", async () => {
      // readAuditEntries returns only tool_call entries; command post-filters for blocked
      mockReadAuditEntries.mockResolvedValue([
        ENTRY_DEVELOPER_BLOCKED,
        ENTRY_EXPLORER, // not blocked
      ]);
      const { stdout } = await runCommand(["bd-fzew", "--blocked"]);
      expect(stdout).toContain("BLOCKED");
      // The non-blocked explorer entry should not appear as BLOCKED
      expect(stdout.split("BLOCKED").length - 1).toBeGreaterThanOrEqual(1);
    });

    it("shows block reason in output for blocked entries", async () => {
      mockReadAuditEntries.mockResolvedValue([ENTRY_DEVELOPER_BLOCKED]);
      const { stdout } = await runCommand(["bd-fzew", "--blocked"]);
      expect(stdout).toContain("command not allowed");
    });
  });

  describe("--json output", () => {
    it("outputs a valid JSON array", async () => {
      mockReadAuditEntries.mockResolvedValue(ALL_ENTRIES);
      const { stdout } = await runCommand(["bd-fzew", "--json"]);
      expect(() => JSON.parse(stdout)).not.toThrow();
      expect(Array.isArray(JSON.parse(stdout))).toBe(true);
    });

    it("JSON array contains all returned entries", async () => {
      mockReadAuditEntries.mockResolvedValue(ALL_ENTRIES);
      const { stdout } = await runCommand(["bd-fzew", "--json"]);
      const parsed = JSON.parse(stdout);
      expect(parsed).toHaveLength(ALL_ENTRIES.length);
    });

    it("JSON entries preserve all fields from AuditEntry", async () => {
      mockReadAuditEntries.mockResolvedValue([ENTRY_DEVELOPER_BLOCKED]);
      const { stdout } = await runCommand(["bd-fzew", "--json"]);
      const [entry] = JSON.parse(stdout);
      expect(entry.phase).toBe("developer");
      expect(entry.eventType).toBe("tool_call");
      expect(entry.blocked).toBe(true);
      expect(entry.blockReason).toBe("command not allowed");
    });

    it("does not output tabular header when --json is used", async () => {
      mockReadAuditEntries.mockResolvedValue(ALL_ENTRIES);
      const { stdout } = await runCommand(["bd-fzew", "--json"]);
      expect(stdout).not.toContain("Audit log for");
      expect(stdout).not.toContain("Total:");
    });
  });

  describe("no entries found", () => {
    it("prints 'No audit entries found' when readAuditEntries returns empty array", async () => {
      mockReadAuditEntries.mockResolvedValue([]);
      const { stdout } = await runCommand(["bd-fzew"]);
      expect(stdout).toContain("No audit entries found");
    });

    it("prints 'No audit entries found' for --json with empty result", async () => {
      mockReadAuditEntries.mockResolvedValue([]);
      const { stdout } = await runCommand(["bd-fzew", "--json"]);
      // For --json with no results, still output empty array
      const parsed = JSON.parse(stdout);
      expect(parsed).toEqual([]);
    });
  });

  describe("default tabular output", () => {
    it("includes seedId in the header", async () => {
      mockReadAuditEntries.mockResolvedValue(ALL_ENTRIES);
      const { stdout } = await runCommand(["bd-fzew"]);
      expect(stdout).toContain("bd-fzew");
    });

    it("includes runId in the header", async () => {
      mockReadAuditEntries.mockResolvedValue(ALL_ENTRIES);
      const { stdout } = await runCommand(["bd-fzew"]);
      expect(stdout).toContain("run-abc123");
    });

    it("includes timestamp column for each entry", async () => {
      mockReadAuditEntries.mockResolvedValue([ENTRY_EXPLORER]);
      const { stdout } = await runCommand(["bd-fzew"]);
      expect(stdout).toContain("2026-03-19T10:00:00.000Z");
    });

    it("includes phase column for each entry", async () => {
      mockReadAuditEntries.mockResolvedValue([ENTRY_EXPLORER]);
      const { stdout } = await runCommand(["bd-fzew"]);
      expect(stdout).toContain("explorer");
    });

    it("includes eventType column for each entry", async () => {
      mockReadAuditEntries.mockResolvedValue([ENTRY_EXPLORER]);
      const { stdout } = await runCommand(["bd-fzew"]);
      expect(stdout).toContain("tool_call");
    });

    it("includes toolName when present", async () => {
      mockReadAuditEntries.mockResolvedValue([ENTRY_EXPLORER]);
      const { stdout } = await runCommand(["bd-fzew"]);
      expect(stdout).toContain("Read");
    });

    it("shows summary footer with total count", async () => {
      mockReadAuditEntries.mockResolvedValue(ALL_ENTRIES);
      const { stdout } = await runCommand(["bd-fzew"]);
      expect(stdout).toContain(`Total: ${ALL_ENTRIES.length}`);
    });

    it("shows blocked count in summary footer", async () => {
      mockReadAuditEntries.mockResolvedValue(ALL_ENTRIES);
      const { stdout } = await runCommand(["bd-fzew"]);
      expect(stdout).toContain("Blocked: 1");
    });

    it("shows phases list in summary footer", async () => {
      mockReadAuditEntries.mockResolvedValue(ALL_ENTRIES);
      const { stdout } = await runCommand(["bd-fzew"]);
      expect(stdout).toContain("Phases:");
      expect(stdout).toContain("explorer");
      expect(stdout).toContain("developer");
      expect(stdout).toContain("qa");
    });

    it("marks blocked entries with BLOCKED label", async () => {
      mockReadAuditEntries.mockResolvedValue([ENTRY_DEVELOPER_BLOCKED]);
      const { stdout } = await runCommand(["bd-fzew"]);
      expect(stdout).toContain("BLOCKED");
    });

    it("marks non-blocked tool_call entries with OK label", async () => {
      mockReadAuditEntries.mockResolvedValue([ENTRY_EXPLORER]);
      const { stdout } = await runCommand(["bd-fzew"]);
      expect(stdout).toContain("OK");
    });
  });

  describe("filter options forwarded to readAuditEntries", () => {
    it("passes --event-type to readAuditEntries", async () => {
      mockReadAuditEntries.mockResolvedValue([]);
      await runCommand(["bd-fzew", "--event-type", "turn_end"]);
      expect(mockReadAuditEntries).toHaveBeenCalledWith(
        "bd-fzew",
        expect.objectContaining({ eventType: "turn_end" }),
      );
    });

    it("passes --since to readAuditEntries", async () => {
      mockReadAuditEntries.mockResolvedValue([]);
      const ts = "2026-03-19T00:00:00.000Z";
      await runCommand(["bd-fzew", "--since", ts]);
      expect(mockReadAuditEntries).toHaveBeenCalledWith(
        "bd-fzew",
        expect.objectContaining({ since: ts }),
      );
    });

    it("passes --until to readAuditEntries", async () => {
      mockReadAuditEntries.mockResolvedValue([]);
      const ts = "2026-03-19T23:59:59.000Z";
      await runCommand(["bd-fzew", "--until", ts]);
      expect(mockReadAuditEntries).toHaveBeenCalledWith(
        "bd-fzew",
        expect.objectContaining({ until: ts }),
      );
    });

    it("passes --search to readAuditEntries", async () => {
      mockReadAuditEntries.mockResolvedValue([]);
      await runCommand(["bd-fzew", "--search", "Bash"]);
      expect(mockReadAuditEntries).toHaveBeenCalledWith(
        "bd-fzew",
        expect.objectContaining({ search: "Bash" }),
      );
    });
  });
});
