---
document_id: PRD-2026-0da9f4d1
label: prd-stack-pr-phase-tag
version: 1.0.0
status: Draft
date: 2026-09-01
scale_depth: STANDARD
author: Lead Agent
total_requirements: 14
readiness_score: 3.6
readiness_gate: CONCERNS_PROCEEDED_FOREMAN
---

# PRD: Phase-Level `stack_pr:` Tag for Stacked Pull Requests

## Foreman Subject

- Foreman task title: **Add stack_pr phase tag for stacked PRs v7**
- Foreman task description: **Test v7**
- Foreman mode: interviews skipped; unresolved product choices are marked inline with `[NEEDS CLARIFICATION: ...]`.

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
| Risk flags | 8 |
| Dependencies | 14 |
| Open ambiguity markers | 26 |
| External dependencies | 2 |
| Readiness score | 3.6/5.0 |

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

Ambiguity scan complete: 26 items marked for clarification.

## Problem Statement

Foreman currently opens at most one pull request for a run, from the run's single branch during finalization. Existing repo guidance says stacked and per-phase PRs are not Foreman manifest behavior today. The requested product change is to add a phase-level `stack_pr:` tag so workflow authors can declare where stacked PR boundaries should exist.

The pain is review granularity. A multi-phase run can produce logically separate review units, but Foreman collapses all committed work into one PR. Operators who want a stack must leave Foreman and use ensemble-skill or manual Git/GitHub flows [NEEDS CLARIFICATION: Is the target user the solo Foreman operator only, or also multi-developer teams running shared workflows?].

## Goals

- Let workflow manifests declare stacked PR boundaries at phase level.
- Preserve today's single-PR behavior unless a workflow opts in.
- Make stack creation deterministic, observable, and safe to retry.
- Keep the semantics distinct from `commit:`: `commit:` controls whether a phase commits; `stack_pr:` controls whether a PR boundary is created [NEEDS CLARIFICATION: Should `stack_pr:` also imply `commit: true`, or must it error when paired with `commit: false`?].

## Non-Goals

- Changing any existing workflow by default.
- Implementing stacked PRs in ensemble skills; those already have separate behavior.
- Adding top-level `pr:`, `merge:`, `stacked:`, or `checkpointPr` settings.
- Supporting non-GitHub PR providers in the first slice [NEEDS CLARIFICATION: Must this support GitHub only, or also GitLab/Bitbucket/Jujutsu-backed flows?].
- Auto-merging the stack after creation [NEEDS CLARIFICATION: Should Foreman ever merge stacked PRs, or only propose them?].

## Users and Success Metrics

### Primary users

- Workflow authors who define Foreman YAML manifests.
- Operators reviewing Foreman-generated branches and PRs.
- Maintainers diagnosing failed run finalization.

### Success metrics

- A workflow with multiple `stack_pr: true` boundaries produces ordered PRs instead of one PR [NEEDS CLARIFICATION: What exact minimum stack size should be supported in v1?].
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
| GitHub CLI / PR API | Existing AutoPR depends on `gh pr create` | Stacked PR creation likely needs multiple branch pushes and base-specific PR creation [NEEDS CLARIFICATION: Should implementation keep shelling out to `gh`, or introduce a typed VCS/PR abstraction first?] |
| Git branch stack mechanics | Existing Foreman run branch is single-branch | Product must define how per-stack branches are created from phase commits [NEEDS CLARIFICATION: Should stack branches be created incrementally during phases or synthesized at finalization from commits?] |

## Assumptions

- A1 — `stack_pr:` is phase-level because the task title says "phase tag".
- A2 — Absent `stack_pr:` preserves current behavior.
- A3 — `stack_pr: true` marks the phase's completed work as the end of one PR slice.
- A4 — GitHub is the first target because current AutoPR shells through GitHub CLI [NEEDS CLARIFICATION: Is GitHub-only acceptable for the first implementation?].
- A5 — Stacks are proposed, not merged.
- A6 — A run may contain several `stack_pr: true` phases; each marks one PR boundary.
- A7 — A phase with `stack_pr: true` but no changes should not create an empty PR [NEEDS CLARIFICATION: Should this warn, hard fail, or silently skip?].
- A8 — Existing `commit:` validation and deferral semantics remain authoritative.

