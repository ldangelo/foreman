---
document_id: TRD-2026-81f29bf4
label: trd-autopr-task-title-body
version: 1.0.1
status: Draft
date: 2026-09-18
prd_reference: docs/PRD/PRD-2026-81f29bf4-autopr-task-title-body.md
prd_label: prd-autopr-task-title-body
scale_depth: STANDARD
total_requirements: 12
total_acceptance_criteria: 31
design_readiness_score: 4.8
readiness_score: 4.8
total_tasks: 24
total_hours_estimate: 62
kind: trd
---

# TRD: Include bead/task title and description in AutoPR PR summary

Foreman task title read from `FOREMAN_TASK_TITLE`: **Include bead/task title and description in AutoPR-generated PR summary**.

Source PRD: `docs/PRD/PRD-2026-81f29bf4-autopr-task-title-body.md` (`PRD-2026-81f29bf4`).

## PRD Validation Summary

- Required PRD sections present: executive summary, background/evidence, personas, scope, assumptions, requirements, dependency map, technical mapping, self-review, readiness gate.
- Requirements: 12 sequential `REQ-NNN` IDs.
- Acceptance criteria: 31 `AC-NNN-M` items, Given/When/Then format.
- PRD readiness score: **4.8 PASS**.
- Subject match: PRD title and `FOREMAN_TASK_TITLE` both describe task/bead title+description in final AutoPR-generated PR summary.
- MCP enhancement: skipped (no MCP tools detected).

## 1. Executive Summary

This TRD plans the brownfield change that makes final run AutoPRs use approved task metadata. Task-backed and Beads-backed runs will thread `Task.title` and `Task.description` into `ForemanServer.Workflow.AutoPR`; AutoPR will use them exactly as `gh pr create --title` and `--body`. Runs without a task keep legacy generated title/body behavior. Task-backed runs with missing, blank, or non-string metadata fail loudly with a typed validation error before publish/create side effects.

Scope is final run AutoPR only. `PhasePR` behavior, task lifecycle, Beads dispatch, and custom CLI flags remain unchanged.

## 2. Domain Analysis

| Domain | Requirements | Existing source | Design implication |
|---|---|---|---|
| Run finalization | REQ-001, REQ-004, REQ-006, REQ-007 | `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` | Add task metadata to final AutoPR context at the executor boundary only. |
| AutoPR composition | REQ-002, REQ-003, REQ-005, REQ-008, REQ-012 | `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex` | Add typed content selection/validation before push/create; keep branch probes unchanged. |
| Typed failure handling | REQ-005, REQ-009 | `AutoPR.maybe_create_pr/1`, `RunExecutor.finalize_run/1` | Return typed metadata errors and keep result handling total. |
| Integration testing | REQ-004, REQ-006, REQ-007, REQ-008 | `auto_pr_test.exs`, `run_executor_test.exs` | Use command-runner seam/no-network tests and real task aggregate/projection path. |
| Documentation | REQ-010, REQ-011 | `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`, `AGENTS.md` | Update only behavior-facing docs; note no-change rationale for agent policy if unchanged. |

Brownfield status: existing Elixir/Phoenix/OTP backend and Go CLI. No schema migration required.

## 3. Capability Reuse Check

`trd-graph-cli capabilities docs/TRD --json` returned an empty capability registry. `trd-graph-cli overlap docs/TRD` reported no overlapping target files across TRDs. No foundational TRD provides this exact capability.

Reusable in-repo capabilities:

| Capability | Reuse source | Usage |
|---|---|---|
| Final AutoPR branch/base handling | `ForemanServer.Workflow.AutoPR` | Preserve head/base resolution, commits-ahead gate, push, `gh pr create`, noop/error behavior. |
| Task metadata in run state | `RunExecutor` state/task projection and `plan_subject_env/1` precedent | Source `Task.title`/`Task.description` without provider calls. |
| Command side-effect seam | Existing test stubs/Mox patterns | Capture `git`/`gh` args without live GitHub. |
| Documentation discipline | `AGENTS.md` | Review docs set before finalization. |

## 4. Architecture Alternatives

