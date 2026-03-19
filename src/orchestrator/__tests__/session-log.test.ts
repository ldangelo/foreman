import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  formatSessionLogFilename,
  generateSessionLogContent,
  writeSessionLog,
} from "../session-log.js";
import type { PhaseRecord, SessionLogData } from "../session-log.js";

// ── Helpers ───────────────────────────────────────────────────────────────

function makeData(overrides: Partial<SessionLogData> = {}): SessionLogData {
  return {
    seedId: "bd-test",
    seedTitle: "Test feature",
    seedDescription: "A test feature description",
    branchName: "foreman/bd-test",
    projectName: "foreman",
    phases: [
      { name: "explorer", skipped: false, success: true, costUsd: 0.12, turns: 8 },
      { name: "developer", skipped: false, success: true, costUsd: 0.85, turns: 22 },
      { name: "qa", skipped: false, success: true, costUsd: 0.43, turns: 12 },
      { name: "reviewer", skipped: false, success: true, costUsd: 0.31, turns: 9 },
    ],
    totalCostUsd: 1.71,
    totalTurns: 51,
    filesChanged: ["src/foo.ts", "src/foo.test.ts"],
    devRetries: 0,
    qaVerdict: "pass",
    ...overrides,
  };
}

// ── formatSessionLogFilename ──────────────────────────────────────────────

describe("formatSessionLogFilename", () => {
  it("formats a date as session-DDMMYY-HH:MM.md", () => {
    const date = new Date("2026-03-17T14:32:00.000Z");
    // Note: getHours() uses local time. Use UTC offset-aware assertions.
    const filename = formatSessionLogFilename(date);
    // Must match pattern session-DDMMYY-HH:MM.md
    expect(filename).toMatch(/^session-\d{6}-\d{2}:\d{2}\.md$/);
  });

  it("produces a filename ending in .md", () => {
    expect(formatSessionLogFilename(new Date())).toMatch(/\.md$/);
  });

  it("starts with 'session-'", () => {
    expect(formatSessionLogFilename(new Date())).toMatch(/^session-/);
  });

  it("pads day and month with leading zeros", () => {
    // Jan 1 → 01 day, 01 month
    const date = new Date(2026, 0, 1, 9, 5); // Jan 1, 2026, 09:05 local
    const filename = formatSessionLogFilename(date);
    expect(filename).toBe("session-010126-09:05.md");
  });

  it("uses 2-digit year (last two digits)", () => {
    const date = new Date(2026, 2, 17, 14, 32); // Mar 17, 2026, 14:32 local
    const filename = formatSessionLogFilename(date);
    expect(filename).toBe("session-170326-14:32.md");
  });

  it("pads single-digit hours and minutes", () => {
    const date = new Date(2026, 5, 3, 7, 4); // Jun 3, 2026, 07:04 local
    const filename = formatSessionLogFilename(date);
    expect(filename).toBe("session-030626-07:04.md");
  });
});

// ── generateSessionLogContent ─────────────────────────────────────────────

