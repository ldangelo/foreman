---
document_id: PRD-2026-81f29bf4
label: prd-autopr-task-title-body
version: 1.0.1
status: Draft
date: 2026-09-18
scale_depth: STANDARD
total_requirements: 12
total_acceptance_criteria: 31
readiness_score: 4.7
---

# PRD: AutoPR PR title/description actual implementation

Foreman task title read from `FOREMAN_TASK_TITLE`: **AutoPR PR title/description: actual implementation**

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 9 |
| Should | 3 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 12/12 (100%) |
| Acceptance criteria coverage | 12/12 (100%) |
| Risk flags | 7 |
| Dependencies | 9 |
| Open ambiguity markers | 0 |
| TRD decisions required | 0 |

## Acceptance Criteria Summary

| Requirement | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Carry task title/description into AutoPR context | Must | Medium | 3 |
| REQ-002 | Use task title as final AutoPR title | Must | Medium | 3 |
| REQ-003 | Use task description as final AutoPR body | Must | Medium | 3 |
| REQ-004 | Preserve existing AutoPR eligibility and branch behavior | Must | High | 3 |
| REQ-005 | Define safe fallback behavior for missing metadata | Must | Medium | 2 |
| REQ-006 | Keep final AutoPR separate from phase PR behavior | Must | Medium | 2 |
| REQ-007 | Verify with a real Task aggregate and AutoPR call | Must | High | 3 |
| REQ-008 | Cover AutoPR title/body composition with focused tests | Must | Medium | 3 |
| REQ-009 | Preserve typed boundary and loud failure conventions | Must | Medium | 3 |
| REQ-010 | Preserve Foreman commit/operator expectations | Should | Low | 2 |
| REQ-011 | Update user-facing docs only where behavior changes | Should | Medium | 2 |
| REQ-012 | Avoid leaking sensitive task content into logs | Should | Medium | 2 |

## 1. Executive Summary

Foreman's final AutoPR currently creates a generic PR title, `feat(run): <run_id>`, and a generated body describing the run artifact. That makes review queues hard to scan and disconnects the final PR from the task an operator approved. This PRD requires the final run AutoPR to use the Task aggregate's title and description as the PR title and body.

This is implementation work for the previously closed PR #513 design. The prior PRD/TRD paths named in the task are not present in this worktree, so they are treated as external investigation artifacts, not as source files to ship. This PRD does not cover `PhasePR` per-phase title behavior or the push-before-reuse bug tracked separately by foreman-2jru.

Foreman mode auto-selected STANDARD depth. This refinement resolved the prior inline clarification markers with best-effort product defaults and left implementation approval for a later step.

## 2. Background and Evidence

### 2.1 Current codebase shape

Foreman is a brownfield Elixir/Phoenix/OTP backend with a Go CLI. The relevant backend files are:

- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
- `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex`
- `packages/foreman_server/lib/foreman_server/events/task_created.ex`
- `packages/foreman_server/test/foreman_server/workflow/auto_pr_test.exs`
- `packages/foreman_server/test/foreman_server/workflow/run_executor_test.exs`

`RunExecutor.auto_pr/1` currently passes an AutoPR context containing `run_id`, `base_branch`, `artifact_path`, `head_branch`, and `cwd`. `AutoPR.open_pr/5` currently composes title/body internally from `run_id` and `artifact_path`.

### 2.2 Relevant existing contracts

- `TaskCreated` carries `title` and `description` fields.
- `RunExecutor.plan_subject_env/1` already extracts task title/description from `plan_context["task"]` or `state.task` to set `FOREMAN_TASK_TITLE` and `FOREMAN_TASK_DESCRIPTION` for phase prompts.
- `AutoPR.maybe_create_pr/1` requires a valid `run_id` and `base_branch`, resolves the head branch from artifact override or run state, checks commits ahead, pushes the head branch, then calls `gh pr create`.
- `PhasePR` is distinct from final AutoPR. Phase PR title/body behavior is out of scope for this PRD.

### 2.3 Product problem

