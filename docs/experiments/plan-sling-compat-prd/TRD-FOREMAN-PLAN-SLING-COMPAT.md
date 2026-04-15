# TRD: Make Foreman Planning Output Directly Consumable by Foreman Execution

## Document Metadata

- **Document ID:** TRD-FOREMAN-PLAN-SLING-COMPAT
- **PRD Reference:** PRD-FOREMAN-PLAN-SLING-COMPAT
- **Version:** 1.0.0
- **Status:** Draft
- **Date:** 2026-04-15
- **Architecture Option:** B (sling prd as new subcommand with embedded Pi session)
- **Design Readiness Score:** TBD

---

## Architecture Decision

### Chosen Approach: Option B — New `sling prd` subcommand with embedded Pi session

The `sling prd` command is added as a new subcommand of `foreman sling`. It runs an embedded Pi session executing `/ensemble:create-trd-foreman`, reads the generated TRD from disk, and feeds it directly to the existing `parseTrd()` + `execute()` pipeline.

**Option A — Extend `sling trd` with PRD auto-conversion (Rejected):**
Would overload the existing `sling trd` subcommand to also accept a PRD path, inferring whether the input is a PRD or TRD based on file extension or content. This creates parser ambiguity (a malformed TRD could be misidentified as a PRD) and mixes two distinct input domains in one command.

**Option C — New `foreman convert prd` top-level command (Rejected):**
Creates a third command surface (`foreman convert`) that users must remember. The semantic grouping (`sling` handles structured-document → task conversion) makes `sling prd` the natural location.

### Architecture Rationale

- Minimal CLI surface: one new subcommand under `sling`
- Reuses existing `parseTrd()` and `sling-executor.ts` without modification
- The embedded Pi session runs `/ensemble:create-trd-foreman` exactly as a user would run it interactively
- No changes to `foreman plan` — it remains PRD-first, output-to-disk only
- Idempotent: externalId (`trd:<ID>`) ensures re-runs skip existing tasks

---

## System Architecture

### Package Structure Changes

```
src/cli/commands/
├── sling.ts           # [MODIFIED] Add prdSubcommand alongside trdSubcommand
└── plan.ts            # [MODIFIED] Update completion hint

src/orchestrator/
├── sling-executor.ts  # [UNCHANGED] Reused as-is

src/orchestrator/__tests__/
├── trd-parser-foreman.test.ts  # [NEW] parseTrd() + create-trd-foreman output

src/cli/commands/__tests__/
├── sling-prd.test.ts         # [NEW] CLI integration tests
```

### Data Flow

```
foreman sling prd <prd-file> [opts]
    │
    ├─ 1. resolveSlingProjectPath(opts) → projectPath
    │
    ├─ 2. runEmbeddedPiSession(
    │       "/ensemble:create-trd-foreman <prd-file>",
    │       outputDir
    │   )
    │   → writes: docs/TRD/TRD-YYYY-NNN.md
    │
    ├─ 3. readFileSync(trdPath) → trdContent
    │
    ├─ 4. parseTrd(trdContent) → SlingPlan
    │
    ├─ 5. analyzeParallel(plan, content) → ParallelResult
    │
    ├─ 6. execute(plan, parallel, options, taskStore) → SlingResult
    │       └─ Creates native tasks (status=open/ready)
    │
    └─ 7. printSummary(result)
```

### Component Boundaries

| Component | Responsibility | Inputs | Outputs |
|-----------|----------------|--------|---------|
| `sling.ts:prdSubcommand` | CLI argument parsing, project path resolution, confirmation prompt | PRD file path, flags | Runs embedded Pi session, then calls sling-executor |
| `sling-executor.ts` | Task upsertion, dependency wiring, progress callback | `SlingPlan`, `ParallelResult`, `SlingOptions`, `NativeTaskStore` | `SlingResult` (created/skipped/failed counts) |
| `trd-parser.ts:parseTrd()` | TRD markdown → structured `SlingPlan` | TRD markdown content | `SlingPlan` with epic/sprints/stories/tasks |
| `pi-sdk-runner.ts:runWithPiSdk()` | Spawn Pi session, run prompt, return result | `prompt`, `cwd`, `model` | `{ success, costUsd, turns, errorMessage? }` |
| `create-trd-foreman.yaml` (../ensemble) | Prompt template for Pi session | PRD path | TRD markdown file |

