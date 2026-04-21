# Acceptance Criteria Validation Matrix

**Project:** Make Foreman Planning Output Directly Consumable by Foreman Execution
**Document ID:** ACM-FOREMAN-PLAN-SLING-COMPAT
**Version:** 1.0.0
**Date:** 2026-04-15

---

## Overview

This document provides a test matrix for validating all acceptance criteria defined in PRD-FOREMAN-PLAN-SLING-COMPAT. Each row maps a specific AC to its verification method, test artifact, and pass criteria.

---

## AC Validation Table

| AC ID | Description | Verification Method | Test Artifact | Pass Criteria | Status |
|-------|-------------|---------------------|---------------|--------------|--------|
| **AC-001-1** | create-trd-foreman reads PRD, elicits technical, writes TRD | Run `/ensemble:create-trd-foreman <prd>` in a Pi session and inspect output file | Manual test or automated Pi session runner test | Output file exists at `docs/TRD/TRD-YYYY-NNN.md`, contains H1 epic title, sprint headers, story headers, task tables | ⬜ |
| **AC-001-2** | TRD satisfies parseTrd() format | Call `parseTrd(output)` on create-trd-foreman output; must not throw | `trd-parser-foreman.test.ts` | No `SLING-010` (missing columns), no `SLING-002` (no tasks), SlingPlan has epic + sprints + stories + tasks | ⬜ |
| **AC-001-3** | All task statuses are `[ ]` | Count `[x]` occurrences in task tables of generated TRD | `trd-parser-foreman.test.ts` | `[x]` count in task tables = 0 | ⬜ |
| **AC-002-1** | sling prd runs create-trd-foreman + parseTrd + execute | Run `foreman sling prd <prd> --dry-run --json` and inspect JSON output | `sling-prd.test.ts` | JSON contains valid `SlingPlan` with `epic.title`, `sprints[]`, `stories[].tasks[]` | ⬜ |
| **AC-002-2** | Tasks created with status=open | Run `foreman sling prd <prd> --auto`; query `br list --status=open` | `sling-prd.test.ts` | All newly created tasks have `status: open` | ⬜ |
| **AC-002-3** | --auto flag skips confirmation | Run `foreman sling prd <prd> --auto --dry-run`; assert no stdin reads | `sling-prd.test.ts` | Process completes without hanging on confirmation prompt | ⬜ |
| **AC-002-4** | --dry-run previews without writing | Run `foreman sling prd <prd> --dry-run`; query task count before/after | `sling-prd.test.ts` | Task store count unchanged after `--dry-run` | ⬜ |
| **AC-002-5** | --project and --project-path work | Run `foreman sling prd <prd> --project <name>`; verify correct project | `sling-prd.test.ts` | Tasks written to correct project's SQLite DB | ⬜ |
| **AC-003-1** | Table has ID and Task columns | Inspect first table header in task section | `trd-parser-foreman.test.ts` | Header row contains `id` (case-insensitive) and `task`/`description`/`title` (case-insensitive) columns | ⬜ |
| **AC-003-2** | Sprint headers match SPRINT_PATTERN | Regex test: `/^###\s+\d+\.\d+[a-z]?\s+Sprint\s+(\d+[a-z]?)\s*[:-]?\s*(.*)/i` against all `### N.M Sprint` lines | `trd-parser-foreman.test.ts` | 100% of sprint headers match the pattern | ⬜ |
| **AC-003-3** | Story headers match STORY_PATTERN | Regex test: `/^####\s+Story\s+(\d+\.\d+)\s*[:-]?\s*(.*)/i` against all `#### Story` lines | `trd-parser-foreman.test.ts` | 100% of story headers match the pattern | ⬜ |
| **AC-003-4** | All task statuses are `[ ]` | Inspect status column in all task table rows | `trd-parser-foreman.test.ts` | 0 `[x]`, 0 `[~]`, all `[ ]` (open) | ⬜ |
| **AC-003-5** | Dependencies use TASK-ID format | Inspect deps column cells; regex test: `/^[A-Z]+-T\d+(,\s*[A-Z]+-T\d+)*$/` | `trd-parser-foreman.test.ts` | All non-empty deps cells match format; range expressions (if any) expand correctly | ⬜ |
| **AC-003-6** | Task IDs match [A-Z]+-T\d+ | Regex test against all trdId values in SlingPlan | `trd-parser-foreman.test.ts` | 100% of trdId values match pattern | ⬜ |
| **AC-004-1** | Tasks in br ready output | Run `br ready` after `sling prd`; count tasks | `sling-prd.test.ts` | All epic/sprint/story/task nodes appear in `br ready` (unblocked) | ⬜ |
| **AC-004-2** | Parent-child dependencies correct | Query task store for dependency type `parent-child` | `sling-prd.test.ts` | Epic has no parent; sprint has parent=epic; story has parent=sprint; task has parent=story | ⬜ |
| **AC-004-3** | externalId set to trd:<TRD-ID> | Query `external_id` column in tasks table | `sling-prd.test.ts` | All rows have `external_id` matching pattern `trd:<id>` | ⬜ |
| **AC-004-4** | Type mapping correct | Query `type` column in tasks table | `sling-prd.test.ts` | epic→epic, sprint→feature, story→feature, task→task, spike→chore | ⬜ |
| **AC-004-5** | Priority mapping correct | Query `priority` column in tasks table | `sling-prd.test.ts` | critical→0, high→1, medium→2, low→3 | ⬜ |
| **AC-005-1** | sling trd works with create-trd output | Run `foreman sling trd <beads-path-trd> --auto` on existing TRD | `sling.test.ts` (existing) | Tasks created, no errors | ⬜ |
| **AC-005-2** | sling trd works with create-trd-foreman output | Run `foreman sling trd <foreman-path-trd> --auto` | `sling-prd.test.ts` | Tasks created, no errors | ⬜ |
| **AC-005-3** | parseTrd() API unchanged | Verify existing `trd-parser.test.ts` tests pass | `trd-parser.test.ts` (existing) | All tests pass without modification | ⬜ |
| **AC-005-4** | execute() API unchanged | Verify existing `sling-executor.test.ts` tests pass | `sling-executor.test.ts` (existing) | All tests pass without modification | ⬜ |
| **AC-006-1** | foreman plan does not write tasks | Run `foreman plan <desc>`; query task store before/after | `sling-prd.test.ts` | Task store count unchanged after `foreman plan` | ⬜ |
| **AC-006-2** | foreman sling prd creates tasks | Run `foreman sling prd <prd> --auto`; query task store | `sling-prd.test.ts` | Task store count increases by expected number of tasks | ⬜ |
| **AC-006-3** | Updated completion hint | Capture stdout from `foreman plan <desc>`; search for hint text | `sling-prd.test.ts` | Hint contains `foreman sling prd` (not `foreman sling trd`) | ⬜ |

