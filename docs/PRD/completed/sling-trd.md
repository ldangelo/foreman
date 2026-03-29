# PRD: Sling-TRD Command

**Document ID:** PRD-SLING-TRD
**Version:** 1.2
**Created:** 2026-03-13
**Last Updated:** 2026-03-13
**Status:** Draft

---

## 1. Product Summary

### 1.1 Problem Statement

Foreman's existing `decompose` command converts TRDs into seeds using heuristic markdown parsing (H2 sections as stories, checklist items as tasks). This works for loosely-structured documents but **fails to extract the rich metadata already present in a well-structured TRD**: explicit task IDs, table-formatted dependencies, hour estimates, file references, status indicators, sprint groupings, and parallelization opportunities.

The merge-queue TRD (docs/TRD/merge-queue.md) exemplifies this: 79 tasks across 9 sprints with explicit dependency chains (e.g., `MQ-T027` depends on `MQ-T026, MQ-T012`), hour estimates, file paths, and completion status — none of which `decompose` can extract from its table format.

Additionally, the project now uses **two task tracking systems** — seeds (`sd`) for Foreman's agent pipeline and beads_rust (`br`) for broader project management — but no command writes to both simultaneously.

### 1.2 Solution

A new `foreman sling trd <file>` command (subcommand pattern: `sling` parent, `trd` subcommand — extensible to `sling prd`, `sling spec`, etc.) that:

1. **Parses TRD table format** — extracts tasks from markdown tables (not checklists), reading ID, title/description, estimate, dependencies, files, and status columns
2. **Dual-writes to sd and br** — creates the full hierarchy in both task trackers simultaneously
3. **Preserves explicit dependencies** — uses the TRD's "Deps" column instead of inferring sequential order
4. **Identifies parallel sprints** — auto-computes from task deps AND validates against TRD dependency graph section
5. **Creates all tasks as open** — default behavior creates all tasks regardless of TRD status, preserving the full plan for re-planning and agent dispatch
6. **Stores acceptance criteria on stories** — parses TRD Section 5 ACs and attaches them to corresponding story issues by FR number

### 1.3 Value Proposition

- **Eliminates manual task creation**: A single command turns a 79-task TRD into fully-wired task hierarchies in both trackers
- **Preserves TRD fidelity**: Task IDs, estimates, dependencies, and file references are carried through — not inferred or lost
- **Enables parallel sprint execution**: Agents can pick up work from independent sprints simultaneously
- **Dual-tracker parity**: Both sd and br stay in sync from the start, reducing cross-system drift

---

## 2. User Analysis

### 2.1 Primary Users

| Persona | Description | Pain Point |
|---------|-------------|------------|
| **Foreman Operator** | Engineer running `foreman run` to dispatch AI agents | Manually creates 50-80 seeds after TRD is written; deps are error-prone |
| **Project Lead** | Uses br/bd for project-level tracking, sd for agent dispatch | Must duplicate task creation across two systems |
| **AI Agent Pipeline** | Automated pipeline consuming `sd ready` | Blocked tasks must be correctly wired or agents pick up unready work |

### 2.2 User Journey

```
1. Team creates PRD → TRD (via /ensemble:create-prd → /ensemble:create-trd)
2. TRD reviewed and refined (via /ensemble:refine-trd)
3. >>> foreman sling trd docs/TRD/merge-queue.md <<<
4. Preview: "79 tasks, 9 sprints, 4 parallel groups — create in sd + br? [y/N]"
5. Tasks created with full hierarchy, dependency wiring, and ACs on stories
6. `sd ready` returns Sprint 1 tasks immediately
7. `br ready` returns the same set
8. `foreman run` dispatches agents to ready tasks
```

---

## 3. Goals & Non-Goals

### 3.1 Goals

