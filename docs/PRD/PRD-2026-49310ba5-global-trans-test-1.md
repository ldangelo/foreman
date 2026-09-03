---
document_id: PRD-2026-49310ba5
label: prd-global-trans-test-1
version: 1.0.0
status: Draft
date: 2026-09-03
scale_depth: STANDARD
author: Foreman ensemble-create-prd
foreman_task_title: Global trans test 1
total_requirements: 12
readiness_score: 4.00
readiness_gate: PASS
---

# PRD: Global trans test 1

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
| Risk flags | 5 |
| Dependencies | 11 |
| Open ambiguity markers | 5 |
| External dependencies | 1 |

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Prove same database paths serialize through `:global.trans` | Must | High | 3 |
| REQ-002 | Scope the lock key to the Beads database path | Must | Medium | 2 |
| REQ-003 | Preserve no-database-path command behavior | Must | Medium | 2 |
| REQ-004 | Use a deterministic concurrency harness | Must | High | 3 |
| REQ-005 | Assert lock lifetime covers the whole `br` invocation | Must | High | 2 |
| REQ-006 | Fail if the backstop is bypassed or removed | Must | Medium | 2 |
| REQ-007 | Avoid real Beads database mutation in the test | Must | Low | 2 |
| REQ-008 | Keep the test local and CI-safe | Must | Medium | 2 |
| REQ-009 | Locate coverage at the correct boundary | Must | Medium | 2 |
| REQ-010 | Document the test's concurrency contract in code comments | Should | Low | 1 |
| REQ-011 | Preserve existing task-provider behavior while adding coverage | Should | Medium | 2 |
| REQ-012 | Expose actionable failure output | Should | Low | 1 |

## Problem Statement

Foreman shells out to `br` for Beads operations. Concurrent `br` writes against the
same Beads SQLite database can corrupt state or produce intermittent lock errors,
so `ForemanServer.TaskProviders.SystemBrRunner` uses `:global.trans/2` as a
per-database serialization backstop around each `br` invocation.

The requested product slice is test coverage for `:global.trans` locking. The PRD
therefore defines maintainability and regression requirements for a test that
proves concurrent `br` calls using the same database path cannot execute their
critical sections at the same time. [NEEDS CLARIFICATION: Is `SystemBrRunner` the
intended locking surface, or should the PRD instead target another `:global.trans`
caller if one is added?]

Primary users are Foreman maintainers and CI. Success means a future edit that
removes, narrows, or accidentally bypasses the `:global.trans` backstop fails a
focused automated test before the change lands.

## Foreman Mode Notes

This PRD was generated under `--foreman`. Clarifying interviews were skipped by
contract. Sparse task input was resolved with best-effort assumptions, and
remaining uncertainty is marked inline with `[NEEDS CLARIFICATION: ...]`.

## Goals

- Add or preserve automated proof that `:global.trans` serializes `br` calls by
  `database_path`.
- Make the test deterministic enough for CI.
- Keep the test independent of real Beads data and external services.
- Fail loudly with enough evidence to diagnose lock regressions.

## Non-Goals

- Changing `SystemBrRunner` production locking behavior.
- Changing Beads schema, database layout, or reconciliation semantics.
- Adding distributed-node lock tests across multiple BEAM nodes.
- Replacing `:global.trans` with another lock implementation.
- Implementing new user-facing CLI behavior.

## Research and Context

### Existing codebase

Foreman is a mixed Go/Elixir system:

- `packages/foreman_server/` — Elixir/Phoenix backend, event store,
  projections, workflow execution, and Beads task-provider integration.
- `packages/foreman_cli/` — Go CLI.
- `packages/jido_harness/` — Elixir harness integration.

Relevant source surfaces observed during reconnaissance:

- `packages/foreman_server/lib/foreman_server/task_providers/system_br_runner.ex`
  is documented as the sole `System.cmd("br", ...)` site and wraps `br` execution
  in `with_database_lock/2`.
