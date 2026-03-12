# Explorer Report: Skill mining from past agent sessions

## Summary

Foreman orchestrates AI agents through a structured pipeline (Explorer → Developer → QA → Reviewer). Each phase produces timestamped reports that communicate findings and decisions. **Skill mining** is the process of analyzing these past reports to extract reusable patterns, best practices, and effective strategies that can improve future agent implementations and prompt engineering.

The codebase currently has:
- A hardcoded prompt system in `roles.ts` with role-specific instructions
- Multiple timestamped reports from past successful runs (6 reports currently visible)
- No existing infrastructure to analyze or mine patterns from these reports
- Opportunity to create a skill extraction system that identifies and formalizes effective techniques

## Relevant Files

### Core Agent Pipeline Files

1. **src/orchestrator/roles.ts** (lines 50-249)
   - **Purpose**: Defines role configurations and prompt templates for Explorer, Developer, QA, and Reviewer
   - **Current State**: Contains hardcoded prompts (`explorerPrompt()`, `developerPrompt()`, `qaPrompt()`, `reviewerPrompt()`) and role configs with budget limits
   - **Relevance**: Primary source for understanding what agents are instructed to do and report. This is where future skill-based prompts would integrate
   - **Pattern**: Each role has explicit instructions, expected report sections, and rules (read-only, write-only, etc.)

2. **src/orchestrator/agent-worker.ts** (lines 1-150+)
   - **Purpose**: Standalone worker process that executes each pipeline phase (explorer, developer, qa, reviewer) as separate SDK sessions
   - **Current State**: Runs `runPhase()` for each role, handles report parsing with `parseVerdict()`, `extractIssues()`, and handles feedback loops (QA → Developer retry)
   - **Relevance**: Where reports are parsed and used to make decisions (e.g., if QA returns FAIL, trigger developer feedback loop)
   - **Pipeline Flow**: Lines 99-150 show sequential phase execution with feedback loops

3. **src/orchestrator/types.ts** (approx 3.7kb)
   - **Purpose**: TypeScript type definitions for agent roles, models, and task structures
   - **Relevance**: Defines `AgentRole` type (explorer, developer, qa, reviewer, lead, worker) and other foundational types

### Report Examples (Past Sessions)

Past agent reports exist as timestamped files:
- `EXPLORER_REPORT.2026-03-12T15-39-43-331Z.md` — 166 lines, thorough analysis of maxTurns→maxBudgetUsd migration
- `DEVELOPER_REPORT.md` — Summary of implementation with files changed, decisions, and trade-offs
- `QA_REPORT.md` — Test results (246 passed, 9 pre-existing failures), test coverage verification
- Multiple QA/Developer reports with timestamps showing iteration cycles

**Pattern Observed**: Successful reports include:
- Relevant Files section with specific paths and line numbers
- Architecture & Patterns section identifying code conventions
- Dependencies section mapping imports and dependents
- Existing Tests section identifying test coverage
- Recommended Approach with step-by-step implementation plan and pitfalls

### Report Generation System

1. **src/orchestrator/templates.ts** (lines 12-45)
   - **Purpose**: Generates TASK.md content placed in each worker worktree
   - **Relevance**: Provides context to all agents about the task structure and agent team roles

2. **src/cli/index.ts** (lines 1-35)
   - **Purpose**: CLI entry point with 10 commands
   - **Relevance**: No skill-mining command yet; would need to add `mineskills` or similar command

### Data Storage

1. **src/lib/store.ts** (16kb)
   - **Purpose**: SQLite state store for projects, runs, costs, events
   - **Relevance**: Stores run metadata (worktree paths, models, costs, timestamps) but not report analysis/mining data

2. **.seeds/issues.jsonl** (git-tracked task database)
   - **Purpose**: Seeds (sd) task tracking with dependencies
   - **Relevance**: Tracks which agents completed which tasks, enabling correlation with report quality

## Architecture & Patterns

### Agent Pipeline Architecture

```
Explorer (Read-only, Haiku)
  ↓ writes EXPLORER_REPORT.md
Developer (Read-write, Sonnet)
  ↓ reads EXPLORER_REPORT.md, writes DEVELOPER_REPORT.md
QA (Read-write, Sonnet)
  ↓ reads DEVELOPER_REPORT.md, writes QA_REPORT.md
  [If FAIL, feedback loop back to Developer]
Reviewer (Read-only, Sonnet)
  ↓ reads all reports, writes REVIEW.md
```

### Report Communication Protocol