| ID | Goal | Success Criteria |
|----|------|-----------------|
| G-1 | Parse TRD markdown table format into structured task hierarchy | All tasks from merge-queue.md TRD extracted with correct IDs, estimates, deps, files |
| G-2 | Create tasks in both sd and br simultaneously | Epic → Sprint → Story → Task hierarchy exists in both systems after one command |
| G-3 | Wire explicit dependencies from TRD | Dependencies match TRD "Deps" column, not positional inference |
| G-4 | Identify and label parallel sprints | Sprints with no cross-dependencies marked as parallelizable |
| G-5 | Handle already-completed tasks | All tasks created as open by default; `--skip-completed` and `--close-completed` available as overrides |
| G-6 | Preserve TRD metadata as labels/fields | Task IDs (e.g., `MQ-T001`), hour estimates, and file references stored |

### 3.2 Non-Goals

- **Modifying the TRD file** — sling-trd is read-only on the input document
- **LLM-based parsing** — TRD tables are structured enough for deterministic parsing
- **Replacing `decompose`** — `decompose` has been retired; `sling-trd` is now the canonical TRD → task hierarchy command
- **Syncing updates** — sling-trd is a one-shot import; subsequent updates are manual
- **Creating the TRD** — use `/ensemble:create-trd` for that

---

## 4. Functional Requirements

### FR-1: TRD Table Parser

Parse the TRD markdown format to extract the task hierarchy.

**Input format** (from docs/TRD/merge-queue.md):

```markdown
### 2.1 Sprint 1: Foundation (FR-2, FR-4) -- Quick Wins

#### Story 1.1: Auto-Commit State Files Before Merge

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| MQ-T001 | Implement autoCommitStateFiles() in refinery.ts | 3h | -- | `src/orchestrator/refinery.ts` | [x] |
| MQ-T002 | Wire autoCommitStateFiles() into mergeCompleted() | 2h | MQ-T001 | `src/orchestrator/refinery.ts` | [x] |
```

**Extraction rules:**
- **Epic**: H1 title (`# TRD: Merge Queue Epic`)
- **Epic description**: Text between H1 and first H2, plus frontmatter metadata (Document ID, Version, Epic ID)
- **Sprints**: H3 sections matching pattern `### X.Y Sprint N: <Name>`
- **Stories**: H4 sections matching pattern `#### Story N.M: <Title>`
- **Tasks**: Table rows parsed via auto-detected columns from the header row. Identifies columns by name (ID, Task, Est., Deps, Files, Status). Handles reordered columns and optional columns gracefully — only ID and Task are required
- **Sprint metadata**: Section 3 "Sprint Planning Summary" table parsed for focus, estimated hours, and key deliverables per sprint (stored as sprint issue description)
- **Sprint parallels**: Auto-computed from cross-sprint task dependencies AND validated against Section 4 "Dependency Graph" (warn on discrepancy)
- **Acceptance criteria**: Section 5 ACs matched to stories by FR number (e.g., `FR-1` ACs → stories implementing FR-1 tasks)
- **Risk register**: Section 7 risks parsed and applied as `risk:high`/`risk:medium` labels on tasks referenced in the "Tasks Affected" column
- **Quality requirements**: Section 6 quality requirements appended to the epic's notes/description field

**Acceptance Criteria:**
- AC-1.1: Parses merge-queue.md TRD correctly: 79 tasks, 9 sprints, ~23 stories
- AC-1.2: Extracts task IDs (e.g., `MQ-T001`) preserving original prefix
- AC-1.3: Extracts hour estimates as numbers (e.g., `3h` → 3)
- AC-1.4: Extracts dependency references (e.g., `MQ-T001, MQ-T012` → `["MQ-T001", "MQ-T012"]`)
- AC-1.5: Extracts file paths from backtick-delimited references
- AC-1.6: Extracts status: `[ ]` → open, `[~]` → in_progress, `[x]` → completed
- AC-1.7: Handles `--` as "no dependencies"
- AC-1.8: Handles multi-line task descriptions (text after `|` that wraps)
- AC-1.9: Auto-computes sprint parallelization from task-level cross-sprint dependencies
- AC-1.10: Also parses Section 4 "Dependency Graph" for parallelization notes; warns if auto-computed result disagrees
- AC-1.11: Falls back gracefully if TRD lacks expected sections (warning, not error)
- AC-1.12: Parses Section 5 acceptance criteria, matching ACs to FRs by section header (e.g., `### 5.1 FR-1:`)
- AC-1.13: ACs stored on corresponding story issues as acceptance/description field content
- AC-1.14: Table columns auto-detected from header row by name (ID, Task, Est., Deps, Files, Status); only ID and Task are required columns
- AC-1.15: Optional columns (Est., Deps, Files, Status) default to sensible values when absent (0h, no deps, no files, open)
- AC-1.16: Section 3 "Sprint Planning Summary" parsed for sprint-level focus, hours, and deliverables
- AC-1.17: Section 7 "Risk Register" parsed; risk labels applied to tasks listed in "Tasks Affected" column
- AC-1.18: Section 6 "Quality Requirements" appended to epic description/notes

