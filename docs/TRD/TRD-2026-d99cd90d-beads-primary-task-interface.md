---
document_id: TRD-2026-d99cd90d
label: trd-beads-primary-interface
kind: trd
prd_reference: docs/PRD/PRD-2026-d99cd90d-beads-primary-task-interface.md
architecture_reference: docs/TRD/TRD-2026-d99cd90d-beads-primary-task-interface-ARCHITECTURE.md
version: 1.3.0
status: Final
date: 2026-09-13
design_readiness_score: 4.5
ensemble_implement_trd_beads:
  branch_name: feature/trd-2026-d99cd90d-beads-primary-task-interface
  use_proposed: false
  stacked_prs: false
---

# TRD: Beads as the Primary Task Interface — Master Task List

## Metadata

| Field | Value |
|---|---|
| Document ID | TRD-2026-d99cd90d |
| Label | trd-beads-primary-interface |
| PRD Reference | docs/PRD/PRD-2026-d99cd90d-beads-primary-task-interface.md |
| Architecture Reference | docs/TRD/TRD-2026-d99cd90d-beads-primary-task-interface-ARCHITECTURE.md (v1.6.0, Final) |
| Version | 1.3.0 |
| Status | Final |
| Correlation ID | d99cd90d (shared with source PRD) |
| Design Readiness Score | 4.5 (PASS) |

## Source

Implements PRD-2026-d99cd90d v1.4.0 (10 requirements) per the finalized
Phase 2.4 architecture (Option B, Full Bidirectional Sync). All 3
architectural risks and 5 open design questions were resolved by
interview before this task breakdown — see the architecture doc's §7.5
and §8.

## Master Task List

### PR 1: Manifest-Declared Type Mapping and Doctor Coverage

**Shippable State:** Operators can declare `task_types:` in a workflow
manifest and run `foreman doctor` to see which beads `issue_type`
values have no mapped workflow, in both human-readable and `--json`
form. No watcher behavior changes yet — this PR is purely additive
catalog/doctor capability.

- [x] **TRD-001**: Add `task_types:` field to workflow YAML parser; fail closed on collision between two workflows declaring the same type [satisfies REQ-001] (2h)
- [x] **TRD-001-TEST**: Test collision detection (two workflows, same type) and omitted-field non-triggering [satisfies REQ-001] [verifies TRD-001] Validates PRD ACs: AC-001-1, AC-001-2 (1h) [depends: TRD-001]
- [x] **TRD-002**: Build `Catalog.type_to_workflow/1` reverse map in GenServer state; rebuild on every manifest file change (hot-reload) [satisfies REQ-001] (2h) [depends: TRD-001]
- [x] **TRD-002-TEST**: Test hot-reload rebuilds the map on file change; multiple types mapping to one workflow [satisfies REQ-001] [verifies TRD-002] Validates PRD ACs: AC-001-3 (1h) [depends: TRD-002]
- [x] **TRD-003**: Implement `Workflow.Catalog.Doctor` type coverage report: query non-closed issue_types via `BeadsAdapter`, diff against `type_to_workflow`, ASCII tree default output, `--json` flag [satisfies REQ-002] (3h) [depends: TRD-002]
- [x] **TRD-003-TEST**: Test doctor reports unmapped types by name in both ASCII and JSON; reports full coverage when none unmapped [satisfies REQ-002] [verifies TRD-003] Validates PRD ACs: AC-002-1, AC-002-2 (1h) [depends: TRD-003]

**PR 1 subtotal: 10h**

### PR 2: Status-Gated Watcher Import

**Shippable State:** The watcher only imports beads with `status:
open`; a bead requiring `trd_path` that lacks one is moved to
`blocked` with an operator-visible comment instead of silently
failing; the watcher refuses to start on a corrupted/partial Beads
export instead of silently importing a fraction of the backlog; and
new `open` beads are picked up within ~1 second instead of waiting
for the next poll cycle.