## Requirements

### Feature Area: Manifest Declaration

### REQ-001: Declare a phase-level `stack_pr:` boolean

**Priority:** Must · **Complexity:** Low

A workflow phase may declare `stack_pr:` with value `true` or `false`. `true` marks the phase as a stacked-PR boundary. `false` is equivalent to absence except that it is preserved for readability [NEEDS CLARIFICATION: Should explicit `false` be preserved in manifest round-trips or omitted as default?].

- AC-001-1: Given a phase declaring `stack_pr: true`, when the workflow loads, then the normalized phase spec carries boolean `true`.
- AC-001-2: Given a phase declaring `stack_pr: false`, when the workflow loads, then the normalized phase spec carries boolean `false` and is not treated as truthy by string coercion.

### REQ-002: Preserve current single-PR behavior by default

**Priority:** Must · **Complexity:** Low

A workflow with no `stack_pr:` declarations behaves exactly as it does today: Foreman opens at most one PR from the run branch during finalization.

- AC-002-1: Given a workflow with no `stack_pr:` keys and changes on the run branch, when finalization runs, then Foreman calls the existing single-PR path and opens at most one PR.
- AC-002-2: Given a workflow with no `stack_pr:` keys and no branch delta, when finalization runs, then no PR is opened and existing no-change behavior is preserved.

### REQ-003: Mark a phase as a stack boundary

**Priority:** Must · **Complexity:** Medium · **[RISK: Boundary semantics can be confused with commit semantics.]**

A phase declaring `stack_pr: true` establishes that the work accumulated since the previous stack boundary belongs to one PR in the stack [NEEDS CLARIFICATION: Is the first boundary measured from run base or from the first commit created by Foreman?].

- AC-003-1: Given phases A and B both produce commits and B declares `stack_pr: true`, when the run finalizes, then one stack entry covers changes through B since the prior boundary.
- AC-003-2: Given consecutive phases each declare `stack_pr: true`, when the run finalizes, then each phase creates a distinct stack entry unless its slice has no changes [NEEDS CLARIFICATION: Should empty stack entries be errors?].
- AC-003-3: Given the final phase does not declare `stack_pr: true`, when earlier stack boundaries exist, then remaining changes are handled by a final stack entry [NEEDS CLARIFICATION: Should a trailing implicit stack entry be created, or must the last phase explicitly declare `stack_pr: true`?].

### REQ-004: Create stacked PRs in phase order

**Priority:** Must · **Complexity:** High · **[RISK: Incorrect base branches can invert or flatten the stack.]**

When stack mode is active, Foreman creates multiple PRs ordered by workflow phase order, where PR N targets the previous stack branch and PR 1 targets the run base branch [NEEDS CLARIFICATION: Should PR bases use GitHub branch stacking or Git Town conventions?].

- AC-004-1: Given two stack entries, when PRs are created, then PR 1 targets the original base branch and PR 2 targets PR 1's head branch.
- AC-004-2: Given three stack entries, when PR URLs are reported, then they are listed in dependency order from base-most to tip-most.
- AC-004-3: Given any PR creation fails, when finalization completes, then the run records a failure or actionable blocked state rather than reporting silent success [NEEDS CLARIFICATION: Should partial stack creation fail the run, or produce a recoverable warning?].

### REQ-005: Reject malformed `stack_pr:` values

**Priority:** Must · **Complexity:** Low

A `stack_pr:` value must be boolean. Strings, numbers, nulls, and objects are malformed manifests.

- AC-005-1: Given `stack_pr: "true"`, when the workflow loads, then loading fails naming the phase and stating `stack_pr` must be boolean.
- AC-005-2: Given `stack_pr: maybe`, when the workflow loads, then loading fails before a run dispatches.

### REQ-006: Require a satisfiable VCS backend for stacking

**Priority:** Must · **Complexity:** Medium · **[RISK: Stacked PRs may be declared where AutoPR is disabled or unsupported.]**

A workflow that declares any `stack_pr: true` must run in a VCS/PR context capable of creating stacked branches and PRs [NEEDS CLARIFICATION: What config flag indicates PR creation is enabled today?].

