---
document_id: PRD-2026-e33bcab7
label: prd-stacked-pr-phase-tag
version: 1.0.1
status: Draft
date: 2026-09-01
scale_depth: STANDARD
author: Foreman ensemble-create-prd
foreman_task_title: Implement stacked PR phase tag
total_requirements: 15
readiness_score: 4.75
readiness_gate: PASS
---

# PRD: Stacked PR Phase Tag (`stack_pr:`)

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 12 |
| Should | 3 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 15/15 (100%) |
| Risk flags | 10 |
| Dependencies | 18 |
| Open ambiguity markers | 0 |
| External dependencies | 2 |

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Declare a phase-level `stack_pr:` boolean | Must | Low | 2 |
| REQ-002 | Preserve existing behavior when `stack_pr:` is absent or false | Must | Low | 2 |
| REQ-003 | Create a phase PR after a successful tagged phase | Must | High | 3 |
| REQ-004 | Target every phase PR at the run base branch | Must | Medium | 2 |
| REQ-005 | Use the run worktree branch as the phase PR head | Must | Medium | 2 |
| REQ-006 | Record phase PRs without overwriting final run `pr_url` | Must | High | 3 |
| REQ-007 | Skip final AutoPR when phase PRs already represent the run | Must | Medium | 2 |
| REQ-008 | Fail loudly on phase PR creation errors | Must | Medium | 2 |
| REQ-009 | Validate and normalize `stack_pr:` through manifest loading | Must | Low | 2 |
| REQ-010 | Preserve `stack_pr:` through manifest serialization | Should | Low | 2 |
| REQ-011 | Surface phase PRs in run-facing projections and CLI/API views | Should | Medium | 2 |
| REQ-012 | Keep commit deferral semantics independent from PR tagging | Must | Medium | 2 |
| REQ-013 | Support rerun/idempotency behavior for already-created phase PRs | Must | High | 3 |
| REQ-014 | Maintain PR monitor compatibility | Should | Medium | 2 |
| REQ-015 | Document operator semantics and constraints | Must | Low | 2 |

## Problem Statement

Foreman currently creates at most one PR for a run, from the run's single branch,
after all phases complete. That is simple, but it forces multi-phase runs into one
review unit even when a workflow phase is intended to be independently reviewable.

The requested product change is a phase-level `stack_pr:` tag. When a phase has
`stack_pr: true`, Foreman creates a PR after that phase completes. The PR targets
the run base branch, not the previous phase PR branch. Later phase PRs may
therefore contain cumulative run diffs because the run still has one branch and
one worktree. Cumulative diffs are acceptable for this slice; immutable
per-phase head branches and true stacked branch topology are explicitly out of
scope.

Primary users are workflow authors and the solo/operator reviewing Foreman run
output. Success means a workflow can mark review boundaries directly in YAML and
get durable, visible PR links for those boundaries without agent-managed branch
or PR scripting.

## Foreman Mode Notes

This PRD was generated and refined under `--foreman`. Clarifying interviews were
skipped by contract. Refinement used best-effort policy defaults and removed the
previous inline ambiguity markers where the default was safe.

## Goals

- Add a declarative phase-level `stack_pr:` boolean.
- Create a GitHub PR automatically after each successful tagged phase.
- Keep every phase PR targeted at the branch the run was cut from.
- Preserve current single-PR AutoPR behavior for workflows that do not use
  `stack_pr:`.
- Make phase PR URLs durable and visible without changing final `pr_url`
  semantics.

## Non-Goals

- Implementing true stacked branch topology where phase N targets phase N-1.
- Adding `pr:`, `merge:`, `checkpointPr`, or `stacked:` workflow-level keys.
- Letting agents create/merge PRs directly.
- Changing commit messages, authors, hooks, or `commit:` semantics.
- Auto-merging phase PRs.
- Retargeting existing PRs created before this feature.

## Research and Context

### Existing codebase

Foreman is a mixed Go/Elixir system:

- `packages/foreman_server/` — Elixir/Phoenix backend, event store, projections,
  workflow execution, worktrees, AutoPR, PR monitor.
- `packages/foreman_cli/` — Go CLI and cockpit rendering.
- `packages/jido_harness/` — Elixir harness integration.

Relevant source surfaces observed during reconnaissance:

- `packages/foreman_server/lib/foreman_server/workflow/phase_spec.ex` normalizes
  phase keys at the boundary and currently knows `commit:`.
- `packages/foreman_server/lib/foreman_server/workflow/interpreter.ex` parses and
  validates workflow YAML.
