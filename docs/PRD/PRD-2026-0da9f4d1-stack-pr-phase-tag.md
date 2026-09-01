---
document_id: PRD-2026-0da9f4d1
label: prd-stack-pr-phase-tag
version: 1.0.1
status: Draft
date: 2026-09-01
scale_depth: STANDARD
author: Lead Agent
total_requirements: 14
readiness_score: 4.5
readiness_gate: READY_FOREMAN
---

# PRD: Phase-Level `stack_pr:` Tag for Stacked Pull Requests

## Foreman Subject

- Foreman task title: **Add stack_pr phase tag for stacked PRs v7**
- Foreman task description: **Test v7**
- Foreman mode: interviews skipped during initial creation; this refinement resolved the generated clarification markers with best-effort defaults.

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 9 |
| Should | 5 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 14/14 (100%) |
| Risk flags | 6 |
| Dependencies | 14 |
| Open ambiguity markers | 0 |
| External dependencies | 2 |
| Readiness score | 4.5/5.0 |

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Declare a phase-level `stack_pr:` boolean | Must | Low | 2 |
| REQ-002 | Preserve current single-PR behavior by default | Must | Low | 2 |
| REQ-003 | Mark a phase as a stack boundary | Must | Medium | 3 |
| REQ-004 | Create stacked PRs in phase order | Must | High | 3 |
| REQ-005 | Reject malformed `stack_pr:` values | Must | Low | 2 |
| REQ-006 | Require a satisfiable VCS backend for stacking | Must | Medium | 2 |
| REQ-007 | Surface stack creation status to the operator | Should | Medium | 2 |
| REQ-008 | Define interaction with `commit:` deferral | Must | High | 3 |
| REQ-009 | Preserve `stack_pr:` through workflow snapshots | Should | Low | 2 |
| REQ-010 | Use deterministic branch naming for stack entries | Must | Medium | 2 |
| REQ-011 | Handle existing or partially-created PRs safely | Must | High | 3 |
| REQ-012 | Keep bundled workflows unchanged unless explicitly updated | Should | Low | 2 |
| REQ-013 | Document operator-facing workflow semantics | Should | Low | 2 |
| REQ-014 | Emit telemetry for stacked PR operations | Should | Medium | 2 |

Ambiguity scan complete: 0 unresolved clarification markers remain after Foreman-mode refinement.

## Problem Statement

Foreman currently opens at most one pull request for a run, from the run's single branch during finalization. Existing repo guidance says stacked and per-phase PRs are not Foreman manifest behavior today. The requested product change is to add a phase-level `stack_pr:` tag so workflow authors can declare where stacked PR boundaries should exist.

The pain is review granularity. A multi-phase run can produce logically separate review units, but Foreman collapses all committed work into one PR. Operators who want a stack must leave Foreman and use ensemble-skill or manual Git/GitHub flows. The target users are both solo Foreman operators and multi-developer teams running shared workflows.

## Goals

- Let workflow manifests declare stacked PR boundaries at phase level.
- Preserve today's single-PR behavior unless a workflow opts in.
- Make stack creation deterministic, observable, and safe to retry.
- Keep the semantics distinct from `commit:`: `commit:` controls whether a phase commits; `stack_pr:` controls whether a PR boundary is created. A phase with `stack_pr: true` must have a committed slice; pairing it with `commit: false` is invalid.

## Non-Goals

- Changing any existing workflow by default.
- Implementing stacked PRs in ensemble skills; those already have separate behavior.
- Adding top-level `pr:`, `merge:`, `stacked:`, or `checkpointPr` settings.
- Supporting non-GitHub PR providers in the first slice; v1 is GitHub-only through Foreman's existing PR backend surface.
- Auto-merging the stack after creation; Foreman only proposes stacked PRs.

## Users and Success Metrics

### Primary users

- Workflow authors who define Foreman YAML manifests.
- Operators reviewing Foreman-generated branches and PRs.
- Maintainers diagnosing failed run finalization.

### Success metrics

