---
document_id: PRD-2026-fe2a98dc
label: prd-autopr-task-pr-summary
version: 1.0.1
status: Draft
date: 2026-09-18
scale_depth: STANDARD
total_requirements: 12
total_acceptance_criteria: 27
readiness_score: 4.8
---

# PRD: Include Task Context in AutoPR-Generated PR Summaries

Foreman task title read from `FOREMAN_TASK_TITLE`: **Include bead/task title and description in AutoPR-generated PR summary**

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
| Risk flags | 5 |
| Dependencies | 10 |
| Open ambiguity markers | 0 |

## Acceptance Criteria Summary

| Requirement | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Carry task summary fields into AutoPR context | Must | Medium | 3 |
| REQ-002 | Build PR title from task title when available | Must | Medium | 3 |
| REQ-003 | Add task context section to PR body | Must | Medium | 3 |
| REQ-004 | Preserve existing fallback PR output | Must | Medium | 2 |
| REQ-005 | Include task/bead traceability identifiers | Must | Medium | 2 |
| REQ-006 | Keep review-findings and artifact sections intact | Must | Low | 2 |
| REQ-007 | Avoid unsafe or malformed PR content | Must | Medium | 3 |
| REQ-008 | Verify through unit and integration-level tests | Must | Medium | 3 |
| REQ-009 | Verify one live Beads-backed AutoPR path | Must | High | 2 |
| REQ-010 | Document operator-visible PR summary behavior | Should | Low | 2 |
| REQ-011 | Keep AutoPR boundaries typed and explicit | Should | Medium | 1 |
| REQ-012 | Support ad-hoc/non-Beads-backed runs | Should | Low | 1 |

## 1. Executive Summary

Foreman AutoPR currently creates GitHub PRs whose title and body identify only the run id. That forces reviewers to leave GitHub and inspect Foreman/Beads state before they know what the run was supposed to accomplish.

This product changes AutoPR output so PR reviewers see the task or bead title, description, and traceability identifiers directly in the generated PR summary. The existing no-task fallback must remain valid and must preserve today's `feat(run): <run_id>` title/body shape for ad-hoc runs that have no task context.

Foreman mode auto-selected STANDARD depth. Clarifying interviews were skipped; refinement resolved the remaining product decisions with explicit default policies for PR title format, task traceability rendering, and task description bounds.

## 2. Background and Evidence

### 2.1 Product input

Requested product: include bead/task title and description in AutoPR-generated PR summary.

Problem evidence from source-checked input:

- `ForemanServer.Workflow.AutoPR.open_pr/5` composes PR title as `feat(run): #{run_id}`.
- The current PR body starts with `Foreman run `<run_id>` complete.` plus optional artifact path and CodeRabbit findings.
- `AutoPR.context()` contains `run_id`, `base_branch`, `artifact_path`, `head_branch`, and `cwd`, but no task title, description, or task id.
- `RunExecutor.auto_pr/1` builds the AutoPR context in `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` with `state.task` already in scope.
- `ForemanServer.Aggregates.Task.State` already carries `:title` and `:description`.
- Task projections can also carry provider-facing `external_id`/`external_link` fields for Beads traceability.
- Task ids can map to Beads ids such as `beads:foreman:foreman-w95o`, giving reviewers a path back to `br show <id>` when available.

### 2.2 Current codebase shape

Foreman is a multi-package repo. This PRD primarily affects:

- `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex` — final run PR creation via `gh pr create`.
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` — run finalization and AutoPR context construction.
- `packages/foreman_server/lib/foreman_server/aggregates/task.ex` and task projections — source of task title, description, and identifiers.
- `packages/foreman_server/test/foreman_server/workflow/auto_pr_test.exs` and related RunExecutor tests — regression coverage.
- Documentation surfaces (`README.md`, `docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`, `AGENTS.md`) if implementation changes operator-visible AutoPR behavior or maintainer expectations.

### 2.3 Product problem

AutoPR makes the GitHub PR the reviewer-facing artifact, but its title/body omit the human task subject. A reviewer opening the PR sees an opaque run id and maybe review findings, not the bead/task title, intended outcome, or task id. This slows review, hides the purpose of generated diffs, and weakens traceability from GitHub back to Foreman/Beads.

## 3. Personas

### 3.1 PR reviewer

Opens the generated GitHub PR and needs to understand the task goal before reviewing code or documents.

### 3.2 Foreman operator

Dispatches Beads-backed PRD/fix/implement workflows and expects AutoPRs to carry enough task context to triage and merge safely.

### 3.3 Foreman maintainer

Needs the change to respect typed boundaries, preserve ad-hoc fallback behavior, and avoid leaking unsafe content into GitHub PR bodies.

## 4. Scope

### In scope

- Passing task title, task description, and task identifiers from `RunExecutor` into AutoPR.
- Using a non-blank task title for AutoPR PR titles.
- Adding a task context section to the AutoPR body.
- Preserving artifact and CodeRabbit findings body content.
- Preserving current fallback output when no usable task context exists.
- Tests for title/body composition and RunExecutor context wiring.
- Live verification for one Beads-backed AutoPR run.
- Documentation updates for real operator-visible behavior.

### Out of scope

- Changing PhasePR behavior unless required to preserve consistency.
- Changing PR gate, PR monitor, or GitHub webhook behavior.
- Changing Beads task creation or task-provider semantics.
- Building a new UI for task metadata.
- Changing branch naming, commit detection, or base branch resolution.

## 5. Assumptions From Foreman Mode

- STANDARD PRD depth is sufficient.
- This is a Foreman server behavior change, not a CLI-only feature.
- `state.task.title` and `state.task.description` are the canonical in-process source at finalization time.
- Task id inclusion is required when a usable id exists; provider-facing Beads ids should be shown separately from Foreman's internal `task_id` when both are available.
- Ad-hoc work-submit style runs may not have meaningful title/description and must continue to create valid PRs.
- Task-backed PR titles should use `feat(task): <task title>` with deterministic truncation rather than a bare task title, preserving a conventional PR-title prefix.

## 6. Requirements

### 6a. Task Context Wiring

### REQ-001: Carry task summary fields into AutoPR context

Priority: Must  
Complexity: Medium  
Risk: Task metadata can silently disappear if context keys are informal or duplicated.

`RunExecutor` MUST pass task summary metadata into `AutoPR.maybe_create_pr/1` when available.

- AC-001-1: Given `state.task` has a non-blank title and description, when `RunExecutor.auto_pr/1` builds the AutoPR context, then the context includes task title and task description sourced from `state.task`.
- AC-001-2: Given `state.task` has a usable internal task id and/or provider-facing external id, when AutoPR context is built, then the context includes those identifiers as distinct optional typed fields for traceability.
- AC-001-3: Given any task field is nil, blank, or absent, when AutoPR context is built, then AutoPR receives nil/absent normalized values and does not crash.

### REQ-002: Build PR title from task title when available

Priority: Must  
Complexity: Medium  
Risk: Unbounded or malformed task titles can produce unusable GitHub PR titles.

AutoPR MUST use the task title as the primary PR title input when it is present and non-blank.

- AC-002-1: Given a task title `Include bead/task title and description in AutoPR-generated PR summary`, when AutoPR opens the PR, then the GitHub PR title is `feat(task): Include bead/task title and description in AutoPR-generated PR summary` instead of only `feat(run): <run_id>`.
- AC-002-2: Given the task title is nil, blank, or whitespace-only, when AutoPR opens the PR, then the title remains exactly `feat(run): <run_id>`.
- AC-002-3: Given a task title exceeds operator-friendly length, when AutoPR builds the title, then it emits `feat(task): <trimmed title>` capped at 120 visible characters total, truncating the title portion deterministically with a trailing ellipsis while preserving the `feat(task): ` prefix.

### REQ-003: Add task context section to PR body

Priority: Must  
Complexity: Medium

AutoPR MUST include a reviewer-readable task context section in the PR body when task metadata is available.

- AC-003-1: Given a task title exists, when AutoPR creates the body, then the body includes a `Task` or equivalent section containing the task title.
- AC-003-2: Given a task description exists, when AutoPR creates the body, then the body includes the task description in that section, preserving useful markdown/plain text.
- AC-003-3: Given both title and description are present, when a reviewer opens the PR, then the first screen of the body explains what the run was supposed to accomplish before any CodeRabbit findings section.

### REQ-004: Preserve existing fallback PR output

Priority: Must  
Complexity: Medium  
Risk: Ad-hoc runs can regress if the new path assumes Beads metadata always exists.

AutoPR MUST preserve current output for runs without usable task title or description.

- AC-004-1: Given no task title and no task description are available, when AutoPR creates a PR, then the title is exactly `feat(run): <run_id>`.
- AC-004-2: Given no task title and no task description are available, when AutoPR creates a PR body, then it remains exactly today's shape: `Foreman run `<run_id>` complete.` plus optional artifact and findings sections.

### REQ-005: Include task/bead traceability identifiers

Priority: Must  
Complexity: Medium

AutoPR MUST include usable task traceability in the PR body when available.

- AC-005-1: Given a task id exists, when AutoPR creates the PR body, then the task context section includes that id.
- AC-005-2: Given a provider-facing Beads id or Beads-style task id exists, when rendered, then the body includes both the plain id and a literal `br show <id>` command so reviewers can navigate back to the task.

### REQ-006: Keep review-findings and artifact sections intact

Priority: Must  
Complexity: Low

AutoPR MUST append task context without replacing existing artifact and review findings body behavior.

- AC-006-1: Given `artifact_path` is present, when AutoPR creates the body, then the existing `Artifact: <path>` line remains present.
- AC-006-2: Given `findings_section/1` returns CodeRabbit unresolved findings, when AutoPR creates the body, then those findings remain present and are not reordered in a way that hides the task summary.

### REQ-007: Avoid unsafe or malformed PR content

Priority: Must  
Complexity: Medium  
Risk: Task descriptions can contain long content, secrets, or markdown that renders poorly in GitHub.

AutoPR MUST normalize task metadata before injecting it into `gh pr create` arguments.

- AC-007-1: Given task title or description contains leading/trailing whitespace, when PR content is composed, then rendered fields are trimmed and blank fields are omitted.
- AC-007-2: Given task description exceeds 4,000 visible characters after trimming/redaction, when PR body is composed, then AutoPR includes only the first 4,000 visible characters followed by a clear truncation notice that points reviewers to the task id/Beads command for the full description.
- AC-007-3: Given task metadata contains obvious secrets or private tokens, when PR content is composed, then implementation uses Foreman's existing redaction boundary or an equivalent PR-body redaction path before invoking `gh`.

### 6b. Verification and Compatibility

### REQ-008: Verify through unit and integration-level tests

Priority: Must  
Complexity: Medium

The implementation MUST be pinned by tests that cover both new behavior and fallback behavior.

- AC-008-1: Given AutoPR receives context with task title/description/id, when body/title composition is tested without network calls, then the generated `gh pr create` arguments contain the expected title and body sections.
- AC-008-2: Given AutoPR receives context with no usable task fields, when the fallback test runs, then the generated title/body match current behavior exactly.
- AC-008-3: Given RunExecutor finalizes a run with `state.task` populated, when the AutoPR context is observed through a test seam, then task title, description, and id are passed to AutoPR.

### REQ-009: Verify one live Beads-backed AutoPR path

Priority: Must  
Complexity: High  
Risk: Unit-only verification can miss real `gh pr create` behavior or task-provider projection drift.

The implementation MUST be verified against one real Beads-backed AutoPR flow before acceptance.

- AC-009-1: Given a Beads-backed `prd`, `fix`, or `implement-trd*` run completes with commits, when AutoPR opens a real GitHub PR through `gh pr create`, then `gh pr view <number>` shows the task's actual title and description, not only `feat(run): <run_id>`.
- AC-009-2: Given an ad-hoc/no-title run path is exercised through a regression check, when AutoPR creates or composes PR output, then the PR title/body are valid and non-empty.

### REQ-010: Document operator-visible PR summary behavior

Priority: Should  
Complexity: Low

Documentation SHOULD describe the new AutoPR summary behavior where it changes operator expectations.

- AC-010-1: Given docs are reviewed, when implementation changes user/operator-visible PR output, then `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`, and `AGENTS.md` are updated only where real behavior or durable conventions changed.
- AC-010-2: Given no documentation file needs a content change, when implementation finishes, then the implementation report states the docs were considered and why no change was required.

### REQ-011: Keep AutoPR boundaries typed and explicit

Priority: Should  
Complexity: Medium

The change SHOULD maintain Foreman's typed-boundary conventions instead of relying on ad-hoc maps.

- AC-011-1: Given `AutoPR.context()` is updated, when Dialyzer/types/tests inspect the contract, then task title, description, and id fields are explicitly documented as optional typed fields, and unknown context keys are not required for behavior.

### REQ-012: Support ad-hoc/non-Beads-backed runs

Priority: Should  
Complexity: Low

The product SHOULD continue to support runs that have no backing Beads/task metadata.

- AC-012-1: Given a run was submitted without a task title/description, when AutoPR opens a PR, then reviewers still receive the current run-id-based summary and can review the diff.

## 7. Dependency Map

- REQ-002 depends on REQ-001.
- REQ-003 depends on REQ-001.
- REQ-004 depends on REQ-002 and REQ-003 preserving fallback branches.
- REQ-005 depends on REQ-001 exposing a usable task id.
- REQ-006 depends on REQ-003 composing body content additively.
- REQ-007 depends on REQ-002 and REQ-003 because title/body rendering must be safe.
- REQ-008 depends on REQ-001 through REQ-007.
- REQ-009 depends on REQ-008 and a working local GitHub/Beads environment.
- REQ-010 depends on final implementation behavior.
- REQ-011 supports REQ-001 and REQ-008.
- REQ-012 depends on REQ-004.

Recommended implementation clusters:

1. Context contract and RunExecutor wiring: REQ-001, REQ-011.
2. Title/body composition and fallback behavior: REQ-002, REQ-003, REQ-004, REQ-005, REQ-006, REQ-007, REQ-012.
3. Tests and live verification: REQ-008, REQ-009.
4. Documentation pass: REQ-010.

No circular dependencies identified.

## 8. Adversarial Review

Foreman mode auto-applied safe resolutions during refinement.

1. **Title format ambiguity.** Resolved: task-backed PRs use `feat(task): <task title>` and cap the full title at 120 visible characters with deterministic ellipsis truncation; no-task fallback remains exactly `feat(run): <run_id>`.
2. **Traceability format ambiguity.** Resolved: the PR body includes the plain task id and, for provider-facing Beads ids, a literal `br show <id>` command.
3. **Description length/safety ambiguity.** Resolved: task descriptions are trimmed/redacted and capped at 4,000 visible characters with a truncation notice pointing to the task id/Beads command for full context.
4. **Fallback regression risk.** Recommended resolution: make exact fallback title/body a Must requirement with tests.
5. **Findings block regression risk.** Recommended resolution: require task context to be additive and keep artifact/findings behavior intact.
6. **Unit-only verification gap.** Recommended resolution: require one live Beads-backed AutoPR verification with `gh pr view`.
7. **Documentation drift risk.** Recommended resolution: require explicit documentation consideration and updates where operator behavior changes.

Ambiguity scan complete: 0 items remain marked for clarification.

## 9. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 5 | Covers data flow, title/body behavior, fallback, traceability, safety, tests, live verification, and docs with resolved formatting/bounds policies. |
| Testability | 5 | Acceptance criteria include exact fallback checks, composition tests, RunExecutor wiring tests, deterministic truncation checks, and live PR verification. |
| Clarity | 5 | Remaining title, traceability, and description-bound decisions are explicit and testable. |
| Feasibility | 4 | Data already exists in `state.task`/task projections; change is localized to RunExecutor/AutoPR plus tests/docs. |
| Overall | 4.8 | READY; suitable for TRD creation/refinement. |

Gate decision: **READY — proceed to TRD creation**. The TRD should preserve the resolved title format, traceability rendering, and description bound policies.

## 10. Suggested Next Step

Run one of:

```bash
/ensemble-refine-prd docs/PRD/PRD-2026-fe2a98dc-autopr-task-pr-summary.md
/ensemble-create-trd docs/PRD/PRD-2026-fe2a98dc-autopr-task-pr-summary.md
```

## 11. Changelog

### 1.0.1 — 2026-09-18

- Resolved title format policy as `feat(task): <task title>` capped at 120 visible characters with fallback `feat(run): <run_id>` unchanged.
- Resolved traceability policy to include plain task ids plus `br show <id>` for provider-facing Beads ids.
- Resolved description rendering policy to trim/redact and cap task descriptions at 4,000 visible characters with a truncation notice.
- Updated PRD Health and readiness score from 4.3 to 4.8.

### 1.0.0 — 2026-09-18

- Initial Foreman-mode PRD created for AutoPR task title/description summaries.
- Added 12 requirements and 27 acceptance criteria.
- Marked 3 unresolved product decisions for refinement.