- [x] **TRD-004**: Add status gate to `BeadsWatcher.process_line/2` (new `check_status/1`): accept only `status: "open"`, emit `[:watcher, :status_gate, :skipped]` for others [satisfies REQ-003] (3h) [depends: TRD-002]
- [x] **TRD-004-TEST**: Test gate rejects `draft`/`blocked`/`closed`, accepts `open` directly (no `draft` intermediate required) [satisfies REQ-003] [verifies TRD-004] Validates PRD ACs: AC-003-1, AC-003-3 (1h) [depends: TRD-004]
- [x] **TRD-005**: Wire workflow selection into `BeadsWatcher`: query `Catalog.type_to_workflow(issue_type)`, emit `:unmapped_type` and hold (transient) when no mapping exists [satisfies REQ-001] (2h) [depends: TRD-004]
- [x] **TRD-005-TEST**: Test unmapped type holds transient and emits telemetry rather than creating a task [satisfies REQ-001] [verifies TRD-005] (1h) [depends: TRD-005]
- [x] **TRD-006**: Implement `trd_path` extraction from `agent_context`; missing/empty when required moves the bead to `blocked` + transition comment (exact text per architecture §8.4) [satisfies REQ-007] (3h) [depends: TRD-005]
- [x] **TRD-006-TEST**: Test missing `trd_path` blocks the bead with the exact comment text and creates no task; present `trd_path` flows into `task.create` [satisfies REQ-007] [verifies TRD-006] Validates PRD ACs: AC-007-1, AC-007-2 (1h) [depends: TRD-006]
- [x] **TRD-007**: Implement auto-approval: dispatch `task.create` + `task.approve` as one effective step in `dispatch_new_bead/2` [satisfies REQ-003] (2h) [depends: TRD-006]
- [x] **TRD-007-TEST**: Test a bead transitioning to `open` results in a created-and-approved task with no separate operator action [satisfies REQ-003] [verifies TRD-007] Validates PRD ACs: AC-003-2 (1h) [depends: TRD-007]
- [x] **TRD-008**: Regression test target: full-replay-on-boot (existing, reused from TRD-81315f37) still creates+approves tasks for beads that transitioned while the watcher was offline, layered under the new status gate [satisfies REQ-004] (1h) [depends: TRD-007]
- [x] **TRD-008-TEST**: Test watcher restart replays and imports a bead that went `draft -> open` while stopped [satisfies REQ-004] [verifies TRD-008] Validates PRD ACs: AC-004-1 (1h) [depends: TRD-008]
- [x] **TRD-009**: Implement coverage-drift detection at watcher boot: call `br sync --status --json` before entering the tail loop; refuse to start and alert the operator with exact counts if `coverage_drift == true` [satisfies REQ-004] (2h) [depends: TRD-004]
- [x] **TRD-009-TEST**: Test watcher refuses to start when `coverage_drift == true` (with counts logged) and resumes normally once `false` [satisfies REQ-004] [verifies TRD-009] (1h) [depends: TRD-009]
- [x] **TRD-010**: Acquire `BeadsDbLease` during boot-time full-replay and each periodic catch-up tail [satisfies REQ-004] (2h) [depends: TRD-009]
- [x] **TRD-010-TEST**: Test watcher and a concurrent `RunExecutor`-dispatched `br update` serialize through the lease (no interleaved reads/writes) [satisfies REQ-004] [verifies TRD-010] (2h) [depends: TRD-010]
- [x] **TRD-011**: Implement filesystem watch (primary, <1s) on `.beads/issues.jsonl` with 30s periodic poll backstop, 100ms debounce [satisfies REQ-003] (3h) [depends: TRD-007]
- [x] **TRD-011-TEST**: Test filesystem-watch-triggered read fires within ~1s of a JSONL write; poll backstop catches a missed watch event within 35s [satisfies REQ-003] [verifies TRD-011] (2h) [depends: TRD-011]
- [x] **TRD-012**: Add fine-grained telemetry buckets per skip reason (`:unmapped_type`, `:missing_trd_path`, `:draft_status`) replacing the single coarse `:skipped` event [satisfies REQ-003] (1h) [depends: TRD-004] [depends: TRD-005] [depends: TRD-006]

**PR 2 subtotal: 29h**

### PR 3: Bidirectional Status Sync and Failure Classification

**Shippable State:** A dispatched run's bound bead moves to
`in_progress` when the run starts, `closed` on success, and `blocked`
with a reason on unrecoverable or retry-exhausted failure — fully
automatically, with no operator action required for the common case.