- A workflow with one or more non-empty `stack_pr: true` boundaries produces deterministic PR entries, and a workflow with multiple non-empty boundaries produces ordered stacked PRs instead of one PR.
- Existing manifests with no `stack_pr:` produce exactly one PR as they do today.
- Failed or retried stack creation never leaves the run reported as successful while PR state is unknowable.
- Operator output names every created PR URL and its stack position.

## Existing Context and Constraints

- The codebase is Elixir/Phoenix under `packages/foreman_server`, with Foreman workflow execution and VCS behavior in server modules.
- `AGENTS.md` says current manifest vocabulary has no `pr`, `merge`, `checkpoint`, stacked-PR, or per-phase PR keys.
- `commit:` already exists as a phase-level boolean; it must not be confused with PR topology.
- Auto PR creation currently happens once at run finalization via `AutoPR.maybe_create_pr/1`.
- Foreman uses fail-loud boundary rules: malformed input must not silently coerce or succeed.
- Documentation must be updated if behavior changes: `CLAUDE.md`, `AGENTS.md`, `README.md`, `docs/user-guide.md`, and `docs/cli-reference.md`.

## External Dependencies

| Dependency | Status | Effect |
|---|---|---|
| GitHub CLI / PR API | Existing AutoPR depends on `gh pr create` | Stacked PR creation may continue using `gh` in v1, but must sit behind a typed internal stack-PR operation boundary so unsupported providers fail loudly. |
| Git branch stack mechanics | Existing Foreman run branch is single-branch | Stack branches are synthesized at finalization from committed phase-boundary slices so retry/idempotency stays centralized. |

## Assumptions

- A1 — `stack_pr:` is phase-level because the task title says "phase tag".
- A2 — Absent `stack_pr:` preserves current behavior.
- A3 — `stack_pr: true` marks the phase's completed work as the end of one PR slice.
- A4 — GitHub is the first target because current AutoPR shells through GitHub CLI; GitHub-only is acceptable for v1.
- A5 — Stacks are proposed, not merged.
- A6 — A run may contain several `stack_pr: true` phases; each marks one PR boundary.
- A7 — A phase with `stack_pr: true` but no changes should not create an empty PR; Foreman warns and skips the empty stack entry.
- A8 — Existing `commit:` validation and deferral semantics remain authoritative.

## Requirements

### Feature Area: Manifest Declaration

### REQ-001: Declare a phase-level `stack_pr:` boolean

**Priority:** Must · **Complexity:** Low

A workflow phase may declare `stack_pr:` with value `true` or `false`. `true` marks the phase as a stacked-PR boundary. `false` is equivalent to absence for behavior, but explicit `false` is preserved in loaded snapshots and serialization for readability and auditability.

- AC-001-1: Given a phase declaring `stack_pr: true`, when the workflow loads, then the normalized phase spec carries boolean `true`.
- AC-001-2: Given a phase declaring `stack_pr: false`, when the workflow loads, then the normalized phase spec carries boolean `false` and is not treated as truthy by string coercion.

### REQ-002: Preserve current single-PR behavior by default

**Priority:** Must · **Complexity:** Low

A workflow with no `stack_pr:` declarations behaves exactly as it does today: Foreman opens at most one PR from the run branch during finalization.

- AC-002-1: Given a workflow with no `stack_pr:` keys and changes on the run branch, when finalization runs, then Foreman calls the existing single-PR path and opens at most one PR.
- AC-002-2: Given a workflow with no `stack_pr:` keys and no branch delta, when finalization runs, then no PR is opened and existing no-change behavior is preserved.

### REQ-003: Mark a phase as a stack boundary

**Priority:** Must · **Complexity:** Medium · **[RISK: Boundary semantics can be confused with commit semantics.]**

A phase declaring `stack_pr: true` establishes that the work accumulated since the previous stack boundary belongs to one PR in the stack. The first boundary is measured from the run base branch.

