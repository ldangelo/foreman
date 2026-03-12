/**
 * Report Analyzer — mines patterns and metrics from past agent session reports.
 *
 * Scans .foreman-worktrees/{worktree}/EXPLORER_REPORT.md, DEVELOPER_REPORT.md, QA_REPORT.md, REVIEW.md
 * and timestamped variants (e.g. EXPLORER_REPORT.2026-03-12T15-41-10-872Z.md).
 *
 * Extracts:
 * - Section structure (completeness, depth)
 * - Verdict distribution (PASS/FAIL/unknown)
 * - Issue severity counts
 * - Recurring patterns and effective techniques (skills)
 */

import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join, basename } from "node:path";
import type { AgentRole } from "./types.js";
import type {
  ParsedReport,
  ReportSection,
  Skill,
  SkillMiningResult,
} from "./types.js";

// ── Constants ─────────────────────────────────────────────────────────────

const REPORT_FILE_PATTERNS: Record<string, Exclude<AgentRole, "lead" | "worker">> = {
  EXPLORER_REPORT: "explorer",
  DEVELOPER_REPORT: "developer",
  QA_REPORT: "qa",
  REVIEW: "reviewer",
};

// Expected sections per role for completeness scoring
const EXPECTED_SECTIONS: Record<string, string[]> = {
  explorer: [
    "Relevant Files",
    "Architecture",
    "Dependencies",
    "Existing Tests",
    "Recommended Approach",
  ],
  developer: [
    "Approach",
    "Files Changed",
    "Tests",
    "Decisions",
  ],
  qa: [
    "Verdict",
    "Summary",
  ],
  reviewer: [
    "Verdict",
    "Summary",
  ],
  unknown: [],
};

// Skill patterns to extract — structural quality indicators
const SKILL_PATTERNS: Array<{
  id: string;
  name: string;
  category: Skill["category"];
  description: string;
  regex: RegExp;
}> = [
  {
    id: "explorer-code-blocks",
    name: "Includes code examples",
    category: "exploration",
    description: "Explorer report contains code blocks demonstrating patterns",
    regex: /```[\s\S]+?```/,
  },
  {
    id: "explorer-line-refs",
    name: "Precise line number references",
    category: "exploration",
    description: "Explorer cites specific line numbers when referencing code",
    regex: /\(lines? \d+[-–]\d+\)/i,
  },
  {
    id: "explorer-architecture-section",
    name: "Architecture section present",
    category: "exploration",
    description: "Report includes dedicated architecture/patterns analysis",
    regex: /^##\s+Architecture/im,
  },
  {
    id: "explorer-pitfalls",
    name: "Documents pitfalls",
    category: "exploration",
    description: "Explorer identifies potential pitfalls and edge cases",
    regex: /pitfall|edge case|gotcha|watch out|caveat/i,
  },
  {
    id: "developer-tests-added",
    name: "Tests explicitly mentioned",
    category: "implementation",
    description: "Developer report mentions test additions",
    regex: /test[s]?\s+(added|written|updated|modified)/i,
  },
  {
    id: "developer-trade-offs",
    name: "Documents trade-offs",
    category: "implementation",
    description: "Developer explains design decisions and trade-offs",
    regex: /trade[-\s]off|decision|rationale|because|chose to/i,
  },
  {
    id: "developer-files-section",
    name: "Files changed section",
    category: "implementation",
    description: "Developer report has structured files changed section",
    regex: /^##\s+Files\s+Changed/im,
  },
  {
    id: "qa-test-counts",
    name: "Reports test counts",
    category: "testing",
    description: "QA report includes specific pass/fail test counts",
    regex: /\d+\s+(passed|failed|skipped|tests)/i,
  },
  {
    id: "qa-edge-cases",
    name: "Documents edge cases found",
    category: "testing",
    description: "QA report explicitly discusses edge cases discovered",
    regex: /edge case|null|undefined|empty|boundary/i,
  },
  {
    id: "reviewer-security",
    name: "Security considerations",
    category: "review",
    description: "Reviewer checks for security implications",
    regex: /security|injection|sanitiz|authori[sz]/i,
  },
  {
    id: "reviewer-maintainability",
    name: "Maintainability assessment",
    category: "review",
    description: "Reviewer comments on code maintainability",
    regex: /maintainab|readable|complex|cohes|coupl/i,
  },
];

// ── ReportAnalyzer class ──────────────────────────────────────────────────

