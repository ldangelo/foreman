---
document_id: PRD-2026-b88e3551
label: prd-stack-pr-phase-tag
version: 1.0.0
status: Draft
date: 2026-09-01
scale_depth: STANDARD
author: Lead Agent
total_requirements: 12
readiness_score: 3.8
readiness_gate: CONCERNS
---

# PRD: Phase-Level `stack_pr` Tag for Stacked PRs

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 8 |
| Should | 3 |
| Could | 1 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 12/12 (100%) |
| AC coverage | 12/12 requirements have acceptance criteria (100%) |
| Risk flags | 6 |
| Dependency count | 11 |
| Open ambiguity markers | 13 |
| External dependencies | 2 |

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Declare a phase-level `stack_pr:` boolean | Must | Low | 2 |
| REQ-002 | Preserve current single-PR behavior by default | Must | Medium | 2 |
| REQ-003 | Open a stacked PR boundary for tagged phases | Must | High | 3 |
| REQ-004 | Derive stacked PR order from phase order | Must | Medium | 2 |
| REQ-005 | Reconcile `stack_pr:` with `commit:` semantics | Must | High | 3 |
| REQ-006 | Reject malformed or unsatisfiable declarations at load | Must | Medium | 3 |
| REQ-007 | Record durable stacked PR metadata | Must | Medium | 2 |
| REQ-008 | Surface stacked PR status in operator views | Should | Medium | 2 |
| REQ-009 | Keep Foreman-dispatched ensemble behavior explicit | Should | Medium | 2 |
| REQ-010 | Provide observable failure and retry behavior | Must | High | 3 |
| REQ-011 | Support non-GitHub VCS backends safely | Could | High | 1 |
| REQ-012 | Document and test the workflow contract | Should | Low | 2 |

## Problem Statement

Foreman currently opens at most one pull request for a run. `AutoPR` runs once at finalization, pushes the run branch, and creates one PR from all commits beyond the run base. This is correct for simple workflows, but it prevents workflow authors from asking Foreman to expose phase groups as a reviewable stack when a run naturally contains multiple shippable slices.

The requested product is a phase-level `stack_pr` tag. The provided Foreman subject was: **Add stack_pr phase tag for stacked PRs**. The provided description was only `Test`, so this PRD uses repository-derived constraints and marks product decisions that need operator confirmation inline.

Who feels the pain: Foreman workflow authors and maintainers reviewing long or multi-slice runs. Primary users are operators who write bundled or project workflow YAML, and reviewers who need separate PRs for separable phases.

## Goals

- Let a workflow phase declare that its committed output should become a stacked PR boundary.
- Preserve existing one-PR behavior for every workflow that does not opt in.
- Keep stacked PR behavior deterministic, phase-ordered, observable, and retry-safe.
- Avoid reintroducing undocumented `pr:`, `merge:`, `stacked:`, or `checkpointPr` behavior.

## Non-Goals

- Implementing the feature in this PRD phase.
- Replacing `commit:`; `stack_pr:` consumes committed work boundaries, it does not decide whether a phase commits.
- Changing how direct ensemble skills create their own stacked PRs outside Foreman.
- Creating multiple PRs by default for existing bundled workflows.
- Defining a full merge queue or automatic stack landing strategy [NEEDS CLARIFICATION: Should Foreman ever auto-merge stacked PRs, or is creation/status only in scope?].

## Existing Context and Constraints

- Foreman is a Go CLI plus Elixir/OTP backend. Workflow execution, phase parsing, worktree handling, commit behavior, and AutoPR live under `packages/foreman_server`.
- Current docs state one run yields at most one PR; no `pr:`, `merge:`, `stacked:`, or `checkpointPr` workflow settings exist.
- Phase-level `commit:` already exists and defaults to committing. `commit: false` defers changes for a later committing phase.
- AutoPR currently gates on commits ahead of the run base, not an explicit phase marker.
- Repository rules require typed boundaries, fail-loud malformed input, no permissive fallback, and docs updates when operator workflow behavior changes.

## External Dependencies