- AC-003-1: Given phases A and B both produce commits and B declares `stack_pr: true`, when the run finalizes, then one stack entry covers changes through B since the prior boundary.
- AC-003-2: Given consecutive phases each declare `stack_pr: true`, when the run finalizes, then each non-empty phase slice creates a distinct stack entry and each empty slice is skipped with an operator warning.
- AC-003-3: Given the final phase does not declare `stack_pr: true`, when earlier stack boundaries exist and trailing committed changes remain, then Foreman creates a trailing implicit stack entry.

### REQ-004: Create stacked PRs in phase order

**Priority:** Must · **Complexity:** High · **[RISK: Incorrect base branches can invert or flatten the stack.]**

When stack mode is active, Foreman creates PRs ordered by workflow phase order, where PR N targets the previous stack branch and PR 1 targets the run base branch. PR bases follow GitHub branch stacking semantics rather than Git Town-specific commands.

- AC-004-1: Given two stack entries, when PRs are created, then PR 1 targets the original base branch and PR 2 targets PR 1's head branch.
- AC-004-2: Given three stack entries, when PR URLs are reported, then they are listed in dependency order from base-most to tip-most.
- AC-004-3: Given any PR creation fails, when finalization completes, then the run finalization fails with actionable retry metadata rather than reporting silent success.

### REQ-005: Reject malformed `stack_pr:` values

**Priority:** Must · **Complexity:** Low

A `stack_pr:` value must be boolean. Strings, numbers, nulls, and objects are malformed manifests.

- AC-005-1: Given `stack_pr: "true"`, when the workflow loads, then loading fails naming the phase and stating `stack_pr` must be boolean.
- AC-005-2: Given `stack_pr: maybe`, when the workflow loads, then loading fails before a run dispatches.

### REQ-006: Require a satisfiable VCS backend for stacking

**Priority:** Must · **Complexity:** Medium · **[RISK: Stacked PRs may be declared where AutoPR is disabled or unsupported.]**

A workflow that declares any `stack_pr: true` must run in a VCS/PR context capable of creating stacked branches and PRs. For v1, that means AutoPR/PR creation is enabled for the run and the resolved PR backend is GitHub-capable.

- AC-006-1: Given stack mode is declared but PR creation is disabled for the run, when the workflow loads or run starts, then Foreman rejects the run with a clear error.
- AC-006-2: Given stack mode is declared under an unsupported VCS backend, when the run starts after project/workflow VCS resolution, then Foreman rejects rather than degrading to a single PR.

### REQ-007: Surface stack creation status to the operator

**Priority:** Should · **Complexity:** Medium

Foreman records run-scoped operator notices for stack planning, PR creation success, and failures.

- AC-007-1: Given stack mode is active, when finalization begins, then the run inbox receives a summary naming planned stack entries.
- AC-007-2: Given a PR is created or reused, when reporting status, then the notice includes stack index, phase boundary, branch name, base branch, and PR URL.

### REQ-008: Define interaction with `commit:` deferral

**Priority:** Must · **Complexity:** High · **[RISK: A stack boundary without a commit may have no durable diff to branch from.]**

`stack_pr:` must interact explicitly with `commit:`. A phase declaring `stack_pr: true` must commit its slice; pairing `stack_pr: true` with `commit: false` is manifest-invalid.

- AC-008-1: Given a phase declares `stack_pr: true` and omits `commit:`, when the phase completes with changes, then the stack boundary has a committed diff.
- AC-008-2: Given a phase declares `stack_pr: true` and `commit: false`, when the workflow loads, then Foreman rejects the manifest with a clear invalid-combination error.
- AC-008-3: Given earlier phases defer with `commit: false` and a later phase declares both `commit: true` and `stack_pr: true`, when finalization creates the stack, then the PR slice includes all deferred changes absorbed by that commit.

### REQ-009: Preserve `stack_pr:` through workflow snapshots

**Priority:** Should · **Complexity:** Low

`stack_pr:` survives workflow loading, run snapshotting, replay, and manifest serialization without changing absent vs explicit false.