### FR-2: Dual-Write to Seeds (sd) and Beads Rust (br)

Create the full task hierarchy in both tracking systems.

**Hierarchy mapping:**

| TRD Level | sd Type | sd Label | br Type | br Label |
|-----------|---------|----------|---------|----------|
| Epic | `epic` | — | `epic` | — |
| Sprint | `feature` | `kind:sprint` | `feature` | `kind:sprint` |
| Story | `feature` | `kind:story` | `feature` | `kind:story` |
| Task | `task` | `trd:<ID>` | `task` | `trd:<ID>` |
| Test task | `task` | `kind:test`, `trd:<ID>` | `task` | `kind:test`, `trd:<ID>` |
| Spike | `chore` | `kind:spike`, `trd:<ID>` | `chore` | `kind:spike`, `trd:<ID>` |

**Metadata mapping:**

| TRD Field | sd Field | br Field |
|-----------|----------|----------|
| Task ID (MQ-T001) | label `trd:MQ-T001` | label `trd:MQ-T001` |
| Estimate (3h) | label `est:3h` | `--estimate 180` (minutes) |
| Files | description suffix | description suffix |
| Status `[x]` | created as open (default) | created as open (default) |
| Status `[~]` | created as open (default) | created as open (default) |
| Priority | Parsed from TRD sprint headers (e.g., "P1 - Critical"); falls back to sprint-number mapping if not found | Same mapping |

**Acceptance Criteria:**
- AC-2.1: Creates identical hierarchy in both sd and br
- AC-2.2: TRD task IDs stored as `trd:<ID>` labels in both systems
- AC-2.3: Hour estimates stored as `est:<N>h` labels in sd and `--estimate` in br
- AC-2.4: File references appended to task descriptions
- AC-2.5: `--sd-only` flag skips br creation
- AC-2.6: `--br-only` flag skips sd creation
- AC-2.7: If sd CLI is missing, warns and continues with br only (and vice versa)
- AC-2.8: Parent-child relationships use `--parent` (organizational, non-blocking)
- AC-2.9: Both systems share `trd:<ID>` labels as the join key — no cross-references between sd and br IDs (independent systems)
- AC-2.10: Priority parsed from TRD sprint headers (e.g., `### P1 - Critical` or section notes); falls back to sprint-number ordinal mapping (Sprint 1-2 → P1, 3-5 → P2, 6+ → P3) if header lacks priority indicator
- AC-2.11: Auto-detects existing epic by searching for `trd:<doc-id>` label in sd/br. If found, reuses as parent. If not found, creates new epic
- AC-2.12: Creation order: all sd issues first (sequential), then all br issues (sequential). Within each tracker: epic → sprints → stories → tasks (hierarchy order)
- AC-2.13: Sprint description populated from Section 3 "Sprint Planning Summary" (focus, est. hours, key deliverables)
- AC-2.14: Risk labels from Section 7 applied to affected tasks in both trackers
- AC-2.15: Quality requirements from Section 6 appended to epic notes in both trackers

### FR-3: Dependency Wiring

Wire task dependencies from the TRD's explicit "Deps" column.

**Rules:**
- Dependencies from the Deps column → blocking `dep add` (not `--parent`)
- `--` in Deps column → no blocking dependencies
- Cross-sprint dependencies resolved by TRD task ID lookup
- Dependencies reference TRD task IDs (e.g., `MQ-T001`) which are mapped to actual sd/br issue IDs via a lookup table built during creation