A Foreman run's final PR should communicate the operator-approved task, not just the internal run id. Today the generic title and generated body hide the task subject, so reviewers must jump through Foreman artifacts or task state to understand why the PR exists. This also makes automated PR processing less reliable because downstream systems see a generic run title rather than the task title.

## 3. Personas

### 3.1 Foreman operator

Approves a task and expects the resulting final PR to be recognizable from the PR list without opening Foreman run details.

### 3.2 PR reviewer

Reviews the final run PR and needs the PR title/body to describe the task intent and expected outcome.

### 3.3 Foreman maintainer

Needs the implementation to stay inside existing typed boundaries, preserve current AutoPR branch/eligibility behavior, and be covered by deterministic tests.

## 4. Scope

### In scope

- Thread Task aggregate `title` and `description` into the final AutoPR context map.
- Use task title as the final AutoPR title.
- Use task description as the final AutoPR body.
- Preserve existing AutoPR branch resolution, commit-ahead detection, push, PR creation, no-op, and error behavior.
- Add regression tests using a real Task aggregate plus an AutoPR call path.
- Update docs where final AutoPR title/body behavior is described or expected.

### Out of scope

- Implementing this PRD.
- Resurrecting or shipping PR #513's design documents without implementation.
- Per-phase `PhasePR` titles or bodies.
- Phase PR push-before-reuse behavior from foreman-2jru.
- Changing task lifecycle, BeadsWatcher dispatch, auto-approval, or `br update` behavior.
- New CLI flags for PR title/body customization.

## 5. Assumptions From Foreman Mode

- The Task aggregate is the source of truth for the final AutoPR title and body.
- The final AutoPR should prefer task metadata from `state.task`; if a plan context task is already the canonical source in the run state, the TRD must verify that exact source before implementation.
- Final AutoPR body MUST be exactly the Task description for task-backed runs. Existing generated run/artifact sections and unresolved review findings MUST NOT be appended to the body unless a later approved requirement explicitly changes that behavior.
- Final AutoPR title MUST equal `Task.title` exactly for task-backed runs. It MUST NOT add phase, workflow, run, or provider-id prefixes.
- Missing task metadata policy: task-backed runs with blank/invalid `Task.title` or `Task.description` MUST fail final AutoPR with a typed validation error. Runs with no Task aggregate preserve the existing legacy generated title/body fallback.

## 6. Requirements

### 6a. Task metadata plumbing

### REQ-001: Carry task title/description into AutoPR context

Priority: Must  
Complexity: Medium  
Risk: Pulling metadata from the wrong map can reproduce the subject-drift class this repo explicitly avoids.

`RunExecutor` MUST pass task title and task description into the final AutoPR context map when the run has task metadata.

- AC-001-1: Given a run state with a Task aggregate carrying `title` and `description`, when final AutoPR is invoked, then the context passed to `AutoPR.maybe_create_pr/1` includes those values under explicit task metadata keys.
- AC-001-2: Given both atom-keyed and string-keyed task metadata shapes can appear in run state, when metadata is extracted, then extraction handles the validated canonical shapes and rejects malformed present values rather than silently skipping them.
- AC-001-3: Given existing AutoPR fields `run_id`, `base_branch`, `artifact_path`, `head_branch`, and `cwd`, when task metadata is added, then those existing fields remain present and unchanged.

### REQ-002: Use task title as final AutoPR title

Priority: Must  
Complexity: Medium  
Risk: Title composition can drift from the operator-approved task and make the PR misleading.

Final AutoPR MUST use the Task title as the GitHub PR title for run-level PRs.

- AC-002-1: Given `Task.title = "AutoPR PR title/description: actual implementation"`, when AutoPR executes `gh pr create`, then the `--title` argument contains that task title instead of `feat(run): <run_id>`.
- AC-002-2: Given the task title contains punctuation, slashes, or issue identifiers, when the title is passed to `gh`, then it is passed as one argument without shell interpolation.
- AC-002-3: Given a phase PR is created through `PhasePR`, when its title is composed, then this requirement does not change that phase PR title behavior.

### REQ-003: Use task description as final AutoPR body