- AC-009-1: Given a phase declares `stack_pr: true`, when the run's workflow snapshot is stored and read back, then the value remains boolean `true`.
- AC-009-2: Given a phase omits `stack_pr:`, when the workflow is serialized, then absence remains distinguishable from explicit `false` for UI/audit purposes.

### REQ-010: Use deterministic branch naming for stack entries

**Priority:** Must · **Complexity:** Medium

Foreman creates deterministic head branches for each stack entry so retries can find and update the same PRs. Branch names use `foreman/<run-id>/stack/<index>-<phase-slug>` with stable 1-based indexes in workflow order.

- AC-010-1: Given a run creates stack entry 2, when its branch is named, then the name includes the run id and stable stack index.
- AC-010-2: Given finalization is retried, when the same stack entry is processed, then Foreman resolves the same branch name instead of creating a duplicate branch.

### REQ-011: Handle existing or partially-created PRs safely

**Priority:** Must · **Complexity:** High · **[RISK: Retry can duplicate PRs or retarget bases incorrectly.]**

Stack creation is idempotent. If a prior attempt created some branches or PRs, retry updates/reuses them or halts with an actionable error.

- AC-011-1: Given PR 1 already exists for the expected branch, when stack creation is retried, then Foreman reuses PR 1 and updates Foreman-owned title/body sections while preserving unrelated reviewer edits.
- AC-011-2: Given PR 1 exists but targets the wrong base, when retry runs, then Foreman refuses with a clear mismatch error.
- AC-011-3: Given PR 1 succeeded and PR 2 failed previously, when retry runs, then Foreman resumes at PR 2 after verifying PR 1's state.

### REQ-012: Keep bundled workflows unchanged unless explicitly updated

**Priority:** Should · **Complexity:** Low

The feature adds capability, not a default workflow behavior change. Bundled workflows, including PRD/TRD workflows, should not start producing stacks in this slice unless a separate task explicitly opts them in.

- AC-012-1: Given the default bundled workflows after implementation, when no workflow has been intentionally edited to add `stack_pr: true`, then their PR behavior remains unchanged.
- AC-012-2: Given a bundled workflow is changed to declare `stack_pr: true`, when docs are updated, then they name the changed workflow and resulting PR shape.

### REQ-013: Document operator-facing workflow semantics

**Priority:** Should · **Complexity:** Low

Documentation must describe `stack_pr:` syntax, defaults, invalid combinations, retry behavior, and relation to `commit:`.

- AC-013-1: Given the feature ships, when a user reads the User Guide and CLI Reference, then they no longer state that Foreman has no stacked PR manifest setting.
- AC-013-2: Given an operator writes `stack_pr: true`, when they read examples, then they can predict branch/PR ordering and failure behavior.

### REQ-014: Emit telemetry for stacked PR operations

**Priority:** Should · **Complexity:** Medium · **[RISK: Finalization failures are hard to diagnose without structured events.]**

Stack planning and PR operations emit telemetry or durable events under an AutoPR stack namespace (for example, `autopr.stack.*`) with enough metadata to debug latency, API failures, and idempotency decisions.

- AC-014-1: Given stack creation attempts a PR operation, when telemetry is collected, then it includes run id, stack index, operation, backend, and result.
- AC-014-2: Given stack creation fails due to API or git errors, when the run is inspected, then structured error metadata is available without scraping raw logs.

## Dependency Map

| REQ | Depends On | Blocked By | Notes |
|---|---|---|---|
| REQ-001 | None | None | Manifest surface. |
| REQ-002 | REQ-001 | None | Default behavior guard. |
| REQ-003 | REQ-001 | REQ-008 | Boundary meaning depends on commit interaction. |
| REQ-004 | REQ-003, REQ-010 | REQ-006, REQ-011 | Core stacked PR behavior. |
| REQ-005 | REQ-001 | None | Fail-loud validation. |
| REQ-006 | REQ-001 | None | Prevents unsupported silent fallback. |
| REQ-007 | REQ-004 | REQ-011 | Operator visibility. |
| REQ-008 | REQ-001 | None | Must be resolved before implementation. |
| REQ-009 | REQ-001 | None | Persistence/audit. |
| REQ-010 | REQ-004 | REQ-006 | Stable retry identity. |
| REQ-011 | REQ-004, REQ-010 | REQ-006 | Partial failure safety. |
| REQ-012 | REQ-002 | None | Bundled workflow compatibility. |
| REQ-013 | All behavior reqs | None | Documentation follows real behavior. |
| REQ-014 | REQ-004, REQ-011 | None | Debuggability. |