### Option A — Compose title/body in `RunExecutor` before calling AutoPR

- **Pros:** Smallest diff; AutoPR receives plain strings.
- **Cons:** Splits PR content policy away from PR creation; duplicate validation likely; executor must know legacy body/finding behavior.
- **Complexity:** Low.
- **Risk:** Medium; weak boundary ownership.

### Option B — Add user-configurable AutoPR title/body templates

- **Pros:** Flexible long term.
- **Cons:** Overbuilds PRD; adds config surface, docs, escaping, validation, and migration concerns.
- **Complexity:** High.
- **Risk:** High; unnecessary behavior surface.

### Option C — Typed task metadata in AutoPR context (chosen)

- **Pros:** Best fit for current code; preserves AutoPR ownership of PR content and side effects; narrow executor plumbing; deterministic tests; supports loud metadata errors.
- **Cons:** Requires explicit context validation and total result handling.
- **Complexity:** Medium.
- **Risk:** Low-medium, mitigated by focused and integration tests.

Foreman mode: auto-selected Option C (typed task metadata in AutoPR context).

## 5. System Architecture Design

### 5.1 Components

| Component | Responsibility | Change |
|---|---|---|
| `RunExecutor.auto_pr_context/2` | Build final AutoPR context | Add `:task_title` and `:task_description` only for task-backed runs. |
| `RunExecutor` task metadata extractor | Normalize run-state task shape | Accept canonical atom/string keys; reject malformed-present values by passing them to AutoPR validation rather than silently falling back. |
| `AutoPR.TaskMetadataError` | Typed validation error | New struct with `run_id`, `field`, and `reason` (`:missing`, `:blank`, `:invalid`). |
| `AutoPR.pr_content/1` | Select title/body | Task-backed metadata path returns exact title/body; no-task path returns legacy generated title/body+findings. |
| `AutoPR.open_pr/6` | Invoke `gh pr create` | Use content returned by validated content selector; keep args list, no shell interpolation. |
| Tests | Regression proof | Add command-runner seam and executor context test through real task state. |
| Docs | Operator expectations | Describe final AutoPR task title/body behavior where user-facing. |

### 5.2 Data Flow

```text
Task aggregate/projection
  -> RunExecutor state.task
  -> auto_pr_context/2 adds :task_title/:task_description for task-backed run
  -> AutoPR.maybe_create_pr/1 resolves head branch
  -> git rev-list checks commits ahead
  -> AutoPR validates task metadata and selects content
  -> git push publishes head branch
  -> gh pr create receives --title Task.title --body Task.description
  -> PrAssociated records final PR URL unchanged
```

No-task flow remains:

```text
RunExecutor context without task metadata
  -> AutoPR legacy content selector
  -> title "feat(run): <run_id>"
  -> generated run body + artifact link + unresolved review findings
```

### 5.3 Interfaces

| Boundary | Input | Output/error |
|---|---|---|
| `RunExecutor.auto_pr_context/2` | run state, base branch | AutoPR context with existing keys plus optional task metadata. |
| `AutoPR.maybe_create_pr/1` | `%{run_id, base_branch, head_branch, cwd?, artifact_path?, task_title?, task_description?}` | `{:ok, pr_url}`, `:noop`, or `{:error, reason}`. |
| `AutoPR.TaskMetadataError` | malformed task-backed metadata | `%TaskMetadataError{run_id, field, reason}` returned before push/create. |
| Command runner seam | executable, argv, opts | `{output, exit_code}`; tests capture argv. |
| `gh pr create` | argv list | `--title` and `--body` values are single args, not shell strings. |

### 5.4 Error Handling and Logging

- Missing, blank, or non-string task title/description on task-backed runs returns typed metadata error.
- Metadata validation happens after commits-ahead detects real work and before `git push`/`gh pr create`, so invalid metadata causes no PR side effects.
- Logs may include run id, branch, field, and reason. Logs must not print full task description.
- Existing `git`/`gh` failure handling and sanitization remain unchanged.

## Master Task List

### PR 1: AutoPR content contract

**Shippable State:** Final AutoPR can use exact task title/body or fail safely before PR side effects when task metadata is invalid.