- AC-006-1: Given stack mode is declared but PR creation is disabled for the run, when the workflow loads or run starts, then Foreman rejects the run with a clear error.
- AC-006-2: Given stack mode is declared under an unsupported VCS backend, when the workflow loads or run starts, then Foreman rejects rather than degrading to a single PR [NEEDS CLARIFICATION: Should unsupported backend rejection occur at load time or finalization time?].

### REQ-007: Surface stack creation status to the operator

**Priority:** Should · **Complexity:** Medium

Foreman records run-scoped operator notices for stack planning, PR creation success, and failures.

- AC-007-1: Given stack mode is active, when finalization begins, then the run inbox or equivalent operator surface receives a summary naming planned stack entries [NEEDS CLARIFICATION: Is the run inbox the required channel for these notices?].
- AC-007-2: Given a PR is created or reused, when reporting status, then the notice includes stack index, phase boundary, branch name, base branch, and PR URL.

### REQ-008: Define interaction with `commit:` deferral

**Priority:** Must · **Complexity:** High · **[RISK: A stack boundary without a commit may have no durable diff to branch from.]**

`stack_pr:` must interact explicitly with `commit:`. A phase declaring `stack_pr: true` must either commit its slice or be rejected when no committed diff can back the PR [NEEDS CLARIFICATION: Should `stack_pr: true` force a commit even if `commit: false`, or is that manifest invalid?].

- AC-008-1: Given a phase declares `stack_pr: true` and omits `commit:`, when the phase completes with changes, then the stack boundary has a committed diff.
- AC-008-2: Given a phase declares `stack_pr: true` and `commit: false`, when the workflow loads, then Foreman either rejects or applies a documented precedence rule [NEEDS CLARIFICATION: Which precedence is desired?].
- AC-008-3: Given earlier phases defer with `commit: false` and a later phase declares both `commit: true` and `stack_pr: true`, when finalization creates the stack, then the PR slice includes all deferred changes absorbed by that commit.

### REQ-009: Preserve `stack_pr:` through workflow snapshots

**Priority:** Should · **Complexity:** Low

`stack_pr:` survives workflow loading, run snapshotting, replay, and manifest serialization without changing absent vs explicit false.

- AC-009-1: Given a phase declares `stack_pr: true`, when the run's workflow snapshot is stored and read back, then the value remains boolean `true`.
- AC-009-2: Given a phase omits `stack_pr:`, when the workflow is serialized, then absence remains distinguishable from explicit `false` [NEEDS CLARIFICATION: Is absence-vs-false distinction required for UI/audit, or can serializers normalize it?].

### REQ-010: Use deterministic branch naming for stack entries

**Priority:** Must · **Complexity:** Medium

Foreman creates deterministic head branches for each stack entry so retries can find and update the same PRs [NEEDS CLARIFICATION: Should branch names be `foreman/<run-id>/<index>` or another scheme?].

- AC-010-1: Given a run creates stack entry 2, when its branch is named, then the name includes the run id and stable stack index.
- AC-010-2: Given finalization is retried, when the same stack entry is processed, then Foreman resolves the same branch name instead of creating a duplicate branch.

### REQ-011: Handle existing or partially-created PRs safely

**Priority:** Must · **Complexity:** High · **[RISK: Retry can duplicate PRs or retarget bases incorrectly.]**

Stack creation is idempotent. If a prior attempt created some branches or PRs, retry updates/reuses them or halts with an actionable error.

- AC-011-1: Given PR 1 already exists for the expected branch, when stack creation is retried, then Foreman reuses or updates PR 1 rather than creating a duplicate [NEEDS CLARIFICATION: Should existing PR metadata be updated or left untouched?].
- AC-011-2: Given PR 1 exists but targets the wrong base, when retry runs, then Foreman refuses with a clear mismatch error.
- AC-011-3: Given PR 1 succeeded and PR 2 failed previously, when retry runs, then Foreman resumes at PR 2 after verifying PR 1's state.

### REQ-012: Keep bundled workflows unchanged unless explicitly updated

**Priority:** Should · **Complexity:** Low

The feature adds capability, not a default workflow behavior change. Bundled workflows should not start producing stacks unless this task explicitly chooses a bundled workflow to update [NEEDS CLARIFICATION: Is the PRD workflow itself supposed to use `stack_pr:` after the feature lands?].