### Integration Points

| Integration | Protocol | Notes |
|------------|----------|-------|
| `sling prd` → `create-trd-foreman` | Pi `runWithPiSdk()` | Same pattern as `dispatchPlanStep()` in dispatcher |
| `parseTrd()` → `sling-executor` | `SlingPlan` object | Shared type, no transformation needed |
| `sling-executor` → `NativeTaskStore` | `NativeTaskWriter` interface | Used as `NativeTaskStore` in the CLI |

---

## Master Task List

### Cluster A — Infrastructure (these must be completed first)

**TRD-FSC-001: Create `packages/development/commands/create-trd-foreman.yaml` in ../ensemble** [satisfies ARCH]
- Copy `create-trd.yaml` v3.0.0 as base
- Modify Phase 3 (Task Breakdown): output markdown tables with ID/Task/Est./Deps columns
- Modify Phase 3: all task statuses always `[ ]` (never `[x]`)
- Modify Phase 3: task IDs follow `[A-Z]+-T\d+` pattern (e.g., `AT-T001`)
- Remove Phase 5 (Adversarial Review) — Foreman-native output skips it
- Modify Phase 6: file naming uses same slug as original TRD (no `-foreman` suffix)
- Add validation step in Phase 3: assert no `[x]` in task tables
- Add validation step in Phase 3: assert task IDs match `[A-Z]+-T\d+` regex
- Estimate: 8h
- Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3

**TRD-FSC-001-TEST: Validate create-trd-foreman output format** [verifies TRD-FSC-001][satisfies ARCH][depends: TRD-FSC-001]
- Run `/ensemble:create-trd-foreman` on a sample PRD
- Assert `parseTrd()` does not throw
- Assert all task statuses are `open` (not `completed`)
- Assert all task IDs match `[A-Z]+-T\d+`
- Assert sprint headers match `SPRINT_PATTERN` regex
- Assert story headers match `STORY_PATTERN` regex
- Estimate: 4h
- Validates PRD ACs: AC-001-2, AC-003-2, AC-003-3, AC-003-6

---

**TRD-FSC-002: Generate `create-trd-foreman.md` via `npm run generate`** [satisfies ARCH][depends: TRD-FSC-001]
- Run ensemble generator to produce `packages/development/commands/ensemble/create-trd-foreman.md`
- Verify generated markdown contains all phases and steps
- Verify Phase 3 table format constraints are preserved in generated output
- Estimate: 1h
- Validates PRD ACs: AC-001-1

---

**TRD-FSC-003: Add `prdSubcommand` to `sling.ts`** [satisfies REQ-002][depends: TRD-FSC-002]
- Add new `Command("prd")` subcommand to `slingCommand`
- Implement argument parsing: `<prd-file>`, `--project`, `--project-path`, `--auto`, `--dry-run`, `--json`, `--force`
- Implement embedded Pi session runner: calls `runWithPiSdk()` with prompt `"/ensemble:create-trd-foreman <prd-file>"`
- Implement project path resolution using `resolveSlingProjectPath()`
- Implement confirmation prompt (skip if `--auto`)
- Integrate with `parseTrd()` → `analyzeParallel()` → `execute()` pipeline
- Print summary using existing `printSummary()` utility
- Update `--dry-run` output to show parsed SlingPlan structure
- Estimate: 12h
- Validates PRD ACs: AC-002-1, AC-002-3, AC-002-4, AC-002-5

**TRD-FSC-003-TEST: Validate sling prd CLI integration** [verifies TRD-FSC-003][satisfies REQ-002][depends: TRD-FSC-003]
- Run `foreman sling prd <prd> --dry-run --json`; assert valid SlingPlan JSON
- Run `foreman sling prd <prd> --auto --dry-run`; assert no confirmation prompt
- Run `foreman sling prd <prd> --project <name>`; assert correct project targeted
- Run `foreman sling prd <prd> --project-path <abs>`; assert correct project targeted
- Run `foreman sling prd nonexistent.prd`; assert error message shown
- Estimate: 6h
- Validates PRD ACs: AC-002-3, AC-002-4, AC-002-5

---

### Cluster B — Sling Output Validation