- `with_database_lock/2` uses lock key `{:br_db_lock, database_path}` when
  `database_path` is a non-empty binary, and bypasses locking when no database
  path is present.
- `packages/foreman_server/test/foreman_server/task_providers/system_br_runner_test.exs`
  already contains task-provider tests and is the natural home for focused
  backstop coverage.

### Prior product docs and cross-cutting requirements

Recent PRDs establish these repo conventions:

- Requirements use `REQ-NNN` headings with MoSCoW priority, complexity, and
  Given/When/Then ACs.
- Foreman work should fail loudly rather than silently reporting success.
- Boundary normalization should happen once, with downstream code reading the
  normalized shape.
- Living docs are updated only when implemented operator behavior changes. This
  PRD is test-only, so no living-doc change is expected unless implementation
  changes maintainer workflow or troubleshooting expectations.

### External dependencies

| Dependency | Status | Impact |
|---|---|---|
| `br` executable path | Test-controlled fake expected | The test should use a fake executable on `PATH`, not the real Beads CLI. |

### Technical constraints

- The test must not depend on the checked-in root `./foreman` binary.
- The test should run under ordinary `mix test` in `packages/foreman_server`.
- Timing must be bounded to avoid wedging CI.
- The test must clean up environment mutation such as `PATH` changes.

## Assumptions

- A1 — The intended lock to test is `SystemBrRunner.with_database_lock/2`, because
  it is the observed production use of `:global.trans/2` for Beads DB writes.
- A2 — The desired proof is process-level serialization inside one BEAM node, not
  distributed Erlang multi-node behavior. [NEEDS CLARIFICATION: Should this PRD
  require a distributed-node `:global` test, or is single-node regression proof
  sufficient?]
- A3 — A fake `br` executable that records entry/exit and maximum concurrency is
  acceptable evidence.
- A4 — Wall-clock sleeps may be used only as bounded synchronization aids, not as
  the sole assertion mechanism. [NEEDS CLARIFICATION: Is adding test-only
  coordination hooks preferred over a fake executable with bounded sleeps?]
- A5 — This slice does not require new CLI/docs behavior.

## Requirements

### Feature Area: Locking Behavior Proof

### REQ-001: Prove same database paths serialize through `:global.trans`

**Priority:** Must · **Complexity:** High

When two `SystemBrRunner.cmd/3` calls run concurrently with the same non-empty
`database_path`, their fake `br` critical sections must not overlap. [RISK:
concurrency tests can pass accidentally if calls do not actually overlap during
setup.]

- AC-001-1: Given two concurrent calls with identical `database_path`, when both
  calls enter the runner, then observed maximum fake-`br` concurrency is exactly
  `1`.
- AC-001-2: Given the first call is still inside fake `br`, when the second call
  starts, then the second call does not enter fake `br` until the first call has
  left.
- AC-001-3: Given both calls finish successfully, when the test inspects ordering
  evidence, then it contains two starts and two finishes with no overlapping
  critical-section interval.

### REQ-002: Scope the lock key to the Beads database path

**Priority:** Must · **Complexity:** Medium

The test suite must prove the serialization contract is per database path, so the
lock key cannot collapse every project into one global bottleneck. [RISK: an
over-broad lock would hide corruption but reduce parallelism across independent
worktrees.]

- AC-002-1: Given concurrent calls using different non-empty `database_path`
  values, when both calls run, then the test allows their fake `br` executions to
  overlap.
- AC-002-2: Given two calls use the same `database_path`, when the test records
  lock IDs indirectly through behavior, then only same-path calls are serialized.

### REQ-003: Preserve no-database-path command behavior

**Priority:** Must · **Complexity:** Medium

Commands that do not carry a usable database path must keep their current behavior
and execute without trying to acquire a database-specific lock.

- AC-003-1: Given a command whose project config has no `database_path`, when the
  runner executes, then the command still runs rather than raising because the
  lock key is absent.
- AC-003-2: Given an empty-string `database_path`, when the runner executes, then
  behavior matches the existing no-lock path. [NEEDS CLARIFICATION: Should empty
  string remain an explicit no-lock value, or should it be rejected before this
  boundary?]