Priority: Must  
Complexity: Medium  
Risk: Body replacement may remove existing artifact/review finding context if not deliberate.

Final AutoPR MUST use the Task description as the exact GitHub PR body for task-backed run-level PRs. It MUST NOT append the current generated run/artifact section or unresolved review findings.

- AC-003-1: Given a Task description, when AutoPR executes `gh pr create`, then the `--body` argument equals the Task description.
- AC-003-2: Given the Task description spans multiple lines and contains Markdown, when the body is passed to `gh`, then line breaks and Markdown are preserved.
- AC-003-3: Given existing unresolved review findings extraction is enabled for artifacts, when task description is used as body, then findings and artifact links are omitted from the PR body and existing artifact files remain the source for that detail.

### REQ-004: Preserve existing AutoPR eligibility and branch behavior

Priority: Must  
Complexity: High  
Risk: AutoPR branch/base behavior has had regressions that opened wrong or stale PRs.

Changing title/body MUST NOT change final AutoPR eligibility, base branch resolution, head branch resolution, ahead check, push behavior, PR association, or no-op semantics.

- AC-004-1: Given a head branch with no commits beyond the recorded base branch, when final AutoPR runs with task metadata, then it still returns `:noop` and does not call `gh pr create`.
- AC-004-2: Given a head branch with commits beyond the recorded base branch, when final AutoPR runs with task metadata, then it still pushes the head branch before creating or reusing a PR according to existing final AutoPR behavior.
- AC-004-3: Given base branch resolution fails, when final AutoPR runs with task metadata, then the failure remains a typed AutoPR base-branch error and no title/body fallback masks it.

### REQ-005: Define safe fallback behavior for missing metadata

Priority: Must  
Complexity: Medium  
Risk: Silent fallback can create a plausible but wrong PR.

AutoPR MUST define explicit behavior for absent or blank task title/description rather than accidentally producing partial metadata. For task-backed runs, blank or non-string task title/description is invalid and MUST fail with a typed validation error. For runs with no Task aggregate, existing generated AutoPR title/body fallback remains unchanged for backward compatibility.

- AC-005-1: Given a task-backed run has an absent, non-string, or blank `Task.title`, when final AutoPR would create a PR, then finalization fails with a typed metadata validation error and does not call `gh pr create`.
- AC-005-2: Given a task-backed run has an absent, non-string, or blank `Task.description`, when final AutoPR would create a PR, then finalization fails with a typed metadata validation error and logs enough context for an operator to diagnose without exposing sensitive body text.

### 6b. Boundary preservation

### REQ-006: Keep final AutoPR separate from phase PR behavior

Priority: Must  
Complexity: Medium  
Risk: Mixing final and phase PR concerns can duplicate PRs or corrupt run-level `pr_url` semantics.

The implementation MUST affect final run AutoPR only.

- AC-006-1: Given a run has `PhasePR` records with created/existing status, when finalization runs, then final AutoPR is still skipped exactly as today.
- AC-006-2: Given a workflow has no phase PR records, when final AutoPR creates a PR, then the final PR uses task title/body while the run-level `PrAssociated` behavior stays unchanged.

### REQ-007: Verify with a real Task aggregate and AutoPR call

Priority: Must  
Complexity: High  
Risk: Unit-only coverage can miss the run-state projection path from Task aggregate to executor.

The change MUST be tested through a real Task aggregate path plus an AutoPR call boundary.

- AC-007-1: Given a Task aggregate is created/approved with title and description, when a run reaches final AutoPR, then the AutoPR context receives that title and description from run state.
- AC-007-2: Given the test intercepts the PR creation boundary, when the PR would be created, then the captured `gh pr create` title/body arguments match the Task aggregate metadata.
- AC-007-3: Given the task metadata test runs, when local Postgres or external GitHub is unavailable, then the test strategy uses deterministic in-process or no-network seams and does not depend on a live GitHub API.

### REQ-008: Cover AutoPR title/body composition with focused tests

Priority: Must  
Complexity: Medium

`AutoPR` MUST have focused tests for title and body composition independent of full run execution.

