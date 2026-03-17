# TRD: Sling-TRD Command

**Document ID:** TRD-SLING-TRD
**Version:** 1.0
**Created:** 2026-03-13
**Last Updated:** 2026-03-13
**PRD Reference:** PRD-SLING-TRD v1.2
**Status:** Implementation Ready

---

## 1. System Architecture

### 1.1 Architecture Overview

The sling-trd system introduces four new modules that convert a structured TRD markdown document into task hierarchies in both seeds (sd) and beads_rust (br) tracking systems. It replaces the retired `decompose` command with a purpose-built table parser, dual-tracker executor, and sprint parallelization analyzer.

```
foreman sling trd <file> (CLI)
  |
  v
TrdParser (deterministic markdown table parser)
  |-- parseEpic(): H1 title + frontmatter metadata
  |-- parseSprints(): H3 sections → sprint objects
  |-- parseStories(): H4 sections → story objects with FR mapping
  |-- parseTasks(): auto-detect table columns, extract rows
  |-- parseAcceptanceCriteria(): Section 5 → FR-keyed AC map
  |-- parseRiskRegister(): Section 7 → task ID → risk level map
  |-- parseQualityRequirements(): Section 6 → text block
  |-- parseSprintSummary(): Section 3 → sprint metadata map
  |
  v
SprintParallelAnalyzer (dependency graph analysis)
  |-- buildSprintDepGraph(): task-level cross-sprint deps → sprint DAG
  |-- computeParallelGroups(): independent sets via topological layers
  |-- parseTrdParallelNotes(): Section 4 text → stated parallel groups
  |-- validate(): compare auto-computed vs TRD-stated, warn on discrepancy
  |
  v
SlingExecutor (dual-write execution engine)
  |-- detectExistingEpic(): search by trd:<doc-id> label
  |-- executeForTracker(): sequential hierarchy creation
  |-- wireDependencies(): TRD task ID → tracker issue ID lookup
  |-- handleCompletedTasks(): skip/close/open logic
  |
  v
SeedsClient (existing)     BeadsRustClient (new, mirrors SeedsClient)
  |-- create()               |-- create()
  |-- close()                |-- close()
  |-- addDependency()        |-- addDependency()
  |-- list()                 |-- list()
  |-- update()               |-- update()
  |-- search()               |-- search()
```

### 1.2 New Module Structure

| File | Purpose | Dependencies |
|------|---------|-------------|
| `src/cli/commands/sling.ts` | Parent `sling` command with `trd` subcommand, CLI option parsing, preview display, progress spinner | `trd-parser.ts`, `sling-executor.ts` |
| `src/orchestrator/trd-parser.ts` | Deterministic TRD markdown parser: tables, hierarchy, ACs, risks, quality, sprint summary | — (pure functions, no side effects) |
| `src/orchestrator/sprint-parallel.ts` | Sprint-level parallelization: dep graph, independent sets, TRD validation | `trd-parser.ts` (types only) |
| `src/orchestrator/sling-executor.ts` | Dual-write engine: sequential creation, dep wiring, idempotency, completed task handling | `seeds.ts`, `beads-rust.ts`, `trd-parser.ts` |
| `src/lib/beads-rust.ts` | br CLI wrapper: typed methods mirroring SeedsClient | — (shells out to `br` binary) |

### 1.3 Data Flow

```
TRD File (markdown)
  │
  ├──▶ TrdParser.parse(content) → SlingPlan
  │     │
  │     ├── epic: { title, description, documentId, qualityNotes }
  │     ├── sprints: [{ title, goal, priority, summary, stories: [...] }]
  │     ├── acceptanceCriteria: Map<frNumber, AC[]>
  │     ├── riskMap: Map<taskId, riskLevel>
  │     └── sprintSummary: Map<sprintNum, { focus, hours, deliverables }>
  │
  ├──▶ SprintParallelAnalyzer.analyze(plan) → ParallelResult
  │     │
  │     ├── parallelGroups: [{ label, sprintIndices }]
  │     └── warnings: string[]
  │
  └──▶ SlingExecutor.execute(plan, parallelResult, options) → SlingResult
        │
        ├── sd: { created, skipped, failed, epicId }
        ├── br: { created, skipped, failed, epicId }
        └── depErrors: string[]
```

### 1.4 Type Definitions