- [x] **TRD-013**: Fix `BeadsAdapter.fail/3` hardcoded `--status open` (2 literals, request map + argv) to `--status blocked` [satisfies REQ-005] (1h)
- [x] **TRD-013-TEST**: Test `fail/3` moves the bead to `blocked` (not `open`) with the transition comment [satisfies REQ-005] [verifies TRD-013] Validates PRD ACs: AC-005-4 (1h) [depends: TRD-013]
- [x] **TRD-014**: Create `ForemanServer.Workflow.FailureClassifier.classify/1`: pattern-match transient (`:model_unreachable`, `:provider_unavailable`, `:database_unavailable`, `:network_error`, `:worker_dispatch_error`) vs. permanent (`:validation_error`, `:workflow_definition_error`, `:agent_error`, `:phase_terminal`); default permanent [satisfies REQ-005] (2h)
- [x] **TRD-014-TEST**: Parametrized test over every documented error pattern; unknown error defaults to permanent [satisfies REQ-005] [verifies TRD-014] (2h) [depends: TRD-014]
- [x] **TRD-015**: Wrap `RunExecutor`'s existing dispatch call (the code path preceding the existing `fail/3` call site at `run_executor.ex:129`) in a transient retry loop: 3 attempts max, waits of 1s (before attempt 2), 5s (before attempt 3), 15s (settle wait before escalating on the 3rd failure — not a 4th attempt). No new call sites; the existing `fail/3` call is only reached once permanent or transient-exhausted [satisfies REQ-005] (3h) [depends: TRD-014]
- [x] **TRD-015-TEST**: Test retry timing matches the 1s/5s/15s schedule exactly; 3rd transient failure escalates and invokes the existing `fail/3` call site after the 15s wait, with no 4th dispatch attempt; a permanent-classified failure skips retry and invokes `fail/3` immediately [satisfies REQ-005] [verifies TRD-015] Validates PRD ACs: AC-005-3 (2h) [depends: TRD-015]
- [x] **TRD-016**: Verify (and fix if needed) that the existing `claim/3` call site (`run_executor.ex:100`) fires before phase 1 dispatch, and the existing `complete/3` call site (line 113) fires on run success — no new wiring expected, this is a confirmation task per the corrected architecture §2.4 [satisfies REQ-005] (1h) [depends: TRD-013]
- [x] **TRD-016-TEST**: End-to-end test: run start → `in_progress` (via existing `claim/3`), run success → `closed` (via existing `complete/3`), run terminal failure → `blocked` with reason (via fixed `fail/3`) [satisfies REQ-005] [verifies TRD-016] Validates PRD ACs: AC-005-1, AC-005-2 (2h) [depends: TRD-016] [depends: TRD-015]

**PR 3 subtotal: 14h**

### PR 4: Beads-Exclusive Task Creation

**Shippable State:** `foreman task create/approve/retry/get` no
longer exist as commands — invoking them produces the CLI's ordinary
"unknown command" error, same as any typo. Beads is now the sole
task-creation interface. The two previously-deleted TRD-implementing
workflow manifests are available again and route correctly through
the new `task_types:` mapping.

- [x] **TRD-018**: Delete `task create`/`task approve`/`task retry`/`task get` CLI subcommands entirely; no custom error handling [satisfies REQ-006] (1h)
- [x] **TRD-018-TEST**: Test invoking any removed `task.*` command produces the CLI's standard "unknown command" error with no task-lifecycle side effect; `run.*` commands unaffected [satisfies REQ-006] [verifies TRD-018] Validates PRD ACs: AC-006-1, AC-006-2 (1h) [depends: TRD-018]
- [x] **TRD-019**: Restore `implement-trd.yaml` and `implement-trd-beads.yaml` workflow manifests with `task_types:` declared [satisfies REQ-008] (1h) [depends: TRD-002]
- [x] **TRD-019-TEST**: Test both manifests load without error, pass REQ-002's conflict validation, and route via `Catalog.type_to_workflow` [satisfies REQ-008] [verifies TRD-019] Validates PRD ACs: AC-008-1 (1h) [depends: TRD-019]

**PR 4 subtotal: 4h**

## Dependency Graph

```
PR 1: TRD-001 -> TRD-002 -> TRD-003
PR 2: TRD-002 -> TRD-004 -> TRD-005 -> TRD-006 -> TRD-007 -> TRD-008
                    |                                  |
                    v                                  v
                 TRD-009 -> TRD-010                 TRD-011
                    |
      TRD-004,005,006 -> TRD-012
PR 3: TRD-013 -> TRD-016 (independent of TRD-014/015)
      TRD-014 -> TRD-015 -> TRD-016-TEST
PR 4: TRD-018 (independent)
      TRD-002 -> TRD-019
```

No circular dependencies. Longest chain: TRD-004 → TRD-005 → TRD-006
→ TRD-007 → TRD-008 (5 tasks, all within `BeadsWatcher.process_line/2`
— an inherently sequential pipeline: status gate, then workflow
selection, then trd_path check, then approval, then boot-replay
regression). Not a parallelization opportunity — each stage's output
gates the next stage's input in the same function.

## Acceptance Criteria Traceability