**Acceptance Criteria:**
- AC-3.1: Blocking dependencies match TRD Deps column exactly
- AC-3.2: No explicit container deps added (epic→sprint, sprint→story, story→task) — only `--parent` for organizational hierarchy
- AC-3.3: Cross-sprint dependencies correctly wired (e.g., Sprint 5 task depends on Sprint 2 task)
- AC-3.4: Missing dependency targets produce warnings, not errors
- AC-3.5: Circular dependency detection with clear error message
- AC-3.6: Dependencies wired in both sd and br identically

### FR-4: Sprint Parallelization Detection

Analyze the dependency graph to identify which sprints can run in parallel.

**Algorithm (dual-source with validation):**
1. **Auto-compute**: Build a directed graph of sprint-level dependencies from task-level cross-sprint deps. Compute independent sets — sprints with no dependency path between them can run in parallel
2. **Parse TRD**: Extract parallelization notes from Section 4 "Dependency Graph" and Section 3 "Parallelization Opportunities" if present
3. **Validate**: Compare auto-computed result with TRD-stated parallelization. Warn on discrepancy (e.g., "TRD says Sprint 5 and 6 are parallel but task MQ-T049 depends on MQ-T018 in Sprint 2"). Use auto-computed result as source of truth
4. **Label**: Apply `parallel:<group>` labels (e.g., `parallel:A`, `parallel:B`) to sprint issues

**Scope**: Sprint-level parallelism only. Story-level and task-level parallelism is an agent scheduling concern handled by `sd ready` / `br ready`.

**Acceptance Criteria:**
- AC-4.1: For merge-queue.md: Sprint 5 and Sprint 6 identified as parallel; Sprint 7 and Sprint 8 identified as parallel
- AC-4.2: Sprints with cross-dependencies NOT marked parallel
- AC-4.3: Parallel group labels applied to sprint issues in both sd and br
- AC-4.4: `--no-parallel` flag disables parallel detection (all sprints sequential)
- AC-4.5: Parallel sprints displayed in preview output with visual grouping

### FR-5: Preview and Dry-Run

Display the parsed hierarchy before creating tasks.

**Preview output:**
```
Epic: TRD: Merge Queue Epic (79 tasks, 9 sprints)

  Sprint 1: Foundation (16h, 6 tasks) [P1]
    Story 1.1: Auto-Commit State Files (3 tasks, all completed)
      ✓ MQ-T001  Implement autoCommitStateFiles()         3h  --
      ✓ MQ-T002  Wire into mergeCompleted()               2h  MQ-T001
      ✓ MQ-T003  Write unit tests                         3h  MQ-T001
    Story 1.2: Safe Branch Deletion (3 tasks, all completed)
      ...

  ║ Parallel Group A:
  ║  Sprint 5: Overlap Clustering (12h, 4 tasks) [P2]
  ║  Sprint 6: Worktree/DryRun/Seeds (37h, 13 tasks) [P2]

  ║ Parallel Group B:
  ║  Sprint 7: Learning and Costs (27h, 10 tasks) [P3]
  ║  Sprint 8: Polish (15h, 6 tasks) [P3]

Summary: 79 tasks (75 completed, 4 open), 231 est. hours
Targets: sd (seeds) + br (beads_rust)
```

**Acceptance Criteria:**
- AC-5.1: `--dry-run` shows full preview without creating any tasks
- AC-5.2: Preview shows task count, hour estimate totals, completion status per sprint/story
- AC-5.3: Parallel sprint groups visually distinguished
- AC-5.4: Completed tasks shown with checkmark, open tasks with empty box
- AC-5.5: Confirmation prompt before creation (unless `--auto`)
- AC-5.6: `--json` outputs parsed structure as JSON (for tooling integration)

### FR-6: Completed Task Handling

Handle tasks already marked as completed in the TRD.

**Default behavior**: Create all tasks as open regardless of TRD status. This preserves the full plan for re-planning, re-estimating, and agent dispatch. TRD status is informational only — the tracker is the source of truth for actual progress.