**TRD-FSC-004: Create `src/orchestrator/__tests__/trd-parser-foreman.test.ts`** [satisfies REQ-003][depends: TRD-FSC-001-TEST]
- Create test TRD content matching `create-trd-foreman` output format
- Test `parseTrd()` against the fixture TRD
- Assert `SlingPlan.epic` fields correct
- Assert `SlingPlan.sprints` array populated
- Assert `SlingPlan.sprints[].stories[].tasks` array populated
- Assert all task statuses parse to `open`
- Assert dependencies parse correctly (individual + range format)
- Assert estimates parse correctly
- Assert risk register parsing (if included in TRD)
- Estimate: 4h
- Validates PRD ACs: AC-003-1, AC-003-2, AC-003-3, AC-003-4, AC-003-5

---

**TRD-FSC-005: Update plan completion hint in `plan.ts`** [satisfies REQ-006][depends: TRD-FSC-003]
- Find line 422 in `src/cli/commands/plan.ts`
- Change from: `\`\nNext step: foreman sling trd ${outputDir}/TRD.md\``
- Change to: `\`\nNext step: foreman sling prd ${prdPath} --auto\``
- Determine `prdPath`: use `--from-prd` path if provided, otherwise infer from `outputDir/PRD.md`
- Estimate: 2h
- Validates PRD ACs: AC-006-3

**TRD-FSC-005-TEST: Validate updated plan completion hint** [verifies TRD-FSC-005][satisfies REQ-006][depends: TRD-FSC-005]
- Run `foreman plan <desc> --dry-run`; assert console output contains `foreman sling prd`
- Run `foreman plan <desc> --from-prd <prd> --dry-run`; assert hint uses the specified PRD path
- Estimate: 2h
- Validates PRD ACs: AC-006-3

---

**TRD-FSC-006: Create `src/cli/commands/__tests__/sling-prd.test.ts`** [satisfies REQ-002][depends: TRD-FSC-003]
- Integration test: `foreman sling prd <prd> --auto` creates tasks in native store
- Verify tasks have `status: open` (ready)
- Verify parent-child dependency hierarchy (epic→sprint→story→task)
- Verify `externalId` set to `trd:<TRD-ID>` format
- Verify type mapping (epic→epic, sprint→feature, story→feature, task→task)
- Verify priority mapping (critical→P0, high→P1, medium→P2, low→P3)
- Verify idempotent re-run (`sling prd` again with same PRD → tasks skipped)
- Verify `--force` refreshes existing tasks
- Estimate: 8h
- Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-004-4, AC-004-5

---

### Cluster C — End-to-End Integration

**TRD-FSC-007: End-to-end flow test** [satisfies REQ-006][depends: TRD-FSC-006]
- Run `foreman plan "build a task management app" --dry-run`
- Run `foreman plan "build a task management app"` (full pipeline)
- Verify PRD created at `docs/PRD/PRD-YYYY-NNN.md`
- Verify TRD created at `docs/TRD/TRD-YYYY-NNN.md`
- Run `foreman sling prd docs/PRD/PRD-YYYY-NNN.md --auto --dry-run`
- Run `foreman sling prd docs/PRD/PRD-YYYY-NNN.md --auto`
- Verify tasks in native store (query `br list --status=open`)
- Verify tasks are unblocked (query `br ready`)
- Verify `foreman run --dry-run` shows the created tasks as dispatch candidates
- Estimate: 6h
- Validates PRD ACs: AC-006-1, AC-006-2

---

**TRD-FSC-008: Backward compatibility test** [satisfies REQ-005][depends: TRD-FSC-006]
- Use an existing TRD file from `docs/TRD/` (beads path output)
- Run `foreman sling trd <existing-trd> --dry-run`; assert parses correctly
- Run `foreman sling trd <existing-trd> --auto`; assert tasks created
- Verify existing TRDs (non-table format) fail with `SLING-002` gracefully
- Run `foreman sling prd <prd>` on same project; verify no regression in `sling trd`
- Estimate: 4h
- Validates PRD ACs: AC-005-1, AC-005-2

---