```typescript
// ── TRD Parser types ──────────────────────────────────────────────────

interface TrdTask {
  trdId: string;              // e.g., "MQ-T001"
  title: string;              // Task description
  estimateHours: number;      // Parsed from "3h" → 3
  dependencies: string[];     // TRD task IDs: ["MQ-T001", "MQ-T012"]
  files: string[];            // ["src/orchestrator/refinery.ts"]
  status: "open" | "in_progress" | "completed";
  riskLevel?: "high" | "medium";  // From risk register
}

interface TrdStory {
  title: string;              // "Auto-Commit State Files Before Merge"
  frNumber?: string;          // "FR-1" if detectable from sprint header
  tasks: TrdTask[];
  acceptanceCriteria?: string;  // ACs matched by FR number
}

interface TrdSprint {
  number: number;             // Sprint ordinal (1, 2, 3a, 3b, ...)
  title: string;              // "Sprint 1: Foundation"
  goal: string;               // From header suffix or summary table
  priority: Priority;         // Parsed from header or ordinal fallback
  stories: TrdStory[];
  summary?: {
    focus: string;
    estimatedHours: number;
    deliverables: string;
  };
}

interface SlingPlan {
  epic: {
    title: string;
    description: string;
    documentId: string;       // "TRD-MERGE-QUEUE"
    qualityNotes?: string;    // Section 6 content
  };
  sprints: TrdSprint[];
  acceptanceCriteria: Map<string, string>;  // FR number → AC text
  riskMap: Map<string, "high" | "medium">;  // task ID → risk level
}

// ── Parallel Analysis types ───────────────────────────────────────────

interface ParallelGroup {
  label: string;              // "A", "B", etc.
  sprintIndices: number[];    // Indices into SlingPlan.sprints[]
}

interface ParallelResult {
  groups: ParallelGroup[];
  warnings: string[];         // Discrepancies between auto-computed and TRD-stated
}

// ── Execution types ───────────────────────────────────────────────────

interface SlingOptions {
  dryRun: boolean;
  auto: boolean;
  json: boolean;
  sdOnly: boolean;
  brOnly: boolean;
  skipCompleted: boolean;
  closeCompleted: boolean;
  noParallel: boolean;
  force: boolean;
  noRisks: boolean;
  noQuality: boolean;
  priorityMap?: Record<string, string>;
}

interface TrackerResult {
  created: number;
  skipped: number;
  failed: number;
  epicId: string | null;
  errors: string[];
}

interface SlingResult {
  sd: TrackerResult | null;   // null if --br-only
  br: TrackerResult | null;   // null if --sd-only
  depErrors: string[];
}

// ── BeadsRust Client types ────────────────────────────────────────────

interface BrIssue {
  id: string;
  title: string;
  type: string;
  priority: string;
  status: string;
  assignee: string | null;
  parent: string | null;
  created_at: string;
  updated_at: string;
}

interface BrIssueDetail extends BrIssue {
  description: string | null;
  labels: string[];
  estimate_minutes: number | null;
  dependencies: string[];
  children: string[];
}
```

### 1.5 Integration Points

| Integration | Direction | Mechanism |
|------------|-----------|-----------|
| CLI → TrdParser | Internal | `parseTrd(content)` returns `SlingPlan` |
| CLI → SprintParallelAnalyzer | Internal | `analyze(plan)` returns `ParallelResult` |
| CLI → SlingExecutor | Internal | `execute(plan, parallel, options)` returns `SlingResult` |
| SlingExecutor → SeedsClient | Outbound | Existing `seeds.ts` methods: `create()`, `close()`, `addDependency()`, `list()` |
| SlingExecutor → BeadsRustClient | Outbound | New `beads-rust.ts` methods mirroring SeedsClient |
| SlingExecutor → sd CLI | Outbound | Via SeedsClient (shells out to `~/.bun/bin/sd`) |
| SlingExecutor → br CLI | Outbound | Via BeadsRustClient (shells out to `~/.local/bin/br`) |

### 1.6 Error Code System

All sling errors use structured codes `SLING-001` through `SLING-012`. Error codes appear in:
- CLI stderr output
- SlingResult error arrays
- JSON output (when `--json` used)

---

## 2. Master Task List

### Legend

- `[ ]` Not started
- `[~]` In progress
- `[x]` Completed

### 2.1 Sprint 1: Foundation — BeadsRust Client + Types

#### Story 1.1: BeadsRust CLI Wrapper

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T001 | Implement `BeadsRustClient` class with `create()`, `close()`, `update()`, `addDependency()`, `list()`, `search()` methods. Mirror SeedsClient pattern: shell out to `br` binary with `--json` flag, parse JSON responses. Include `ensureBrInstalled()` and `isInitialized()` checks | 4h | -- | `src/lib/beads-rust.ts` | [ ] |
| SL-T002 | Implement `execBr()` low-level helper function. Handle `br` CLI JSON envelope unwrapping (br returns `{ id, title, ... }` directly, not wrapped like sd). Include error handling for non-zero exit codes | 2h | -- | `src/lib/beads-rust.ts` | [ ] |
| SL-T003 | Write unit tests for BeadsRustClient — mock `execFile` calls, verify argument construction, JSON parsing, error handling, missing binary detection | 4h | SL-T001, SL-T002 | `src/lib/__tests__/beads-rust.test.ts` | [ ] |