**Override options:**
- (default): Create all tasks as open — useful for re-planning or fresh starts
- `--skip-completed`: Do not create tasks marked `[x]` — reduces noise, only actionable work appears
- `--close-completed`: Create tasks marked `[x]` then immediately close them — preserves full history with correct status

**Acceptance Criteria:**
- AC-6.1: Default behavior creates ALL tasks (including `[x]`) in open status
- AC-6.2: `--skip-completed` excludes `[x]` tasks from creation
- AC-6.3: `--close-completed` creates `[x]` tasks and immediately closes them
- AC-6.4: `[~]` tasks always created as open (TRD in-progress status is not transferred — tracker is source of truth)
- AC-6.5: When `--skip-completed` is used, dependencies on skipped tasks are silently dropped (not errors)
- AC-6.6: When `--skip-completed` is used, sprint/story containers with all tasks completed are also skipped

### FR-7: Idempotency and Resume

Support re-running sling-trd on an already-slung TRD.

**Epic auto-detection**: Before creating a new epic, search both trackers for an existing issue with label `trd:<document-id>` (e.g., `trd:TRD-MERGE-QUEUE`). If found, reuse it as the parent epic. This enables partial re-runs and avoids duplicate epics.

**Acceptance Criteria:**
- AC-7.1: If `trd:<ID>` label already exists in sd/br, skip that task (do not duplicate)
- AC-7.2: `--force` flag recreates tasks even if labels match (for re-slinging after TRD update)
- AC-7.3: Resumable: if creation fails mid-way, re-running picks up where it left off
- AC-7.4: Reports "X created, Y skipped (already exist), Z failed" summary
- AC-7.5: Existing epic auto-detected by `trd:<document-id>` label search; reused as parent if found

---

## 5. Non-Functional Requirements

### 5.1 Performance

| Operation | Target |
|-----------|--------|
| TRD parsing (80 tasks) | < 500ms |
| Full dual-write (80 tasks, sequential per-tracker) | < 90s |
| Dry-run preview | < 1s |
| Epic auto-detection (label search) | < 2s |

### 5.2 Reliability

- sd or br CLI unavailability degrades gracefully to single-tracker mode
- Individual task creation failures do not abort the batch — collect errors, report at end
- Dependency wiring errors are warnings, not fatal

### 5.3 Compatibility

- Works with TRD format as exemplified by docs/TRD/merge-queue.md
- Compatible with existing sd and br CLI versions
- Does not modify existing seeds/beads data (additive only, unless `--force`)

---

## 6. CLI Interface

```
foreman sling trd <trd-file> [options]

Arguments:
  trd-file              Path to TRD markdown file

Options:
  --dry-run             Preview without creating tasks
  --auto                Skip confirmation prompt
  --json                Output parsed structure as JSON
  --sd-only             Write to seeds (sd) only
  --br-only             Write to beads_rust (br) only
  --skip-completed      Skip [x] tasks (not created)
  --close-completed     Create [x] tasks and immediately close them
  --no-parallel         Disable parallel sprint detection
  --force               Recreate tasks even if trd:<ID> labels already exist
  --priority-map <json> Override sprint→priority mapping (JSON string)
  --no-risks            Skip risk register parsing (no risk labels)
  --no-quality          Skip quality requirements parsing (no epic notes)
```

**Subcommand pattern**: `sling` is the parent command, `trd` is the first subcommand. Future subcommands (e.g., `sling prd`) can be added without breaking the CLI surface.

**Progress UX**: During creation, displays a spinner with counter: `Creating tasks... 42/79 (sd: 42, br: 42)`. Compact, shows progress for the 40-80s creation phase.

---

## 7. Error Handling