**TRD-FSC-009: PRD readiness gate propagation** [satisfies REQ-002][depends: TRD-FSC-003]
- Create a PRD with readiness score < 4.0 (FAIL)
- Run `foreman sling prd <fail-prd>`; assert command halts with warning
- Create a PRD with readiness score 3.5 (CONCERNS)
- Run `foreman sling prd <concerns-prd>`; assert warning printed, command continues
- Create a PRD with readiness score >= 4.0 (PASS)
- Run `foreman sling prd <pass-prd>`; assert normal execution
- Estimate: 4h
- Validates PRD ACs: AC-002-1

---

## Sprint Planning

### Sprint 1: Foundation (TRD-FSC-001, TRD-FSC-002, TRD-FSC-003)

**Goal:** `create-trd-foreman` command exists and `sling prd` subcommand is functional.

**TRD-FSC-001:** 8h
**TRD-FSC-002:** 1h
**TRD-FSC-003:** 12h
**Sprint total:** 21h (~3-4 days)

### Sprint 2: Validation and Testing (TRD-FSC-001-TEST, TRD-FSC-003-TEST, TRD-FSC-004)

**Goal:** Parser compatibility validated and CLI integration tested.

**TRD-FSC-001-TEST:** 4h
**TRD-FSC-003-TEST:** 6h
**TRD-FSC-004:** 4h
**Sprint total:** 14h (~2 days)

### Sprint 3: Integration and Polish (TRD-FSC-005, TRD-FSC-005-TEST, TRD-FSC-006, TRD-FSC-007, TRD-FSC-008, TRD-FSC-009)

**Goal:** Full end-to-end flow working and backward compatibility verified.

**TRD-FSC-005:** 2h
**TRD-FSC-005-TEST:** 2h
**TRD-FSC-006:** 8h
**TRD-FSC-007:** 6h
**TRD-FSC-008:** 4h
**TRD-FSC-009:** 4h
**Sprint total:** 26h (~4-5 days)

---

## Acceptance Criteria Traceability

| REQ | AC | TRD Tasks | Verification |
|-----|----|-----------|-------------|
| REQ-001 | AC-001-1 | TRD-FSC-001 | Run `/ensemble:create-trd-foreman`; inspect output |
| REQ-001 | AC-001-2 | TRD-FSC-001-TEST | Run `parseTrd()` on output; no errors |
| REQ-001 | AC-001-3 | TRD-FSC-001, TRD-FSC-001-TEST | Count `[x]` in output → 0 |
| REQ-002 | AC-002-1 | TRD-FSC-003 | `sling prd --dry-run --json` → valid SlingPlan |
| REQ-002 | AC-002-2 | TRD-FSC-006 | Query `br ready` → tasks present |
| REQ-002 | AC-002-3 | TRD-FSC-003-TEST | `--auto` → no confirmation prompt |
| REQ-002 | AC-002-4 | TRD-FSC-003-TEST | `--dry-run` → no tasks in store |
| REQ-002 | AC-002-5 | TRD-FSC-003-TEST | `--project`/`--project-path` → correct targeting |
| REQ-003 | AC-003-1 | TRD-FSC-004 | Table header inspection |
| REQ-003 | AC-003-2 | TRD-FSC-001-TEST | Sprint header regex test |
| REQ-003 | AC-003-3 | TRD-FSC-001-TEST | Story header regex test |
| REQ-003 | AC-003-4 | TRD-FSC-004 | Count `[x]` → 0 |
| REQ-003 | AC-003-5 | TRD-FSC-004 | Deps column format inspection |
| REQ-003 | AC-003-6 | TRD-FSC-001-TEST | Task ID regex test |
| REQ-004 | AC-004-1 | TRD-FSC-006 | `br ready` query |
| REQ-004 | AC-004-2 | TRD-FSC-006 | Parent-child dependency query |
| REQ-004 | AC-004-3 | TRD-FSC-006 | externalId field query |
| REQ-004 | AC-004-4 | TRD-FSC-006 | Type field query |
| REQ-004 | AC-004-5 | TRD-FSC-006 | Priority field query |
| REQ-005 | AC-005-1 | TRD-FSC-008 | `sling trd` on beads-path TRD |
| REQ-005 | AC-005-2 | TRD-FSC-008 | `sling trd` on foreman-path TRD |
| REQ-005 | AC-005-3 | N/A (existing API) | Existing tests pass |
| REQ-005 | AC-005-4 | N/A (existing API) | Existing tests pass |
| REQ-006 | AC-006-1 | TRD-FSC-007 | `foreman plan` → no tasks in store |
| REQ-006 | AC-006-2 | TRD-FSC-007 | `sling prd` → tasks in store |
| REQ-006 | AC-006-3 | TRD-FSC-005, TRD-FSC-005-TEST | Console output inspection |