- [x] **TRD-001**: Add `AutoPR.TaskMetadataError` typed error and task metadata fields to the AutoPR context contract (2h) [satisfies REQ-005, REQ-009]
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-009-1, AC-009-3.
  - Implementation AC:
    - Given malformed task metadata, when AutoPR validates content, then it returns `%TaskMetadataError{}` with field and reason.
    - Given no task metadata keys are present, when AutoPR validates content, then legacy fallback remains available.

- [x] **TRD-001-TEST**: Add focused tests for typed metadata errors and legacy no-task fallback (2h) [verifies TRD-001] [satisfies REQ-005, REQ-008, REQ-009] [depends: TRD-001]
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-008-3, AC-009-1.
  - Implementation AC:
    - Given blank/non-string/missing task-backed fields, when tested, then each expected error reason is asserted.
    - Given no task metadata keys, when tested, then generated legacy title/body still appear.

- [x] **TRD-002**: Implement AutoPR PR content selection that uses exact task title/body when task metadata keys are present (3h) [satisfies REQ-002, REQ-003, REQ-012] [depends: TRD-001]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-003-1, AC-003-2, AC-003-3, AC-012-1.
  - Implementation AC:
    - Given task title/description, when `gh pr create` args are built, then title/body equal task metadata exactly.
    - Given artifact findings exist, when task body path is used, then findings are not appended.

- [x] **TRD-002-TEST**: Add AutoPR command-argument tests for exact task title/body, multiline Markdown, and shell-special characters (3h) [verifies TRD-002] [satisfies REQ-002, REQ-003, REQ-008, REQ-012] [depends: TRD-002]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-003-1, AC-003-2, AC-003-3, AC-008-1, AC-008-2, AC-012-2.
  - Implementation AC:
    - Given multiline Markdown body, when command args are captured, then body is one arg preserving line breaks.
    - Given shell-special title text, when args are captured, then no shell interpolation occurs.

- [x] **TRD-003**: Add a command-runner seam to AutoPR so tests can capture `git`/`gh` boundaries without network (2h) [satisfies REQ-007, REQ-008]
  - Validates PRD ACs: AC-007-2, AC-007-3, AC-008-1.
  - Implementation AC:
    - Given `command_runner` is supplied, when AutoPR runs commands, then it calls the seam instead of `System.cmd/3`.
    - Given no seam is supplied, when production code runs, then `System.cmd/3` behavior remains unchanged.

- [x] **TRD-003-TEST**: Add seam tests proving command order: rev-list, metadata validation, push, then PR create (2h) [verifies TRD-003] [satisfies REQ-004, REQ-007, REQ-008] [depends: TRD-003, TRD-001, TRD-002]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-007-2, AC-007-3.
  - Implementation AC:
    - Given invalid metadata and commits ahead, when AutoPR runs, then rev-list occurs but push and gh do not.
    - Given valid metadata and commits ahead, when AutoPR runs, then push precedes gh create.

### PR 2: RunExecutor task metadata plumbing

**Shippable State:** Task-backed final AutoPR receives approved task title/description from run state while no-task runs still generate legacy PR summaries.

- [x] **TRD-004**: Extend final `RunExecutor` AutoPR context with `:task_title` and `:task_description` for task-backed runs only (3h) [satisfies REQ-001, REQ-004, REQ-006]
  - Validates PRD ACs: AC-001-1, AC-001-3, AC-004-3, AC-006-2.
  - Implementation AC:
    - Given state has task metadata, when context is built, then explicit task keys are present.
    - Given state has no task aggregate, when context is built, then task keys are absent.

- [x] **TRD-004-TEST**: Add executor context tests for task-backed and no-task runs preserving existing AutoPR fields (3h) [verifies TRD-004] [satisfies REQ-001, REQ-004, REQ-006] [depends: TRD-004]
  - Validates PRD ACs: AC-001-1, AC-001-3, AC-004-3, AC-006-2.
  - Implementation AC:
    - Given task-backed state, when helper/test seam builds context, then run/base/artifact/head/cwd and task fields are asserted.
    - Given no-task state, when context is built, then legacy fields are unchanged and task fields absent.