---

## Test Execution Order

Tests must be executed in this dependency order:

```
1. TRD-FSC-001 (create-trd-foreman.yaml)
   ↓
2. TRD-FSC-001-TEST (parseTrd() compatibility)
   ↓
3. TRD-FSC-002 (generate create-trd-foreman.md)
   ↓
4. TRD-FSC-003 (sling prd CLI subcommand)
   ↓
5. TRD-FSC-003-TEST (CLI integration)
   ↓
6. TRD-FSC-004 (trd-parser-foreman.test.ts)
   ↓
7. TRD-FSC-005 (plan completion hint)
   ↓
8. TRD-FSC-005-TEST (hint validation)
   ↓
9. TRD-FSC-006 (sling-prd.test.ts — native task store)
   ↓
10. TRD-FSC-007 (end-to-end flow)
    ↓
11. TRD-FSC-008 (backward compatibility)
    ↓
12. TRD-FSC-009 (PRD readiness gate)
```

---

## Test Fixtures Required

### Fixture 1: Sample PRD (for AC-001-1, AC-002-1, AC-002-2)

A minimal PRD that `create-trd-foreman` can process. Must include:
- `**Document ID:** PRD-2026-001-test`
- `**Version:** 1.0.0`
- `**Status:** Draft`
- H1 title (`# Test Product`)
- REQ-001, REQ-002 requirements with acceptance criteria
- At least 2 sprints worth of content