#### Story 1.2: Sling Type Definitions

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T004 | Define `TrdTask`, `TrdStory`, `TrdSprint`, `SlingPlan`, `ParallelGroup`, `ParallelResult`, `SlingOptions`, `TrackerResult`, `SlingResult` types. Export from types.ts | 2h | -- | `src/orchestrator/types.ts` | [ ] |
| SL-T005 | Define `BrIssue`, `BrIssueDetail` interfaces in beads-rust.ts matching br CLI JSON output format | 1h | SL-T001 | `src/lib/beads-rust.ts` | [ ] |

### 2.2 Sprint 2: TRD Table Parser (FR-1)

#### Story 2.1: Core Table Parser

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T006 | Implement `parseTableHeader()` — auto-detect column names from markdown table header row. Match by name (case-insensitive): ID, Task, Est./Estimate, Deps/Dependencies, Files, Status/Done. Return column index map. Require ID and Task columns; others optional | 3h | -- | `src/orchestrator/trd-parser.ts` | [ ] |
| SL-T007 | Implement `parseTableRow()` — extract cell values from a pipe-delimited markdown table row using the column index map. Handle backtick-delimited file paths, `--` as empty deps, `[x]`/`[~]`/`[ ]` status parsing, `3h` → 3 estimate parsing, comma-separated dep IDs | 3h | SL-T006 | `src/orchestrator/trd-parser.ts` | [ ] |
| SL-T008 | Implement `parseEpic()` — extract H1 title, frontmatter metadata (Document ID, Version, Epic ID), and description text between H1 and first H2 | 2h | -- | `src/orchestrator/trd-parser.ts` | [ ] |
| SL-T009 | Implement `parseSprints()` — identify H3 sections matching `### X.Y Sprint N: <Name>`. Extract sprint number (handle sub-sprints like "3a", "3b"), title, and goal from header suffix. Parse priority from header text (e.g., "P1 - Critical") with ordinal fallback | 3h | -- | `src/orchestrator/trd-parser.ts` | [ ] |
| SL-T010 | Implement `parseStories()` — identify H4 sections matching `#### Story N.M: <Title>`. Detect FR references from parent sprint header (e.g., "(FR-2, FR-4)"). Collect all table rows within the story section as tasks | 2h | SL-T006, SL-T007 | `src/orchestrator/trd-parser.ts` | [ ] |
| SL-T011 | Implement top-level `parseTrd(content: string): SlingPlan` — orchestrate all sub-parsers, assemble the full plan. Validate at least one task extracted (SLING-002). Warn on missing sections | 2h | SL-T006 through SL-T010 | `src/orchestrator/trd-parser.ts` | [ ] |
| SL-T012 | Write unit tests for core table parser — auto-detect columns (standard order, reordered, missing optional), row parsing (estimates, deps, files, status), `--` handling, multi-line descriptions | 5h | SL-T006 through SL-T011 | `src/orchestrator/__tests__/trd-parser.test.ts` | [ ] |

#### Story 2.2: Metadata Parsers

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T013 | Implement `parseAcceptanceCriteria()` — parse Section 5, identify subsections by `### 5.X FR-N:` pattern, extract AC items (lines starting with `- [ ]` or `- AC-`), return `Map<frNumber, acText>` | 3h | -- | `src/orchestrator/trd-parser.ts` | [ ] |
| SL-T014 | Implement `parseRiskRegister()` — parse Section 7 table rows. Extract risk level (Likelihood × Impact → high/medium), task IDs from "Tasks Affected" column. Return `Map<taskId, riskLevel>` | 2h | -- | `src/orchestrator/trd-parser.ts` | [ ] |
| SL-T015 | Implement `parseQualityRequirements()` — extract Section 6 content as a text block for epic notes | 1h | -- | `src/orchestrator/trd-parser.ts` | [ ] |
| SL-T016 | Implement `parseSprintSummary()` — parse Section 3 "Sprint Planning Summary" table. Extract focus, est. hours, and key deliverables per sprint. Return `Map<sprintNum, summary>` | 2h | -- | `src/orchestrator/trd-parser.ts` | [ ] |
| SL-T017 | Write unit tests for metadata parsers — AC matching by FR number, risk register parsing, quality requirements extraction, sprint summary extraction. Test with merge-queue.md as fixture | 4h | SL-T013 through SL-T016 | `src/orchestrator/__tests__/trd-parser-metadata.test.ts` | [ ] |