Reports serve as the **primary inter-agent communication mechanism**:
- **EXPLORER_REPORT.md** → Input for Developer
- **DEVELOPER_REPORT.md** → Input for QA
- **QA_REPORT.md** → Input for Reviewer, triggers Developer feedback if FAIL verdict
- **REVIEW.md** → Final quality gate (PASS/FAIL verdict, issue list with severity levels)

### Prompt Template Pattern

Each role's prompt follows a consistent structure:
1. **Role definition** ("You are an Explorer…")
2. **Task context** (seed ID, title, description)
3. **Instructions** (numbered steps, what to read/write)
4. **Output format specification** (markdown template with sections)
5. **Rules** (constraints, dos and don'ts)

Example (Explorer prompt, lines 50-95 of roles.ts):
- Instruction to read TASK.md
- Instruction to explore codebase (files, patterns, dependencies, tests)
- Explicit EXPLORER_REPORT.md format with 5 required sections
- Rules: read-only, no source file modifications, focus on understanding

### Verdict & Issue Parsing

- `parseVerdict()` (line 259) — Extracts PASS/FAIL from "## Verdict:" heading
- `extractIssues()` (line 268) — Extracts issue list between "## Issues" and next heading
- `hasActionableIssues()` (line 278) — Checks for CRITICAL/WARNING/NOTE markers
- Used to gate progression (developer re-runs on QA FAIL, reviewer blocks on CRITICAL issues)

## Dependencies

### What Uses Report Structure

1. **agent-worker.ts** (`runPhase()` function):
   - Calls `query()` with phase-specific prompt from `roles.ts`
   - After phase completes, parses report file for verdict
   - Uses `parseVerdict()`, `extractIssues()` to read results
   - Passes feedback context to developer if QA FAIL

2. **dispatcher.ts**:
   - Creates worktrees and writes TASK.md via `workerAgentMd()` from templates.ts
   - Records runs in SQLite store with metadata (worktree path, model, budget)

3. **roles.ts** (exports):
   - `explorerPrompt()`, `developerPrompt()`, `qaPrompt()`, `reviewerPrompt()` — exported to agent-worker.ts
   - `ROLE_CONFIGS` — role metadata (model, budget, report filename)
   - `parseVerdict()`, `extractIssues()` — exported to agent-worker.ts for report parsing

### What Depends on Report Files

- **agent-worker.ts**: Reads reports from disk to determine next phase behavior
- **lead-prompt.ts**: References report filenames in lead orchestrator prompt
- **Future skill-mining system**: Would read reports from `.foreman-worktrees/*/` directories

## Existing Tests

### Test Files for Agent Pipeline

1. **src/orchestrator/__tests__/roles.test.ts**
   - **Tests**: Role config structure, prompt templates, verdict parsing, issue extraction
   - **Coverage**: Verifies all roles are defined, models correct, budgets are positive, parseVerdict/extractIssues work correctly
   - **Relevant lines**: Tests for `ROLE_CONFIGS` completeness, verdict parsing with PASS/FAIL/unknown cases, issue extraction

2. **src/orchestrator/__tests__/agent-worker.test.ts**
   - **Tests**: Worker initialization, config file handling, phase execution flow
   - **Coverage**: Verifies worker starts, logs correctly, cleans up temp files
   - **Note**: No tests directly verify report content or parsing feedback loops

3. **src/orchestrator/__tests__/agent-worker-team.test.ts**
   - **Tests**: Team-based orchestration (if applicable to multi-phase)
   - **Status**: Likely tests pipeline coordination

### Test Gap

- **No tests for skill extraction or pattern mining** — This is new functionality
- **No tests for report quality metrics** — Opportunity to add metrics for analyzing report effectiveness
- **No integration tests** — End-to-end verification of report generation and feedback loops

## Recommended Approach

### Phase 1: Analysis & Metrics (Understanding)

1. **Create a report analyzer module** (`src/orchestrator/report-analyzer.ts`):
   - Scan `.foreman-worktrees/*/` for timestamped report files
   - Parse report structure (extract sections, identify patterns)
   - Build metrics: report completeness, section quality, formatting consistency
   - Track which reports correlated with PASS/FAIL verdicts downstream

2. **Define "skill" structure** (`src/orchestrator/types.ts` addition):
   - Skill: {name, category, pattern, frequency, successRate, sourceReports}
   - Categories: exploration-techniques, implementation-patterns, test-strategies, review-criteria
   - Pattern: extracted prompt snippet or behavioral pattern

3. **Add skill mining command** (`src/cli/commands/mine-skills.ts`):
   - Command: `foreman mine-skills [--project]`
   - Scans reports, builds skill database
   - Output: JSON file with extracted skills, or summary table

### Phase 2: Pattern Extraction (Mining)

1. **Analyze Explorer reports**:
   - Extract common file-finding strategies (glob patterns, directory conventions)
   - Identify effective architecture analysis patterns (module identification, pattern recognition)
   - Extract dependency mapping techniques
   - Success metric: How many upstream tasks referenced this explorer's files?

2. **Analyze Developer reports**:
   - Extract code organization patterns (file grouping, structure decisions)
   - Identify test coverage strategies
   - Extract implementation sequencing decisions
   - Success metric: How many downstream QA tests passed on first try?

3. **Analyze QA reports**:
   - Extract test identification strategies (what triggers new tests)
   - Identify regression detection techniques
   - Extract edge case discovery patterns
   - Success metric: How many issues caught vs. developers missed?

4. **Analyze Reviewer reports**:
   - Extract code quality checks (security, performance, maintainability)
   - Identify risk assessment patterns
   - Extract feedback prioritization (CRITICAL vs. WARNING vs. NOTE)
   - Success metric: How many issues caught vs. merged anyway?

### Phase 3: Formalization & Integration (Optional)

1. **Create skill library** (`src/orchestrator/skill-library.ts`):
   - Registry of mined skills with success metrics
   - Ability to query skills by category/phase
   - Integration hooks for role-based prompt enhancement

2. **Enhance role prompts**:
   - Optionally inject top-performing skill patterns into agent prompts
   - A/B test: baseline vs. skill-enhanced prompts
   - Track which skill injections improve report quality

3. **Build dashboard integration**:
   - Display mined skills per project/role
   - Show skill effectiveness metrics
   - Enable skill selection per task

### Implementation Order

1. **First (Simplest)**: Build report analyzer + metrics
   - Scans existing reports, computes statistics
   - No changes to agent pipeline
   - Output: JSON file with insight
   - Enables human review of patterns

2. **Second**: Pattern extractor for each role
   - Identifies recurring phrases, structures in successful reports
   - Groups patterns by effectiveness
   - Output: skill registry JSON

3. **Third (Optional)**: Integration with prompts
   - Dynamically enhance prompts with effective patterns
   - Requires careful testing to avoid confusing agents

## Potential Pitfalls & Edge Cases

### 1. **Report Variability**
- Reports vary in format/detail depending on complexity
- Some reports have bonus sections (Known Limitations, Positive Notes)
- Solution: Parse flexible templates, handle optional sections

### 2. **Success Metric Ambiguity**
- How do we know if a skill was "good"? (subsequent agent success, verdict, density of insights?)
- Downstream agents might succeed for reasons unrelated to explorer's skill
- Solution: Correlate with immediate downstream verdict + downstream issue mentions

### 3. **Sample Size**
- Only 6 visible reports currently
- Patterns may be overfitted to these specific tasks
- Solution: Design system to accumulate data over time; require minimum N reports before extracting skills

### 4. **False Positives in Pattern Extraction**
- Common phrases may not be causal (e.g., "important" appears in many reports, but isn't a skill)
- Solution: Focus on structural patterns (sections, code blocks, lists) over word frequency

### 5. **Timestamp/Metadata Correlation**
- Reports are timestamped, but linking to seed metadata requires parsing `.seeds/issues.jsonl`
- Solution: Enhance store.ts or create report-to-seed mapping utility

### 6. **Storage & Query Performance**
- Scanning disk reports is slow; mining repeatedly is expensive
- Solution: Build a report cache in SQLite (once reports are analyzed, cache metadata)

## Files to Modify/Create

### New Files (for skill mining system)

1. **src/orchestrator/report-analyzer.ts** — Core analyzer
2. **src/cli/commands/mine-skills.ts** — CLI command
3. **src/orchestrator/skill-library.ts** — Skill registry (Phase 3)
4. **tests for each** — Comprehensive unit tests

### Modified Files

1. **src/orchestrator/types.ts** — Add Skill type definition
2. **src/lib/store.ts** — Optional: add skill storage tables
3. **src/cli/index.ts** — Register mine-skills command
4. **package.json** — No new dependencies needed (use existing Node fs, JSON APIs)

## Next Steps for Developer

1. **Design the Skill structure** — Define what a "skill" record contains (name, category, pattern, frequency, successRate, reports)
2. **Build ReportAnalyzer** — Scan worktree reports, parse structure, extract basic metrics (section completeness, verdict distribution)
3. **Implement pattern extraction** — Design algorithms for identifying recurring techniques per role (heuristic: code block presence, section depth, list item patterns)
4. **Create mine-skills command** — Wire up CLI to invoke analyzer and output results
5. **Add tests** — Verify analyzer correctly identifies patterns in test fixture reports
6. **Consider Phase 3** — Evaluate if skill injection into prompts makes sense (A/B testing required)