| Dependency | Status | Effect |
|---|---|---|
| GitHub CLI / GitHub PR APIs | Existing for AutoPR | Initial stacked PR support is assumed to use the same GitHub path [NEEDS CLARIFICATION: Is GitHub-only acceptable for the first slice?]. |
| VCS backend abstraction | Existing, Git/Jujutsu support varies | Stacked PR creation must either be backend-capable or explicitly rejected with a typed error. |

## Assumptions

- **A1** — The tag name is exactly `stack_pr` in YAML, using snake_case [NEEDS CLARIFICATION: Should the public YAML key be `stack_pr`, `stackPr`, or `stack-pr`?].
- **A2** — A tagged phase means “create/propose a PR boundary after this phase’s committed work,” not “start a new branch before this phase” [NEEDS CLARIFICATION: Should `stack_pr: true` mark the end of a PR slice or the beginning of one?].
- **A3** — Stacked PR base order follows phase order, with each later PR targeting the previous stack branch.
- **A4** — Untagged workflows continue through current AutoPR unchanged.
- **A5** — The first supported implementation may be GitHub-only if other VCS adapters cannot create stacked PRs safely.
- **A6** — `--foreman` continues to disable direct ensemble stacked-PR behavior inside agent skills; this feature is Foreman-owned stack creation after phase commits.

## Requirements

### Feature Area: Workflow Declaration

#### REQ-001: Declare a phase-level `stack_pr:` boolean

**Priority:** Must · **Complexity:** Low

A workflow phase may declare `stack_pr:` with value `true` or `false`. `true` opts the phase into stacked PR boundary behavior; `false` is equivalent to absence and exists only for explicitness [NEEDS CLARIFICATION: Should `false` be preserved in normalized specs or dropped as default noise?].

- AC-001-1: Given a phase declaring `stack_pr: true`, when the workflow loads, then the phase spec carries a typed boolean true value.
- AC-001-2: Given a phase declaring `stack_pr: "true"`, when the workflow loads, then Foreman rejects the manifest with a typed malformed-value error that names the phase index and key.

#### REQ-002: Preserve current single-PR behavior by default

**Priority:** Must · **Complexity:** Medium

A workflow with no `stack_pr: true` phase keeps current finalization behavior: one AutoPR from the run branch when commits exist, and no PR when no commits exist.

- AC-002-1: Given an existing workflow with no `stack_pr` keys and committed changes, when the run finalizes, then Foreman calls the existing single-PR path once.
- AC-002-2: Given an existing workflow with no `stack_pr` keys and no commits ahead of base, when the run finalizes, then Foreman remains `:noop` and creates no phantom PR.

#### REQ-003: Open a stacked PR boundary for tagged phases

**Priority:** Must · **Complexity:** High · **[RISK: branch and PR creation now happen more than once per run]**

When one or more phases declare `stack_pr: true`, Foreman creates a stack of PRs whose boundaries correspond to the tagged phases and the final committed slice [NEEDS CLARIFICATION: Should the final phase automatically become a stack boundary if not tagged?].

- AC-003-1: Given phases 1 and 3 declare `stack_pr: true`, when all phases complete with commits in each slice, then Foreman creates PRs in phase-order stack sequence.
- AC-003-2: Given a tagged phase produces no new commit beyond its slice base, when stack creation reaches that boundary, then Foreman records a no-op boundary and does not create an empty PR.
- AC-003-3: Given stack creation fails for boundary N, when finalization reports the failure, then later boundaries are not silently created against an unknown base.

#### REQ-004: Derive stacked PR order from phase order

**Priority:** Must · **Complexity:** Medium

Foreman computes stack order from the workflow phase list, not from git history order, branch-name sorting, PR creation time, or external tool output.

- AC-004-1: Given multiple tagged phases, when Foreman builds the stack plan, then each boundary records the phase index that caused it.
- AC-004-2: Given a later phase commits earlier deferred work, when stack order is computed, then the boundary follows the committing phase that produced the commit, not the earlier deferred phase.

#### REQ-005: Reconcile `stack_pr:` with `commit:` semantics

**Priority:** Must · **Complexity:** High · **[RISK: `commit: false` can make a requested PR boundary impossible]**

A `stack_pr: true` phase can only create a PR boundary from committed work. If the same phase declares `commit: false`, Foreman must not pretend a PR exists for uncommitted changes [NEEDS CLARIFICATION: Should `stack_pr: true` plus `commit: false` be a load-time error, or should the boundary attach to the next committing phase?].