#### Story 2.3: Integration Test with Real TRD

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T018 | Write integration test that parses docs/TRD/merge-queue.md end-to-end and validates: 79 tasks, 9 sprints, ~23 stories, correct dep chains, AC extraction, risk map, sprint summaries | 3h | SL-T011 through SL-T016 | `src/orchestrator/__tests__/trd-parser-integration.test.ts` | [ ] |

### 2.3 Sprint 3: Sprint Parallelization (FR-4)

#### Story 3.1: Parallel Sprint Detection

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T019 | Implement `buildSprintDepGraph()` — iterate all tasks, collect cross-sprint deps (task in sprint X depends on task in sprint Y → sprint X depends on sprint Y). Build adjacency list | 2h | SL-T004 | `src/orchestrator/sprint-parallel.ts` | [ ] |
| SL-T020 | Implement `computeParallelGroups()` — perform topological sort on sprint DAG. Sprints at the same topological level with no edges between them form a parallel group. Label groups A, B, C, etc. | 3h | SL-T019 | `src/orchestrator/sprint-parallel.ts` | [ ] |
| SL-T021 | Implement `parseTrdParallelNotes()` — scan Section 4 "Dependency Graph" and any "Parallelization Opportunities" subsection for sprint parallelization statements. Extract stated parallel pairs | 2h | -- | `src/orchestrator/sprint-parallel.ts` | [ ] |
| SL-T022 | Implement `validate()` — compare auto-computed groups against TRD-stated groups. Return warnings for discrepancies (e.g., "Auto-computed: Sprint 5 and 6 are NOT parallel due to MQ-T049→MQ-T018; TRD states they are parallel") | 2h | SL-T020, SL-T021 | `src/orchestrator/sprint-parallel.ts` | [ ] |
| SL-T023 | Implement top-level `analyzeParallel(plan: SlingPlan): ParallelResult` orchestrator | 1h | SL-T019 through SL-T022 | `src/orchestrator/sprint-parallel.ts` | [ ] |
| SL-T024 | Write tests for sprint parallelization — merge-queue.md yields Sprints 5+6 parallel and 7+8 parallel, cross-dep sprints excluded, validation warns on discrepancy, empty graph, single sprint | 4h | SL-T023 | `src/orchestrator/__tests__/sprint-parallel.test.ts` | [ ] |

### 2.4 Sprint 4: Dual-Write Executor (FR-2, FR-3, FR-6, FR-7)

#### Story 4.1: Core Execution Engine

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T025 | Implement `detectExistingEpic()` — search sd (via `sd list --labels trd:<doc-id>`) and br (via `br list --label trd:<doc-id>`) for existing epic. Return epic IDs if found. SLING-009 on duplicate | 3h | SL-T001, SL-T004 | `src/orchestrator/sling-executor.ts` | [ ] |
| SL-T026 | Implement `executeForTracker()` — sequential creation of epic → sprints → stories → tasks for a single tracker (sd or br). Build `trdIdToTrackerId` lookup map during creation. Apply labels: `trd:<ID>`, `kind:sprint/story/test/spike`, `est:<N>h`, `parallel:<group>`, `risk:<level>`. Use `--parent` for hierarchy. Emit progress callbacks for spinner | 5h | SL-T025, SL-T004 | `src/orchestrator/sling-executor.ts` | [ ] |
| SL-T027 | Implement type/priority mapping — `toSeedsType()`, `toSeedsPriority()`, `toBrType()`, `toBrPriority()` in sling-executor.ts (br accepts same type names as sd). Handle task type inference from title: "test" → kind:test, "spike" → kind:spike | 2h | -- | `src/orchestrator/sling-executor.ts` | [ ] |
| SL-T028 | Implement `wireDependencies()` — second pass after all issues created. For each task with deps, look up `trdIdToTrackerId` map, call `addDependency()`. Warn on missing targets (SLING-007). Detect cycles (SLING-008) | 3h | SL-T026 | `src/orchestrator/sling-executor.ts` | [ ] |

#### Story 4.2: Completed Task Handling

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T029 | Implement completed task handling in `executeForTracker()`: default creates all as open; `--skip-completed` filters out `[x]` tasks (and containers where all children completed); `--close-completed` creates then immediately calls `close()` | 3h | SL-T026 | `src/orchestrator/sling-executor.ts` | [ ] |
| SL-T030 | Handle dependency drops when skipping completed tasks — if a dep target was skipped, silently drop that dependency (no error). Track dropped deps in result | 2h | SL-T028, SL-T029 | `src/orchestrator/sling-executor.ts` | [ ] |