- AC-012-1: Given the default bundled workflows after implementation, when no workflow has been intentionally edited to add `stack_pr: true`, then their PR behavior remains unchanged.
- AC-012-2: Given a bundled workflow is changed to declare `stack_pr: true`, when docs are updated, then they name the changed workflow and resulting PR shape.

### REQ-013: Document operator-facing workflow semantics

**Priority:** Should · **Complexity:** Low

Documentation must describe `stack_pr:` syntax, defaults, invalid combinations, retry behavior, and relation to `commit:`.

- AC-013-1: Given the feature ships, when a user reads the User Guide and CLI Reference, then they no longer state that Foreman has no stacked PR manifest setting.
- AC-013-2: Given an operator writes `stack_pr: true`, when they read examples, then they can predict branch/PR ordering and failure behavior.

### REQ-014: Emit telemetry for stacked PR operations

**Priority:** Should · **Complexity:** Medium · **[RISK: Finalization failures are hard to diagnose without structured events.]**

Stack planning and PR operations emit telemetry or durable events with enough metadata to debug latency, API failures, and idempotency decisions [NEEDS CLARIFICATION: Which telemetry namespace should be used for AutoPR/stack events?].

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
| REQ-013 | All behavior reqs | Open clarifications | Documentation follows real behavior. |
| REQ-014 | REQ-004, REQ-011 | None | Debuggability. |

Implementation clusters:

1. Manifest schema and validation: REQ-001, REQ-002, REQ-005, REQ-009.
2. Stack semantics: REQ-003, REQ-004, REQ-008, REQ-010.
3. Safety and observability: REQ-006, REQ-007, REQ-011, REQ-014.
4. Compatibility and docs: REQ-012, REQ-013.

No circular dependencies identified, but REQ-008 is a gating ambiguity for REQ-003 and REQ-004.

## Adversarial Self-Review

Foreman mode auto-applied the recommended resolutions below where possible.

1. **Issue:** The task description is only "Test v7", so product intent is sparse.  
   **Resolution:** Use the task title as authoritative scope and mark every unresolved behavior choice inline.
2. **Issue:** Existing repo guidance says stacked PRs are not Foreman behavior.  
   **Resolution:** Treat this PRD as a proposed product change and require documentation updates if implemented.
3. **Issue:** `stack_pr:` can conflict with existing `commit:` deferral.  
   **Resolution:** Add REQ-008 and mark precedence unresolved rather than guessing.
4. **Issue:** Branch-stack construction is technically underspecified.  
   **Resolution:** Add REQ-010 and REQ-011; leave exact naming/API choices for clarification/TRD.
5. **Issue:** Unsupported providers could silently degrade to one PR.  
   **Resolution:** Add REQ-006 requiring fail-loud rejection.
6. **Issue:** Empty phase slices may produce meaningless PRs.  
   **Resolution:** Mark explicit clarification in REQ-003/A7.
7. **Issue:** Existing AutoPR finalizes once from a single branch, which may not support stacking without architectural change.  
   **Resolution:** Flag REQ-004 as high complexity and require TRD to map branch synthesis.
8. **Issue:** Partial PR creation can leave external state behind.  
   **Resolution:** Add idempotent retry/reuse requirements in REQ-011.

## Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 4 | Major feature areas covered, but sparse task description leaves open policy choices. |
| Testability | 4 | Every requirement has ACs; several ACs depend on clarification before implementation. |
| Clarity | 3 | Core intent is clear; branch semantics and `commit:` precedence can be read multiple ways. |
| Feasibility | 3.5 | Achievable, but current AutoPR single-finalization model likely needs real redesign. |

Overall readiness score: **3.6/5.0** — **CONCERNS**.

Foreman mode defaulted to proceeding despite concerns. The PRD is suitable for refinement, not direct implementation. The next phase should resolve the `[NEEDS CLARIFICATION]` markers before TRD handoff.

## Suggested Refinement Agenda

1. Decide whether `stack_pr: true` requires or implies `commit: true`.
2. Choose branch naming and whether to follow GitHub-only or a VCS abstraction.
3. Decide trailing changes behavior after the final explicit stack boundary.
4. Decide empty-stack-entry behavior.
5. Decide partial creation failure semantics: hard run failure vs recoverable warning.
6. Confirm whether bundled workflows should adopt `stack_pr:` immediately or remain unchanged.