- AC-005-1: Given `stack_pr: true` and `commit: true` on a dirty phase, when the phase completes, then its commit range is eligible for a stack boundary.
- AC-005-2: Given `stack_pr: true` and `commit: false` on a phase, when the workflow loads, then Foreman either rejects the declaration or records a deterministic deferred-boundary rule; it never succeeds with silent no-op behavior [NEEDS CLARIFICATION: Which behavior is desired?].
- AC-005-3: Given deferred work is absorbed by a later committing phase, when stacked PRs are created, then the PR content includes all changes committed at that later boundary.

#### REQ-006: Reject malformed or unsatisfiable declarations at load

**Priority:** Must · **Complexity:** Medium · **[RISK: permissive parsing would make PR topology unpredictable]**

Foreman validates `stack_pr:` at workflow load using the same fail-loud discipline as `commit:`. Unknown values, impossible combinations, and unsupported backend combinations must fail before execution begins.

- AC-006-1: Given `stack_pr:` is not a boolean, when the workflow loads, then Foreman returns a typed error; no run starts.
- AC-006-2: Given `stack_pr: true` in a workflow with `worktree.enabled: false`, when the workflow loads, then Foreman rejects it because no branch can be proposed [NEEDS CLARIFICATION: Should this be a warning instead for dry-run workflows?].
- AC-006-3: Given the selected VCS backend cannot support stacked PRs, when the workflow loads or run starts, then Foreman rejects with a typed unsupported-feature error before phase execution.

### Feature Area: PR Creation and Metadata

#### REQ-007: Record durable stacked PR metadata

**Priority:** Must · **Complexity:** Medium

Every planned, created, skipped, or failed stack boundary is recorded durably against the run.

- AC-007-1: Given a stacked PR is created, when the run projection is read, then it includes PR URL, head branch, base branch, boundary phase index, and status [NEEDS CLARIFICATION: What exact projection/API shape should expose multiple PRs?].
- AC-007-2: Given a boundary is skipped because no commits exist, when the run projection is read, then it records the skipped boundary and reason.

#### REQ-008: Surface stacked PR status in operator views

**Priority:** Should · **Complexity:** Medium

Operators can see stacked PR state in existing run/status/watch surfaces without reading raw logs.

- AC-008-1: Given a run created stacked PRs, when `foreman run status` or equivalent run detail is displayed, then all stack PR URLs and statuses are visible [NEEDS CLARIFICATION: Which exact CLI command owns the display?].
- AC-008-2: Given stack creation fails, when `foreman watch` displays the terminal run state, then the failure explains the boundary and underlying command/API error.

#### REQ-009: Keep Foreman-dispatched ensemble behavior explicit

**Priority:** Should · **Complexity:** Medium

This Foreman feature must not conflict with ensemble skills that create stacked PRs when run directly. Under Foreman dispatch, agents still avoid their own `git town append` or stacked-PR path unless explicitly changed by a separate contract.

- AC-009-1: Given an ensemble skill runs with `--foreman`, when it reaches implementation instructions, then it does not create its own stacked PRs; Foreman remains the PR owner.
- AC-009-2: Given a workflow declares `stack_pr: true`, when phases run, then worker prompts and environment make clear whether the agent should only write files or may affect VCS state [NEEDS CLARIFICATION: Should agents receive a `FOREMAN_STACK_PR_BOUNDARY` env var?].

#### REQ-010: Provide observable failure and retry behavior

**Priority:** Must · **Complexity:** High · **[RISK: partial stack creation can leave remote branches and PRs behind]**

Stack creation must be retry-safe and explicit about partial success. A finalization retry must not duplicate already-created PRs.

- AC-010-1: Given Foreman creates PR 1 then fails creating PR 2, when the run is inspected, then PR 1 is recorded and PR 2 is marked failed with retryable details.
- AC-010-2: Given finalization is retried after partial creation, when Foreman sees an already-recorded PR for a boundary, then it reuses or reconciles it rather than creating a duplicate [NEEDS CLARIFICATION: Is finalization retry an existing supported operator action for this path?].
- AC-010-3: Given a remote branch push fails, when Foreman reports the run terminal state, then the failure includes stderr/exit code without leaking secrets.

