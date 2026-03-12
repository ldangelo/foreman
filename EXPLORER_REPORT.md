# Explorer Report: Skill mining from past agent sessions

## Executive Summary

**Skill mining** is the process of analyzing timestamped reports from past agent sessions (Explorer, Developer, QA, Reviewer) to identify, extract, and formalize reusable patterns, best practices, and effective techniques. The goal is to improve future agent implementations by learning what works.

Foreman has:
- A well-structured multi-phase agent pipeline (Explorer → Developer → QA → Reviewer)
- **6+ timestamped reports** from successful and failed runs
- **No existing infrastructure** for analyzing or mining patterns from these reports
- **Clear opportunity** to create a skill extraction system with minimal dependencies

The recommended approach is a three-phase implementation:
1. **Phase 1 (Simplest)**: Report analyzer + metrics (understand what's in past reports)
2. **Phase 2**: Pattern extraction per role (identify recurring effective techniques)
3. **Phase 3 (Optional)**: Skill library + prompt injection (use mined skills to improve future agents)

---

## Relevant Files

### Core Pipeline Files

#### **src/orchestrator/roles.ts** (lines 1-350+)
- **Purpose**: Defines role configurations and hardcoded prompt templates
- **Key Components**:
  - `ROLE_CONFIGS` (lines 21-46): Metadata for each role (model, budget, report filename)
    - explorer: Claude Haiku, $1.00 budget, EXPLORER_REPORT.md
    - developer: Claude Sonnet, $5.00 budget, DEVELOPER_REPORT.md
    - qa: Claude Sonnet, $3.00 budget, QA_REPORT.md
    - reviewer: Claude Sonnet, $2.00 budget, REVIEW.md
  - Prompt template functions (lines 50+): `explorerPrompt()`, `developerPrompt()`, `qaPrompt()`, `reviewerPrompt()`
    - Each includes role definition, task context, detailed instructions, output format, and rules
  - Report parsing functions (lines 259-290+): `parseVerdict()`, `extractIssues()`, `hasActionableIssues()`
- **Relevance**: Primary source for understanding what agents are instructed to do. Future skill mining would extract patterns from the prompts and enhance them with mined skills.
- **Example Pattern**: Explorer prompt (lines 50-96) has explicit instruction to write EXPLORER_REPORT.md with sections: Relevant Files, Architecture & Patterns, Dependencies, Existing Tests, Recommended Approach

#### **src/orchestrator/agent-worker.ts** (lines 1-300+)
- **Purpose**: Standalone worker process that executes each pipeline phase as separate SDK queries
- **Key Functions**:
  - `runPhase()` (lines 120+): Executes a single phase (explorer, developer, qa, reviewer)
  - Report parsing (lines 140-180): Calls `parseVerdict()`, `extractIssues()` to read results from disk
  - Feedback loops (lines 180-210): If QA FAIL, triggers developer re-run with feedback context
  - Phase sequencing (lines 99-150): Orchestrates explorer → developer → qa → reviewer pipeline
- **Relevance**: Shows how reports are parsed and used to make decisions. Skill mining would feed insights back into prompt selection/enhancement.
- **Data Flow**: Report files (EXPLORER_REPORT.md, etc.) are written to disk, read back by next phase, and verdict/issues extracted via regex

#### **src/orchestrator/types.ts** (lines 1-152)
- **Purpose**: TypeScript type definitions for orchestration system
- **Key Types**:
  - `AgentRole` (line 7): "lead" | "explorer" | "developer" | "qa" | "reviewer" | "worker"
  - `ModelSelection` (line 5): "claude-opus-4-6" | "claude-sonnet-4-6" | "claude-haiku-4-5-20251001"
  - `DecompositionPlan` (lines 37-43): Epic/sprint/story/task hierarchy
  - `DispatchResult` (lines 72-77): Result of dispatching tasks
- **Relevance**: Defines the shape of data flowing through the system. Skill structure would be added here.

### Report Examples (Past Sessions)

Multiple timestamped report files exist in the worktree:

**Available Reports:**
- `EXPLORER_REPORT.2026-03-12T15-41-10-872Z.md` — Detailed 296-line analysis of skill mining task itself (comprehensive)
- `EXPLORER_REPORT.2026-03-12T15-39-43-331Z.md` — ~166 lines analyzing code quality issue
- `EXPLORER_REPORT.2026-03-12T11-59-36-491Z.md` — ~200+ lines analyzing iTerm hanging issue
- `DEVELOPER_REPORT.md` — Latest developer implementation summary
- `DEVELOPER_REPORT.2026-03-12T12-07-04-236Z.md` — Previous developer report with timestamp
- `QA_REPORT.md` — Latest QA verification (246 passed tests, 9 pre-existing failures)
- `QA_REPORT.2026-03-12T12-08-15-693Z.md` — Previous QA report
- `REVIEW.md` — Latest review (PASS/FAIL verdict with issue list)
- `REVIEW.2026-03-12T12-04-45-598Z.md` — Previous review report

**Common Report Structure:**
1. Title/summary (task description)
2. Relevant Files (file paths with line numbers + descriptions)
3. Architecture & Patterns (naming conventions, abstractions, patterns observed)
4. Dependencies (what the code depends on, what depends on it)
5. Existing Tests (test file paths and coverage)
6. Recommended Approach (step-by-step plan + pitfalls)
7. (Optional) Verdict (PASS/FAIL for QA/Review)
8. (Optional) Issues (list with severity: CRITICAL, WARNING, NOTE)

### Data Storage Files

#### **src/lib/store.ts** (lines 1-400+)
- **Purpose**: SQLite database store for projects, runs, costs, events
- **Schema**:
  - `projects` table: id, name, path, status, created_at, updated_at
  - `runs` table: id, project_id, seed_id, agent_type, session_key, worktree_path, status, started_at, completed_at, progress (JSON)
  - `costs` table: id, run_id, tokens_in, tokens_out, cache_read, estimated_cost
  - `events` table: id, project_id, run_id, event_type, details, created_at
- **RunProgress Structure** (lines 64-75): Tracks turns, tool calls, files changed, tokens, cost, current phase
- **Relevance**: Stores run metadata but **not report analysis/mining data**. Opportunity to extend with skill cache tables.

#### **.seeds/issues.jsonl** (git-tracked task database)
- **Purpose**: Structured seed/task tracking with dependencies
- **Relevance**: Links which agents completed which tasks; enables correlation with report quality

### CLI Command Files

#### **src/cli/index.ts** (lines 1-36)
- **Purpose**: CLI entry point with command registration
- **Current Commands**: init, plan, decompose, run, status, merge, pr, monitor, reset, attach, doctor
- **Relevance**: No skill-mining command yet. Would need to add `mine-skills` command here.

#### **src/cli/commands/status.ts** (lines 1-185)
- **Purpose**: Shows project status, active agents, costs
- **Pattern**: Executes CLI tools, parses JSON output, formats with chalk colors
- **Relevance**: Model for how new commands are structured (parse args, execute, format output)

### Test Files

#### **src/orchestrator/__tests__/roles.test.ts** (lines 1-144)
- **Tests**: ROLE_CONFIGS completeness, prompt templates, verdict parsing, issue extraction
- **Coverage Areas**:
  - Role config structure: lines 12-59
  - Prompt templates: lines 61-100 (verifies seed ID, instructions, report filenames are present)
  - Verdict parsing: lines 102-123 (PASS/FAIL/unknown cases, case-insensitivity)
  - Issue extraction: lines 125-143 (extracts between "## Issues" and next heading, filters severity)
- **Relevance**: No tests for skill extraction yet — this is new functionality

#### **src/orchestrator/__tests__/agent-worker.test.ts** (referenced in prior reports)
- Tests worker initialization, config file handling, phase execution flow
- No direct verification of report content or parsing feedback loops

#### **src/orchestrator/__tests__/agent-worker-team.test.ts** (referenced)
- Tests team-based orchestration and multi-phase coordination

---

## Architecture & Patterns

### Pipeline Architecture

```
┌─────────────────────────────────────────┐
│  Explorer Phase (Haiku, $1)             │
│  - Read TASK.md + codebase              │
│  - Write EXPLORER_REPORT.md             │
└──────────────┬──────────────────────────┘
               │ reads EXPLORER_REPORT.md
               ↓
┌─────────────────────────────────────────┐
│  Developer Phase (Sonnet, $5)           │
│  - Read EXPLORER_REPORT.md              │
│  - Write DEVELOPER_REPORT.md            │
│  - Make code changes                    │
└──────────────┬──────────────────────────┘
               │ reads DEVELOPER_REPORT.md
               ↓
┌─────────────────────────────────────────┐
│  QA Phase (Sonnet, $3)                  │
│  - Read DEVELOPER_REPORT.md             │
│  - Run tests, verify changes            │
│  - Write QA_REPORT.md                   │
│  - Verdict: PASS or FAIL                │
└──────────────┬──────────────────────────┘
               │ [If FAIL: feedback loop]
               │ reads QA_REPORT.md
               ↓
┌─────────────────────────────────────────┐
│  Reviewer Phase (Sonnet, $2)            │
│  - Read all previous reports            │
│  - Independent code review              │
│  - Write REVIEW.md                      │
│  - Verdict: PASS or FAIL                │
└─────────────────────────────────────────┘
```

### Report Communication Protocol

**Reports are the primary inter-agent communication mechanism:**
- Explorer → Developer: EXPLORER_REPORT.md provides codebase analysis
- Developer → QA: DEVELOPER_REPORT.md describes changes made
- QA → Developer (feedback loop): QA_REPORT.md verdict triggers developer re-run if FAIL
- All → Reviewer: All previous reports inform final review
- Reviewer → System: REVIEW.md verdict determines task completion

### Report Parsing Pattern

Key functions extract structured data from markdown:
- `parseVerdict(content: string): "pass" | "fail" | "unknown"` (lines 259-266 in roles.ts)
  - Searches for "## Verdict: PASS" or "## Verdict: FAIL" (case-insensitive)
  - Returns "unknown" if no verdict found
- `extractIssues(content: string): string` (lines 268-276)
  - Extracts section between "## Issues" heading and next heading
  - Returns fallback message if no issues section found
- `hasActionableIssues(content: string): boolean` (lines 278-283)
  - Checks for CRITICAL/WARNING markers in issues
  - Used to block task completion on critical issues

### Prompt Template Pattern

Each role's prompt follows consistent structure (from roles.ts):
1. **Role definition** ("You are an Explorer…") — establishes agent identity
2. **Task context** (seed ID, title, description) — provides work scope
3. **Instructions** (numbered steps) — tells agent what to do
4. **Output format specification** — prescribes markdown template with required sections
5. **Rules** (constraints, dos/don'ts) — establishes boundaries

Example (Explorer, lines 50-96):
```
# Explorer Agent
You are an **Explorer** — your job is to understand the codebase...
## Task
**Seed:** ${seedId} — ${seedTitle}...
## Instructions
1. Read TASK.md...
2. Explore the codebase...
3. Write your findings to **EXPLORER_REPORT.md**
## EXPLORER_REPORT.md Format
[markdown template with sections]
## Rules
- DO NOT modify any source code files...
```

---

## Dependencies

### What Uses Reports

1. **agent-worker.ts** (`runPhase()` function):
   - Calls `query()` with phase-specific prompt from roles.ts
   - After phase completes, parses report file using `parseVerdict()`, `extractIssues()`
   - Uses parsed verdict to determine next phase behavior
   - Passes extracted issues to next phase as feedback context

2. **dispatcher.ts** (referenced in earlier exploration):
   - Creates worktrees and writes TASK.md template
   - Records runs in SQLite with metadata (worktree path, model, budget, start time)

3. **roles.ts** (exports):
   - `explorerPrompt()`, `developerPrompt()`, `qaPrompt()`, `reviewerPrompt()` — exported to agent-worker.ts
   - `ROLE_CONFIGS` — role metadata used by dispatcher and agent-worker
   - `parseVerdict()`, `extractIssues()`, `hasActionableIssues()` — exported to agent-worker.ts for verdict/issue extraction

### What Depends on Reports

- **agent-worker.ts**: Reads .md report files from disk (synchronously via readFileSync)
- **lead-prompt.ts** (referenced): Summarizes reports for lead agent
- **Future skill-mining system**: Would scan `.foreman-worktrees/*/` directories for report files

### Report File Locations

- Reports written to worktree root: `.foreman-worktrees/<seed-id>/EXPLORER_REPORT.md` (etc.)
- Timestamped backups also stored in same directory: `.../EXPLORER_REPORT.2026-03-12T15-41-10-872Z.md`
- Reports readable by any downstream phase in same worktree

---

## Existing Tests

### Test Coverage

#### **roles.test.ts** (144 lines, 25+ test cases)
- **ROLE_CONFIGS tests** (lines 12-59):
  - ✅ All roles defined
  - ✅ Explorer uses Haiku (cost efficiency)
  - ✅ Sonnet used for complex roles (Developer, QA, Reviewer)
  - ✅ Budget values positive and in expected ranges
  - ✅ Report filenames match expected names
  - ✅ No legacy `maxTurns` properties

- **Prompt template tests** (lines 61-100):
  - ✅ explorerPrompt includes seed context and read-only rules
  - ✅ developerPrompt includes EXPLORER_REPORT.md reference
  - ✅ developerPrompt includes feedback when provided
  - ✅ qaPrompt references QA_REPORT.md
  - ✅ reviewerPrompt includes read-only rules

- **Verdict parsing tests** (lines 102-123):
  - ✅ PASS verdict detected
  - ✅ FAIL verdict detected
  - ✅ Case-insensitive parsing
  - ✅ Unknown verdict when missing
  - ✅ Unknown for empty content

- **Issue extraction tests** (lines 125-143):
  - ✅ Extracts issues section between headings
  - ✅ Filters out non-issue content (e.g., "Positive Notes")
  - ✅ Returns fallback message when no issues section

### Test Gaps

- **No tests for skill extraction** — Completely new functionality
- **No tests for report quality metrics** — Opportunity to add metric calculations
- **No integration tests** — End-to-end verification of report generation and feedback loops
- **No tests for report-to-seed correlation** — Linking reports to seed metadata not yet tested
- **No performance tests** — Report scanning/parsing efficiency not measured

---

## Recommended Approach

### Phase 1: Analysis & Metrics (Simplest, No Changes to Pipeline)

**Goal**: Understand what's in existing reports without modifying agent behavior

**Step 1.1: Create Report Analyzer Module** (`src/orchestrator/report-analyzer.ts`)
- Scan `.foreman-worktrees/*/` directories for report files
- Parse report markdown structure using regex:
  - Extract sections: Relevant Files, Architecture & Patterns, Dependencies, Existing Tests, Recommended Approach
  - Count lines per section
  - Detect verdict and issues
  - Extract timestamps from filename
- Build metrics for each report:
  - Completeness score (0-100: all 5 sections present and non-empty)
  - Section depth (avg lines per section)
  - Verdict distribution (PASS/FAIL/unknown percentages)
  - Issue severity distribution (CRITICAL/WARNING/NOTE counts)
  - Links to seed metadata (if available via .seeds/issues.jsonl)

**Step 1.2: Define Skill Type** (modify `src/orchestrator/types.ts`)
```typescript
export interface Skill {
  id: string;
  name: string;
  category: "exploration" | "implementation" | "testing" | "review";
  description: string;
  pattern: string;              // The actual technique/phrase
  frequency: number;             // How many reports contain this pattern
  successRate: number;            // Percentage of reports with this pattern that passed downstream
  sourceReports: string[];        // Filenames that contain this pattern
  confidence: number;             // 0-1, based on sample size
}
```

**Step 1.3: CLI Command** (`src/cli/commands/mine-skills.ts`)
```bash
foreman mine-skills [--project <path>] [--output json|table]
```
- Scans reports in project (or all if --project omitted)
- Invokes ReportAnalyzer
- Outputs JSON file or human-readable table
- Example output:
```json
{
  "reportCount": 6,
  "phraseFrequency": [
    { "phrase": "Relevant Files", "count": 6 },
    { "phrase": "Architecture & Patterns", "count": 6 },
    ...
  ],
  "verdictDistribution": { "pass": 4, "fail": 1, "unknown": 1 },
  "averageCompleteness": 0.94
}
```

**Step 1.4: Tests** (`src/orchestrator/__tests__/report-analyzer.test.ts`)
- Test parsing of sample report markdown
- Verify metric calculations
- Verify section detection works with variant formats
- Test fixture reports with known structure

**Output**: JSON file with metrics, no changes to agents or prompts

---

### Phase 2: Pattern Extraction (Mining)

**Goal**: Identify recurring techniques in successful reports

**Step 2.1: Analyze Explorer Reports**
Extract patterns like:
- Common file-finding strategies: "Used glob patterns to find...", "Searched for files matching..."
- Architecture analysis techniques: "Identified module structure...", "Traced dependencies..."
- Dependency mapping: "Found X imports from Y", "Determined Z depends on..."
- Success metric: Did downstream developer reference this explorer's files?

**Step 2.2: Analyze Developer Reports**
Extract patterns like:
- Code organization decisions: "Grouped related functions into...", "Structured as..."
- Test coverage strategies: "Added tests for edge cases...", "Verified implementation with..."
- Implementation sequencing: "Implemented X first because Y requires it"
- Success metric: Did QA tests pass on first try (no failures)?

**Step 2.3: Analyze QA Reports**
Extract patterns like:
- Test identification strategies: "Ran test suite to catch...", "Added regression tests..."
- Edge case discovery: "Found issue with null handling...", "Identified missing validation..."
- Success metric: How many issues did QA catch vs. developer missed?

**Step 2.4: Analyze Reviewer Reports**
Extract patterns like:
- Code quality checks: "Verified security considerations...", "Checked for performance issues..."
- Risk assessment: "Flagged potential issues with...", "Noted maintainability concern..."
- Success metric: How many CRITICAL issues identified?

**Implementation**:
- Extend ReportAnalyzer with phrase extraction logic
- Use heuristic-based pattern detection:
  - Code blocks present in section (indicates concrete examples)
  - List item depth (nested vs. flat structure)
  - Common keywords per role ("Verified" in QA, "Dependency" in Explorer)
- Build skill registry mapping patterns to roles

---

### Phase 3 (Optional): Formalization & Integration

**Goal**: Use mined skills to enhance future agent prompts (requires A/B testing)

**Step 3.1: Skill Library** (`src/orchestrator/skill-library.ts`)
- Registry of mined skills with success metrics
- Query interface: `getSkills(role: AgentRole, category: string)`
- Integration points for prompt enhancement

**Step 3.2: Prompt Injection** (modify roles.ts)
- Optionally append top-performing skills to agent prompts
- Example: "Based on successful past sessions, effective exploration techniques include: [skill pattern]"
- A/B test: baseline vs. skill-enhanced prompts
- Track which skill injections improve report quality

**Step 3.3: Dashboard Integration** (future)
- Display mined skills per project/role
- Show skill effectiveness metrics
- Enable skill selection per task

---

## Potential Pitfalls & Edge Cases

### 1. **Report Format Variability**
- **Issue**: Reports vary in format/detail depending on task complexity
- **Example**: Some reports have bonus sections (Known Limitations, Positive Notes) not in template
- **Solution**: Parse flexible templates; handle optional sections gracefully
  - Use regex with optional groups: `## Architecture & Patterns\n?([\s\S]*?)\n(?=## |\Z)`
  - Track section presence separately from content

### 2. **Success Metric Ambiguity**
- **Issue**: How do we know if a skill was "good"?
- **Options**:
  - Subsequent agent success? (downstream verdict PASS)
  - Report quality? (completeness score)
  - Task completion? (seed marked as closed)
  - Downstream issue density? (fewer issues caught by QA)
- **Solution**: Use multiple signals
  - Correlate with immediate downstream verdict + downstream issue mentions
  - Weight by confidence (more data = higher confidence)
  - Start with simple heuristics, refine over time

### 3. **Sample Size Problem**
- **Issue**: Only 6 visible reports currently; patterns may be overfitted
- **Solution**: Design system to accumulate data over time
  - Store skill metrics in SQLite (report_cache table)
  - Require minimum N reports (e.g., N=3) before extracting a skill
  - Periodically re-score skills as more data arrives
  - Track confidence intervals

### 4. **False Positives in Pattern Extraction**
- **Issue**: Common phrases may not be causal (e.g., "important" appears everywhere but isn't a skill)
- **Solution**: Focus on structural patterns, not word frequency
  - Detect: presence of code blocks (indicates examples)
  - Detect: list depth (nested structure indicates organization)
  - Detect: section completeness (did explorer cover all 5 sections?)
  - Weight: structural patterns > keyword frequency

### 5. **Timestamp/Metadata Correlation**
- **Issue**: Reports are timestamped (.../EXPLORER_REPORT.2026-03-12T15-41-10-872Z.md), but linking to seed metadata requires parsing .seeds/issues.jsonl
- **Solution**:
  - Create utility function: `reportToSeed(reportPath): SeedInfo | null`
  - Parse timestamp from filename, match to seed creation time (approximate)
  - Store report-to-seed mapping in SQLite (report_cache table)

### 6. **Storage & Query Performance**
- **Issue**: Scanning disk reports is slow; mining repeatedly is expensive
- **Solution**: Build report cache in SQLite
  - New table: `report_cache (id, report_path, parsed_sections JSON, metrics JSON, cached_at)`
  - CLI command checks cache before re-parsing
  - Cache invalidates if report file mtime changed
  - `mine-skills` command uses cache for fast aggregation

### 7. **Report Absence**
- **Issue**: Some runs may fail before producing reports (agent crash, timeout)
- **Solution**: Handle gracefully
  - Skip missing reports without error
  - Track report availability as metric ("6 of 10 runs produced explorer reports")
  - Don't correlate skills from incomplete pipelines

---

## Files to Modify/Create

### New Files (Core Implementation)

1. **src/orchestrator/report-analyzer.ts** (~150 lines)
   - `ReportAnalyzer` class with parsing/metric methods
   - Report structure detection (sections, verdict, issues)
   - Metric calculation (completeness, section depth, etc.)
   - Pattern extraction (for Phase 2)

2. **src/cli/commands/mine-skills.ts** (~80 lines)
   - CLI command entry point
   - Option parsing (--project, --output)
   - Invokes ReportAnalyzer, formats output
   - Implements `mine-skills` command

3. **src/orchestrator/__tests__/report-analyzer.test.ts** (~120 lines)
   - Test fixture reports (sample markdown files)
   - Unit tests for parsing, metric calculation
   - Test edge cases (missing sections, variant formats)

4. **src/orchestrator/skill-library.ts** (~100 lines, Phase 3 only)
   - Skill registry data structure
   - Query interface
   - Scoring/ranking functions

### Modified Files

1. **src/orchestrator/types.ts**
   - Add `Skill` interface (lines ~153)
   - Add `ReportMetrics` interface
   - Add `SkillMiningResult` interface

2. **src/cli/index.ts**
   - Import and register `mineSkillsCommand` (lines 5, 33)
   - Add to program: `program.addCommand(mineSkillsCommand)`

3. **src/lib/store.ts** (optional, Phase 1.4)
   - Add schema for report_cache table (optional, for caching)
   - Methods: `cacheReport()`, `getReportCache()`, `invalidateReportCache()`

4. **package.json**
   - No new dependencies needed (use existing Node fs, JSON APIs)

---

## Next Steps for Developer

1. **Design Phase 1 Implementation**:
   - Write `ReportAnalyzer` class structure
   - Define regex patterns for section extraction
   - Implement metric calculation functions
   - Create CLI command skeleton

2. **Build Test Fixtures**:
   - Create sample report markdown files in test directory
   - Include edge cases: missing sections, variant formats, bonus sections
   - Use actual past reports as reference

3. **Implement Phase 1**:
   - Parse reports (scan directories, extract sections)
   - Calculate metrics (completeness, verdict distribution, issue counts)
   - Output JSON or table format
   - Verify against actual reports in worktree

4. **Add to CLI**:
   - Wire up `mine-skills` command
   - Test with `foreman mine-skills --help`
   - Test with `foreman mine-skills --output json > skills.json`

5. **Write Tests**:
   - Unit tests for all ReportAnalyzer methods
   - Integration test: scan actual reports, verify output
   - Edge case tests for malformed reports

6. **Document**:
   - Add section to README about skill mining feature
   - Examples of skill patterns extracted
   - Future work (Phase 2 & 3)

7. **Phase 2 (if time)**:
   - Extend with pattern extraction logic
   - Analyze successful reports, identify techniques
   - Build skill registry

---

## Summary of Key Insights

✅ **System is well-architected** for skill mining:
- Clear separation of concerns (roles, agent-worker, store)
- Consistent report format across all roles
- Structured report parsing already in place (`parseVerdict`, `extractIssues`)

✅ **Historical data exists**:
- 6+ timestamped reports from past runs
- Mix of successful (PASS) and failed (FAIL) outcomes
- Good variety of task types (architecture analysis, bug fixes, feature implementation)

✅ **No external dependencies needed**:
- Existing Node.js fs, path, and JSON APIs sufficient
- No need for additional npm packages
- Can start simple with Phase 1 (metrics) without impacting agent pipeline

✅ **Clear extension points**:
- Skill type can be added to types.ts
- Report cache can extend store.ts schema
- New command follows existing CLI pattern
- Tests follow existing Vitest structure

⚠️ **Considerations**:
- Phase 2+ requires careful design to avoid false positives
- Success metrics must account for external factors (task complexity, model capability)
- A/B testing needed before injecting skills into prompts (Phase 3)