Implementation clusters:

1. Manifest schema and validation: REQ-001, REQ-002, REQ-005, REQ-009.
2. Stack semantics: REQ-003, REQ-004, REQ-008, REQ-010.
3. Safety and observability: REQ-006, REQ-007, REQ-011, REQ-014.
4. Compatibility and docs: REQ-012, REQ-013.

No circular dependencies identified. REQ-008 is now an explicit gating rule for REQ-003 and REQ-004.

## Adversarial Self-Review

Foreman mode auto-applied the recommended resolutions below where possible.

1. **Issue:** The task description is only "Test v7", so product intent is sparse.  
   **Resolution:** Use the task title as authoritative scope and mark every unresolved behavior choice inline.
2. **Issue:** Existing repo guidance says stacked PRs are not Foreman behavior.  
   **Resolution:** Treat this PRD as a proposed product change and require documentation updates if implemented.
3. **Issue:** `stack_pr:` can conflict with existing `commit:` deferral.  
   **Resolution:** REQ-008 now makes `stack_pr: true` with `commit: false` invalid and requires a committed stack boundary.
4. **Issue:** Branch-stack construction was technically underspecified.  
   **Resolution:** REQ-010 now defines deterministic branch names; REQ-011 defines idempotent retry/reuse behavior.
5. **Issue:** Unsupported providers could silently degrade to one PR.  
   **Resolution:** Add REQ-006 requiring fail-loud rejection.
6. **Issue:** Empty phase slices may produce meaningless PRs.  
   **Resolution:** Empty stack entries are skipped with operator warnings.
7. **Issue:** Existing AutoPR finalizes once from a single branch, which may not support stacking without architectural change.  
   **Resolution:** Flag REQ-004 as high complexity and require TRD to map branch synthesis.
8. **Issue:** Partial PR creation can leave external state behind.  
   **Resolution:** Add idempotent retry/reuse requirements in REQ-011.

## Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 4.5 | Major feature areas covered; policy choices from create-prd markers have best-effort defaults. |
| Testability | 4.5 | Every requirement has ACs and the highest-risk behavior choices are testable. |
| Clarity | 4.5 | Branch semantics, commit precedence, empty slices, and retry behavior are explicit. |
| Feasibility | 4.5 | Achievable with focused AutoPR/finalization changes, while preserving unsupported-provider rejection. |

Overall readiness score: **4.5/5.0** — **READY**.

Foreman mode auto-applied best-effort clarification defaults. The PRD is ready for TRD handoff, subject to technical validation against the implementation source.

## Suggested TRD Handoff Focus

1. Verify the exact current `commit:` default and deferral implementation before coding REQ-008.
2. Map finalization-time branch synthesis onto Foreman's current AutoPR/run branch model.
3. Define the typed stack-PR operation boundary around the existing GitHub/`gh` implementation.
4. Pin idempotency behavior with tests for retry after partial PR creation.
5. Keep bundled workflows unchanged unless a separate task opts them into `stack_pr:`.


## Changelog

### 2026-09-01 — v1.0.1

- Resolved all Foreman-mode clarification markers with best-effort product defaults.
- Clarified `stack_pr:` interaction with `commit:`: `stack_pr: true` plus `commit: false` is invalid.
- Defined GitHub-first stack creation, finalization-time branch synthesis, deterministic stack branch naming, empty-slice skip warnings, trailing implicit entries, partial-failure hard errors, and bundled workflow non-adoption.
- Updated PRD Health and Implementation Readiness Gate score from 3.6 to 4.5.