#### REQ-011: Support non-GitHub VCS backends safely

**Priority:** Could · **Complexity:** High · **[RISK: stacked PR primitives differ by host and backend]**

Foreman should expose stacked PR support through the VCS adapter boundary where practical. Unsupported backends must fail loudly rather than silently falling back to a single PR.

- AC-011-1: Given a backend has no stacked PR implementation, when a workflow declares `stack_pr: true`, then Foreman returns a typed unsupported-feature result and does not execute the workflow.

### Feature Area: Documentation and Validation

#### REQ-012: Document and test the workflow contract

**Priority:** Should · **Complexity:** Low

The feature updates operator docs, CLI reference, and workflow examples only where behavior actually changes.

- AC-012-1: Given `stack_pr:` ships, when docs are reviewed, then `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`, and `AGENTS.md` are either updated or explicitly reported as unaffected.
- AC-012-2: Given workflow parsing, stack planning, PR creation, projection, and docs behavior, when tests run, then each new boundary has coverage that would fail if Foreman silently reverted to one PR.

## Dependency Map

- REQ-002 depends on REQ-001 because absence/default behavior must be defined after tag parsing.
- REQ-003 depends on REQ-001, REQ-002, and REQ-004.
- REQ-004 depends on REQ-001.
- REQ-005 depends on existing `commit:` behavior and REQ-003.
- REQ-006 depends on REQ-001 and REQ-005.
- REQ-007 depends on REQ-003 and REQ-010.
- REQ-008 depends on REQ-007.
- REQ-009 depends on REQ-003 and existing `--foreman` skill behavior.
- REQ-010 depends on REQ-003 and REQ-007.
- REQ-011 depends on REQ-003 and the VCS adapter capability model.
- REQ-012 depends on all behavior requirements.

Implementation clusters:

1. **Schema and planning:** REQ-001, REQ-002, REQ-004, REQ-005, REQ-006.
2. **PR creation:** REQ-003, REQ-010, REQ-011.
3. **State and UX:** REQ-007, REQ-008.
4. **Skill/docs contract:** REQ-009, REQ-012.

No circular dependencies identified.

## Adversarial Review

Foreman mode auto-applied the following resolutions instead of pausing for interview:

1. **Issue:** The requested description was `Test`, which does not define users, success metrics, or exact semantics.  
   **Resolution:** Scope the PRD around the title, use current Foreman behavior as constraint, and mark unresolved decisions inline.
2. **Issue:** Existing docs explicitly say there is no stacked PR setting.  
   **Resolution:** Treat this PRD as a product request to change that behavior, while requiring docs updates when implemented.
3. **Issue:** `commit: false` can conflict with PR boundary semantics.  
   **Resolution:** Add REQ-005 and mark the desired conflict behavior for clarification.
4. **Issue:** Multiple PR creation can leave partial remote state.  
   **Resolution:** Add retry-safe durable metadata and partial-failure requirements.
5. **Issue:** Existing AutoPR is finalization-only and commit-count based.  
   **Resolution:** Require deterministic stack planning from phase order rather than inferring from git history alone.
6. **Issue:** Non-GitHub support may not exist.  
   **Resolution:** Make backend support fail-loud and classify broad multi-backend support as Could.
7. **Issue:** The exact YAML key style is unconfirmed.  
   **Resolution:** Assume `stack_pr` from the task title and mark naming ambiguity inline.

Ambiguity scan complete: 13 items marked for clarification.

## Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 4 | Covers parsing, defaults, stack planning, commit interaction, metadata, UX, retry, docs. |
| Testability | 4 | ACs are mostly executable, but several depend on unresolved semantic choices. |
| Clarity | 3 | The core intent is clear; boundary semantics and `commit: false` interaction need confirmation. |
| Feasibility | 4 | Feasible within existing Foreman workflow/AutoPR architecture, but multi-PR finalization is non-trivial. |

**Overall score:** 3.8  
**Gate decision:** CONCERNS — proceeding under `--foreman` mode with warnings recorded. The PRD is good enough for a refine-PRD interview, not implementation without clarification.

## Suggested Next Step

Run:

```text
/skill:ensemble-refine-prd docs/PRD/PRD-2026-b88e3551-stack-pr-phase-tag.md --foreman
```