| PRD AC | Task(s) |
|---|---|
| AC-001-1 | TRD-001-TEST |
| AC-001-2 | TRD-001-TEST |
| AC-001-3 | TRD-002-TEST |
| AC-002-1 | TRD-003-TEST |
| AC-002-2 | TRD-003-TEST |
| AC-003-1 | TRD-004-TEST |
| AC-003-2 | TRD-007-TEST |
| AC-003-3 | TRD-004-TEST |
| AC-004-1 | TRD-008-TEST |
| AC-005-1 | TRD-016-TEST |
| AC-005-2 | TRD-016-TEST |
| AC-005-3 | TRD-015-TEST |
| AC-005-4 | TRD-013-TEST |
| AC-006-1 | TRD-018-TEST |
| AC-006-2 | TRD-018-TEST |
| AC-007-1 | TRD-006-TEST |
| AC-007-2 | TRD-006-TEST |
| AC-008-1 | TRD-019-TEST |
| AC-009-1 | Already satisfied by existing `TaskProvider` contract — no new task (see architecture §2.4) |

18/19 PRD acceptance criteria have a covering task; AC-009-1 needs none (already satisfied by the existing `TaskProvider` contract).

## Summary

- **Total tasks**: 18 implementation + 17 paired test tasks = 35 tasks
- **Total estimated hours**: 57h (PR1: 10h, PR2: 29h, PR3: 14h, PR4: 4h)
- **PRs**: 4, each independently shippable per the Shippable State statements above
- **Requirements covered**: 10/10 (REQ-001 through REQ-009, plus REQ-004 regression coverage). REQ-009 required no new task — already satisfied by the existing `TaskProvider` contract.
- **Architectural risks covered**: 3/3 (coverage drift TRD-009, lease scope TRD-010, status trigger TRD-011)

## Design Readiness Gate Scorecard

| Dimension | Score | Justification |
|---|---:|---|
| Architecture completeness | 5/5 | All components, interfaces, data flows fully defined in the architecture doc (v1.6.0, Final — verified `claim/3`/`complete/3`/`fail/3` already exist and are wired, TaskProvider §2.4 false premise fixed). |
| Task coverage | 5/5 | Every REQ has implementation + test tasks; 18/19 PRD ACs traced (AC-009-1 needs none). |
| Dependency clarity | 4/5 | Dependencies explicit and acyclic; one 5-task sequential chain in PR 2 (inherent to the pipeline, not a design flaw) slightly caps this score. |
| Estimate confidence | 4/5 | Estimates are granular (1-3h) and consistent with sibling PRDs' actuals; no task exceeds the 8h split threshold. |
| **Average** | **4.5** | **PASS** |

## Changelog

- **1.3.0** — 2026-09-13 — Implementation complete. All 35 tasks (18
  impl + 17 test) closed via beads; epic `foreman-31jm` closed.
  Independent completion-verification run: full test suite green
  (2872 tests, 0 failures attributable to this work) after fixing
  several genuine regressions the implementation surfaced (see
  `docs/reports/trd-2026-d99cd90d-beads-primary-task-interface-completion-2026-09-13.md`
  for the full report). Checkboxes flipped to reflect closure.

- **1.2.0** — 2026-09-12 — Converted the Master Task List from markdown
  tables to the checklist format (`- [ ] **TRD-NNN**: ... [annotations]`)
  the ensemble TRD CLI parser requires — the table format silently
  parsed as 0 tasks (`taskCount: 0`, phases/PR-format detected
  correctly, only the task rows were unreadable) despite passing every
  earlier structural review in this session. Added missing `[verifies
  TRD-NNN]` annotations to every test task (required for `bv`
  scheduling and completion-verification traceability; the table
  version never carried this annotation). No content or task-count
  changes — 18 impl + 17 test = 35 tasks, 57h, unchanged. Status
  remains Final.
- **1.1.0** — 2026-09-12 — User reviewed and finalized the corrected
  Master Task List (57h total, 35 tasks). Status Draft → Final.
- **1.0.0** — 2026-09-12 — Initial Master Task List generated from Final
  PRD-2026-d99cd90d v1.4.0 and architecture doc (subsequently corrected
  to v1.5.0 after PR3's tasks were found to duplicate existing
  `claim/3`/`complete/3`/`fail/3` TaskProvider callbacks — see PR3's
  revised task set, which fixes the real gap (`fail/3`'s hardcoded
  `open` status) instead of building parallel new callbacks). 18
  implementation tasks + 17 test tasks across 4 PRs, all 19 PRD ACs
  traced, all 3 architectural risk decisions and all 5 resolved design
  questions incorporated.