---

## Quality Requirements

### Security
- No execution of `create-trd-foreman` output without user confirmation (unless `--auto`).
- PRD file path validated before passing to Pi session.
- No arbitrary command injection in embedded Pi session prompt.

### Performance
- `sling prd` total time dominated by Pi session runtime (~60-180s for `create-trd-foreman`).
- `parseTrd()` and `execute()` run in <1s for typical TRDs (<500 tasks).
- Idempotent re-runs skip existing tasks without re-running Pi session.

### Reliability
- If Pi session fails, `sling prd` exits with non-zero code and no partial task creation.
- If `parseTrd()` fails, `sling prd` exits with non-zero code and no task creation.
- All errors printed to stderr with error code.

### Observability
- `sling prd` prints: file path read, task count, sprint count, parallel group summary.
- `--dry-run` prints parsed SlingPlan structure (JSON if `--json` flag).
- Spinner during task creation phase (same as `sling trd`).

---

## Implementation Notes

### parseTrd() Column Map for create-trd-foreman

The `parseTrd()` parser will look for these exact column headers in the task table:

```typescript
const COLUMN_ALIASES: Record<keyof ColumnMap, string[]> = {
  id: ["id"],
  task: ["task", "description", "title"],
  estimate: ["est.", "est", "estimate", "hours", "time"],
  deps: ["deps", "dependencies", "dep", "depends on", "depends"],
  files: ["files", "file", "affected files"],
  status: ["status", "done", "state"],
};
```

**Critical:** Use `ID` (not `TRD ID` or `Task ID`) in the first column header. The word `id` must appear as `id` exactly (lowercase) for the parser to auto-detect it.

### Task ID Format

All task IDs must match `[A-Z]+-T\d+`:
- Valid: `AT-T001`, `AT-T002`, `AUTH-T001`, `FE-T001`
- Invalid: `AT001`, `T001`, `at-t001` (lowercase)

The risk register parser uses `[A-Z]+-T\d+` to extract task IDs. Lowercase IDs will be silently ignored in risk register parsing.

### Story Numbering

Story headers must follow `#### Story N.M`:
- Valid: `#### Story 1.1: Authentication Implementation`
- Invalid: `#### Story 1.1.1: JWT Token Generation` (three-part numbering)

If a story has sub-stories, they should use a different format (e.g., `Story 1.1` with `Task 1.1.1` in the table, or use `Story 1.1a`/`Story 1.1b`).

### Dependency Ordering Constraint

Tasks within a story should be ordered so that dependencies reference only earlier tasks in the same story. The `sling-executor` wires dependencies in a single pass; forward references are logged as `SLING-007` errors and skipped.

**Correct ordering:**
```
| AT-T001 | Task A | | |
| AT-T002 | Task B | | AT-T001 |  ← depends on earlier task
| AT-T003 | Task C | | AT-T002 |  ← depends on earlier task
```

**Incorrect ordering (will generate SLING-007 errors):**
```
| AT-T003 | Task C | | AT-T004 |  ← forward reference
| AT-T004 | Task D | | | |
| AT-T001 | Task A | | | |  ← depends on task that comes after it
```

### Sprint Number Format

Sprint headers use the format `### N.M Sprint N` (with optional suffix):
- Valid: `### 1.1 Sprint 1: Core Authentication`, `### 2.3a Sprint 2: API Endpoints`
- Invalid: `### Sprint 1.1` (reversed order), `### Story 1.1` (wrong heading level)

The parser extracts sprint number using `parseInt()` so `1.1` becomes `number=1, suffix="a"`. The suffix is preserved but the number is used for sprint ordering.

### Status Always [ ]

For `create-trd-foreman`, all task status values in the table must be `[ ]` (open). The parser interprets:
- `[ ]` → `status: "open"` (created as ready for dispatch)
- `[x]` → `status: "completed"` (created but skipped when `skipCompleted=false`)
- `[~]` → `status: "in_progress"` (created in-progress)

Since the goal is to produce tasks marked ready for dispatch, use `[ ]` everywhere.