- [x] **TRD-005**: Implement task metadata extraction for canonical atom-keyed and string-keyed task shapes without accepting unknown fields (2h) [satisfies REQ-001, REQ-009] [depends: TRD-004]
  - Validates PRD ACs: AC-001-2, AC-009-2.
  - Implementation AC:
    - Given atom-keyed task title/description, when extracted, then exact values are used.
    - Given string-keyed task title/description, when extracted, then exact values are used.
    - Given unknown task keys, when extracted, then they are ignored.

- [x] **TRD-005-TEST**: Add extractor tests for atom keys, string keys, unknown keys, nil, blank, and non-string values flowing to AutoPR validation (3h) [verifies TRD-005] [satisfies REQ-001, REQ-005, REQ-009] [depends: TRD-005]
  - Validates PRD ACs: AC-001-2, AC-005-1, AC-005-2, AC-009-1, AC-009-2.
  - Implementation AC:
    - Given malformed-present fields, when final AutoPR context reaches AutoPR, then typed validation fails instead of silent no-task fallback.
    - Given unknown keys, when tests inspect context, then unknown values are not propagated.

- [x] **TRD-006**: Preserve final-only AutoPR behavior by avoiding `PhasePR` title/body paths and existing phase PR skip semantics (2h) [satisfies REQ-006]
  - Validates PRD ACs: AC-002-3, AC-006-1, AC-006-2.
  - Implementation AC:
    - Given phase PR records exist, when run finalization evaluates final AutoPR, then existing skip behavior is unchanged.
    - Given no phase PR records exist, when final AutoPR runs, then task title/body apply only to final PR.

- [x] **TRD-006-TEST**: Add regression tests showing `PhasePR` behavior and phase-PR skip logic are unchanged (3h) [verifies TRD-006] [satisfies REQ-002, REQ-006] [depends: TRD-006]
  - Validates PRD ACs: AC-002-3, AC-006-1, AC-006-2.
  - Implementation AC:
    - Given `PhasePR` creates/reuses phase PRs, when tests run, then phase titles do not use task metadata.
    - Given phase PR statuses exist, when finalization runs, then final AutoPR remains skipped as before.

### PR 3: Integration proof and branch behavior preservation

**Shippable State:** A task-backed run reaching final AutoPR opens/reuses the final PR with task title/body while preserving branch/noop/error behavior.

- [x] **TRD-007**: Add real Task aggregate/run-state integration path so final AutoPR context receives task title/description from task state (4h) [satisfies REQ-001, REQ-007] [depends: TRD-004, TRD-005]
  - Validates PRD ACs: AC-001-1, AC-007-1, AC-007-2, AC-007-3.
  - Implementation AC:
    - Given created/approved Task aggregate metadata, when final AutoPR boundary is reached, then captured context contains that metadata.
    - Given local GitHub is unavailable, when test runs, then command runner seam prevents network calls.

- [x] **TRD-007-TEST**: Add integration test through task creation/approval/run finalization boundary capturing final PR `gh` args (5h) [verifies TRD-007] [satisfies REQ-001, REQ-002, REQ-003, REQ-007] [depends: TRD-007, TRD-003]
  - Validates PRD ACs: AC-001-1, AC-002-1, AC-003-1, AC-007-1, AC-007-2, AC-007-3.
  - Implementation AC:
    - Given task title/body in aggregate, when final PR would be created, then captured `--title`/`--body` equal aggregate values.
    - Given DB/GitHub are unavailable, when focused test runs, then no external network dependency exists.

- [x] **TRD-008**: Preserve commits-ahead noop, base/head resolution, push-before-create, PR association, and error semantics with task metadata present (3h) [satisfies REQ-004, REQ-006, REQ-009] [depends: TRD-002, TRD-004]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-006-2, AC-009-3.
  - Implementation AC:
    - Given no commits ahead, when task metadata exists, then AutoPR returns `:noop` and does not call `gh`.
    - Given base branch resolution fails, when finalization runs, then typed base-branch error is returned unchanged.