export class ReportAnalyzer {
  private worktreesRoot: string;

  constructor(projectPath: string) {
    this.worktreesRoot = join(projectPath, ".foreman-worktrees");
  }

  /**
   * Scan all worktrees and mine skills from all reports found.
   */
  analyze(): SkillMiningResult {
    const reports = this.scanAllReports();
    const skills = this.extractSkills(reports);

    const roleBreakdown: Record<string, number> = {};
    const verdictDistribution = { pass: 0, fail: 0, unknown: 0 };
    let totalCompleteness = 0;

    for (const r of reports) {
      roleBreakdown[r.role] = (roleBreakdown[r.role] ?? 0) + 1;
      verdictDistribution[r.verdict]++;
      totalCompleteness += r.completenessScore;
    }

    const sectionCounts = new Map<string, number>();
    for (const r of reports) {
      for (const s of r.sections) {
        sectionCounts.set(s.name, (sectionCounts.get(s.name) ?? 0) + 1);
      }
    }

    const sectionFrequency = Array.from(sectionCounts.entries())
      .map(([section, count]) => ({
        section,
        count,
        percentage: reports.length > 0 ? Math.round((count / reports.length) * 100) : 0,
      }))
      .sort((a, b) => b.count - a.count);

    return {
      projectPath: this.worktreesRoot,
      scannedAt: new Date().toISOString(),
      reportCount: reports.length,
      roleBreakdown,
      verdictDistribution,
      averageCompleteness:
        reports.length > 0 ? totalCompleteness / reports.length : 0,
      sectionFrequency,
      skills,
      reports,
    };
  }

  /**
   * Scan all .foreman-worktrees subdirectories for report files.
   */
  scanAllReports(): ParsedReport[] {
    if (!existsSync(this.worktreesRoot)) {
      return [];
    }

    const reports: ParsedReport[] = [];

    let worktreeDirs: string[];
    try {
      worktreeDirs = readdirSync(this.worktreesRoot, { withFileTypes: true })
        .filter((d) => d.isDirectory())
        .map((d) => join(this.worktreesRoot, d.name));
    } catch {
      return [];
    }

    for (const dir of worktreeDirs) {
      const seedId = basename(dir);
      const files = this.listReportFiles(dir);
      for (const filePath of files) {
        try {
          const report = this.parseReport(filePath, seedId);
          reports.push(report);
        } catch {
          // Skip files that can't be parsed
        }
      }
    }

    return reports;
  }

  /**
   * List report files in a directory (current + timestamped backups).
   */
  listReportFiles(dir: string): string[] {
    let files: string[];
    try {
      files = readdirSync(dir);
    } catch {
      return [];
    }

    const reportFiles: string[] = [];
    for (const file of files) {
      for (const prefix of Object.keys(REPORT_FILE_PATTERNS)) {
        if (file.startsWith(prefix) && file.endsWith(".md")) {
          reportFiles.push(join(dir, file));
          break;
        }
      }
    }
    return reportFiles;
  }

  /**
   * Parse a single report file into a ParsedReport.
   */
  parseReport(filePath: string, seedId: string): ParsedReport {
    const content = readFileSync(filePath, "utf-8");
    const filename = basename(filePath);

    const role = this.detectRole(filename);
    const timestamp = this.extractTimestamp(filename);
    const sections = this.extractSections(content);
    const verdict = this.parseVerdict(content);
    const issueCount = this.countIssues(content);
    const completenessScore = this.calculateCompleteness(role, sections);

    return {
      filePath,
      role,
      timestamp,
      seedId,
      sections,
      verdict,
      issueCount,
      completenessScore,
      lineCount: content.split("\n").length,
      rawContent: content,
    };
  }

  /**
   * Detect agent role from filename.
   */
  detectRole(filename: string): ParsedReport["role"] {
    for (const [prefix, role] of Object.entries(REPORT_FILE_PATTERNS)) {
      if (filename.startsWith(prefix)) {
        return role;
      }
    }
    return "unknown";
  }

  /**
   * Extract ISO timestamp from filename like EXPLORER_REPORT.2026-03-12T15-41-10-872Z.md
   */
  extractTimestamp(filename: string): string | null {
    // Match: 2026-03-12T15-41-10-872Z
    const m = filename.match(/(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d+Z)/);
    if (!m) return null;
    // Convert filename timestamp format (dashes in time) to ISO format (colons)
    // e.g., 2026-03-12T15-41-10-872Z → 2026-03-12T15:41:10.872Z
    const raw = m[1];
    const isoish = raw.replace(/T(\d{2})-(\d{2})-(\d{2})-(\d+)Z/, "T$1:$2:$3.$4Z");
    return isoish;
  }