| Error Code | Condition | Behavior |
|------------|-----------|----------|
| SLING-001 | TRD file not found | Fatal error with path suggestion |
| SLING-002 | No tasks extracted from TRD | Fatal error — TRD format may not match expected structure |
| SLING-003 | sd CLI not found | Warning, continue with br only (unless --sd-only) |
| SLING-004 | br CLI not found | Warning, continue with sd only (unless --br-only) |
| SLING-005 | Neither sd nor br available | Fatal error |
| SLING-006 | Task creation failed | Warning per task, continue batch, report at end |
| SLING-007 | Dependency target not found | Warning, skip that dependency |
| SLING-008 | Circular dependency detected | Fatal error with cycle details |
| SLING-009 | Duplicate trd:<ID> label found | Skip task (or recreate with --force) |
| SLING-010 | Table header row missing required columns (ID, Task) | Fatal error with column names found vs expected |
| SLING-011 | Risk register references unknown task ID | Warning, skip risk label for that task |
| SLING-012 | AC section references unknown FR number | Warning, ACs stored on epic as fallback |

---

## 8. Test Scenarios

| ID | Scenario | Expected Result |
|----|----------|----------------|
| TS-1 | Parse merge-queue.md TRD | 79 tasks, 9 sprints, correct hierarchy, ACs extracted |
| TS-2 | Dry-run mode | No sd/br calls, full preview displayed |
| TS-3 | Default (create all as open) | All 79 tasks created in open status in both sd and br |
| TS-4 | --skip-completed | Only `[ ]` and `[~]` tasks created; deps on skipped tasks dropped |
| TS-5 | --close-completed | All tasks created, `[x]` immediately closed |
| TS-6 | sd-only mode | Only sd receives tasks, br untouched |
| TS-7 | br-only mode | Only br receives tasks, sd untouched |
| TS-8 | Parallel sprint detection (auto-compute) | Sprints 5+6 parallel, Sprints 7+8 parallel |
| TS-9 | Parallel validation (TRD Section 4) | Warns if auto-computed disagrees with TRD notes |
| TS-10 | Cross-sprint dependency | Sprint 5 task → Sprint 2 task correctly wired |
| TS-11 | Idempotent re-run | Second run skips all existing tasks (trd:<ID> labels match) |
| TS-12 | sd unavailable | Degrades to br-only with warning |
| TS-13 | Malformed TRD table | Graceful degradation with warnings |
| TS-14 | JSON output | Valid JSON matching extended DecompositionPlan |
| TS-15 | AC parsing | Section 5 ACs attached to correct story issues by FR number |
| TS-16 | Priority from TRD headers | Sprint headers with "P1 - Critical" → P1; headers without priority → ordinal fallback |
| TS-17 | Auto-detect columns | TRD with reordered columns (Task, ID, Status, Deps) parsed correctly |
| TS-18 | Missing optional columns | TRD table with only ID and Task columns: other fields default gracefully |
| TS-19 | Sprint summary metadata | Section 3 data stored as sprint issue descriptions |
| TS-20 | Risk labels | Section 7 risks applied as labels to referenced tasks |
| TS-21 | Quality reqs on epic | Section 6 content appended to epic notes |
| TS-22 | Auto-detect existing epic | Second sling run reuses existing epic (no duplicate) |
| TS-23 | Progress spinner | Creation phase shows spinner with counter updating per issue |

---

## 9. Implementation Notes

### 9.1 Relationship to Existing Commands

| Command | Input | Parser | Output | Difference |
|---------|-------|--------|--------|------------|
| `foreman decompose` | PRD/TRD (loose markdown) | Heuristic (H2→stories, checklists→tasks) | sd only | **Retired** — use `sling trd` instead |
| `foreman sling trd` | TRD (structured tables) | Table parser (columns: ID, Task, Est, Deps, Files, Status) | sd + br | Uses explicit deps from table, stores ACs on stories |

### 9.2 Reuse Opportunities

- **Type mappings**: Implement `toSeedsType()`, `toSeedsPriority()`, `toBrType()`, `toBrPriority()` in sling-executor.ts
- **Execution pattern**: Dual-write executor pattern in sling-executor.ts
- **SlingPlan type**: Defined in `src/orchestrator/types.ts` with sprint/story/task hierarchy
- **Display helpers**: `printSlingPlan()`, `priorityBadge()`, `complexityBadge()` in sling.ts

### 9.3 New Files