- [x] **TRD-008-TEST**: Add branch behavior regression tests with task metadata present (4h) [verifies TRD-008] [satisfies REQ-004, REQ-006, REQ-009] [depends: TRD-008]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-006-2, AC-009-3.
  - Implementation AC:
    - Given no commits ahead plus task metadata, when test runs, then result is `:noop`.
    - Given commits ahead plus task metadata, when test captures commands, then push occurs before create.
    - Given base error, when test runs, then error is not masked by metadata fallback.

- [x] **TRD-009**: Audit AutoPR and RunExecutor logging to avoid raw task description leakage (2h) [satisfies REQ-012]
  - Validates PRD ACs: AC-005-2, AC-012-1, AC-012-2.
  - Implementation AC:
    - Given description contains sensitive-looking content, when success/failure logs are emitted, then full body text is absent.
    - Given metadata validation fails, when logs are emitted, then field/reason/run id are present without body text.

- [x] **TRD-009-TEST**: Add logging/redaction tests or assertions for task description not being logged by new code paths (3h) [verifies TRD-009] [satisfies REQ-005, REQ-012] [depends: TRD-009]
  - Validates PRD ACs: AC-005-2, AC-012-1, AC-012-2.
  - Implementation AC:
    - Given a sentinel secret in description, when new log paths execute, then captured logs do not contain the sentinel.
    - Given `gh pr create` fails, when result/logs are inspected, then no new log line contains the raw body.

### PR 4: Documentation and release validation

**Shippable State:** Operators and maintainers can see the final AutoPR task-title/task-body behavior documented and verified by focused compile/test gates.

- [x] **TRD-010**: Review and update behavior-facing docs for final AutoPR task title/body (`README.md`, `docs/user-guide.md`, `docs/cli-reference.md`) (3h) [satisfies REQ-011]
  - Validates PRD ACs: AC-011-1.
  - Implementation AC:
    - Given docs mention final AutoPR title/body, when updated, then they describe task title as PR title and task description as PR body for task-backed runs.
    - Given a doc has no relevant behavior text, when reviewed, then no unrelated text is changed.

- [x] **TRD-010-TEST**: Add documentation verification notes and grep/source checks for changed AutoPR docs (1h) [verifies TRD-010] [satisfies REQ-011] [depends: TRD-010]
  - Validates PRD ACs: AC-011-1, AC-011-2.
  - Implementation AC:
    - Given changed docs, when verification runs, then referenced behavior matches source/tests.
    - Given untouched docs, when output is prepared, then no-change rationale is recorded.

- [x] **TRD-011**: Review `CLAUDE.md` and `AGENTS.md` for operator/agent expectation changes; update surgically or record no-change rationale (2h) [satisfies REQ-010, REQ-011]
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-011-1, AC-011-2.
  - Implementation AC:
    - Given agent policy docs mention AutoPR or Foreman commit expectations, when behavior changes, then text is updated accurately.
    - Given no policy behavior changes are needed, when final output is written, then rationale is explicit.

- [x] **TRD-011-TEST**: Verify doc-policy consistency and no accidental claims about user-authored commits/hooks (1h) [verifies TRD-011] [satisfies REQ-010, REQ-011] [depends: TRD-011]
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-011-2.
  - Implementation AC:
    - Given docs mention commit behavior, when reviewed, then they do not contradict Foreman author/no-verify policy.
    - Given `AGENTS.md` is unchanged, when final notes are written, then the review rationale is present.

- [x] **TRD-012**: Run implementation validation gates and prepare final proof artifact (2h) [satisfies REQ-004, REQ-007, REQ-008, REQ-009, REQ-011, REQ-012] [depends: TRD-001-TEST, TRD-002-TEST, TRD-003-TEST, TRD-004-TEST, TRD-005-TEST, TRD-006-TEST, TRD-007-TEST, TRD-008-TEST, TRD-009-TEST, TRD-010-TEST, TRD-011-TEST]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-007-1, AC-007-2, AC-007-3, AC-008-1, AC-008-2, AC-008-3, AC-009-1, AC-009-2, AC-009-3, AC-011-1, AC-011-2, AC-012-1, AC-012-2.
  - Implementation AC:
    - Given focused tests and compile gates, when they pass or are blocked by environment, then final proof records exact commands and results.
    - Given local Postgres blocks integration tests, when finalizing, then report blocked tests truthfully and include passing compile/diff checks.