#### Story 4.3: Idempotency

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T031 | Implement idempotency check — before creating each issue, search tracker for existing `trd:<ID>` label. If found, skip (or recreate with `--force`). Track skipped count in result | 3h | SL-T026 | `src/orchestrator/sling-executor.ts` | [ ] |
| SL-T032 | Implement `--force` re-creation — when force flag set, skip idempotency check. Note: does not delete existing issues, creates new ones (may result in duplicates; user should clean up manually) | 1h | SL-T031 | `src/orchestrator/sling-executor.ts` | [ ] |

#### Story 4.4: AC and Metadata Attachment

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T033 | Implement AC attachment — after story creation, look up ACs by FR number from the AC map. If found, update story's description/acceptance field via `update()`. If FR not matched, store on epic as fallback (SLING-012) | 2h | SL-T026, SL-T013 | `src/orchestrator/sling-executor.ts` | [ ] |
| SL-T034 | Implement risk label application — for each task in riskMap, add `risk:high` or `risk:medium` label during creation. Warn if task ID not found (SLING-011) | 1h | SL-T026, SL-T014 | `src/orchestrator/sling-executor.ts` | [ ] |
| SL-T035 | Implement quality notes — append Section 6 content to epic's description/notes field via `update()` after epic creation | 1h | SL-T026, SL-T015 | `src/orchestrator/sling-executor.ts` | [ ] |
| SL-T036 | Implement sprint summary — populate sprint issue description from Section 3 data (focus, hours, deliverables) | 1h | SL-T026, SL-T016 | `src/orchestrator/sling-executor.ts` | [ ] |

#### Story 4.5: Executor Tests

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T037 | Write unit tests for executor — mock SeedsClient and BeadsRustClient. Test: hierarchy creation order, label application, dep wiring, skip-completed, close-completed, idempotency, force, AC attachment, risk labels, quality notes, sprint summaries, progress callbacks | 6h | SL-T025 through SL-T036 | `src/orchestrator/__tests__/sling-executor.test.ts` | [ ] |
| SL-T038 | Write tests for error handling — SLING-003/004 (missing CLI graceful degradation), SLING-005 (neither available), SLING-006 (individual task failure continues batch), SLING-007 (missing dep target warning), SLING-008 (circular dep detection) | 4h | SL-T037 | `src/orchestrator/__tests__/sling-executor-errors.test.ts` | [ ] |

### 2.5 Sprint 5: CLI Command (FR-5) + Registration

#### Story 5.1: Sling Command

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T039 | Implement `sling` parent command with `trd` subcommand using commander.js. Parse all CLI options from PRD Section 6. Wire argument parsing to `SlingOptions` type | 3h | SL-T004 | `src/cli/commands/sling.ts` | [ ] |
| SL-T040 | Implement TRD file reading and validation — resolve path, check existence (SLING-001), read content, print summary (lines/chars), call `parseTrd()`, handle SLING-002 | 2h | SL-T011 | `src/cli/commands/sling.ts` | [ ] |
| SL-T041 | Implement preview display — `printSlingPlan()` function showing hierarchy with task counts, hour totals, completion status per sprint/story, parallel group visual grouping (║ prefix), TRD task IDs, dep chains (implemented in `src/cli/commands/sling.ts`) | 4h | SL-T011, SL-T023 | `src/cli/commands/sling.ts` | [ ] |
| SL-T042 | Implement `--json` output — serialize SlingPlan + ParallelResult to JSON. Validate output matches expected schema | 1h | SL-T041 | `src/cli/commands/sling.ts` | [ ] |
| SL-T043 | Implement confirmation prompt and `--auto` bypass — `confirm()` helper in `src/cli/commands/sling.ts` | 1h | SL-T041 | `src/cli/commands/sling.ts` | [ ] |
| SL-T044 | Implement spinner with counter progress UX — single-line spinner updating: `Creating tasks... 42/79 (sd: 42, br: 0)`. Use `readline.clearLine()` + `readline.cursorTo()` for in-place updates. Wire progress callbacks from executor | 3h | SL-T026 | `src/cli/commands/sling.ts` | [ ] |
| SL-T045 | Implement summary output — final report: "Created: X (sd: Y, br: Z), Skipped: N, Failed: M" with error details if any | 1h | SL-T044 | `src/cli/commands/sling.ts` | [ ] |
| SL-T046 | Wire CLI tracker availability checks — detect sd and br CLIs. Handle `--sd-only` and `--br-only` flags. Implement SLING-003, SLING-004, SLING-005 error handling | 2h | SL-T001, SL-T039 | `src/cli/commands/sling.ts` | [ ] |

#### Story 5.2: CLI Registration

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T047 | Register `sling` command in `src/cli/index.ts` — import and add to program | 1h | SL-T039 | `src/cli/index.ts` | [ ] |

