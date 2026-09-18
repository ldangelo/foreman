---
document_id: PRD-2026-1c4f4a55
label: prd-autopr-task-pr-summary
version: 1.0.1
status: Draft
date: 2026-09-18
scale_depth: STANDARD
total_requirements: 13
total_acceptance_criteria: 33
readiness_score: 4.7
---

# PRD: Include bead/task title and description in AutoPR-generated PR summary

Foreman task title read from `FOREMAN_TASK_TITLE`: **Include bead/task title and description in AutoPR-generated PR summary**

Foreman mode active: STANDARD depth auto-selected. Clarifying interviews were skipped; assumptions are recorded below and unresolved ambiguity markers are included only where a later refinement truly needs human input.

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 10 |
| Should | 3 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 13/13 (100%) |
| Acceptance criteria coverage | 13/13 (100%) |
| Risk flags | 7 |
| Dependency count | 12 |
| Open ambiguity markers | 0 |

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Thread task metadata into final AutoPR context | Must | Medium | 3 |
| REQ-002 | Compose a task-aware PR title | Must | Medium | 3 |
| REQ-003 | Add a task summary section to the PR body | Must | Medium | 3 |
| REQ-004 | Preserve existing artifact and review findings body content | Must | Medium | 2 |
| REQ-005 | Preserve legacy fallback for runs without task metadata | Must | Medium | 3 |
| REQ-006 | Include task/bead identifiers when safely available | Should | Medium | 2 |
| REQ-007 | Preserve AutoPR branch, push, and PR creation behavior | Must | High | 3 |
| REQ-008 | Keep final AutoPR separate from PhasePR behavior | Must | Medium | 2 |
| REQ-009 | Validate metadata at typed boundaries | Must | Medium | 3 |
| REQ-010 | Provide deterministic unit/integration coverage | Must | High | 3 |
| REQ-011 | Verify the live Beads-backed PR path | Must | High | 3 |
| REQ-012 | Avoid leaking sensitive task descriptions in logs | Should | Medium | 2 |
| REQ-013 | Update relevant operator-facing docs | Should | Low | 1 |

## 1. Executive Summary

Foreman's final AutoPR currently opens pull requests with a generic title, `feat(run): <run_id>`, and a body derived only from the run id, optional artifact path, and CodeRabbit findings. Reviewers cannot tell which bead/task the PR implements without leaving GitHub and manually looking up the run. The Task aggregate already stores `title` and `description`, and `RunExecutor` has `state.task` available while building the AutoPR context, but that metadata is not passed into `AutoPR.maybe_create_pr/1`.

This PRD requires final AutoPRs for task-backed runs to surface the task title and description in the GitHub PR title/body while preserving the current behavior for ad-hoc runs that have no task metadata.

## 2. Problem Statement

A reviewer opening a Foreman-generated PR sees only an internal run id and optional review findings. This hides the operator-approved work item, slows review triage, and makes multiple Foreman PRs hard to distinguish in a GitHub PR list. The missing context is already available in Foreman's domain state; the product gap is wiring and presentation, not new task storage.

## 3. Users and Success Metrics

### Primary users

- **Foreman operator:** dispatches or approves Beads-backed tasks and expects the resulting PR to be recognizable.
- **PR reviewer:** opens a GitHub PR and needs enough context to understand intent before reviewing the diff.
- **Foreman maintainer:** must preserve existing AutoPR safety behavior and typed-boundary rules.

### Success metrics

- 100% of final AutoPRs for Beads-backed/task-backed runs display the task title in the PR title.
- 100% of final AutoPRs for Beads-backed/task-backed runs include the task description in the PR body.
- Ad-hoc runs without task title/description continue to produce valid PRs with the current generic title/body shape.
- No regressions in branch selection, push-before-create behavior, PR association, or phase PR handling.

## 4. Current State and Evidence

Source reconnaissance found these relevant facts:

- `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex` defines `AutoPR.context()` with `run_id`, `base_branch`, `artifact_path`, `head_branch`, and `cwd`; no task metadata fields exist.
- `AutoPR.open_pr/5` currently composes `title = "feat(run): #{run_id}"` and a body from run id, optional artifact path, and `findings_section/1`.
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` builds the AutoPR context in `auto_pr/1` from `state.run_id`, base branch, completion artifact path, last worktree branch, and VCS working directory.
- `packages/foreman_server/lib/foreman_server/aggregates/task.ex` includes `:title` and `:description` on `Task.State`.
- Existing PRD conventions use micro-UUID document IDs, health summaries, requirement tables, `REQ-NNN` headings, and Given/When/Then ACs.

## 5. Scope

### In scope

- Add task title/description fields to the final AutoPR context contract.
- Populate those fields from `RunExecutor` state when a task is present.
- Use the task title to make the PR title human-readable.
- Add a task summary section to the PR body using the task description.
- Include a task/bead identifier when it is safely available from existing state.
- Preserve current title/body fallback exactly for no-task/ad-hoc runs.
- Add focused tests and a live verification path for Beads-backed task PRs.
- Update behavior-facing docs where final AutoPR output is described.

### Out of scope

- Implementing this PRD.
- Changing task creation, approval, Beads ingestion, claim/complete/fail behavior, or provider adapters.
- Changing PhasePR title/body composition.
- Adding user-configurable PR title/body templates.
- Removing artifact links or review findings from PR bodies.
- Requiring live GitHub or local Postgres for deterministic automated tests.

## 6. Foreman-Mode Assumptions

- `state.task.title` and `state.task.description` are the canonical metadata source for final AutoPRs when present.
- If task metadata is absent because the run is ad-hoc/no-task, the existing generic PR title/body remains valid and must not be treated as an error.
- If a task aggregate is present but either title or description is malformed or blank, final AutoPR should fail loudly with a typed validation error before creating a misleading task-backed PR.
- Task-backed title and description are treated as an atomic pair: both are required for task-aware PR composition, while ad-hoc/no-task runs keep the legacy fallback.
- The task summary should be additive: it should appear before existing artifact and review findings sections, not replace them.
- A task/bead identifier should be included only if it is already available in Foreman state; implementation must not shell out to `br` or inspect Beads SQLite.

## 7. Requirements

### REQ-001: Thread task metadata into final AutoPR context

Priority: Must  
Complexity: Medium  
Risk: Reading task metadata from the wrong structure can reintroduce subject drift.

`RunExecutor` MUST include task title and task description in the context map passed to final `AutoPR.maybe_create_pr/1` when the run state has task metadata.

- AC-001-1: Given `state.task` contains a non-blank title and description, when `RunExecutor` invokes final AutoPR, then the AutoPR context includes explicit task title and task description fields.
- AC-001-2: Given existing context fields `run_id`, `base_branch`, `artifact_path`, `head_branch`, and `cwd`, when task metadata is added, then those fields remain populated with the same values as today.
- AC-001-3: Given the run has no task metadata, when `RunExecutor` invokes final AutoPR, then it does not synthesize task title/description from repository files, git history, artifacts, or PRD/TRD documents.

### REQ-002: Compose a task-aware PR title

Priority: Must  
Complexity: Medium  
Risk: A misleading title can cause reviewers to approve the wrong change.

Final AutoPR MUST use the task title to compose a human-readable GitHub PR title when a task title is available.

- AC-002-1: Given task title `Include bead/task title and description in AutoPR-generated PR summary`, when `gh pr create` is invoked, then the `--title` argument contains that task title rather than only `feat(run): <run_id>`.
- AC-002-2: Given a task title contains punctuation, slashes, quotes, or issue identifiers, when the command is built, then the title is passed as a data argument and not shell-interpolated.
- AC-002-3: Given no task title is available, when a PR is created for an ad-hoc run, then the title remains exactly the current fallback shape `feat(run): <run_id>`.

### REQ-003: Add a task summary section to the PR body

Priority: Must  
Complexity: Medium  
Risk: Body formatting can bury or distort task intent.

Final AutoPR MUST add a clearly labeled task summary section to the PR body when task description is available.

- AC-003-1: Given a task description is available, when the PR body is composed, then the body includes a section that describes what the task/bead was for.
- AC-003-2: Given a multi-line Markdown task description, when the body is passed to `gh pr create`, then line breaks and Markdown formatting are preserved.
- AC-003-3: Given no task description is available for an ad-hoc run, when the PR body is composed, then the body remains exactly the current fallback content: run completion text, optional artifact path, and findings section.

### REQ-004: Preserve existing artifact and review findings body content

Priority: Must  
Complexity: Medium

Task context MUST be additive and must not remove the artifact path or CodeRabbit findings section from task-backed PRs.

- AC-004-1: Given `artifact_path` is present and task metadata is present, when the PR body is composed, then the artifact path still appears in the body.
- AC-004-2: Given `ReviewFindings.extract/1` returns unresolved findings and task metadata is present, when the PR body is composed, then the unresolved findings section still appears in the body.

### REQ-005: Preserve legacy fallback for runs without task metadata

Priority: Must  
Complexity: Medium  
Risk: Breaking ad-hoc AutoPRs would regress valid non-Beads workflows.

AutoPR MUST keep the existing behavior for no-task/ad-hoc runs that do not have task title or description.

- AC-005-1: Given an AutoPR context with no task metadata, when `open_pr` is reached, then title and body match the current generic title/body byte-for-byte except for existing dynamic run/artifact/findings content.
- AC-005-2: Given a run has no Task aggregate, when final AutoPR succeeds, then no task metadata validation error is raised.
- AC-005-3: Given a task aggregate is present but only one of task title or description is available, when metadata validation runs, then final AutoPR fails with a typed validation error before any PR title/body is composed or `gh pr create` is invoked.

### REQ-006: Include task/bead identifiers when safely available

Priority: Should  
Complexity: Medium

The PR body SHOULD include a traceability identifier, such as task id or Beads/provider id, when it is already present in Foreman state.

- AC-006-1: Given `state.task_id` or a provider-facing Beads id is available from existing run/task state, when the PR body is composed, then the identifier is included in the task summary section.
- AC-006-2: Given the identifier is not available in state, when composing the PR body, then AutoPR does not call `br`, open Beads SQLite, or call provider adapter internals to discover it.

### REQ-007: Preserve AutoPR branch, push, and PR creation behavior

Priority: Must  
Complexity: High  
Risk: AutoPR branch/base behavior has had regressions that can create wrong PRs.

Adding task context MUST NOT change base branch resolution, head branch resolution, commits-ahead checks, push-before-create behavior, PR creation, or error/no-op semantics.

- AC-007-1: Given a branch has no commits ahead of base, when final AutoPR runs with task metadata, then it still returns `:noop` and does not call `gh pr create`.
- AC-007-2: Given a branch has commits ahead of base, when final AutoPR runs with task metadata, then it still pushes the head branch before creating the PR.
- AC-007-3: Given base or head branch resolution fails, when task metadata is present, then the existing typed branch error is returned and no title/body fallback masks it.

### REQ-008: Keep final AutoPR separate from PhasePR behavior

Priority: Must  
Complexity: Medium

This change MUST affect final run AutoPR only.

- AC-008-1: Given phase PR records exist with `created` or `existing` status, when finalization reaches AutoPR, then final AutoPR is skipped exactly as today.
- AC-008-2: Given PhasePR creates or reuses a per-phase PR, when this feature is implemented, then PhasePR title/body behavior is unchanged.

### REQ-009: Validate metadata at typed boundaries

Priority: Must  
Complexity: Medium  
Risk: Silent fallback can leave a PR plausibly but incorrectly titled.

Task metadata handling MUST follow the repo's typed-boundary and loud-failure conventions.

- AC-009-1: Given task metadata is present but non-string or blank, when AutoPR context is validated, then the behavior is a typed validation outcome and is covered by tests.
- AC-009-2: Given unknown keys appear in task metadata, when the AutoPR context is built, then only the known title/description/id fields are used.
- AC-009-3: Given a new AutoPR error variant is introduced, when `RunExecutor.finalize_run/1` handles AutoPR results, then total result handling is preserved and no unmatched error is treated as success.

### REQ-010: Provide deterministic unit/integration coverage

Priority: Must  
Complexity: High

The implementation MUST include deterministic tests that do not require live GitHub or mutable local credentials.

- AC-010-1: Given AutoPR receives task title/description, when command argument composition is tested, then captured `gh pr create` args include the expected title and body section.
- AC-010-2: Given AutoPR receives no task metadata, when fallback composition is tested, then captured title/body match legacy behavior.
- AC-010-3: Given a RunExecutor test uses a real task/run state path, when final AutoPR context is captured, then task title/description are shown to come from task state rather than invented from artifacts or docs.

### REQ-011: Verify the live Beads-backed PR path

Priority: Must  
Complexity: High  
Risk: Unit tests can miss provider/task projection wiring.

The release verification MUST include a live or staging Beads-backed workflow check when environment access allows it.

- AC-011-1: Given a `prd`, `fix`, or `implement-trd*` run is dispatched from a Beads-backed task, when AutoPR creates a real GitHub PR, then `gh pr view <number>` shows the task's actual subject in the PR title/body, not only `feat(run): <run_id>`.
- AC-011-2: Given an ad-hoc run with no task title/description creates a PR, when viewed in GitHub, then the title/body are valid and not empty or malformed.
- AC-011-3: Given live verification cannot run due to local credentials, GitHub auth, or service availability, when implementation is completed, then the blocker is reported explicitly and deterministic tests still pass.

### REQ-012: Avoid leaking sensitive task descriptions in logs

Priority: Should  
Complexity: Medium  
Risk: Task descriptions may contain operator context not intended for logs.

AutoPR logging MUST avoid dumping full task descriptions while still giving operators enough diagnostics.

- AC-012-1: Given a task description contains sensitive-looking text, when AutoPR logs start/success/failure events, then logs include identifiers and outcome metadata but not the full task description.
- AC-012-2: Given `gh pr create` fails, when the error is logged/returned, then existing command output handling is preserved and no new log line prints the raw task body.

### REQ-013: Update relevant operator-facing docs

Priority: Should  
Complexity: Low

Documentation MUST be reviewed and updated only where this behavior is described or operator expectations change.

- AC-013-1: Given `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`, and `AGENTS.md` are reviewed, when any document describes final AutoPR output, then it is surgically updated to mention task-aware PR title/body behavior; otherwise the no-change decision is documented in implementation output.

## 8. Dependency Map

| REQ | Depends On | Notes |
|---|---|---|
| REQ-001 | — | Base metadata plumbing. |
| REQ-002 | REQ-001, REQ-005 | Title needs metadata and fallback policy. |
| REQ-003 | REQ-001, REQ-005 | Body section needs metadata and fallback policy. |
| REQ-004 | REQ-003 | Existing body sections must remain after task summary insertion. |
| REQ-005 | REQ-001 | Defines no-task behavior. |
| REQ-006 | REQ-001 | Identifier inclusion depends on available state. |
| REQ-007 | REQ-001 | Branch behavior must remain unchanged while context grows. |
| REQ-008 | REQ-007 | Final AutoPR must remain separate from PhasePR. |
| REQ-009 | REQ-001, REQ-005 | Validation wraps metadata/fallback. |
| REQ-010 | REQ-002, REQ-003, REQ-005, REQ-009 | Tests prove composition and validation. |
| REQ-011 | REQ-010 | Live verification follows deterministic proof. |
| REQ-012 | REQ-003 | Logging is affected by body content. |
| REQ-013 | REQ-002, REQ-003, REQ-004 | Docs after behavior is defined. |

Implementation clusters:

1. Context contract and metadata extraction: REQ-001, REQ-005, REQ-009.
2. PR title/body composition: REQ-002, REQ-003, REQ-004, REQ-006, REQ-012.
3. Behavior preservation and tests: REQ-007, REQ-008, REQ-010.
4. Verification and docs: REQ-011, REQ-013.

No circular dependencies identified.

## 9. Technical Dependency Mapping

| Component | Interaction | Data Flow | Requirement Impact |
|---|---|---|---|
| Task aggregate/projection | Source of task title/description | `Task.title`, `Task.description`, task/provider ids → run state | REQ-001, REQ-006, REQ-010 |
| `RunExecutor` | Builds final AutoPR context | run/task/worktree state → `AutoPR.maybe_create_pr/1` context | REQ-001, REQ-007, REQ-008 |
| `AutoPR` | Validates context, composes title/body, invokes `gh` | context → `gh pr create --title --body` args | REQ-002, REQ-003, REQ-004, REQ-005, REQ-009 |
| `ReviewFindings` | Existing body section source | artifact path → findings section | REQ-004 |
| Git/GitHub CLI | External PR boundary | branch/base/title/body args → GitHub PR | REQ-007, REQ-011 |
| ProjectionStore/read models | Phase PR skip and PR association | phase PR records/run PR URL | REQ-008 |
| Docs | Operator-facing expectations | final AutoPR behavior | REQ-013 |

## 10. Adversarial Self-Review

1. **Issue:** Task-aware body composition could accidentally replace artifact links and CodeRabbit findings.  
   **Resolution:** REQ-004 makes task summary additive and preserves existing sections.

2. **Issue:** The implementation could infer a task subject from artifacts, docs, or git history when state lacks metadata.  
   **Resolution:** REQ-001 and REQ-005 forbid synthesis and preserve exact no-task fallback.

3. **Issue:** A partially present task title/description policy can be ambiguous.  
   **Resolution:** Foreman-mode refinement selected the loud-failure policy: task-backed AutoPR requires both title and description, while no-task/ad-hoc runs keep the legacy fallback.

4. **Issue:** Including Beads IDs might tempt implementation to shell out to `br` or inspect Beads storage.  
   **Resolution:** REQ-006 permits identifiers only when already present in Foreman state.

5. **Issue:** Branch/push behavior is fragile and unrelated to title/body, but easy to regress while changing AutoPR.  
   **Resolution:** REQ-007 requires preserving current branch, ahead, push, and PR semantics.

6. **Issue:** Phase PR behavior can be conflated with final AutoPR behavior.  
   **Resolution:** REQ-008 excludes PhasePR changes and preserves skip behavior when phase PR records exist.

7. **Issue:** Task descriptions may be sensitive and new logging could leak them.  
   **Resolution:** REQ-012 requires body-safe logging.

All safe resolutions auto-applied under Foreman mode.

Ambiguity scan complete: 0 items marked for clarification after resolving the partial-metadata policy.

## 11. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 4.7 | Covers metadata plumbing, title/body composition, fallback, traceability id, branch behavior, PhasePR separation, tests, live verification, logging, and docs. |
| Testability | 4.8 | Requirements have concrete ACs; deterministic tests plus optional live verification are defined, including the partial-metadata failure path. |
| Clarity | 4.8 | Additive body behavior, no-task fallback, and partial task metadata failure policy are explicit. |
| Feasibility | 4.6 | Uses existing task fields and current AutoPR/RunExecutor seams; no new storage or provider integration required. |

Overall readiness score: **4.7**
Gate decision: **PASS**

## 12. Suggested Next Step

Create a TRD from this PRD:

```sh
/ensemble-create-trd docs/PRD/PRD-2026-1c4f4a55-autopr-task-pr-summary.md
```

## 13. Version History

### 2026-09-18 — v1.0.1

- Resolved the partial task metadata policy: task-backed AutoPR requires both title and description; missing/blank partial metadata fails with a typed validation error.
- Updated readiness score from 4.6 to 4.7 after clarification.