- [x] **TRD-012-TEST**: Validate the final task graph with `trd-cli parse`, compile/tests, and `git diff --check` before implementation completion (2h) [verifies TRD-012] [satisfies REQ-004, REQ-007, REQ-008, REQ-009, REQ-011, REQ-012] [depends: TRD-012]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-007-3, AC-008-1, AC-008-2, AC-008-3, AC-009-3, AC-011-1, AC-012-2.
  - Implementation AC:
    - Given TRD file exists, when parsed, then all intended tasks are found and no task parser warnings exist.
    - Given repo diff exists, when whitespace check runs, then no whitespace errors are reported.

## Sprint Planning

## Sprint 1: AutoPR content boundary

- PR 1: typed metadata validation, exact content selection, command runner seam, focused AutoPR tests.

## Sprint 2: Executor integration

- PR 2: final AutoPR context plumbing, task shape extraction, final-only/PhasePR guard tests.

## Sprint 3: End-to-end proof

- PR 3: real Task aggregate/run-state proof, branch/noop/error behavior regression, log leakage tests.

## Sprint 4: Operator-facing completion

- PR 4: docs review/updates, policy no-change rationale, validation artifact.

## 8. Dependency Graph

```text
TRD-001 -> TRD-002 -> TRD-002-TEST
TRD-001 -> TRD-001-TEST
TRD-003 -> TRD-003-TEST
TRD-004 -> TRD-004-TEST
TRD-004 -> TRD-005 -> TRD-005-TEST
TRD-004,TRD-005 -> TRD-007 -> TRD-007-TEST
TRD-002,TRD-004 -> TRD-008 -> TRD-008-TEST
TRD-006 -> TRD-006-TEST
TRD-009 -> TRD-009-TEST
TRD-010 -> TRD-010-TEST
TRD-011 -> TRD-011-TEST
all tests -> TRD-012 -> TRD-012-TEST
```

No circular dependencies identified. Longest chain depth is acceptable for a four-PR stack. No task is estimated at 8h+. Total estimate: 62h.

Dependency graph refinement note: implementation tasks are sequenced before their paired test tasks; cross-PR dependencies flow backward only, so each PR remains shippable without depending on later PR work.

## Acceptance Criteria Traceability

| REQ-NNN | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 | Carry task title/description into AutoPR context | TRD-004, TRD-005, TRD-007 | TRD-004-TEST, TRD-005-TEST, TRD-007-TEST |
| REQ-002 | Use task title as final AutoPR title | TRD-002, TRD-006 | TRD-002-TEST, TRD-006-TEST, TRD-007-TEST |
| REQ-003 | Use task description as final AutoPR body | TRD-002 | TRD-002-TEST, TRD-007-TEST |
| REQ-004 | Preserve existing AutoPR eligibility and branch behavior | TRD-004, TRD-008, TRD-012 | TRD-003-TEST, TRD-008-TEST, TRD-012-TEST |
| REQ-005 | Define safe fallback behavior for missing metadata | TRD-001 | TRD-001-TEST, TRD-005-TEST, TRD-009-TEST |
| REQ-006 | Keep final AutoPR separate from phase PR behavior | TRD-004, TRD-006, TRD-008 | TRD-004-TEST, TRD-006-TEST, TRD-008-TEST |
| REQ-007 | Verify with a real Task aggregate and AutoPR call | TRD-003, TRD-007, TRD-012 | TRD-003-TEST, TRD-007-TEST, TRD-012-TEST |
| REQ-008 | Cover AutoPR title/body composition with focused tests | TRD-001, TRD-002, TRD-003, TRD-012 | TRD-001-TEST, TRD-002-TEST, TRD-003-TEST, TRD-012-TEST |
| REQ-009 | Preserve typed boundary and loud failure conventions | TRD-001, TRD-005, TRD-008, TRD-012 | TRD-001-TEST, TRD-005-TEST, TRD-008-TEST, TRD-012-TEST |
| REQ-010 | Preserve Foreman commit/operator expectations | TRD-011 | TRD-011-TEST |
| REQ-011 | Update user-facing docs only where behavior changes | TRD-010, TRD-011, TRD-012 | TRD-010-TEST, TRD-011-TEST, TRD-012-TEST |
| REQ-012 | Avoid leaking sensitive task content into logs | TRD-002, TRD-009, TRD-012 | TRD-002-TEST, TRD-009-TEST, TRD-012-TEST |