- AC-008-1: Given an AutoPR context with task title/description, when title/body composition is exercised, then it returns those values in the PR command arguments.
- AC-008-2: Given task title/description contain newlines, Markdown, and shell-special characters, when AutoPR prepares the command, then values remain data arguments and are not shell-evaluated.
- AC-008-3: Given task metadata is absent, when AutoPR composition runs, then the explicit fallback/failure policy from REQ-005 is covered.

### REQ-009: Preserve typed boundary and loud failure conventions

Priority: Must  
Complexity: Medium  
Risk: Bare maps and permissive fallback conflict with AGENTS.md typed-boundary rules.

The metadata addition MUST use typed or explicitly validated boundaries and total result handling.

- AC-009-1: Given AutoPR receives a context with malformed task metadata, when `maybe_create_pr/1` validates it, then it returns a typed error or raises at the validated boundary; it does not silently compose a PR from malformed values.
- AC-009-2: Given context extraction sees unknown task keys, when building AutoPR context, then only known task metadata fields are used and unknowns are ignored.
- AC-009-3: Given a new AutoPR error variant is added, when `RunExecutor.finalize_run/1` handles AutoPR results, then the handling remains total and does not report success for an unmatched error shape.

### 6c. Operational and documentation expectations

### REQ-010: Preserve Foreman commit/operator expectations

Priority: Should  
Complexity: Low

Implementation work MUST preserve repo operator conventions for Foreman-authored commits.

- AC-010-1: Given implementation work commits changes, when Foreman commits them, then commits use the fixed Foreman message, Foreman author identity, and `--no-verify` per `AGENTS.md` policy.
- AC-010-2: Given tests or docs describe commit behavior, when reviewed, then they do not imply user-authored commits or hook execution that Foreman does not perform.

### REQ-011: Update user-facing docs only where behavior changes

Priority: Should  
Complexity: Medium

Documentation MUST reflect the new final AutoPR title/body behavior where users or operators would expect it.

- AC-011-1: Given README, `docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`, and `AGENTS.md` are reviewed, when behavior-facing AutoPR docs exist, then they are updated surgically to describe task title/body PRs.
- AC-011-2: Given no repository-level agent policy changes are made, when `AGENTS.md` is reviewed, then it is left unchanged with that decision noted in implementation output.

### REQ-012: Avoid leaking sensitive task content into logs

Priority: Should  
Complexity: Medium  
Risk: Task descriptions can contain operator context not intended for logs.

AutoPR logging MUST not dump full task descriptions while preparing or invoking PR creation.

- AC-012-1: Given a Task description contains sensitive-looking text, when AutoPR logs start/success/failure metadata, then logs include identifiers and outcome metadata but not the full description body.
- AC-012-2: Given `gh pr create` fails, when AutoPR reports the failure, then command output is handled according to existing sanitization expectations and does not add a new log line containing the raw task body.

## 7. Dependency Map

| Requirement | Depends On | Notes |
|---|---|---|
| REQ-001 | — | Base plumbing requirement. |
| REQ-002 | REQ-001, REQ-005 | Title policy needs metadata and fallback decision. |
| REQ-003 | REQ-001, REQ-005 | Body policy needs metadata and fallback decision. |
| REQ-004 | REQ-001 | Branch behavior must remain unchanged while context grows. |
| REQ-005 | REQ-001 | Fallback applies to extracted metadata. |
| REQ-006 | REQ-002, REQ-003, REQ-004 | Ensures final-only scope. |
| REQ-007 | REQ-001, REQ-002, REQ-003 | Integration proof. |
| REQ-008 | REQ-002, REQ-003, REQ-005 | Focused composition proof. |
| REQ-009 | REQ-001, REQ-005 | Boundary correctness. |
| REQ-010 | — | Operator process constraint. |
| REQ-011 | REQ-002, REQ-003, REQ-006 | Docs after behavior is clear. |
| REQ-012 | REQ-003 | Body handling and logs. |

Implementation clusters:

1. Metadata extraction and AutoPR context contract: REQ-001, REQ-005, REQ-009.
2. Title/body composition: REQ-002, REQ-003, REQ-008, REQ-012.
3. Executor integration and final-only behavior: REQ-004, REQ-006, REQ-007.
4. Documentation/process: REQ-010, REQ-011.

No circular dependencies identified.

## 8. Technical Dependency Mapping

| Component | Interaction | Data flow | Requirement impact |
|---|---|---|---|
| Task aggregate/projection | Source of task metadata | `Task.title`, `Task.description` into run state | REQ-001, REQ-007 |
| `RunExecutor` | Builds AutoPR context at finalization | run state/task metadata → AutoPR context | REQ-001, REQ-004, REQ-006 |
| `AutoPR` | Composes and invokes `gh pr create` | context → `--title`, `--body` args | REQ-002, REQ-003, REQ-008 |
| Git/GitHub CLI | External PR creation boundary | branch/base/title/body args | REQ-004, REQ-012 |
| `PrAssociate`/ProjectionStore | Records final run PR URL | PR URL → run read model | REQ-006 |
| Docs | Operator-facing behavior | final AutoPR expectations | REQ-011 |

## 9. Adversarial Self-Review

1. **Issue:** Existing generated body includes run artifact and unresolved review findings; replacing it with task description could hide useful review data.
   **Resolution:** Resolved to exact Task description body for task-backed runs. Artifact files remain the source for run artifacts/findings unless a later requirement adds append behavior.

2. **Issue:** The task description says "phase prefix override? TBD", so exact title composition was unclear.
   **Resolution:** Resolved to exact `Task.title` for final AutoPR. No phase/workflow/run/provider prefix is added.

3. **Issue:** Missing title/description fallback can produce plausible wrong PRs.
   **Resolution:** Resolved to typed validation failure for task-backed runs with blank/invalid title or description, while preserving legacy generated fallback only when no Task aggregate exists.

4. **Issue:** Integration test could accidentally depend on live GitHub or local Postgres credentials.  
   **Resolution:** Added REQ-007 no-network deterministic seam requirement.

5. **Issue:** Task description may contain sensitive details and fail logs might expose it.  
   **Resolution:** Added REQ-012 to prevent full body logging.

6. **Issue:** Prior PRD/TRD artifacts named in the task are absent from this worktree.  
   **Resolution:** Treat them as external investigation artifacts only; do not ship docs without implementation.

7. **Issue:** PhasePR and final AutoPR bugs are easy to conflate.  
   **Resolution:** Scope and REQ-006 explicitly exclude PhasePR title/push behavior.

All safe resolutions auto-applied under Foreman mode.

Ambiguity scan complete: 0 items remain marked for clarification.

## 10. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 4.7 | Covers metadata plumbing, exact composition, explicit fallback/error policy, phase separation, tests, docs, and logging. |
| Testability | 4.7 | Every Must/Should requirement has measurable ACs; exact title/body and fallback/error policies are testable without external GitHub. |
| Clarity | 4.8 | Prior ambiguity markers are resolved: exact title, exact body, no appended artifacts/findings, typed failure for blank task metadata, legacy fallback only for no-task runs. |
| Feasibility | 4.6 | Builds on existing `RunExecutor` task metadata extraction and AutoPR context with a narrow validation/composition change. |

Overall readiness score: **4.7**
Gate decision: **PASS**

## 11. Suggested Next Step

Create a TRD from this PRD:

```sh
/ensemble-create-trd docs/PRD/PRD-2026-81f29bf4-autopr-task-title-body.md
```


## 12. Changelog

### 2026-09-18 — v1.0.1

- Resolved six Foreman-mode clarification markers.
- Defined final AutoPR title as exact `Task.title` for task-backed runs.
- Defined final AutoPR body as exact `Task.description` for task-backed runs, with no generated run/artifact/finding appendix.
- Defined fallback/error policy: task-backed blank or invalid title/description fails with a typed validation error; no-task runs keep the existing generated AutoPR fallback.
- Re-scored Implementation Readiness Gate from 4.3 to 4.7.