describe("generateSessionLogContent", () => {
  const date = new Date(2026, 2, 17, 14, 32); // Mar 17, 2026 (local)

  it("includes YAML frontmatter with date, branch, seed", () => {
    const content = generateSessionLogContent(makeData(), date);
    expect(content).toContain("---");
    expect(content).toContain("branch: foreman/bd-test");
    expect(content).toContain("seed: bd-test");
    expect(content).toContain("base_branch: main");
  });

  it("includes project name in frontmatter when provided", () => {
    const content = generateSessionLogContent(makeData({ projectName: "foreman" }), date);
    expect(content).toContain("project: foreman");
  });

  it("omits project name in frontmatter when not provided", () => {
    const data = makeData();
    data.projectName = undefined;
    const content = generateSessionLogContent(data, date);
    expect(content).not.toContain("project:");
  });

  it("includes the session title as an h1 heading", () => {
    const content = generateSessionLogContent(makeData(), date);
    expect(content).toContain("# Session Log: Test feature");
  });

  it("includes a Summary section with seed ID and title", () => {
    const content = generateSessionLogContent(makeData(), date);
    expect(content).toContain("## Summary");
    expect(content).toContain("bd-test");
    expect(content).toContain("Test feature");
  });

  it("includes cost, turns, files changed, and qa verdict in summary", () => {
    const content = generateSessionLogContent(makeData(), date);
    expect(content).toContain("$1.7100");
    expect(content).toContain("51");
    expect(content).toContain("2"); // filesChanged.length
    expect(content).toContain("pass");
  });

  it("shows developer retries when devRetries > 0", () => {
    const content = generateSessionLogContent(makeData({ devRetries: 2 }), date);
    expect(content).toContain("Developer retries");
    expect(content).toContain("2");
  });

  it("omits developer retries line when devRetries is 0", () => {
    const content = generateSessionLogContent(makeData({ devRetries: 0 }), date);
    expect(content).not.toContain("Developer retries");
  });

  it("includes a Phases table with all phase names", () => {
    const content = generateSessionLogContent(makeData(), date);
    expect(content).toContain("## Phases");
    expect(content).toContain("| explorer |");
    expect(content).toContain("| developer |");
    expect(content).toContain("| qa |");
    expect(content).toContain("| reviewer |");
  });

  it("marks passed phases with ✓", () => {
    const content = generateSessionLogContent(makeData(), date);
    expect(content).toContain("✓ passed");
  });

  it("marks failed phases with ✗", () => {
    const phases: PhaseRecord[] = [
      { name: "explorer", skipped: false, success: true, costUsd: 0.1, turns: 5 },
      { name: "developer", skipped: false, success: false, costUsd: 0.5, turns: 10, error: "SDK error" },
    ];
    const content = generateSessionLogContent(makeData({ phases, totalCostUsd: 0.6, totalTurns: 15 }), date);
    expect(content).toContain("✗ failed");
  });

  it("marks skipped phases with ⏭", () => {
    const phases: PhaseRecord[] = [
      { name: "explorer", skipped: true },
      { name: "developer", skipped: false, success: true, costUsd: 0.8, turns: 20 },
      { name: "qa", skipped: false, success: true, costUsd: 0.4, turns: 10 },
      { name: "reviewer", skipped: true },
    ];
    const content = generateSessionLogContent(makeData({ phases }), date);
    expect(content).toContain("⏭ skipped");
  });

  it("shows — for cost and turns when phase is skipped", () => {
    const phases: PhaseRecord[] = [
      { name: "explorer", skipped: true },
      { name: "developer", skipped: false, success: true, costUsd: 0.8, turns: 20 },
      { name: "qa", skipped: false, success: true, costUsd: 0.4, turns: 10 },
      { name: "reviewer", skipped: true },
    ];
    const content = generateSessionLogContent(makeData({ phases }), date);
    // Skipped phase rows have — for cost and turns
    const rows = content.split("\n").filter((l) => l.includes("⏭ skipped"));
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      expect(row).toContain("| — |");
    }
  });

  it("includes Files Changed section when files exist", () => {
    const content = generateSessionLogContent(makeData(), date);
    expect(content).toContain("## Files Changed");
    expect(content).toContain("`src/foo.ts`");
    expect(content).toContain("`src/foo.test.ts`");
  });

  it("omits Files Changed section when no files changed", () => {
    const content = generateSessionLogContent(makeData({ filesChanged: [] }), date);
    expect(content).not.toContain("## Files Changed");
  });

  it("includes Problems section when phases failed", () => {
    const phases: PhaseRecord[] = [
      { name: "developer", skipped: false, success: false, costUsd: 0.5, turns: 10, error: "rate limit hit" },
    ];
    const content = generateSessionLogContent(makeData({ phases }), date);
    expect(content).toContain("## Problems & Resolutions");
    expect(content).toContain("developer phase failed");
    expect(content).toContain("rate limit hit");
  });

  it("includes Problems section when devRetries > 0", () => {
    const content = generateSessionLogContent(makeData({ devRetries: 1 }), date);
    expect(content).toContain("## Problems & Resolutions");
    expect(content).toContain("retried 1 time");
  });

  it("omits Problems section when all phases passed and no retries", () => {
    const content = generateSessionLogContent(makeData(), date);
    expect(content).not.toContain("## Problems & Resolutions");
  });

  it("includes the seed description as a blockquote when non-empty", () => {
    const content = generateSessionLogContent(makeData({ seedDescription: "Implement OAuth2 login" }), date);
    expect(content).toContain("> Implement OAuth2 login");
  });

  it("omits blockquote for placeholder description", () => {
    const content = generateSessionLogContent(makeData({ seedDescription: "(no description provided)" }), date);
    expect(content).not.toContain("> (no description");
  });

  it("truncates very long descriptions in blockquote", () => {
    const longDesc = "x".repeat(300);
    const content = generateSessionLogContent(makeData({ seedDescription: longDesc }), date);
    // Should be truncated at 200 chars
    expect(content).toContain("…");
    // Should not contain full 300-char string as a continuous block
    const blockquoteLine = content.split("\n").find((l) => l.startsWith("> "));
    expect(blockquoteLine).toBeDefined();
    expect(blockquoteLine!.length).toBeLessThan(220); // 2 ("> ") + 200 + 3 ("…") + buffer
  });

  it("lists active (non-skipped) phases in summary", () => {
    const content = generateSessionLogContent(makeData(), date);
    expect(content).toContain("explorer → developer → qa → reviewer");
  });

  it("shows '(none)' in summary when all phases skipped", () => {
    const phases: PhaseRecord[] = [
      { name: "explorer", skipped: true },
      { name: "reviewer", skipped: true },
    ];
    const content = generateSessionLogContent(makeData({ phases }), date);
    expect(content).toContain("(none)");
  });

  it("ends with a trailing newline (POSIX convention)", () => {
    const content = generateSessionLogContent(makeData(), date);
    expect(content.endsWith("\n")).toBe(true);
  });

  it("derives frontmatter date field in UTC (may differ from local-time filename date)", () => {
    // This test documents the known UTC-vs-local-time mismatch: toISOString()
    // returns the UTC date while formatSessionLogFilename() uses local time.
    // For a date constructed as UTC midnight, the ISO date will be the same day.
    const utcDate = new Date("2026-03-17T00:00:00.000Z");
    const content = generateSessionLogContent(makeData(), utcDate);
    // The frontmatter date must be the UTC date string
    expect(content).toContain("date: 2026-03-17");
  });
});