| File | Purpose |
|------|---------|
| `src/cli/commands/sling.ts` | Parent `sling` command with `trd` subcommand |
| `src/orchestrator/trd-parser.ts` | TRD table format parser (tasks, deps, ACs, parallel detection) |
| `src/orchestrator/sling-executor.ts` | Dual-write execution engine (sd + br) |
| `src/lib/beads-rust.ts` | br CLI wrapper (mirrors seeds.ts pattern — typed methods: create, close, addDependency, list, update, search) |

---

## 10. Resolved Decisions

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| 1 | Should sling-trd update existing tasks if TRD changes? | No — use `--force` to re-create | Sync is out of scope for v1; one-shot import with idempotency via `trd:<ID>` labels |
| 2 | Should parallel groups be auto-detected or parsed from TRD? | Both with validation | Auto-compute from task deps (source of truth), parse TRD Section 4 for validation, warn on discrepancy |
| 3 | Should br cross-reference sd IDs and vice versa? | No — independent systems | Both share `trd:<ID>` labels as join key; no cross-references needed |
| 4 | Default completed-task behavior? | Create all as open | Tracker is source of truth; TRD status is informational. `--skip-completed` and `--close-completed` as overrides |
| 5 | Command name structure? | `foreman sling trd <file>` | Subcommand pattern extensible to `sling prd`, `sling spec`, etc. |
| 6 | Priority derivation? | Parse from TRD headers, fallback to sprint-number mapping | Respects TRD author intent; ordinal fallback for TRDs without explicit priority indicators |
| 7 | Acceptance criteria handling? | Store ACs on stories | Parse Section 5, match to stories by FR number, store as acceptance/description field |
| 8 | br wrapper architecture? | New beads-rust.ts module | Mirrors seeds.ts pattern; typed wrapper reusable by future commands |
| 9 | Parallel detection scope? | Sprint-level only | Story/task parallelism is an agent scheduling concern handled by `sd ready` / `br ready` |
| 10 | Table column parsing? | Auto-detect from header row | Identifies columns by name; handles reordered/optional columns. Only ID and Task required |
| 11 | Creation concurrency? | Sequential per-tracker | All sd issues first, then all br issues. Predictable ordering, no concurrency bugs |
| 12 | Sprint summary metadata? | Store as sprint description | Parse Section 3 for focus, hours, deliverables. Enriches sprint issues |
| 13 | Progress UX during creation? | Spinner with counter | Single line: `Creating tasks... 42/79 (sd: 42, br: 42)`. Clean and informative |
| 14 | Quality reqs and risk register? | Both: risks as labels, quality as epic notes | Risk labels on affected tasks; quality reqs appended to epic description |
| 15 | Existing epic handling? | Auto-detect by `trd:<doc-id>` label | Search trackers before creating; reuse if found. Enables partial re-runs |

## 10.1 Open Questions

1. **Should the `sling` parent command auto-detect document type?** (e.g., `foreman sling docs/TRD/merge-queue.md` infers `trd` subcommand from content). Defer to v2.

---

## 11. Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-03-13 | Initial PRD |
| 1.1 | 2026-03-13 | Refinement pass 1: (1) Command renamed to `foreman sling trd` (subcommand pattern); (2) Default changed to create-all-as-open; (3) Cross-references removed — `trd:<ID>` as join key; (4) Parallel detection: dual-source with validation; (5) Priority: parse from TRD headers; (6) ACs stored on stories by FR number; (7) br wrapper as beads-rust.ts; (8) Sprint-level parallelism only; (9) Resolved decisions table |
| 1.2 | 2026-03-13 | Refinement pass 2: (1) Table columns auto-detected from header row — handles reordered/optional columns, only ID+Task required; (2) Creation order: sequential per-tracker (sd first, then br) for predictable ordering; (3) Section 3 sprint summary parsed and stored as sprint descriptions; (4) Spinner with counter progress UX during creation; (5) Risk register (Section 7) parsed — risk labels applied to affected tasks; (6) Quality requirements (Section 6) appended to epic notes; (7) Epic auto-detection by `trd:<doc-id>` label — reuses existing epic on re-runs; (8) New error codes SLING-010/011/012 for column parsing, risk references, and AC references; (9) 7 additional test scenarios (TS-17 through TS-23) |