#### Story 5.3: CLI Tests

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T048 | Write CLI integration tests — `sling trd --help` shows options, `--dry-run` shows preview without creating, `--json` outputs valid JSON, file not found error, `--sd-only`/`--br-only` flags, `--skip-completed`/`--close-completed` behavior | 5h | SL-T039 through SL-T047 | `src/cli/__tests__/sling.test.ts` | [ ] |

### 2.6 Sprint 6: Polish — End-to-End + Edge Cases

#### Story 6.1: End-to-End Integration Test

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T049 | Write end-to-end test that slins merge-queue.md TRD into mocked sd + br — verifies full pipeline: parse → parallel detect → execute → dep wire. Validates task counts, hierarchy depth, label correctness, parallel groups | 5h | SL-T048 | `src/orchestrator/__tests__/sling-e2e.test.ts` | [ ] |

#### Story 6.2: Edge Cases and Error Paths

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| SL-T050 | Write tests for idempotent re-run — first run creates all, second run skips all (trd:<ID> labels found) | 2h | SL-T031 | `src/orchestrator/__tests__/sling-idempotent.test.ts` | [ ] |
| SL-T051 | Write tests for malformed TRD — missing table headers, extra columns, empty tables, missing H1, no tasks found (SLING-002), partial sections | 3h | SL-T011 | `src/orchestrator/__tests__/trd-parser-edge.test.ts` | [ ] |
| SL-T052 | Write tests for single-tracker degradation — sd missing (SLING-003, continues with br), br missing (SLING-004, continues with sd), both missing (SLING-005, fatal) | 2h | SL-T046 | `src/cli/__tests__/sling-degradation.test.ts` | [ ] |

---

## 3. Sprint Planning Summary

| Sprint | Focus | Tasks | Est. Hours | Key Deliverables |
|--------|-------|-------|-----------|--------------------|
| 1 | Foundation | SL-T001 to SL-T005 | 13h | BeadsRustClient wrapper, type definitions |
| 2 | TRD Parser | SL-T006 to SL-T018 | 35h | Full TRD table parser with metadata extraction |
| 3 | Parallelization | SL-T019 to SL-T024 | 14h | Sprint-level parallel detection with validation |
| 4 | Dual-Write Executor | SL-T025 to SL-T038 | 37h | Sequential dual-write engine with idempotency |
| 5 | CLI Command | SL-T039 to SL-T048 | 23h | `foreman sling trd` command with preview + spinner |
| 6 | Polish | SL-T049 to SL-T052 | 12h | E2E tests, edge cases, degradation tests |

**Total: 52 tasks, ~134 estimated hours across 6 sprints**

### Parallelization Opportunities

- **Sprint 1**: Stories 1.1 (BeadsRustClient) and 1.2 (Types) can run in parallel
- **Sprint 2**: Stories 2.1 (Core Parser) and 2.2 (Metadata Parsers) can start in parallel since metadata parsers are independent of core table parsing
- **Sprint 3** and **Sprint 2 Story 2.3** (Integration Test) can overlap — integration test depends on Sprint 2 Stories 2.1+2.2 but not on Sprint 3
- **Sprint 5** and **Sprint 6** have a dependency — Sprint 6 tests depend on Sprint 5 CLI, so they must be sequential

---

## 4. Dependency Graph

```
Sprint 1 (Foundation)
  SL-T001 -> SL-T003
  SL-T002 -> SL-T003
  SL-T001 -> SL-T005
  SL-T004 (independent)

Sprint 2 (TRD Parser) -- depends on SL-T004 for types
  SL-T006 -> SL-T007 -> SL-T010 -> SL-T011 -> SL-T012
  SL-T008 -> SL-T011
  SL-T009 -> SL-T011
  SL-T013 -> SL-T017
  SL-T014 -> SL-T017
  SL-T015 -> SL-T017
  SL-T016 -> SL-T017
  SL-T011, SL-T013 through SL-T016 -> SL-T018

Sprint 3 (Parallelization) -- depends on SL-T004
  SL-T019 -> SL-T020 -> SL-T023 -> SL-T024
  SL-T021 -> SL-T022 -> SL-T023

Sprint 4 (Executor) -- depends on Sprint 1 + Sprint 2
  SL-T025 -> SL-T026 -> SL-T028 -> SL-T037
  SL-T026 -> SL-T029 -> SL-T030 -> SL-T037
  SL-T026 -> SL-T031 -> SL-T032 -> SL-T037
  SL-T026 -> SL-T033 -> SL-T037
  SL-T026 -> SL-T034 -> SL-T037
  SL-T026 -> SL-T035 -> SL-T037
  SL-T026 -> SL-T036 -> SL-T037
  SL-T027 -> SL-T026
  SL-T037 -> SL-T038

Sprint 5 (CLI) -- depends on Sprint 2 + Sprint 3 + Sprint 4
  SL-T039 -> SL-T040 -> SL-T041 -> SL-T042
  SL-T041 -> SL-T043
  SL-T039 -> SL-T046
  SL-T044 -> SL-T045
  SL-T039 -> SL-T047
  SL-T047 -> SL-T048

Sprint 6 (Polish) -- depends on Sprint 5
  SL-T048 -> SL-T049
  SL-T031 -> SL-T050
  SL-T011 -> SL-T051
  SL-T046 -> SL-T052
```

