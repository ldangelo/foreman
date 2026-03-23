import { describe, it, expect, afterEach } from "vitest";
import {
  mkdtempSync,
  existsSync,
  writeFileSync,
  mkdirSync,
  rmSync,
  readFileSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { archiveWorktreeReports, REPORT_FILES } from "../archive-reports.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeTempDir(): string {
  return mkdtempSync(join(tmpdir(), "foreman-archive-test-"));
}

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs) {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {
      // ignore cleanup errors
    }
  }
  tempDirs.length = 0;
});

function makeDirs(): { projectPath: string; worktreePath: string } {
  const projectPath = makeTempDir();
  const worktreePath = makeTempDir();
  tempDirs.push(projectPath, worktreePath);
  return { projectPath, worktreePath };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("archiveWorktreeReports", () => {
  it("copies report files from worktree to .foreman/reports/<seedId>/", async () => {
    const { projectPath, worktreePath } = makeDirs();
    const seedId = "seed-abc";

    // Create some report files in the worktree
    writeFileSync(join(worktreePath, "EXPLORER_REPORT.md"), "# Explorer");
    writeFileSync(join(worktreePath, "DEVELOPER_REPORT.md"), "# Developer");
    writeFileSync(join(worktreePath, "TASK.md"), "# Task");

    const count = await archiveWorktreeReports(projectPath, worktreePath, seedId);

    expect(count).toBe(3);

    const destDir = join(projectPath, ".foreman", "reports", seedId);
    expect(existsSync(destDir)).toBe(true);
    expect(existsSync(join(destDir, "EXPLORER_REPORT.md"))).toBe(true);
    expect(existsSync(join(destDir, "DEVELOPER_REPORT.md"))).toBe(true);
    expect(existsSync(join(destDir, "TASK.md"))).toBe(true);
  });

  it("preserves file contents when copying", async () => {
    const { projectPath, worktreePath } = makeDirs();
    const seedId = "seed-xyz";

    const content = "# QA Report\n\nAll tests pass!\n";
    writeFileSync(join(worktreePath, "QA_REPORT.md"), content);

    await archiveWorktreeReports(projectPath, worktreePath, seedId);

    const destDir = join(projectPath, ".foreman", "reports", seedId);
    const archived = readFileSync(join(destDir, "QA_REPORT.md"), "utf-8");
    expect(archived).toBe(content);
  });

  it("returns 0 and skips missing report files", async () => {
    const { projectPath, worktreePath } = makeDirs();
    const seedId = "seed-empty";

    // No report files in worktree
    const count = await archiveWorktreeReports(projectPath, worktreePath, seedId);

    expect(count).toBe(0);
  });

  it("creates the archive directory if it does not exist", async () => {
    const { projectPath, worktreePath } = makeDirs();
    const seedId = "seed-newdir";

    writeFileSync(join(worktreePath, "REVIEW.md"), "# Review");

    const destDir = join(projectPath, ".foreman", "reports", seedId);
    expect(existsSync(destDir)).toBe(false);

    await archiveWorktreeReports(projectPath, worktreePath, seedId);

    expect(existsSync(destDir)).toBe(true);
  });

  it("overwrites existing archive files (idempotent)", async () => {
    const { projectPath, worktreePath } = makeDirs();
    const seedId = "seed-idempotent";

    const destDir = join(projectPath, ".foreman", "reports", seedId);
    mkdirSync(destDir, { recursive: true });

    // Write old content to archive
    writeFileSync(join(destDir, "EXPLORER_REPORT.md"), "old content");

    // Write new content to worktree
    writeFileSync(join(worktreePath, "EXPLORER_REPORT.md"), "new content");

    await archiveWorktreeReports(projectPath, worktreePath, seedId);

    const result = readFileSync(join(destDir, "EXPLORER_REPORT.md"), "utf-8");
    expect(result).toBe("new content");
  });

  it("archives BLOCKED.md if present", async () => {
    const { projectPath, worktreePath } = makeDirs();
    const seedId = "seed-blocked";

    writeFileSync(join(worktreePath, "BLOCKED.md"), "# Blocked\n\nCannot proceed.");

    const count = await archiveWorktreeReports(projectPath, worktreePath, seedId);

    expect(count).toBe(1);
    const destDir = join(projectPath, ".foreman", "reports", seedId);
    expect(existsSync(join(destDir, "BLOCKED.md"))).toBe(true);
  });

  it("is best-effort — does not throw when worktree path does not exist", async () => {
    const projectPath = makeTempDir();
    tempDirs.push(projectPath);
    const missingWorktree = join(projectPath, "nonexistent-worktree");
    const seedId = "seed-missing";

    // Should not throw even if worktree doesn't exist (no files to copy)
    const count = await archiveWorktreeReports(projectPath, missingWorktree, seedId);

    expect(count).toBe(0);
  });

  it("REPORT_FILES contains the standard agent report files", () => {
    expect(REPORT_FILES).toContain("EXPLORER_REPORT.md");
    expect(REPORT_FILES).toContain("DEVELOPER_REPORT.md");
    expect(REPORT_FILES).toContain("QA_REPORT.md");
    expect(REPORT_FILES).toContain("REVIEW.md");
    expect(REPORT_FILES).toContain("TASK.md");
    expect(REPORT_FILES).toContain("BLOCKED.md");
  });

  it("REPORT_FILES contains diagnostic artifact files that should never cause merge conflicts", () => {
    // SESSION_LOG.md and RUN_LOG.md are excluded from commits in finalize prompts,
    // but must also be in REPORT_FILES so the conflict resolver auto-resolves
    // them if they were committed by an older pipeline version.
    expect(REPORT_FILES).toContain("SESSION_LOG.md");
    expect(REPORT_FILES).toContain("RUN_LOG.md");
  });

  it("archives SESSION_LOG.md if present", async () => {
    const { projectPath, worktreePath } = makeDirs();
    const seedId = "seed-session-log";

    const content = "# Session Log\n\n## Phase: developer\n";
    writeFileSync(join(worktreePath, "SESSION_LOG.md"), content);

    const count = await archiveWorktreeReports(projectPath, worktreePath, seedId);

    expect(count).toBe(1);
    const destDir = join(projectPath, ".foreman", "reports", seedId);
    expect(existsSync(join(destDir, "SESSION_LOG.md"))).toBe(true);
    const archived = readFileSync(join(destDir, "SESSION_LOG.md"), "utf-8");
    expect(archived).toBe(content);
  });
});