Traceability check: 12 requirements covered, 0 uncovered, 0 orphaned annotations.

## 10. Adversarial Review

### 10.1 Architecture issues

1. **Issue:** If `RunExecutor` adds `nil` task metadata for every run, no-task runs could incorrectly fail instead of using legacy fallback.  
   **Resolution:** Add task metadata keys only for task-backed runs; no-task contexts omit both keys.

2. **Issue:** If content validation happens after `git push`, invalid metadata could publish a branch even though PR creation fails.  
   **Resolution:** Validate task title/body after commits-ahead and before push/create.

3. **Issue:** Appending legacy findings to task descriptions would violate PRD exact-body requirement.  
   **Resolution:** Content selector has two exclusive paths: task metadata exact body, or no-task legacy generated body.

### 10.2 Task coverage issues

1. **Issue:** Branch behavior regressions are easy to miss if tests only assert title/body.  
   **Resolution:** TRD-008 and TRD-008-TEST explicitly cover noop, base errors, push-before-create, and PR association behavior.

2. **Issue:** Docs can drift because behavior is backend-only and easy to under-document.  
   **Resolution:** TRD-010/TRD-011 require review of README, user guide, CLI reference, CLAUDE, and AGENTS with update/no-change rationale.

Task parser self-check required: `trd-cli parse` must find all 24 tasks and no `No tasks found` warning.

### 10.3 Dependency and estimate issues

1. **Issue:** Real Task aggregate integration may depend on local EventStore/Postgres and become flaky.  
   **Resolution:** Keep deterministic no-network command seam; if DB auth blocks local execution, final proof must report the block truthfully and rely on compile/focused unit checks until DB fixed.

2. **Issue:** Task-backed detection can be ambiguous if run state contains partial task maps.  
   **Resolution:** Define task-backed by run source/task id; malformed metadata stays present and fails typed validation rather than silently becoming no-task fallback.

### 10.4 Testability issues

1. **Issue:** "Sensitive content not logged" can become subjective.  
   **Resolution:** Use a sentinel body string in tests/log capture; pass/fail is exact absence from new log messages.

2. **Issue:** Shell-safety claims can be vague.  
   **Resolution:** Assert captured argv list positions for `--title` and `--body`; do not inspect shell-quoted strings.

## 11. Design Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Architecture completeness | 4.8 | Components, boundaries, validation timing, and data flows defined; no migration required. |
| Task coverage | 4.9 | Every PRD requirement has implementation and test tasks; traceability matrix complete. |
| Dependency clarity | 4.7 | Dependencies are explicit and acyclic; integration/DB risk called out. |
| Estimate confidence | 4.7 | Tasks are granular; none exceed 5h; estimates align with focused Elixir/backend/docs scope. |

Overall design readiness score: **4.8**  
Gate decision: **PASS**

## 12. Output and Next Steps

- TRD file: `docs/TRD/TRD-2026-81f29bf4-autopr-task-title-body.md`
- Task count: 24
- Source PRD correlation id: `81f29bf4`

Suggested next commands:

```sh
/ensemble-configure-team docs/TRD/TRD-2026-81f29bf4-autopr-task-title-body.md
/ensemble-implement-trd-beads docs/TRD/TRD-2026-81f29bf4-autopr-task-title-body.md
```

## Version History

- **1.0.1** — 2026-09-18 — Foreman refinement pass: added total hour estimate metadata, clarified dependency graph sequencing, recorded PR-stack shippability validation, and preserved 24-task scope/readiness.
- **1.0.0** — 2026-09-18 — Initial TRD generated from PRD-2026-81f29bf4.