**Location:** `src/orchestrator/__tests__/fixtures/test-prd-foreman.md`

### Fixture 2: Sample TRD (for AC-003-*, AC-005-2)

A TRD in `create-trd-foreman` format generated from Fixture 1. Must include:
- H1 epic title
- `**Document ID:** TRD-2026-001-test`
- `### 1.1 Sprint 1` header (matches SPRINT_PATTERN)
- `#### Story 1.1` header (matches STORY_PATTERN)
- Task table with `| ID | Task | Est. | Deps |` header
- All task statuses `[ ]`
- Task IDs matching `[A-Z]+-T\d+`
- At least 3 tasks with dependencies

**Location:** `src/orchestrator/__tests__/fixtures/test-trd-foreman.md`

### Fixture 3: Beads-path TRD (for AC-005-1)

An existing TRD in the original `create-trd` format from `docs/TRD/TRD-2026-018-ensemble-pi-runtime.md`. Used for backward compatibility testing.

**Location:** `docs/TRD/TRD-2026-018-ensemble-pi-runtime.md` (existing file)

### Fixture 4: Low-readiness PRD (for AC-002-1 propagation)

A PRD with `**Readiness Score:** 2.5` (FAIL grade).

**Location:** `src/orchestrator/__tests__/fixtures/test-prd-low-readiness.md`

### Fixture 5: Concerns-readiness PRD (for AC-002-1 propagation)

A PRD with `**Readiness Score:** 3.5` (CONCERNS grade).

**Location:** `src/orchestrator/__tests__/fixtures/test-prd-concerns.md`

---

## Regression Testing

### parseTrd() Regression

All existing tests in `src/orchestrator/__tests__/trd-parser.test.ts` must pass without modification. Run:
```bash
npx vitest run src/orchestrator/__tests__/trd-parser.test.ts
```

### Sling Executor Regression

All existing tests in `src/orchestrator/__tests__/sling-executor.test.ts` must pass without modification. Run:
```bash
npx vitest run src/orchestrator/__tests__/sling-executor.test.ts
```

### Existing Sling CLI Regression

All existing tests in `src/cli/__tests__/sling.test.ts` must pass without modification. Run:
```bash
npx vitest run src/cli/__tests__/sling.test.ts
```

---

## Coverage Targets

| Test Suite | Coverage Target | Notes |
|-----------|----------------|-------|
| `trd-parser-foreman.test.ts` | 80%+ statement | New test file for parseTrd() with foreman TRD |
| `sling-prd.test.ts` | 80%+ statement | New test file for `sling prd` subcommand |
| Existing tests (no regression) | All passing | Zero new failures in existing test files |

---

## Edge Cases to Test

| Edge Case | Expected Behavior | AC Coverage |
|-----------|-----------------|------------|
| TRD with 0 tasks (empty sprints) | `SLING-002` thrown by parseTrd() | AC-001-2 |
| TRD with malformed table (missing ID column) | `SLING-010` thrown by parseTrd() | AC-001-2 |
| TRD with `[x]` status markers | Tasks created as `completed` (skipped by default) | AC-001-3 |
| TRD with lowercase task IDs (`at-t001`) | IDs parsed but risk register can't extract them | AC-003-6 |
| TRD with forward dependency references | `SLING-007` logged, dependency not wired | Risk 7 |
| PRD with readiness FAIL score | `sling prd` halts with warning | AC-002-1 |
| PRD with readiness CONCERNS score | `sling prd` warns but continues | AC-002-1 |
| Idempotent re-run (same PRD twice) | Second run: tasks skipped, no duplicates | AC-004-3 |
| `--force` refresh | Second run: tasks updated (not skipped) | AC-004-3 |
| Non-existent PRD path | Error: "PRD file not found" | AC-002-1 |
| Empty PRD (no requirements) | `create-trd-foreman` generates TRD with no tasks | AC-001-1 |
