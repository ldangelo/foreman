# Developer Report: Skill mining from past agent sessions

## Approach

Implemented a three-component skill mining system following the Explorer's Phase 1 recommendation:

1. **`ReportAnalyzer` class** — scans `.foreman-worktrees/*/` for all report files (including timestamped backups), parses markdown structure, extracts sections, verdicts, issue counts, completeness scores, and matches 11 structural skill patterns.
2. **`mine-skills` CLI command** — invokes `ReportAnalyzer` and renders results as a rich terminal table or JSON, with optional `--save` to file.
3. **Types** — added `ReportSection`, `ParsedReport`, `Skill`, and `SkillMiningResult` interfaces to `types.ts`.

No changes were made to the agent pipeline itself — skill mining is purely analytical/read-only.

## Files Changed

- `src/orchestrator/types.ts` — Added `ReportSection`, `ParsedReport`, `Skill`, and `SkillMiningResult` interfaces in the new "Skill mining types" section.
- `src/orchestrator/report-analyzer.ts` — New file (~230 lines). `ReportAnalyzer` class with: `analyze()`, `scanAllReports()`, `listReportFiles()`, `parseReport()`, `detectRole()`, `extractTimestamp()`, `extractSections()`, `parseVerdict()`, `countIssues()`, `calculateCompleteness()`, `extractSkills()`.
- `src/cli/commands/mine-skills.ts` — New file (~100 lines). `mineSkillsCommand` with `--project`, `--output table|json`, and `--save <file>` options.
- `src/cli/index.ts` — Added import and `program.addCommand(mineSkillsCommand)`.

## Tests Added/Modified

- `src/orchestrator/__tests__/report-analyzer.test.ts` — New file, 38 tests covering:
  - Empty/missing worktrees directory
  - Scanning EXPLORER_REPORT.md, DEVELOPER_REPORT.md, QA_REPORT.md, REVIEW.md
  - Timestamped filename scanning and timestamp extraction
  - Multi-seed, multi-report scanning
  - `detectRole()` for all known prefixes and unknown filenames
  - `extractTimestamp()` with and without timestamp in filename
  - `parseVerdict()` — pass, fail, case-insensitive, unknown, empty
  - `extractSections()` — section names, code block detection, line counts
  - `countIssues()` — CRITICAL/WARNING/NOTE counts
  - `calculateCompleteness()` — full, empty, unknown role
  - `analyze()` — reportCount, roleBreakdown, verdictDistribution, skills extraction, sectionFrequency sorting, scannedAt
  - `parseReport()` — complete and minimal reports

All 38 tests pass.

## Decisions & Trade-offs

- **Regex-based skill patterns** over ML/NLP: keeps zero new dependencies, works with small sample sizes, easy to extend.
- **Confidence = min(frequency/10, 1.0)**: simple asymptotic function that stays low until 10+ reports confirm a pattern — avoids overfitting on the current ~6 reports.
- **Read files twice in `extractSkills()`** (once during `parseReport`, once for pattern matching): acceptable for the current volume; a future SQLite cache would eliminate this.
- **No Phase 2/3 implemented**: pattern extraction and prompt injection were scoped out per the Explorer's recommendation to start with Phase 1 metrics only.
- **`successRate` based on report's own verdict**: a downstream correlation (did the *next* phase pass?) would be more meaningful but requires cross-report linking that adds complexity.

## Known Limitations

- **Small sample size**: with only ~6 real reports, skill `confidence` values will be low. The system is designed to improve as more runs accumulate.
- **No SQLite caching**: each `mine-skills` invocation re-reads all files from disk. For projects with hundreds of runs this could be slow.
- **Success metric is per-report verdict**, not downstream phase outcome. Phase 2 could improve this with cross-report correlation.
- **Skill patterns are heuristic**: false positives are possible (e.g., a report mentioning "edge case" in passing). Structural patterns (code blocks, section presence) are more reliable than keyword matches.
- **No prompt injection** (Phase 3 deferred): mined skills are surfaced for human review but not yet fed back into agent prompts.