### Feature Area: Test Design

### REQ-004: Use a deterministic concurrency harness

**Priority:** Must · **Complexity:** High

The test must force both contenders to be live before assertions begin, reducing
flakiness from scheduler timing. [RISK: sleep-only tests can be green even if the
second process never contended for the lock.]

- AC-004-1: Given the test starts two runner calls, when the calls are launched,
  then the harness records that both caller processes attempted execution before
  completion assertions are made.
- AC-004-2: Given a caller process hangs or crashes, when the bounded wait expires,
  then the test fails with a timeout message naming the missing caller.
- AC-004-3: Given the scheduler runs processes in either order, when the test
  completes, then the assertion remains order-independent except for the required
  non-overlap invariant.

### REQ-005: Assert lock lifetime covers the whole `br` invocation

**Priority:** Must · **Complexity:** High

The lock must cover the whole port lifecycle, not only argument construction or
process start.

- AC-005-1: Given fake `br` blocks after startup, when another same-path call is
  launched, then the second fake `br` body does not begin until the first body
  exits.
- AC-005-2: Given fake `br` writes start and finish markers, when the test checks
  the log, then no `CALL` marker for a same-path second invocation appears before
  the first invocation's `DONE` marker.

### REQ-006: Fail if the backstop is bypassed or removed

**Priority:** Must · **Complexity:** Medium

The test must be sensitive to the actual production backstop and fail if an edit
moves command execution outside the `:global.trans` critical section.

- AC-006-1: Given `with_database_lock/2` is removed or made a no-op for non-empty
  `database_path`, when the test runs, then same-path max concurrency can exceed
  `1` and the test fails.
- AC-006-2: Given production code calls fake `br` before acquiring the lock, when
  same-path calls race, then ordering evidence exposes the overlap and the test
  fails.

### REQ-007: Avoid real Beads database mutation in the test

**Priority:** Must · **Complexity:** Low

The test must not create, update, or corrupt real project Beads data.

- AC-007-1: Given the test runs locally or in CI, when `br` is invoked, then it is
  a test-controlled fake executable placed earlier on `PATH`.
- AC-007-2: Given the test provides `database_path`, when the fake `br` runs, then
  no real `.beads/` database file is required.

### REQ-008: Keep the test local and CI-safe

**Priority:** Must · **Complexity:** Medium

The test must run with ordinary project test commands and must clean up process,
file, and environment state.

- AC-008-1: Given `mix test` runs for `packages/foreman_server`, when the locking
  test executes, then it needs no network, no GitHub CLI, and no external Beads
  installation.
- AC-008-2: Given the test mutates `PATH` or creates temp files, when the test
  exits successfully or fails, then original environment and temp state are
  restored or isolated by the test tmp directory.

### REQ-009: Locate coverage at the correct boundary

**Priority:** Must · **Complexity:** Medium

Coverage must exercise the public runner path that production uses, not a copied
private helper or synthetic lock wrapper.

- AC-009-1: Given the test calls the runner, when it executes, then the path under
  test includes `SystemBrRunner.cmd/3` and the production `with_database_lock/2`
  call.
- AC-009-2: Given the test needs observability, when adding helpers, then helpers
  observe fake external command behavior rather than duplicating lock logic.

### Feature Area: Maintainability and Diagnostics

### REQ-010: Document the test's concurrency contract in code comments

**Priority:** Should · **Complexity:** Low

The test should explain what failing evidence means so future maintainers do not
weaken it into a non-concurrent smoke test.

- AC-010-1: Given a maintainer reads the test, when they inspect comments and
  assertion messages, then they can identify the invariant: same database path
  must have max concurrency `1` across the full fake-`br` body.

### REQ-011: Preserve existing task-provider behavior while adding coverage

**Priority:** Should · **Complexity:** Medium

Adding the test must not require behavior changes to existing command argument
construction, timeout handling, telemetry, or temp-file cleanup.