- `packages/foreman_server/lib/foreman_server/workflow/manifest_writer.ex`
  serializes manifests for round-trip behavior.
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` commits
  phase work, records the run base branch, calls AutoPR at finalization, and
  records `PrAssociated` for final PR visibility.
- `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex` opens the PR
  via `git push` and `gh pr create`, using the run base branch and head branch.
- `packages/foreman_server/lib/foreman_server/aggregates/pr_association.ex`,
  `events/pr_associated.ex`, and `projection_store.ex` hold run-level PR URLs.

### Prior product docs and cross-cutting requirements

The closest prior PRD is
`docs/PRD/PRD-2026-d306444f-phase-commit-control.md`. It establishes that:

- `commit:` is phase-level and controls only whether a phase commits.
- A run has one worktree and one branch by default.
- Existing docs explicitly say Foreman has no per-phase/stacked PR setting. This
  PRD intentionally changes that operator-visible contract.
- `docs/PRD/*` and `docs/TRD/*` are historical specs and should not be rewritten
  when implementation changes; living docs must be updated instead.

### External dependencies

| Dependency | Status | Impact |
|---|---|---|
| `git` CLI | Existing | Push/commit ancestry checks and branch publication. |
| GitHub `gh` CLI | Existing | PR creation and PR monitor compatibility. |

### Technical constraints

- Foreman must fail loudly rather than silently reporting success when PR creation
  cannot be honored.
- Manifest keys must be normalized once at the boundary, with atom-keyed reads
  downstream.
- Unknown YAML keys are currently dropped by `PhaseSpec.normalize/1`; adding the
  field must be explicit.
- Final run `pr_url` currently means the run-level AutoPR URL. Phase PRs need a
  distinct durable model or field to avoid corrupting that meaning.

## Assumptions

- A1 — `stack_pr:` is a phase-level boolean, matching the user's title and the
  existing `commit:` shape.
- A2 — Phase PRs use the run worktree branch directly as the head. Foreman does
  not create generated immutable phase branches for this slice.
- A3 — A tagged phase creates its PR after Foreman has applied that phase's
  commit decision. `stack_pr: true` remains valid with `commit: false`; it
  creates a PR only when the already-committed run branch is ahead of base and
  otherwise records a no-op outcome.
- A4 — GitHub is the only required PR provider for this slice, consistent with
  existing AutoPR.
- A5 — Phase PR visibility belongs in run projections/CLI views, not only logs.
- A6 — Existing final AutoPR should not create a duplicate PR for the same run
  after one or more phase PRs are actually created. No-op phase PR attempts do
  not suppress final AutoPR.

## Requirements

### Feature Area: Manifest Declaration

### REQ-001: Declare a phase-level `stack_pr:` boolean

**Priority:** Must · **Complexity:** Low

A workflow phase may declare `stack_pr: true` or `stack_pr: false`. `true` means
Foreman attempts to create a phase PR after that phase succeeds. `false` means no
phase PR is created.

- AC-001-1: Given a phase declaring `stack_pr: true`, when the workflow loads,
  then the normalized phase spec carries boolean `true` to the executor.
- AC-001-2: Given a phase declaring `stack_pr: false`, when the workflow loads,
  then the normalized phase spec carries boolean `false`, not a string or
  missing value.

### REQ-002: Preserve existing behavior when `stack_pr:` is absent or false

**Priority:** Must · **Complexity:** Low

Workflows that do not declare `stack_pr:` continue to create at most one final
run PR through existing AutoPR behavior. A phase declaring `stack_pr: false`
behaves the same as absence for PR creation.

- AC-002-1: Given an existing workflow with no `stack_pr:` keys, when it
  completes with commits, then Foreman attempts final AutoPR exactly as before.
- AC-002-2: Given a phase declaring `stack_pr: false`, when that phase completes,
  then no phase PR is attempted because of that phase.

### REQ-003: Create a phase PR after a successful tagged phase

**Priority:** Must · **Complexity:** High

After a phase with `stack_pr: true` completes successfully, Foreman creates a PR
for the run's current branch state before advancing to the next phase or before
final run completion. [RISK: creating the PR before the phase's commit state is
settled can publish stale or empty diffs.]

- AC-003-1: Given a tagged phase that completes and leaves the run branch ahead
  of the base, when phase finalization runs, then Foreman pushes the head branch
  and creates a GitHub PR.
- AC-003-2: Given a tagged phase that fails, blocks, or is skipped, when the run
  handles that phase terminal state, then no phase PR is created for it.
- AC-003-3: Given a tagged phase whose branch has no commits ahead of the base,
  when phase PR creation runs, then Foreman records a no-op outcome rather than
  creating an empty PR.

### REQ-004: Target every phase PR at the run base branch

**Priority:** Must · **Complexity:** Medium

Each phase PR uses the base branch recorded when the run first started, matching
the user's requirement. Foreman must not fall back to `main` or infer a different
base from the local checkout later.

[RISK: resolving the base from the current checkout instead of run state can
publish PRs against the wrong branch after local branch drift.]

- AC-004-1: Given a run cut from `feature/base`, when a tagged phase creates a
  PR, then `gh pr create` receives `--base feature/base`.
- AC-004-2: Given Foreman cannot resolve the run base branch, when a tagged phase
  attempts PR creation, then the phase PR attempt fails with a typed error and no
  default base is used.

### REQ-005: Use the run worktree branch as the phase PR head

**Priority:** Must · **Complexity:** Medium

The phase PR head is the Foreman-managed run worktree branch. It is derived from
Foreman's run/worktree state, not agent output. Foreman does not create an
immutable phase-specific head branch for this slice, so later commits may update
the diff shown by earlier open phase PRs when they share the same head/base pair.

[RISK: shared head branches make earlier phase PR diffs mutable as later phases
commit additional work.]

- AC-005-1: Given a tagged phase completes, when Foreman creates the phase PR,
  then the head branch is derived from Foreman state, not from a required
  artifact marker.
- AC-005-2: Given the head branch cannot be resolved, when Foreman attempts phase
  PR creation, then it returns a typed error and does not mark the phase PR as
  created.

### REQ-006: Record phase PRs without overwriting final run `pr_url`

**Priority:** Must · **Complexity:** High

Phase PR URLs must be durable and queryable, but must not overwrite the existing
run-level `pr_url` semantics used by final AutoPR and PR monitor views. A phase
PR needs a distinct event/projection shape such as `PhasePrRecorded`.

[RISK: reusing `PrAssociated` for phase PRs would make a run look like its final
PR is whichever phase PR was created last.]

- AC-006-1: Given a phase PR is created, when events are read for the run, then a
  durable event records `run_id`, phase identity/index, PR URL, PR number, base,
  head, and timestamp.
- AC-006-2: Given a phase PR is created, when `ProjectionStore.run(run_id)` is
  read, then the existing final `pr_url` field is unchanged unless final AutoPR
  separately records one.
- AC-006-3: Given multiple tagged phases create PRs, when the run projection is
  read, then all phase PR records are visible in phase order.

### REQ-007: Skip final AutoPR when phase PRs already represent the run

**Priority:** Must · **Complexity:** Medium

When one or more phase PRs were actually created for a run, final AutoPR must not
create a duplicate catch-all PR unless a later explicit rule requires it. Phase
PR no-op outcomes do not count as created PRs and do not suppress final AutoPR.

[RISK: counting no-op attempts as real phase PRs would suppress the only final PR
for untagged committed work.]

- AC-007-1: Given at least one phase PR was created, when the run reaches final
  completion, then final AutoPR is skipped and the run completes without a
  duplicate PR.
- AC-007-2: Given all tagged phase PR attempts no-op because there are no commits
  and the run ends with commits from untagged work, when the run finalizes, then
  final AutoPR still runs according to existing eligibility rules.

### REQ-008: Fail loudly on phase PR creation errors

**Priority:** Must · **Complexity:** Medium

If a tagged phase has commits to propose but PR creation fails, Foreman must make
the failure attributable to that run/phase. It must not silently continue as if
the phase PR exists. [RISK: phase success plus hidden PR failure makes workflow
review boundaries disappear.]

- AC-008-1: Given `git push` or `gh pr create` fails for a tagged phase with
  proposable commits, when phase PR creation runs, then Foreman blocks the run at
  that phase with a typed phase PR failure until operator recovery or reset.
- AC-008-2: Given PR creation fails, when the operator inspects run events/logs,
  then the base, head, phase, and command failure reason are visible.

### REQ-009: Validate and normalize `stack_pr:` through manifest loading

**Priority:** Must · **Complexity:** Low

`stack_pr:` accepts only booleans. String values, integers, lists, maps, and
blank values are malformed and rejected at manifest load.

- AC-009-1: Given `stack_pr: "true"`, when the workflow loads, then loading fails
  with a typed manifest validation error naming the phase and key.
- AC-009-2: Given `stack_pr:` is absent, when the workflow loads and phase specs
  normalize, then absence stays distinguishable from explicit `false`.

### REQ-010: Preserve `stack_pr:` through manifest serialization

**Priority:** Should · **Complexity:** Low

Manifest round-trips through Foreman's writer/installer must preserve boolean
`stack_pr:` values.

- AC-010-1: Given a manifest with `stack_pr: true`, when it is written and loaded
  again, then the phase still carries boolean `true`.
- AC-010-2: Given a manifest with `stack_pr: false`, when it is written and
  loaded again, then the phase still carries boolean `false`.

### REQ-011: Surface phase PRs in run-facing projections and CLI/API views

**Priority:** Should · **Complexity:** Medium

Operators can see which phase produced which PR from existing run inspection
surfaces. At minimum this includes a projection/API path and `foreman run get
<id>` JSON output. Cockpit/run rendering should show phase PR links near phase
status when that view consumes the enriched projection.

[RISK: recording phase PRs only in logs would make restart recovery and operator
inspection depend on non-authoritative text output.]

- AC-011-1: Given a run has phase PR records, when the run projection/API is
  queried, then the records include phase name/index and PR URL.
- AC-011-2: Given a run has phase PR records, when a supported CLI view renders
  the run, then phase PR URLs are visible without reading raw logs.

### REQ-012: Keep commit deferral semantics independent from PR tagging

**Priority:** Must · **Complexity:** Medium

`stack_pr:` controls PR creation only. `commit:` continues to control whether the
phase commits. A tagged phase must not implicitly force a commit; with
`commit: false`, PR creation evaluates the existing run branch after the phase
and records a no-op if no committed diff is ahead of base.

[RISK: silently making `stack_pr: true` imply `commit: true` would violate the
operator-controlled commit design.]

- AC-012-1: Given `commit: false` and `stack_pr: true` appear together, when the
  workflow loads or phase completes, then Foreman accepts both tags, preserves
  the commit deferral policy, and does not create a phase PR unless the existing
  run branch is already ahead of base.
- AC-012-2: Given a phase declares `commit: true` and `stack_pr: true`, when it
  completes with changes, then the phase commit exists before the phase PR diff
  is evaluated.

### REQ-013: Support rerun/idempotency behavior for already-created phase PRs

**Priority:** Must · **Complexity:** High

Retried phases or executor restarts must not create unbounded duplicate PRs for
the same run phase. Foreman must detect existing recorded phase PRs and choose a
stable policy: reuse an existing recorded open PR for the same run phase and
head/base pair, reconcile an unrecorded existing open PR when GitHub reports one,
or fail with an actionable reason when the only matching PR is closed.

[RISK: retrying `gh pr create` without reconciliation can create duplicate review
objects or surface opaque provider errors.]

- AC-013-1: Given a phase PR was already recorded for a run phase, when the same
  phase PR step runs again after a process restart, then Foreman does not create
  a duplicate PR.
- AC-013-2: Given GitHub already has an open PR for the intended head/base pair
  but no local event was recorded, when phase PR creation runs, then Foreman
  records or reports that existing PR instead of failing with an opaque `gh`
  error.
- AC-013-3: Given the existing matching PR is closed, when retry policy runs,
  then Foreman fails with an actionable typed error rather than silently creating
  a replacement PR.

### REQ-014: Maintain PR monitor compatibility

**Priority:** Should · **Complexity:** Medium

Foreman's PR monitor should not confuse phase PRs with the final run PR. If phase
PRs are monitored, their events and task/run status effects must be distinct and
explicit.

[RISK: treating any phase PR merge as final run merge can prematurely close or
advance the parent task/run.]

- AC-014-1: Given a phase PR is merged, when the PR monitor observes it, then it
  does not incorrectly mark the entire run/task merged unless that policy is
  explicitly implemented and documented.
- AC-014-2: Given a final run PR exists separately, when PR monitor updates are
  applied, then final PR state and phase PR state remain distinguishable.

### REQ-015: Document operator semantics and constraints

**Priority:** Must · **Complexity:** Low

Because `stack_pr:` changes Foreman's public workflow YAML vocabulary and PR
behavior, living docs must be updated when implementation ships.

- AC-015-1: Given implementation adds `stack_pr:`, when the change is finalized,
  then `CLAUDE.md`, `AGENTS.md`, `README.md`, `docs/user-guide.md`, and
  `docs/cli-reference.md` are considered and edited or explicitly reported as
  not needing edits.
- AC-015-2: Given docs currently state there is no per-phase PR setting, when the
  feature ships, then those stale statements are updated in living docs.

## Dependency Map

| Requirement | Depends On | Blocked By | Notes |
|---|---|---|---|
| REQ-001 | — | — | Base declaration. |
| REQ-002 | REQ-001 | — | Default compatibility. |
| REQ-003 | REQ-001, REQ-004, REQ-005 | Base/head resolution | Core behavior. |
| REQ-004 | Existing run base branch capture | — | Must reuse no-default base policy. |
| REQ-005 | Existing worktree/run branch state | — | Uses run branch as phase PR head. |
| REQ-006 | REQ-003 | Event/projection design | Avoid `pr_url` corruption. |
| REQ-007 | REQ-006 | — | Skip final AutoPR only after a created phase PR. |
| REQ-008 | REQ-003 | — | Phase PR creation errors block the run at that phase. |
| REQ-009 | REQ-001 | — | Load-time safety. |
| REQ-010 | REQ-001, REQ-009 | — | Round-trip safety. |
| REQ-011 | REQ-006 | — | `foreman run get <id>` and enriched cockpit/run projection. |
| REQ-012 | REQ-001, existing `commit:` | — | Keeps tags independent; no implicit commit. |
| REQ-013 | REQ-006 | — | Reuse/reconcile open PRs; closed matches fail. |
| REQ-014 | REQ-006 | Monitor policy | Prevent state confusion. |
| REQ-015 | REQ-001–REQ-014 | — | Living doc gate. |

Implementation clusters:

1. Manifest schema: REQ-001, REQ-002, REQ-009, REQ-010.
2. Phase PR executor path: REQ-003, REQ-004, REQ-005, REQ-008, REQ-012,
   REQ-013.
3. Durable model and surfaces: REQ-006, REQ-011, REQ-014.
4. Finalization/docs: REQ-007, REQ-015.

No circular dependencies identified.

## Adversarial Self-Critique

Foreman mode auto-applied resolutions where safe.

1. **Issue:** The term "stacked" can imply PRs targeting previous phase PRs, but
   the task says each PR targets the run base branch.  
   **Resolution:** Non-goaled true stacked topology and stated cumulative diff
   risk. Auto-applied.
2. **Issue:** Reusing existing `PrAssociated` would overwrite final `pr_url`.  
   **Resolution:** Added REQ-006 requiring a distinct durable phase PR record.
   Auto-applied.
3. **Issue:** Final AutoPR could create a duplicate catch-all PR after phase PRs.
   **Resolution:** Added REQ-007 and refined it so only actually-created phase
   PRs suppress final AutoPR; no-op phase PR attempts do not.
4. **Issue:** `commit:false` combined with `stack_pr:true` is underspecified.  
   **Resolution:** Added REQ-012 and refined it so `stack_pr:` never implies a
   commit; the PR attempt no-ops unless the existing branch is already ahead.
5. **Issue:** Retry/restart may duplicate PRs.  
   **Resolution:** Added REQ-013 and refined it to reuse/reconcile open PRs and
   fail on closed matching PRs instead of creating replacements.
6. **Issue:** PR monitor may treat phase PRs as run completion.  
   **Resolution:** Added REQ-014 to keep phase/final PR states distinct.
   Auto-applied.

Ambiguity scan complete: 0 items remain marked for clarification.

## Implementation Readiness Gate

| Dimension | Score | Rationale |
|---|---:|---|
| Completeness | 5 | Covers declaration, execution, storage, views, idempotency, docs, and previously ambiguous policies. |
| Testability | 5 | Every requirement has Given/When/Then ACs. |
| Clarity | 5 | Core semantics and edge policies are explicit, with no remaining clarification markers. |
| Feasibility | 4 | Builds on existing AutoPR/worktree/projection patterns; shared-head PR semantics and retry reconciliation still require care. |

Overall score: **4.75**  
Readiness score: 4.25 -> 4.75 (improved)  
Gate decision: **PASS**

## Suggested Next Step

Create or update the TRD from this refined PRD, then stop for explicit approval
before implementation:

```bash
/ensemble-create-trd docs/PRD/PRD-2026-e33bcab7-stacked-pr-phase-tag.md
```

## Changelog

### 2026-09-01 — v1.0.1

- Resolved 8 `--foreman` ambiguity markers using best-effort defaults.
- Added missing risk indicators for all Medium/High complexity requirements.
- Clarified cumulative diff/shared head-branch semantics for phase PRs.
- Clarified `commit: false` + `stack_pr: true` behavior and no-op handling.
- Clarified final AutoPR skip policy, phase PR failure policy, retry/idempotency
  policy, and first-release visibility surface.
- Re-scored readiness from 4.25 to 4.75.