// ── writeSessionLog ───────────────────────────────────────────────────────

describe("writeSessionLog", () => {
  let tmpDir: string;

  beforeEach(async () => {
    tmpDir = join(tmpdir(), `session-log-test-${Date.now()}`);
    await mkdir(tmpDir, { recursive: true });
  });

  afterEach(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  it("creates the SessionLogs/ directory if it does not exist", async () => {
    const date = new Date(2026, 2, 17, 14, 32);
    await writeSessionLog(tmpDir, makeData(), date);

    const { access } = await import("node:fs/promises");
    await expect(access(join(tmpDir, "SessionLogs"))).resolves.toBeUndefined();
  });

  it("writes the session log file with the correct filename", async () => {
    const date = new Date(2026, 2, 17, 14, 32);
    const filepath = await writeSessionLog(tmpDir, makeData(), date);

    expect(filepath).toContain("session-170326-14:32.md");
    const { access } = await import("node:fs/promises");
    await expect(access(filepath)).resolves.toBeUndefined();
  });

  it("returns the absolute path to the written file", async () => {
    const date = new Date(2026, 2, 17, 14, 32);
    const filepath = await writeSessionLog(tmpDir, makeData(), date);
    expect(filepath).toContain(tmpDir);
    expect(filepath).toContain("SessionLogs");
    expect(filepath).toMatch(/\.md$/);
  });

  it("file content contains expected session log markdown", async () => {
    const date = new Date(2026, 2, 17, 14, 32);
    const filepath = await writeSessionLog(tmpDir, makeData(), date);
    const content = await readFile(filepath, "utf-8");

    expect(content).toContain("# Session Log: Test feature");
    expect(content).toContain("bd-test");
    expect(content).toContain("## Phases");
  });

  it("written file ends with a trailing newline", async () => {
    const date = new Date(2026, 2, 17, 14, 32);
    const filepath = await writeSessionLog(tmpDir, makeData(), date);
    const content = await readFile(filepath, "utf-8");
    expect(content.endsWith("\n")).toBe(true);
  });

  it("defaults date to now when not provided", async () => {
    const before = new Date();
    const filepath = await writeSessionLog(tmpDir, makeData());
    const after = new Date();

    const filename = filepath.split("/").pop()!;
    // Filename starts with session- and ends with .md — can't assert exact time
    // but it must exist and be readable
    expect(filename).toMatch(/^session-\d{6}-\d{2}:\d{2}\.md$/);
    const { access } = await import("node:fs/promises");
    await expect(access(filepath)).resolves.toBeUndefined();
  });

  it("overwrites an existing file at the same timestamp", async () => {
    const date = new Date(2026, 2, 17, 14, 32);
    const filepath1 = await writeSessionLog(tmpDir, makeData({ seedTitle: "First run" }), date);
    const filepath2 = await writeSessionLog(tmpDir, makeData({ seedTitle: "Second run" }), date);

    expect(filepath1).toBe(filepath2);
    const content = await readFile(filepath2, "utf-8");
    expect(content).toContain("Second run");
    expect(content).not.toContain("First run");
  });

  it("works when SessionLogs/ dir already exists", async () => {
    await mkdir(join(tmpDir, "SessionLogs"), { recursive: true });
    const date = new Date(2026, 2, 17, 14, 32);
    await expect(writeSessionLog(tmpDir, makeData(), date)).resolves.not.toThrow();
||||||| parent of 4bc57b9 (finalize() in agent-worker.ts has no SessionLogs step — pipeline completion produces no session transcript (bd-uj9e))
  });
});
