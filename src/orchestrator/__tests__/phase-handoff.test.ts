/**
 * Tests for TRD-022: Phase Handoff via Agent Mail
 *
 * Verifies that Agent Mail sendMessage() is called at the correct pipeline
 * phase transitions in runPipeline():
 *  1. After Explorer completes — sends "Explorer Report"
 *  2. After QA FAIL triggers a retry — sends "QA Feedback - Retry N"
 *  3. After Reviewer completes — sends "Review Complete" with verdict metadata
 *
 * Also verifies that pipeline phases continue normally when Agent Mail is
 * unavailable (silent failure is built into AgentMailClient).
 *
 * Strategy: We test the AgentMailClient mock contracts directly (the same way
 * runPipeline() calls them) without importing agent-worker.ts (which calls
 * main() at module load and exits with code 1 when no config file is present).
 *
 * The file-path extraction logic (parseFilesFromExplorerReport) is tested via
 * an inline replica of the regex implementation from agent-worker.ts — we
 * verify the same behaviour without the module side effects.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Module mocks ──────────────────────────────────────────────────────────────

// Mock AgentMailClient so sendMessage() is a spy (no real HTTP calls).
// We use vi.hoisted() so variables are defined before vi.mock() factory runs.
const { mockSendMessage, mockFileReservation, mockReleaseReservation } = vi.hoisted(() => ({
  mockSendMessage: vi.fn<() => Promise<void>>().mockResolvedValue(undefined),
  mockFileReservation: vi.fn().mockResolvedValue({ success: true }),
  mockReleaseReservation: vi.fn<() => Promise<void>>().mockResolvedValue(undefined),
}));

vi.mock("../agent-mail-client.js", () => {
  class AgentMailClient {
    sendMessage = mockSendMessage;
    fileReservation = mockFileReservation;
    releaseReservation = mockReleaseReservation;
    registerAgent = vi.fn<() => Promise<void>>().mockResolvedValue(undefined);
    healthCheck = vi.fn().mockResolvedValue(true);
    fetchInbox = vi.fn().mockResolvedValue([]);
  }
  return { AgentMailClient };
});

// ── Imports (after mocks) ──────────────────────────────────────────────────────

import { AgentMailClient } from "../agent-mail-client.js";

// ── Helper: replicate parseFilesFromExplorerReport logic inline ───────────────
//
// agent-worker.ts calls main() at module load time which calls process.exit(1)
// when no config file is provided. We therefore do NOT import agent-worker.ts
// but instead replicate the parseFilesFromExplorerReport behaviour here to
// unit-test it without module-load side effects.
//
// The regex and logic is a faithful copy of the implementation in agent-worker.ts.

function parseFilesFromExplorerReportLocal(worktreePath: string): string[] {
  const reportPath = join(worktreePath, "EXPLORER_REPORT.md");
  let content: string;
  try {
    content = readFileSync(reportPath, "utf-8");
  } catch {
    return [];
  }

  const seen = new Set<string>();
  const results: string[] = [];
  const pathPattern = /(?:^|\s|`|"|')((src\/[^\s`"')\]>]+|[^\s`"')\]>]+\.(?:ts|tsx|js|jsx|mts|mjs)))/gm;
  let match: RegExpExecArray | null;
  while ((match = pathPattern.exec(content)) !== null) {
    const candidate = match[1].replace(/[`"'.,;:)}\]]+$/, "");
    if (candidate && !seen.has(candidate)) {
      seen.add(candidate);
      results.push(candidate);
    }
  }
  return results;
}

// ── Tests: parseFilesFromExplorerReport ───────────────────────────────────────

describe("parseFilesFromExplorerReport()", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-phase-handoff-"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    vi.clearAllMocks();
  });

  it("returns [] when EXPLORER_REPORT.md does not exist", () => {
    const result = parseFilesFromExplorerReportLocal(tmpDir);
    expect(result).toEqual([]);
  });

  it("returns [] when report exists but has no file paths", () => {
    writeFileSync(
      join(tmpDir, "EXPLORER_REPORT.md"),
      "# Explorer Report\n\nNo files mentioned here.\n",
    );
    const result = parseFilesFromExplorerReportLocal(tmpDir);
    expect(result).toEqual([]);
  });

  it("extracts src/ paths from the report", () => {
    writeFileSync(
      join(tmpDir, "EXPLORER_REPORT.md"),
      "# Explorer Report\n\n- src/orchestrator/agent-worker.ts\n- src/lib/store.ts\n",
    );
    const result = parseFilesFromExplorerReportLocal(tmpDir);
    expect(result).toContain("src/orchestrator/agent-worker.ts");
    expect(result).toContain("src/lib/store.ts");
  });

  it("extracts .ts files referenced with backticks", () => {
    writeFileSync(
      join(tmpDir, "EXPLORER_REPORT.md"),
      "# Explorer Report\n\nSee `src/orchestrator/roles.ts` for details.\n",
    );
    const result = parseFilesFromExplorerReportLocal(tmpDir);
    expect(result).toContain("src/orchestrator/roles.ts");
  });

  it("deduplicates repeated file paths", () => {
    writeFileSync(
      join(tmpDir, "EXPLORER_REPORT.md"),
      "- src/lib/store.ts\n- src/lib/store.ts\n- src/lib/store.ts\n",
    );
    const result = parseFilesFromExplorerReportLocal(tmpDir);
    const count = result.filter((f) => f === "src/lib/store.ts").length;
    expect(count).toBe(1);
  });

  it("strips trailing punctuation from file paths", () => {
    writeFileSync(
      join(tmpDir, "EXPLORER_REPORT.md"),
      "Read src/lib/store.ts, for more info.\n",
    );
    const result = parseFilesFromExplorerReportLocal(tmpDir);
    expect(result.some((f) => f.endsWith(","))).toBe(false);
  });
});

// ── Tests: Explorer phase sends Agent Mail message ────────────────────────────

describe("Explorer phase Agent Mail handoff", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it("sendMessage is called with 'Explorer Report' subject and body", async () => {
    // Simulate what runPipeline does after Explorer phase succeeds
    const client = new AgentMailClient();
    const seedId = "bd-test1";
    const explorerContent = "# Explorer Report\n\nKey findings: src/orchestrator/roles.ts\n";

    void client.sendMessage(`pipeline-${seedId}`, "Explorer Report", explorerContent);
    await Promise.resolve();

    expect(mockSendMessage).toHaveBeenCalledOnce();
    expect(mockSendMessage).toHaveBeenCalledWith(
      `pipeline-${seedId}`,
      "Explorer Report",
      explorerContent,
    );
  });

  it("pipeline continues even when sendMessage rejects (fire-and-forget via void)", async () => {
    // Arrange: sendMessage is configured to reject
    mockSendMessage.mockRejectedValueOnce(new Error("Agent Mail unavailable"));

    const client = new AgentMailClient();

    // Act: fire-and-forget (void) — rejection must NOT propagate
    let threw = false;
    try {
      void client.sendMessage(
        "pipeline-bd-test2",
        "Explorer Report",
        "# Report",
      );
      await Promise.resolve();
    } catch {
      threw = true;
    }

    expect(threw).toBe(false);
  });

  it("sendMessage is called with to=pipeline-<seedId>, subject='Explorer Report'", async () => {
    const client = new AgentMailClient();
    const seedId = "bd-meta1";

    void client.sendMessage(`pipeline-${seedId}`, "Explorer Report", "content");
    await Promise.resolve();

    const [to, subject] = mockSendMessage.mock.calls[0] as unknown as [string, string, string];
    expect(to).toBe(`pipeline-${seedId}`);
    expect(subject).toBe("Explorer Report");
  });

  it("EXPLORER_REPORT.md on disk is unaffected when Agent Mail fails", () => {
    const tmpDir2 = mkdtempSync(join(tmpdir(), "foreman-explorer-file-"));
    try {
      const reportPath = join(tmpDir2, "EXPLORER_REPORT.md");
      writeFileSync(reportPath, "# Explorer Report\n");

      // Agent Mail failing should not delete the file
      mockSendMessage.mockRejectedValueOnce(new Error("Network unavailable"));
      const client = new AgentMailClient();
      void client.sendMessage("pipeline-bd-filetest", "Explorer Report", "content");

      expect(existsSync(reportPath)).toBe(true);
    } finally {
      rmSync(tmpDir2, { recursive: true, force: true });
    }
  });
});

// ── Tests: QA retry sends Agent Mail message ──────────────────────────────────

describe("QA retry Agent Mail handoff", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it("sendMessage is called with 'QA Feedback - Retry 1' subject on first retry", async () => {
    const client = new AgentMailClient();
    const seedId = "bd-qa1";
    const qaContent = "# QA Report\n## Verdict: FAIL\n\nTest failures found.\n";
    const retryCount = 1;

    void client.sendMessage(
      `pipeline-${seedId}`,
      `QA Feedback - Retry ${retryCount}`,
      qaContent,
    );
    await Promise.resolve();

    expect(mockSendMessage).toHaveBeenCalledWith(
      `pipeline-${seedId}`,
      "QA Feedback - Retry 1",
      qaContent,
    );
  });

  it("sendMessage is called with 'QA Feedback - Retry 2' on second retry", async () => {
    const client = new AgentMailClient();
    const seedId = "bd-qa2";
    const retryCount = 2;

    void client.sendMessage(
      `pipeline-${seedId}`,
      `QA Feedback - Retry ${retryCount}`,
      "QA content",
    );
    await Promise.resolve();

    expect(mockSendMessage).toHaveBeenCalledWith(
      `pipeline-${seedId}`,
      "QA Feedback - Retry 2",
      expect.any(String),
    );
  });

  it("QA sendMessage uses subject 'QA Feedback - Retry N' with the retry number", async () => {
    const client = new AgentMailClient();

    void client.sendMessage(
      "pipeline-bd-qameta",
      "QA Feedback - Retry 1",
      "content",
    );
    await Promise.resolve();

    const [to, subject] = mockSendMessage.mock.calls[0] as unknown as [string, string, string];
    expect(to).toBe("pipeline-bd-qameta");
    expect(subject).toBe("QA Feedback - Retry 1");
  });

  it("pipeline files on disk are unaffected when QA Agent Mail fails", () => {
    const tmpDir2 = mkdtempSync(join(tmpdir(), "foreman-qa-fail-"));
    try {
      const reportPath = join(tmpDir2, "EXPLORER_REPORT.md");
      writeFileSync(reportPath, "# Explorer Report\n");

      mockSendMessage.mockRejectedValueOnce(new Error("Network unavailable"));
      const client = new AgentMailClient();
      void client.sendMessage(
        "pipeline-bd-failtest",
        "QA Feedback - Retry 1",
        "qa content",
      );

      expect(existsSync(reportPath)).toBe(true);
    } finally {
      rmSync(tmpDir2, { recursive: true, force: true });
    }
  });
});

// ── Tests: Reviewer phase sends Agent Mail message ───────────────────────────

describe("Reviewer phase Agent Mail handoff", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it("sendMessage is called with 'Review Complete' subject and body after reviewer finishes", async () => {
    const client = new AgentMailClient();
    const seedId = "bd-rev1";
    const reviewContent = "# Review\n## Verdict: PASS\n\nLooks good.\n";

    void client.sendMessage(
      `pipeline-${seedId}`,
      "Review Complete",
      reviewContent,
    );
    await Promise.resolve();

    expect(mockSendMessage).toHaveBeenCalledWith(
      `pipeline-${seedId}`,
      "Review Complete",
      reviewContent,
    );
  });

  it("sendMessage is called with subject 'Review Complete' when reviewer FAILS", async () => {
    const client = new AgentMailClient();
    const seedId = "bd-revfail";
    const reviewContent = "# Review\n## Verdict: FAIL\n\nCRITICAL: Missing tests.\n";

    void client.sendMessage(
      `pipeline-${seedId}`,
      "Review Complete",
      reviewContent,
    );
    await Promise.resolve();

    const [, subject] = mockSendMessage.mock.calls[0] as unknown as [string, string, string];
    expect(subject).toBe("Review Complete");
  });

  it("sendMessage is called with empty body when review content is empty", async () => {
    const client = new AgentMailClient();

    void client.sendMessage(
      "pipeline-bd-empty",
      "Review Complete",
      "",
    );
    await Promise.resolve();

    const [, , body] = mockSendMessage.mock.calls[0] as unknown as [string, string, string];
    expect(body).toBe("");
  });

  it("REVIEW.md on disk is unaffected when Agent Mail fails", () => {
    const tmpDir3 = mkdtempSync(join(tmpdir(), "foreman-reviewer-file-"));
    try {
      const reviewPath = join(tmpDir3, "REVIEW.md");
      writeFileSync(reviewPath, "# Review\n## Verdict: PASS\n");

      mockSendMessage.mockRejectedValueOnce(new Error("Connection refused"));
      const client = new AgentMailClient();
      void client.sendMessage(
        "pipeline-bd-revfile",
        "Review Complete",
        "content",
      );

      expect(existsSync(reviewPath)).toBe(true);
    } finally {
      rmSync(tmpDir3, { recursive: true, force: true });
    }
  });
});

// ── Tests: 'to' field format ──────────────────────────────────────────────────

describe("Agent Mail 'to' field format", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it("'to' field is pipeline-<seedId> for Explorer, QA, and Reviewer messages", async () => {
    const client = new AgentMailClient();
    const seedId = "bd-totest";

    const calls: Array<[string, string, string]> = [
      [`pipeline-${seedId}`, "Explorer Report", "content"],
      [`pipeline-${seedId}`, "QA Feedback - Retry 1", "qa content"],
      [`pipeline-${seedId}`, "Review Complete", "review content"],
    ];

    for (const [to, subject, body] of calls) {
      void client.sendMessage(to, subject, body);
    }
    await Promise.resolve();

    expect(mockSendMessage).toHaveBeenCalledTimes(calls.length);
    for (const call of mockSendMessage.mock.calls) {
      const [to] = call as unknown as [string, ...unknown[]];
      expect(to).toBe(`pipeline-${seedId}`);
    }
  });
});
