import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ReportAnalyzer } from "../report-analyzer.js";

// ── Fixture helpers ───────────────────────────────────────────────────────

function createTmpProject(): string {
  const dir = join(tmpdir(), `foreman-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  mkdirSync(dir, { recursive: true });
  return dir;
}

const EXPLORER_REPORT_PASS = `# Explorer Report: Test Task

## Summary
A test explorer report for unit testing.

## Relevant Files

- \`src/foo.ts\` (lines 1-50) — Main module

## Architecture & Patterns

\`\`\`typescript
export function foo() { return "bar"; }
\`\`\`

## Dependencies

No external dependencies.

## Existing Tests

- \`src/__tests__/foo.test.ts\` — tests for foo

## Recommended Approach

1. Step one
2. Step two

Watch out for potential pitfalls with edge cases.

## Verdict: PASS
`;

const EXPLORER_REPORT_FAIL = `# Explorer Report: Failed Task

## Summary
A failing explorer report.

## Relevant Files

- \`src/bar.ts\` — Bar module

## Verdict: FAIL

## Issues

- WARNING: Missing tests
`;

const DEVELOPER_REPORT = `# Developer Report: Test Task

## Approach
- Implemented feature X

## Files Changed
- \`src/foo.ts\` — Added foo function
- \`src/__tests__/foo.test.ts\` — Tests added

## Tests Added/Modified
- Tests written for edge cases

## Decisions & Trade-offs
- Chose to use Y because Z (trade-off: performance vs simplicity)

## Known Limitations
- None
`;

const QA_REPORT_PASS = `# QA Report

## Summary
All tests pass.

250 passed, 0 failed, 5 skipped.

## Verdict: PASS
`;

const REVIEW_REPORT = `# Code Review

## Summary
Code looks good. Security considerations reviewed.

Maintainability is good.

## Verdict: PASS
`;

const MINIMAL_REPORT = `# Minimal Report

No sections here.
`;

// ── Tests ─────────────────────────────────────────────────────────────────

describe("ReportAnalyzer", () => {
  let projectDir: string;
  let analyzer: ReportAnalyzer;

  beforeEach(() => {
    projectDir = createTmpProject();
    analyzer = new ReportAnalyzer(projectDir);
  });

  afterEach(() => {
    rmSync(projectDir, { recursive: true, force: true });
  });

  describe("when no worktrees directory exists", () => {
    it("returns empty result", () => {
      const result = analyzer.analyze();
      expect(result.reportCount).toBe(0);
      expect(result.reports).toHaveLength(0);
      expect(result.skills).toHaveLength(0);
    });

    it("scanAllReports returns empty array", () => {
      expect(analyzer.scanAllReports()).toHaveLength(0);
    });
  });

  describe("with worktrees directory present", () => {
    let worktreesDir: string;
    let seedDir: string;

    beforeEach(() => {
      worktreesDir = join(projectDir, ".foreman-worktrees");
      seedDir = join(worktreesDir, "test-seed-abc1");
      mkdirSync(seedDir, { recursive: true });
    });

    it("scans EXPLORER_REPORT.md", () => {
      writeFileSync(join(seedDir, "EXPLORER_REPORT.md"), EXPLORER_REPORT_PASS);
      const reports = analyzer.scanAllReports();
      expect(reports).toHaveLength(1);
      expect(reports[0].role).toBe("explorer");
    });

    it("scans DEVELOPER_REPORT.md", () => {
      writeFileSync(join(seedDir, "DEVELOPER_REPORT.md"), DEVELOPER_REPORT);
      const reports = analyzer.scanAllReports();
      expect(reports).toHaveLength(1);
      expect(reports[0].role).toBe("developer");
    });

    it("scans QA_REPORT.md", () => {
      writeFileSync(join(seedDir, "QA_REPORT.md"), QA_REPORT_PASS);
      const reports = analyzer.scanAllReports();
      expect(reports).toHaveLength(1);
      expect(reports[0].role).toBe("qa");
    });

    it("scans REVIEW.md as reviewer role", () => {
      writeFileSync(join(seedDir, "REVIEW.md"), REVIEW_REPORT);
      const reports = analyzer.scanAllReports();
      expect(reports).toHaveLength(1);
      expect(reports[0].role).toBe("reviewer");
    });

    it("scans timestamped report files", () => {
      writeFileSync(
        join(seedDir, "EXPLORER_REPORT.2026-03-12T15-41-10-872Z.md"),
        EXPLORER_REPORT_PASS,
      );
      const reports = analyzer.scanAllReports();
      expect(reports).toHaveLength(1);
      expect(reports[0].role).toBe("explorer");
      expect(reports[0].timestamp).toBe("2026-03-12T15:41:10.872Z");
    });

    it("scans multiple seeds and report types", () => {
      const seed2Dir = join(worktreesDir, "test-seed-def2");
      mkdirSync(seed2Dir, { recursive: true });
      writeFileSync(join(seedDir, "EXPLORER_REPORT.md"), EXPLORER_REPORT_PASS);
      writeFileSync(join(seedDir, "DEVELOPER_REPORT.md"), DEVELOPER_REPORT);
      writeFileSync(join(seed2Dir, "QA_REPORT.md"), QA_REPORT_PASS);
      const reports = analyzer.scanAllReports();
      expect(reports).toHaveLength(3);
    });
  });

  describe("detectRole", () => {
    it("detects explorer from EXPLORER_REPORT.md", () => {
      expect(analyzer.detectRole("EXPLORER_REPORT.md")).toBe("explorer");
    });

    it("detects developer from DEVELOPER_REPORT.md", () => {
      expect(analyzer.detectRole("DEVELOPER_REPORT.md")).toBe("developer");
    });

    it("detects qa from QA_REPORT.md", () => {
      expect(analyzer.detectRole("QA_REPORT.md")).toBe("qa");
    });

    it("detects reviewer from REVIEW.md", () => {
      expect(analyzer.detectRole("REVIEW.md")).toBe("reviewer");
    });

    it("detects from timestamped filename", () => {
      expect(
        analyzer.detectRole("EXPLORER_REPORT.2026-03-12T15-41-10-872Z.md"),
      ).toBe("explorer");
    });

    it("returns unknown for unrecognized filename", () => {
      expect(analyzer.detectRole("SOME_OTHER.md")).toBe("unknown");
    });
  });

  describe("extractTimestamp", () => {
    it("extracts timestamp from filename", () => {
      const ts = analyzer.extractTimestamp(
        "EXPLORER_REPORT.2026-03-12T15-41-10-872Z.md",
      );
      expect(ts).toBe("2026-03-12T15:41:10.872Z");
    });

    it("returns null for non-timestamped filename", () => {
      expect(analyzer.extractTimestamp("EXPLORER_REPORT.md")).toBeNull();
    });
  });

  describe("parseVerdict", () => {
    it("returns pass for ## Verdict: PASS", () => {
      expect(analyzer.parseVerdict("## Verdict: PASS\n")).toBe("pass");
    });

    it("returns fail for ## Verdict: FAIL", () => {
      expect(analyzer.parseVerdict("## Verdict: FAIL\n")).toBe("fail");
    });

    it("is case-insensitive", () => {
      expect(analyzer.parseVerdict("## Verdict: pass\n")).toBe("pass");
      expect(analyzer.parseVerdict("## Verdict: fail\n")).toBe("fail");
    });

    it("returns unknown when no verdict", () => {
      expect(analyzer.parseVerdict("# Report\n\nSome content.")).toBe("unknown");
    });

    it("returns unknown for empty string", () => {
      expect(analyzer.parseVerdict("")).toBe("unknown");
    });
  });

  describe("extractSections", () => {
    it("extracts sections from explorer report", () => {
      const sections = analyzer.extractSections(EXPLORER_REPORT_PASS);
      const names = sections.map((s) => s.name);
      expect(names).toContain("Summary");
      expect(names).toContain("Relevant Files");
      expect(names).toContain("Architecture & Patterns");
      expect(names).toContain("Dependencies");
      expect(names).toContain("Recommended Approach");
    });

    it("detects code blocks in sections", () => {
      const sections = analyzer.extractSections(EXPLORER_REPORT_PASS);
      const arch = sections.find((s) => s.name === "Architecture & Patterns");
      expect(arch?.hasCodeBlocks).toBe(true);
    });

    it("returns empty array for content with no sections", () => {
      expect(analyzer.extractSections("No sections here.\n")).toHaveLength(0);
    });

    it("reports correct line count", () => {
      const sections = analyzer.extractSections(EXPLORER_REPORT_PASS);
      for (const s of sections) {
        expect(s.lineCount).toBeGreaterThanOrEqual(1);
      }
    });
  });

  describe("countIssues", () => {
    it("counts CRITICAL, WARNING, NOTE occurrences", () => {
      const content = "- CRITICAL: issue one\n- WARNING: issue two\n- NOTE: info\n- NOTE: info2";
      const counts = analyzer.countIssues(content);
      expect(counts.critical).toBe(1);
      expect(counts.warning).toBe(1);
      expect(counts.note).toBe(2);
    });

    it("returns zeros for clean report", () => {
      const counts = analyzer.countIssues("All good here.");
      expect(counts.critical).toBe(0);
      expect(counts.warning).toBe(0);
      expect(counts.note).toBe(0);
    });
  });

  describe("calculateCompleteness", () => {
    it("scores 1.0 for fully complete explorer report", () => {
      const sections = analyzer.extractSections(EXPLORER_REPORT_PASS);
      const score = analyzer.calculateCompleteness("explorer", sections);
      // EXPLORER_REPORT_PASS contains all 5 expected explorer sections, so score must be exactly 1.0
      expect(score).toBe(1.0);
    });

    it("scores 0 for explorer with no sections", () => {
      const score = analyzer.calculateCompleteness("explorer", []);
      expect(score).toBe(0);
    });

    it("scores 0.5 for unknown role", () => {
      const score = analyzer.calculateCompleteness("unknown", []);
      expect(score).toBe(0.5);
    });
  });

  describe("analyze()", () => {
    it("returns correct reportCount", () => {
      const worktreesDir = join(projectDir, ".foreman-worktrees");
      const seedDir = join(worktreesDir, "foreman-abc1");
      mkdirSync(seedDir, { recursive: true });
      writeFileSync(join(seedDir, "EXPLORER_REPORT.md"), EXPLORER_REPORT_PASS);
      writeFileSync(join(seedDir, "QA_REPORT.md"), QA_REPORT_PASS);

      const result = analyzer.analyze();
      expect(result.reportCount).toBe(2);
    });

    it("computes role breakdown", () => {
      const worktreesDir = join(projectDir, ".foreman-worktrees");
      const seedDir = join(worktreesDir, "foreman-abc1");
      mkdirSync(seedDir, { recursive: true });
      writeFileSync(join(seedDir, "EXPLORER_REPORT.md"), EXPLORER_REPORT_PASS);
      writeFileSync(join(seedDir, "QA_REPORT.md"), QA_REPORT_PASS);

      const result = analyzer.analyze();
      expect(result.roleBreakdown.explorer).toBe(1);
      expect(result.roleBreakdown.qa).toBe(1);
    });

    it("computes verdict distribution", () => {
      const worktreesDir = join(projectDir, ".foreman-worktrees");
      const seedDir = join(worktreesDir, "foreman-abc1");
      mkdirSync(seedDir, { recursive: true });
      writeFileSync(join(seedDir, "EXPLORER_REPORT.md"), EXPLORER_REPORT_PASS);
      writeFileSync(join(seedDir, "QA_REPORT.md"), EXPLORER_REPORT_FAIL);

      const result = analyzer.analyze();
      expect(result.verdictDistribution.pass).toBe(1);
      expect(result.verdictDistribution.fail).toBe(1);
    });

    it("extracts skills from reports with patterns", () => {
      const worktreesDir = join(projectDir, ".foreman-worktrees");
      const seedDir = join(worktreesDir, "foreman-abc1");
      mkdirSync(seedDir, { recursive: true });
      // Explorer with code blocks and line refs
      writeFileSync(join(seedDir, "EXPLORER_REPORT.md"), EXPLORER_REPORT_PASS);
      // Developer with trade-offs
      writeFileSync(join(seedDir, "DEVELOPER_REPORT.md"), DEVELOPER_REPORT);

      const result = analyzer.analyze();
      expect(result.skills.length).toBeGreaterThan(0);
      const ids = result.skills.map((s) => s.id);
      expect(ids).toContain("explorer-code-blocks");
      expect(ids).toContain("explorer-pitfalls");
    });

    it("includes sectionFrequency sorted by count", () => {
      const worktreesDir = join(projectDir, ".foreman-worktrees");
      const seedDir = join(worktreesDir, "foreman-abc1");
      mkdirSync(seedDir, { recursive: true });
      writeFileSync(join(seedDir, "EXPLORER_REPORT.md"), EXPLORER_REPORT_PASS);

      const result = analyzer.analyze();
      expect(result.sectionFrequency.length).toBeGreaterThan(0);
      // Should be sorted descending
      for (let i = 1; i < result.sectionFrequency.length; i++) {
        expect(result.sectionFrequency[i - 1].count).toBeGreaterThanOrEqual(
          result.sectionFrequency[i].count,
        );
      }
    });

    it("includes scannedAt timestamp", () => {
      const result = analyzer.analyze();
      expect(result.scannedAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    });
  });

  describe("parseReport()", () => {
    it("parses a complete explorer report", () => {
      const worktreesDir = join(projectDir, ".foreman-worktrees");
      const seedDir = join(worktreesDir, "foreman-abc1");
      mkdirSync(seedDir, { recursive: true });
      const filePath = join(seedDir, "EXPLORER_REPORT.md");
      writeFileSync(filePath, EXPLORER_REPORT_PASS);

      const report = analyzer.parseReport(filePath, "foreman-abc1");
      expect(report.role).toBe("explorer");
      expect(report.seedId).toBe("foreman-abc1");
      expect(report.verdict).toBe("pass");
      expect(report.sections.length).toBeGreaterThan(0);
      expect(report.lineCount).toBeGreaterThan(0);
    });

    it("parses a minimal report without sections", () => {
      const worktreesDir = join(projectDir, ".foreman-worktrees");
      const seedDir = join(worktreesDir, "foreman-abc1");
      mkdirSync(seedDir, { recursive: true });
      const filePath = join(seedDir, "EXPLORER_REPORT.md");
      writeFileSync(filePath, MINIMAL_REPORT);

      const report = analyzer.parseReport(filePath, "foreman-abc1");
      expect(report.sections).toHaveLength(0);
      expect(report.verdict).toBe("unknown");
      expect(report.completenessScore).toBe(0);
    });
  });
});