- AC-011-1: Given the locking test is added, when the existing
  `SystemBrRunner` test suite runs, then previously covered success, timeout,
  temp-file, and command-shape behavior still passes.
- AC-011-2: Given the test uses a fake `br`, when it exits non-zero or times out
  in unrelated cases, then existing runner error behavior remains unchanged.

### REQ-012: Expose actionable failure output

**Priority:** Should · **Complexity:** Low

When the test fails, it should report enough state to distinguish overlapping
critical sections from a fake-command setup problem.

- AC-012-1: Given max concurrency is not `1`, when the assertion fails, then the
  failure message includes observed max concurrency and the recorded call log.

## Ambiguity Marking Pass

Ambiguity scan complete: 5 items marked for clarification.

## Dependency Map

| REQ | Depends On | Blocked By | Notes |
|---|---|---|---|
| REQ-001 | None | None | Core same-path serialization proof. |
| REQ-002 | REQ-001 | None | Extends proof to lock-key scope. |
| REQ-003 | REQ-001 | None | Covers existing no-lock branch. |
| REQ-004 | REQ-001 | None | Makes the concurrency proof credible. |
| REQ-005 | REQ-001, REQ-004 | None | Verifies lock duration. |
| REQ-006 | REQ-001, REQ-005 | None | Regression sensitivity. |
| REQ-007 | REQ-001 | None | Test isolation. |
| REQ-008 | REQ-004, REQ-007 | None | CI safety. |
| REQ-009 | REQ-001 | None | Ensures production boundary coverage. |
| REQ-010 | REQ-001, REQ-012 | None | Maintainer readability. |
| REQ-011 | REQ-001, REQ-008, REQ-009 | None | Non-regression around existing runner behavior. |
| REQ-012 | REQ-004, REQ-005 | None | Debuggability for failures. |

### Implementation clusters

- Cluster A: same-path serialization harness — REQ-001, REQ-004, REQ-005,
  REQ-006, REQ-012.
- Cluster B: scope and compatibility — REQ-002, REQ-003, REQ-011.
- Cluster C: test isolation and maintainability — REQ-007, REQ-008, REQ-009,
  REQ-010.

No circular dependencies identified.

## Adversarial Review

| Issue | Category | Recommended resolution | Foreman-mode disposition |
|---|---|---|---|
| Sparse task input could target an unknown `:global.trans` caller. | Ambiguity | Anchor to observed `SystemBrRunner` use and mark ambiguity. | Auto-applied with marker. |
| Concurrency tests can pass without real overlap. | Testability | Require both caller processes to attempt execution and assert max concurrency/log evidence. | Auto-applied in REQ-004/REQ-005. |
| Test could mutate real Beads DBs. | Missing edge case | Use fake `br` and temp dirs only. | Auto-applied in REQ-007. |
| Lock might accidentally serialize all DB paths. | Gap | Require distinct-path overlap proof. | Auto-applied in REQ-002. |
| Sleep-heavy tests can be flaky in CI. | Risk | Use bounded waits and evidence-based assertions; keep sleeps as fake workload only. | Auto-applied in REQ-004/REQ-008. |
| Failure output could be opaque. | Maintainability | Include observed max concurrency and call log in assertion output. | Auto-applied in REQ-012. |

## Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 4 | Covers same-path lock behavior, scope, no-path compatibility, isolation, and diagnostics. Sparse task input leaves one target-surface ambiguity. |
| Testability | 4 | Every Must/Should requirement has verifiable ACs; concurrency determinism still needs careful TRD design. |
| Clarity | 4 | Requirements point to concrete observed files and behavior, with ambiguity markers where subject input was under-specified. |
| Feasibility | 4 | Achievable with existing ExUnit/fake-executable patterns and no production behavior change. |

Overall score: 4.00 — PASS

Gate decision: PASS. Save PRD and proceed to TRD creation/refinement before any
implementation.

## Suggested Next Step

Run:

```bash
/ensemble-create-trd docs/PRD/PRD-2026-49310ba5-global-trans-test-1.md
```