  /**
   * Extract markdown sections from report content.
   */
  extractSections(content: string): ReportSection[] {
    const sections: ReportSection[] = [];
    // Match ## headings and capture content up to next ## heading or end
    const sectionRegex = /^## (.+)$/gm;
    const headings: Array<{ name: string; index: number }> = [];

    let m: RegExpExecArray | null;
    while ((m = sectionRegex.exec(content)) !== null) {
      headings.push({ name: m[1].trim(), index: m.index });
    }

    for (let i = 0; i < headings.length; i++) {
      const heading = headings[i];
      const start = heading.index;
      const end = i + 1 < headings.length ? headings[i + 1].index : content.length;
      const sectionContent = content.slice(start, end).trim();
      const bodyContent = sectionContent.replace(/^##[^\n]*\n/, "").trim();

      sections.push({
        name: heading.name,
        content: bodyContent,
        lineCount: bodyContent.split("\n").length,
        hasCodeBlocks: /```[\s\S]+?```/.test(bodyContent),
      });
    }

    return sections;
  }

  /**
   * Parse verdict from report content.
   */
  parseVerdict(content: string): "pass" | "fail" | "unknown" {
    if (/## verdict:\s*pass/i.test(content)) return "pass";
    if (/## verdict:\s*fail/i.test(content)) return "fail";
    // Also check for inline verdict mentions
    if (/\bverdict[:\s]+pass\b/i.test(content)) return "pass";
    if (/\bverdict[:\s]+fail\b/i.test(content)) return "fail";
    if (/\*\*pass\*\*/i.test(content)) return "pass";
    if (/\*\*fail\*\*/i.test(content)) return "fail";
    return "unknown";
  }

  /**
   * Count issue severities in report.
   */
  countIssues(content: string): { critical: number; warning: number; note: number } {
    const criticalCount = (content.match(/\bCRITICAL\b/g) ?? []).length;
    const warningCount = (content.match(/\bWARNING\b/g) ?? []).length;
    const noteCount = (content.match(/\bNOTE\b/g) ?? []).length;
    return { critical: criticalCount, warning: warningCount, note: noteCount };
  }

  /**
   * Calculate completeness score (0-1) based on expected sections for the role.
   */
  calculateCompleteness(
    role: ParsedReport["role"],
    sections: ReportSection[],
  ): number {
    const expected = EXPECTED_SECTIONS[role] ?? [];
    if (expected.length === 0) {
      // Unknown role: return a neutral 0.5 rather than 0 (which would imply
      // "definitely incomplete") or 1.0 (which would imply "fully complete").
      // The neutral value avoids skewing averageCompleteness in either direction
      // when unrecognized report files are scanned.
      return 0.5;
    }

    const sectionNames = sections.map((s) => s.name.toLowerCase());
    let matched = 0;
    for (const exp of expected) {
      if (sectionNames.some((name) => name.includes(exp.toLowerCase()))) {
        matched++;
      }
    }
    return matched / expected.length;
  }

  /**
   * Extract skills from a set of parsed reports.
   */
  extractSkills(reports: ParsedReport[]): Skill[] {
    const skills: Skill[] = [];

    for (const patternDef of SKILL_PATTERNS) {
      const matchingReports: string[] = [];
      let passCount = 0;

      for (const report of reports) {
        // Use the cached rawContent from parseReport() — avoids a redundant disk read
        const content = report.rawContent;

        if (patternDef.regex.test(content)) {
          matchingReports.push(basename(report.filePath));
          if (report.verdict === "pass") {
            passCount++;
          }
        }
      }

      if (matchingReports.length === 0) continue;

      const frequency = matchingReports.length;
      const successRate =
        matchingReports.length > 0 ? passCount / matchingReports.length : 0;
      // Confidence increases with sample size (asymptotic toward 1.0)
      const confidence = Math.min(frequency / 10, 1.0);

      skills.push({
        id: patternDef.id,
        name: patternDef.name,
        category: patternDef.category,
        description: patternDef.description,
        pattern: patternDef.regex.toString(),
        frequency,
        successRate,
        sourceReports: matchingReports,
        confidence,
      });
    }

    return skills.sort((a, b) => b.frequency - a.frequency);
  }
}