---

## 5. Acceptance Criteria (Technical Validation)

### 5.1 FR-1: TRD Table Parser

- [ ] AC-1.1: Parses merge-queue.md: 79 tasks, 9 sprints, ~23 stories
- [ ] AC-1.2: Task IDs preserved (MQ-T001 format)
- [ ] AC-1.3: Hour estimates parsed (3h → 3)
- [ ] AC-1.4: Dependency references extracted as arrays
- [ ] AC-1.5: File paths extracted from backticks
- [ ] AC-1.6: Status correctly mapped ([ ]/[~]/[x])
- [ ] AC-1.7: `--` handled as no dependencies
- [ ] AC-1.14: Columns auto-detected from header row
- [ ] AC-1.15: Missing optional columns default gracefully
- [ ] AC-1.12: Section 5 ACs matched to FRs
- [ ] AC-1.17: Section 7 risks applied to tasks
- [ ] AC-1.18: Section 6 quality reqs captured
- [ ] AC-1.16: Section 3 sprint summaries extracted

### 5.2 FR-2: Dual-Write

- [ ] AC-2.1: Identical hierarchy in both sd and br
- [ ] AC-2.2: `trd:<ID>` labels in both systems
- [ ] AC-2.3: Estimates as labels (sd) and --estimate (br)
- [ ] AC-2.4: File references in task descriptions
- [ ] AC-2.5: `--sd-only` skips br
- [ ] AC-2.6: `--br-only` skips sd
- [ ] AC-2.7: Missing CLI graceful degradation
- [ ] AC-2.8: `--parent` for hierarchy (non-blocking)
- [ ] AC-2.11: Epic auto-detected by label
- [ ] AC-2.12: Sequential per-tracker creation

### 5.3 FR-3: Dependency Wiring

- [ ] AC-3.1: Blocking deps match TRD Deps column
- [ ] AC-3.2: No container deps (parent-child only)
- [ ] AC-3.3: Cross-sprint deps correctly wired
- [ ] AC-3.4: Missing targets → warning
- [ ] AC-3.5: Circular dep detection
- [ ] AC-3.6: Identical deps in both trackers

### 5.4 FR-4: Sprint Parallelization

- [ ] AC-4.1: Sprints 5+6 and 7+8 identified as parallel
- [ ] AC-4.2: Cross-dep sprints excluded
- [ ] AC-4.3: Parallel labels in both trackers
- [ ] AC-4.4: `--no-parallel` disables detection
- [ ] AC-4.5: Preview shows parallel grouping

### 5.5 FR-5: Preview and Dry-Run

- [ ] AC-5.1: `--dry-run` no-op
- [ ] AC-5.2: Task counts, hours, status shown
- [ ] AC-5.3: Parallel groups visually distinguished
- [ ] AC-5.5: Confirmation prompt (unless `--auto`)
- [ ] AC-5.6: `--json` valid JSON output

### 5.6 FR-6: Completed Task Handling

- [ ] AC-6.1: Default creates all as open
- [ ] AC-6.2: `--skip-completed` excludes [x]
- [ ] AC-6.3: `--close-completed` creates + closes
- [ ] AC-6.5: Deps on skipped tasks silently dropped

### 5.7 FR-7: Idempotency and Resume

- [ ] AC-7.1: Duplicate trd:<ID> skipped
- [ ] AC-7.2: `--force` recreates
- [ ] AC-7.3: Re-run picks up where left off
- [ ] AC-7.4: Summary report (created/skipped/failed)
- [ ] AC-7.5: Epic auto-detected on re-run

---

## 6. Quality Requirements

### 6.1 Testing Standards

| Type | Target | Notes |
|------|--------|-------|
| Unit test coverage | >= 80% | All new modules must have co-located `__tests__/` |
| Integration test coverage | >= 70% | Parser integration, E2E sling flow |
| Test framework | Vitest | Co-located in `__tests__/` subdirectories per CLAUDE.md |

### 6.2 Code Quality

