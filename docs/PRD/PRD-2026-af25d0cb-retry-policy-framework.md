---
document_id: PRD-2026-af25d0cb
label: prd-retry-policy-framework
version: 1.0.0
status: Draft
date: 2026-09-18
scale_depth: STANDARD
total_requirements: 15
total_acceptance_criteria: 37
readiness_score: 4.4
readiness_gate: PASS
---

# PRD: Retry Policy Framework — Design Ratification and Implementation

Foreman task title read from `FOREMAN_TASK_TITLE`: **retry_policy framework: design ratification + implementation**

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 12 |
| Should | 3 |
| Could | 0 |
| Won't | 1 |

| Metric | Value |
|---|---:|
| Requirement coverage | 15/15 (100%) |
| Acceptance criteria coverage | 15/15 (100%) |
| Risk flags | 10 |
| Dependencies | 14 |
| Open ambiguity markers | 0 |
| TRD decisions required | 5 |

## Acceptance Criteria Summary

| Requirement | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Ratify or explicitly defer the five open retry-policy decisions | Must | Medium | 3 |
| REQ-002 | Split implementation work into four PR-sized beads | Must | Low | 2 |
| REQ-003 | Extend failure policy precedence with `:retryable` | Must | High | 3 |
| REQ-004 | Use a closed retryable-code whitelist | Must | Medium | 3 |
| REQ-005 | Re-dispatch the same phase with a fresh worker in the same worktree | Must | High | 3 |
| REQ-006 | Apply per-attempt timeout budgets | Must | Medium | 2 |
| REQ-007 | Use capped exponential backoff with jitter | Must | Medium | 2 |
| REQ-008 | Emit durable retry lifecycle events | Must | Medium | 2 |
| REQ-009 | Project retry attempts and exhausted state | Must | Medium | 2 |
| REQ-010 | Expose `FOREMAN_RETRY_ATTEMPT` to retried workers | Should | Low | 2 |
| REQ-011 | Preserve non-idempotent default safety | Must | High | 3 |
| REQ-012 | Retry PR creation/gate failures only when whitelisted | Must | High | 3 |
| REQ-013 | Notify operators without blocking retry execution | Should | Medium | 2 |
| REQ-014 | Document retry behavior and operator expectations | Should | Medium | 2 |
| REQ-015 | Cover all four implementation PRs with tests | Must | High | 3 |

## 1. Executive Summary

Foreman phases currently fail terminally for worker timeouts, PR failures, and retryable agent/API failures that could succeed on a second attempt. This PRD turns the ratified retry-policy design into implementation-ready product requirements: explicit design ratification first, then a four-PR implementation split covering policy, executor loop, visibility, and docs.

Foreman mode auto-selected STANDARD depth. Clarifying interviews were skipped; unresolved product decisions are represented as requirements that must be ratified or explicitly deferred before implementation begins.

## 2. Source Inputs and Evidence

Primary task input:

- Design proposal path: `docs/design/retry-policy.md`.
- Ratified decisions as of 2026-09-18:
  - Retry scope is per phase.
  - Retry means re-dispatch the same phase with a fresh worker in the same worktree.
  - Retryable failures are whitelist-based.
  - Initial whitelist: `:worker_timeout`, `:phase_pr_failed`, `:phase_pr_creation_failed`, `:api_error_retryable`, `:agent_error_retryable`.
  - Backoff formula: `base * 2^(n-1) + random(0..base)`, capped by `backoff_max_ms`.
  - Default `max_attempts` is 2.
- Open decisions still requiring ratification: `idempotent_default`, timeout model, default table size, phase-level integer override, and inbox dependency behavior.

Current codebase evidence:

- `packages/foreman_server/lib/foreman_server/agent_runtime/failure_policy.ex` owns runtime policy precedence and currently defaults `max_attempts` to 1 except fallback mode.
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` owns phase dispatch, worker timeout handling, PR phase failure handling, terminal dispatch, and phase timeout option wiring.
- `packages/foreman_server/lib/foreman_server/workflow/phase_spec.ex` is the canonical phase manifest normalization boundary and already whitelists known phase fields.
- `packages/foreman_server/lib/foreman_server/projection_store.ex` owns read-model projection for run/operator visibility.
- `packages/foreman_server/lib/foreman_server/aggregates/inbox_thread.ex` and the MCP inbox tooling provide the run-scoped notice pattern used by recent workflow progress work.
- `docs/design/retry-policy.md` was referenced by the task but was not present in this checkout during PRD creation; implementation must verify or restore that source before treating it as authoritative.

## 3. Personas

- **Foreman operator:** wants transient phase failures retried automatically without hiding permanent errors or duplicating unsafe work.
- **Workflow author:** needs manifest-level retry behavior that is understandable, bounded, and documented.
- **Foreman maintainer:** needs event-sourced retry state, typed failure handling, deterministic tests, and no silent key drift.
- **Dispatched worker/agent:** needs to know which attempt it is on so logs, artifacts, and recovery behavior can be attempt-aware.

## 4. Scope

In scope:

- Design ratification or explicit deferral for all five open decisions.
- Four implementation beads/PRs matching the design proposal:
  1. Foundation: failure policy, events, projection schema.
  2. Loop: executor retry loop, attempt env var, manifest schema.
  3. Visibility: inbox/Logger notice and interaction tests.
  4. Docs: operator docs and agent-context docs.
- Tests for each PR area.

Out of scope for v1:

- Phase-level integer retry override. This is a **Won't for v1** unless ratification changes scope before TRD.
- Retrying only part of a phase's agent transcript.
- Retrying in a different worktree.
- Recovering from permanent validation, schema, authorization, or operator-decision failures.
- Fixing underlying 30-minute ceiling root causes from prior runs; retry may absorb symptoms but does not replace root-cause work.

## 5. Assumptions From Foreman Mode

- `idempotent_default` ships as `false` unless ratification explicitly changes it.
- Timeout model ships as per-attempt: each attempt gets a fresh `timeout_minutes` budget.
- Default retryable table ships with the five supplied codes.
- Phase-level integer override remains out of scope for v1.
- Inbox delivery is best-effort; if `inbox.send` is unavailable, retry notices fall back to Logger and must not block retries.
- Existing event-sourced boundaries remain authoritative; projections must not be written directly.
- Existing documentation discipline applies: behavior changes require surgical docs updates.

## 6. Requirements

### REQ-001: Ratify or explicitly defer the five open retry-policy decisions

Priority: Must  
Complexity: Medium  
Risk: Implementation before ratification can encode the wrong safety posture.

Before implementation beads are approved, the workflow must record final decisions for `idempotent_default`, timeout model, default retryable table size, phase-level override scope, and inbox dependency behavior.

- AC-001-1: Given TRD work begins, when the open-decision section is reviewed, then each of the five decisions has a final state: ratified value or explicitly deferred with rationale.
- AC-001-2: Given a decision is deferred, when implementation scope is generated, then no code path depends on the deferred behavior.
- AC-001-3: Given a decision changes from the proposal default, when the TRD is written, then affected requirements and tests are updated before implementation starts.

### REQ-002: Split implementation work into four PR-sized beads

Priority: Must  
Complexity: Low

Implementation work must be split according to the design proposal's four PRs so review and rollback remain bounded.

- AC-002-1: Given implementation beads are created, when listed, then they map to Foundation, Loop, Visibility, and Docs.
- AC-002-2: Given a bead is scoped, when reviewed, then it contains only the tasks needed for its PR area and declares dependencies on prior beads where required.

### REQ-003: Extend failure policy precedence with `:retryable`

Priority: Must  
Complexity: High  
Risk: Policy precedence drift can silently make auto-retry either too aggressive or inert.

Foreman's failure policy resolution must represent retryability separately from fallback and timeout settings, using one normalized key convention at the boundary.

- AC-003-1: Given a per-call retryable setting is supplied, when policy resolves, then it overrides task config and built-in defaults.
- AC-003-2: Given task-type config supplies retryable behavior, when no per-call override exists, then task config wins over defaults.
- AC-003-3: Given no layer supplies retryable behavior, when policy resolves, then the ratified built-in default is applied without changing unrelated `fail_fast`, `fallback`, `max_attempts`, or `timeout_ms` behavior.

### REQ-004: Use a closed retryable-code whitelist

Priority: Must  
Complexity: Medium  
Risk: Retrying unknown errors can repeat destructive or invalid work.

Auto-retry eligibility must be driven by an explicit whitelist of failure codes, not a broad transient/permanent guess.

- AC-004-1: Given a failure code is one of `:worker_timeout`, `:phase_pr_failed`, `:phase_pr_creation_failed`, `:api_error_retryable`, or `:agent_error_retryable`, when the phase fails and retry policy permits retry, then the failure is eligible for retry.
- AC-004-2: Given a failure code is absent from the whitelist, when the phase fails, then Foreman treats it as non-retryable by default.
- AC-004-3: Given whitelist contents are configured, when unknown keys or malformed entries are supplied, then Foreman rejects or ignores them loudly according to existing typed-boundary conventions rather than minting arbitrary atoms.

### REQ-005: Re-dispatch the same phase with a fresh worker in the same worktree

Priority: Must  
Complexity: High  
Risk: Worktree reuse can preserve useful state but can also expose partial side effects.

A retry attempt must re-run the same phase definition, allocate a fresh worker, and preserve the same run worktree.

- AC-005-1: Given attempt 1 fails with a retryable code and attempts remain, when retry starts, then Foreman dispatches the same phase index/name again.
- AC-005-2: Given retry starts, when the worker is launched, then it is a fresh worker process/session and not a resumed crashed worker.
- AC-005-3: Given retry starts, when the phase executes, then it uses the same run worktree so prior checkout and partial file state are visible to the new attempt.

### REQ-006: Apply per-attempt timeout budgets

Priority: Must  
Complexity: Medium

Each attempt receives the phase's full ratified timeout budget instead of sharing a cumulative timer across all attempts.

- AC-006-1: Given `timeout_minutes` is nonzero, when attempt N starts, then the timeout clock starts fresh for that attempt.
- AC-006-2: Given attempt N times out, when attempts remain and the timeout code is retryable, then attempt N+1 is allowed its own full timeout budget.

### REQ-007: Use capped exponential backoff with jitter

Priority: Must  
Complexity: Medium

Retry attempts must be delayed using the ratified formula so transient infrastructure failures do not stampede.

- AC-007-1: Given retry attempt N is scheduled, when delay is computed, then delay equals `base * 2^(N-1) + random(0..base)`, capped at `backoff_max_ms`.
- AC-007-2: Given tests run, when the backoff function is exercised with deterministic randomness, then base, cap, and jitter bounds are verified without sleeping real wall-clock time.

### REQ-008: Emit durable retry lifecycle events

Priority: Must  
Complexity: Medium  
Risk: Invisible retries make run history hard to audit.

Foreman must append durable events when a phase retry is scheduled and when retry attempts are exhausted.

- AC-008-1: Given a retryable failure schedules another attempt, when the event stream is inspected, then a `PhaseRetrying` event records run id, phase id/name, failed attempt, next attempt, reason code, and delay.
- AC-008-2: Given a retryable failure exhausts attempts, when the event stream is inspected, then a `PhaseRetryExhausted` event records run id, phase id/name, final attempt count, and final reason code.

### REQ-009: Project retry attempts and exhausted state

Priority: Must  
Complexity: Medium

Run projections must expose retry attempt state so CLI/API views can explain what happened without replaying raw logs.

- AC-009-1: Given one or more retry lifecycle events exist, when the run projection is fetched, then phase state includes current attempt count and latest retry reason.
- AC-009-2: Given retries are exhausted, when the run projection is fetched, then the exhausted state is visible and distinct from a first-attempt terminal failure.

### REQ-010: Expose `FOREMAN_RETRY_ATTEMPT` to retried workers

Priority: Should  
Complexity: Low

Workers should receive an attempt number in their environment for logging and attempt-aware behavior.

- AC-010-1: Given attempt 1 runs, when the worker environment is built, then `FOREMAN_RETRY_ATTEMPT` is `1`.
- AC-010-2: Given attempt N runs after retry, when the worker environment is built, then `FOREMAN_RETRY_ATTEMPT` equals N and is consistent with projected attempt state.

### REQ-011: Preserve non-idempotent default safety

Priority: Must  
Complexity: High  
Risk: Retrying non-idempotent phases can duplicate external side effects.

The conservative default is non-idempotent unless ratification explicitly changes it. Auto-retry must not silently assume arbitrary phases are safe to repeat.

- AC-011-1: Given no manifest/config value marks retry idempotency, when retry policy resolves, then the ratified default `false` prevents unsafe auto-retry paths.
- AC-011-2: Given a phase is marked retryable/idempotent by approved schema, when it fails with a whitelisted code and attempts remain, then auto-retry may proceed.
- AC-011-3: Given a phase is not retry-safe, when it fails with a whitelisted code, then Foreman fails loudly and reports why retry did not occur.

### REQ-012: Retry PR creation/gate failures only when whitelisted

Priority: Must  
Complexity: High  
Risk: Retrying PR operations can create duplicate branches, duplicate PRs, or confusing gate state.

PR-related retry behavior must be limited to ratified whitelisted codes and must preserve existing PR/branch idempotency safeguards.

- AC-012-1: Given PR creation fails with `:phase_pr_creation_failed`, when retry policy permits retry, then the same phase is retried without creating duplicate unreconciled PR state.
- AC-012-2: Given PR gate fails with `:phase_pr_failed`, when retry policy permits retry, then retry behavior is recorded and existing PR gate failure context is preserved.
- AC-012-3: Given PR failure reason is not whitelisted, when the phase fails, then no retry occurs and the original failure reason remains visible.

### REQ-013: Notify operators without blocking retry execution

Priority: Should  
Complexity: Medium

Retry scheduling and exhaustion should produce operator-readable notices, but notice delivery must not become a new failure source.

- AC-013-1: Given inbox write support is available, when a retry is scheduled or exhausted, then Foreman sends a concise run-scoped inbox notice.
- AC-013-2: Given inbox write support is unavailable or fails, when a retry notice is needed, then Foreman logs the notice through Logger and retry execution continues.

### REQ-014: Document retry behavior and operator expectations

Priority: Should  
Complexity: Medium

Operator-facing docs must explain retry defaults, safety, configuration, and visibility.

- AC-014-1: Given implementation changes behavior, when docs are updated, then `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`, and `AGENTS.md` are reviewed and surgically updated or explicitly left unchanged with rationale.
- AC-014-2: Given CLI/manifest syntax changes, when docs are checked, then examples match source behavior verified from Go/Elixir source or a fresh build, not a stale root binary.

### REQ-015: Cover all four implementation PRs with tests

Priority: Must  
Complexity: High  
Risk: Retry behavior is timing- and state-sensitive, making superficial tests misleading.

Tests must cover policy resolution, executor retry loop behavior, projection/visibility, and documentation-sensitive manifest behavior.

- AC-015-1: Given Foundation work is implemented, when tests run, then policy precedence, event encoding, and projection schema changes are covered.
- AC-015-2: Given Loop work is implemented, when tests run, then the executor retries a real phase failure using deterministic timing and attempt counts.
- AC-015-3: Given Visibility and Docs work are implemented, when tests/checks run, then inbox/Logger fallback and doc references are covered without relying on live external services.

## 7. Dependency Map

| Requirement | Depends On | Notes |
|---|---|---|
| REQ-001 | None | Ratification gates implementation. |
| REQ-002 | REQ-001 | Beads must reflect final decisions. |
| REQ-003 | REQ-001 | Policy default depends on ratification. |
| REQ-004 | REQ-001, REQ-003 | Whitelist size is an open decision. |
| REQ-005 | REQ-003, REQ-004 | Executor needs resolved retry eligibility. |
| REQ-006 | REQ-001, REQ-005 | Timeout model must be ratified. |
| REQ-007 | REQ-005 | Backoff wraps retry scheduling. |
| REQ-008 | REQ-005, REQ-007 | Events emitted during scheduling/exhaustion. |
| REQ-009 | REQ-008 | Projection consumes events. |
| REQ-010 | REQ-005 | Attempt value comes from retry loop. |
| REQ-011 | REQ-001, REQ-003 | Safety default gates retry. |
| REQ-012 | REQ-004, REQ-005, REQ-011 | PR retries need whitelist + safety. |
| REQ-013 | REQ-008, REQ-009 | Notices consume lifecycle state. |
| REQ-014 | REQ-003 through REQ-013 | Docs describe implemented behavior. |
| REQ-015 | REQ-002 through REQ-014 | Test matrix spans all PRs. |

No circular dependencies identified.

## 8. Adversarial Self-Review

| Issue | Resolution |
|---|---|
| Open decisions could block implementation. | Converted them into REQ-001 with explicit ratify/defer ACs. Auto-applied under foreman mode. |
| Retrying same worktree can duplicate side effects. | Added REQ-011 requiring conservative idempotency default and loud skip behavior. Auto-applied under foreman mode. |
| PR retry semantics are especially risky. | Added REQ-012 with duplicate-state safeguards. Auto-applied under foreman mode. |
| Referenced design doc is absent from this checkout. | Recorded evidence gap and required implementation to verify/restore it before treating it as authoritative. Auto-applied under foreman mode. |
| Existing FailureClassifier has a broad transient list that may conflict with whitelist behavior. | Required a closed whitelist in REQ-004. Auto-applied under foreman mode. |
| Wall-clock backoff tests can be slow/flaky. | Required deterministic timing tests in REQ-007 and REQ-015. Auto-applied under foreman mode. |

## 9. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 4.4 | Covers ratification, all four PR areas, tests, and docs. |
| Testability | 4.5 | Every requirement has measurable ACs; deterministic timing called out. |
| Clarity | 4.2 | Open decisions are isolated in REQ-001; behavior defaults are documented as assumptions. |
| Feasibility | 4.4 | Uses existing policy, executor, projection, inbox, and docs boundaries. |

Overall score: **4.4 PASS**

Concerns:

- `docs/design/retry-policy.md` was not present in this checkout, so TRD authors must verify the design artifact before relying on details not included in the task description.
- `idempotent_default` is safety-critical; if ratification changes it to permissive, REQ-011 and tests must be revised before implementation.

Gate decision: **PASS**. Save PRD and proceed to TRD only after REQ-001 is satisfied.

## 10. Suggested Next Step

`/ensemble-create-trd docs/PRD/PRD-2026-af25d0cb-retry-policy-framework.md`