- TypeScript strict mode — no `any` escape hatches
- ESM only — all imports use `.js` extensions
- TDD methodology — RED-GREEN-REFACTOR for all coding tasks
- Non-interactive commands — all shell commands must be non-interactive
- Input validation at boundaries only (CLI argument parsing)

### 6.3 Performance Targets

| Operation | Target | Task Reference |
|-----------|--------|----------------|
| TRD parsing (80 tasks) | < 500ms | SL-T011 |
| Epic auto-detection | < 2s | SL-T025 |
| Full dual-write (80 tasks) | < 90s | SL-T026 |
| Dry-run preview | < 1s | SL-T041 |

### 6.4 Compatibility

- Works with TRD format as exemplified by docs/TRD/merge-queue.md
- Compatible with existing sd CLI (seeds) and br CLI (beads_rust)
- Does not modify existing seeds/beads data (additive only, unless `--force`)
- New types added to `src/orchestrator/types.ts` without breaking existing interfaces

---

## 7. Risk Register

| Risk | Likelihood | Impact | Mitigation | Tasks Affected |
|------|-----------|--------|------------|----------------|
| TRD format varies between documents | Medium | Medium | Auto-detect columns, graceful fallback for missing sections | SL-T006, SL-T011 |
| br CLI not available on all machines | Medium | Low | Graceful degradation to sd-only mode (SLING-004) | SL-T001, SL-T046 |
| Large TRD (100+ tasks) slow creation | Low | Medium | Sequential creation acceptable per PRD; 90s target for 80 tasks | SL-T026 |
| Circular dependencies in TRD | Low | Medium | Pre-creation validation with cycle detection (SLING-008) | SL-T028 |
| sd/br CLI JSON format changes | Low | Low | Version-pinned, JSON envelope unwrapping handles both formats | SL-T002, SL-T001 |

---

## 8. Files Modified/Created Summary

### New Files

| File | Sprint | Tasks |
|------|--------|-------|
| `src/lib/beads-rust.ts` | 1 | SL-T001, SL-T002, SL-T005 |
| `src/orchestrator/trd-parser.ts` | 2 | SL-T006 through SL-T016 |
| `src/orchestrator/sprint-parallel.ts` | 3 | SL-T019 through SL-T023 |
| `src/orchestrator/sling-executor.ts` | 4 | SL-T025 through SL-T036 |
| `src/cli/commands/sling.ts` | 5 | SL-T039 through SL-T046 |

### Modified Files

| File | Sprint | Tasks | Changes |
|------|--------|-------|---------|
| `src/orchestrator/types.ts` | 1 | SL-T004 | Add TrdTask, TrdStory, TrdSprint, SlingPlan, SlingOptions, SlingResult types |
| `src/cli/index.ts` | 5 | SL-T047 | Import and register sling command |

### Test Files (all new)

| File | Sprint | Tasks |
|------|--------|-------|
| `src/lib/__tests__/beads-rust.test.ts` | 1 | SL-T003 |
| `src/orchestrator/__tests__/trd-parser.test.ts` | 2 | SL-T012 |
| `src/orchestrator/__tests__/trd-parser-metadata.test.ts` | 2 | SL-T017 |
| `src/orchestrator/__tests__/trd-parser-integration.test.ts` | 2 | SL-T018 |
| `src/orchestrator/__tests__/sprint-parallel.test.ts` | 3 | SL-T024 |
| `src/orchestrator/__tests__/sling-executor.test.ts` | 4 | SL-T037 |
| `src/orchestrator/__tests__/sling-executor-errors.test.ts` | 4 | SL-T038 |
| `src/cli/__tests__/sling.test.ts` | 5 | SL-T048 |
| `src/orchestrator/__tests__/sling-e2e.test.ts` | 6 | SL-T049 |
| `src/orchestrator/__tests__/sling-idempotent.test.ts` | 6 | SL-T050 |
| `src/orchestrator/__tests__/trd-parser-edge.test.ts` | 6 | SL-T051 |
| `src/cli/__tests__/sling-degradation.test.ts` | 6 | SL-T052 |

---

## 9. Definition of Done

A task is considered complete when:

1. Implementation follows TypeScript strict mode (no `any`)
2. All imports use `.js` extensions (ESM)
3. TDD cycle completed (test written first, implementation makes it pass, refactored)
4. Unit tests pass with >= 80% coverage for the touched module
5. `npx tsc --noEmit` passes with zero errors
6. `npm test` passes (full suite)
7. Non-interactive commands only (no `-i` flags)
8. Error codes used for all failure paths (SLING-xxx)
9. Git commit with descriptive message referencing task ID

---

## 10. Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-03-13 | Initial TRD creation from PRD-SLING-TRD v1.2 |
