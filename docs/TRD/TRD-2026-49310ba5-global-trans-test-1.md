---
document_id: TRD-2026-49310ba5
label: trd-global-trans-test-1
version: 1.0.0
status: Draft
date: 2026-09-03
prd_reference: PRD-2026-49310ba5
prd_label: prd-global-trans-test-1
scale_depth: STANDARD
total_requirements: 12
total_acceptance_criteria: 24
design_readiness_score: 4.5
readiness_score: 4.5
kind: trd
---

# TRD: Global trans test 1

## 1. Executive Summary

This TRD turns PRD `PRD-2026-49310ba5` into a test-only implementation plan for proving `ForemanServer.TaskProviders.SystemBrRunner` serializes same-Beads-database `br` invocations through its `:global.trans/2` backstop. No production behavior, CLI behavior, Beads schema, or operator workflow changes are planned.

Scope is brownfield and localized to `packages/foreman_server/test/foreman_server/task_providers/system_br_runner_test.exs` plus, if needed, small test-support helpers in that same test file. The production surface under test is `packages/foreman_server/lib/foreman_server/task_providers/system_br_runner.ex`, specifically `SystemBrRunner.cmd/3` entering `with_database_lock/2` before opening the `br` port.

The current codebase already contains an initial same-path concurrency test. This TRD plans to harden it into the PRD contract: deterministic contender readiness, fake `br` evidence, same-path non-overlap, different-path allowed overlap, no/empty database-path compatibility, actionable assertion output, and code comments explaining the lock invariant.

## Reused Capabilities

No foundational TRD capabilities were registered by `trd-graph-cli capabilities docs/TRD --json`. `trd-graph-cli overlap docs/TRD` reported no overlapping target files. Existing repo test helpers and fake-`br` patterns are reused in-place, not duplicated as foundational capabilities.

## 2. Architecture Decision

### 2.1 Alternatives Considered

#### Option A — Minimal same-path smoke test

Keep one ExUnit test that launches two processes with the same `database_path`, uses a fake `br`, sleeps briefly, and asserts max concurrency is `1`.

- **Pros:** smallest diff; preserves current test shape.
- **Cons:** insufficient PRD coverage; does not prove contenders were live, different DB paths can overlap, empty/no path bypasses lock, or failures include enough ordering evidence.
- **Risk:** Medium-high flake/false-green risk.

#### Option B — Dedicated test harness module

Add a reusable helper module under `test/support/` that owns fake executable creation, event logging, bounded waits, and concurrency assertions.

- **Pros:** reusable for future provider runner tests; clearer isolation if more locking tests are added.
- **Cons:** overbuild for one test-only slice; broader compile/support surface; more maintenance than PRD needs.
- **Risk:** Medium scope creep risk.

#### Option C — In-file deterministic ExUnit harness (chosen)

Strengthen `SystemBrRunnerTest` with local helpers: temp-dir fake `br`, file-backed event log/counter, explicit parent messages before runner entry, bounded `assert_receive` waits, and assertion helpers that print max concurrency plus ordered event log.

- **Pros:** best fit for existing codebase; surgical; exercises production `cmd/3`; avoids production test hooks; local and CI-safe.
- **Cons:** shell/file coordination needs careful cleanup and bounded waits.
- **Risk:** Low if assertions rely on evidence instead of sleeps alone.

Foreman mode: auto-selected Option C (in-file deterministic ExUnit harness for existing `SystemBrRunnerTest`).

### 2.2 System Architecture

#### Components and responsibilities

| Component | Path | Responsibility |
|---|---|---|
| `SystemBrRunner.cmd/3` | `packages/foreman_server/lib/foreman_server/task_providers/system_br_runner.ex` | Production entry point under test; builds argv, enters `with_database_lock/2`, opens the fake `br` port, waits for completion, returns existing result envelope. |
| `with_database_lock/2` | same file | Existing private backstop using lock key `{:br_db_lock, database_path}` for non-empty binaries; bypasses when database path is absent or empty. |
| Fake `br` executable | test temp dir | Test-controlled executable placed first on `PATH`; records `CALL`, `ENTER`, `DONE`, and counter state without touching real Beads data. |
| ExUnit concurrency harness | `system_br_runner_test.exs` | Starts contender tasks/processes, records caller-attempt messages, enforces bounded waits, and checks ordering/max-concurrency evidence. |
| Assertion helpers | `system_br_runner_test.exs` | Parse event logs, compute max concurrency, assert same-path non-overlap and different-path overlap, and emit diagnostic failure text. |

#### Data flow

```text
ExUnit test
  -> writes fake br + temp evidence files
  -> prepends temp dir to PATH
  -> starts concurrent SystemBrRunner.cmd/3 calls
  -> SystemBrRunner.cmd/3 reads project_config.database_path
  -> with_database_lock/2 chooses lock key or no-lock branch
  -> Port opens fake br
  -> fake br appends event/counter evidence
  -> cmd/3 returns {:ok | :error, result}
  -> test parses evidence and asserts invariants
  -> on_exit restores PATH and removes temp dir
```

#### Integration points

- `PATH`: test-only mutation scoped by `setup`/`on_exit`; fake executable shadows real `br`.
- File system: temp-dir-only evidence files (`events.log`, `counter`, `max`, optional gate files). No `.beads/` DB file required.
- BEAM concurrency: ExUnit tasks/processes and `:global.trans/2` in one BEAM node. Distributed Erlang is out of scope.
- Shell/port: existing `SystemBrRunner` port lifecycle remains unchanged; test observes external-command behavior.

#### Technology choices

| Choice | Decision | Rationale |
|---|---|---|
| Test framework | ExUnit, `async: false` | Existing runner tests mutate `PATH`; serial test module avoids env races. |
| Fake command | POSIX shell script named `br` | Exercises production shell/port path without Beads dependency. |
| Coordination evidence | Temp files + parent process messages | Avoids production hooks and supports actionable failure output. |
| Wait strategy | Bounded `assert_receive` / helper timeouts | CI-safe; failures name missing caller/evidence. |
| Scope | In-place test hardening | No operator behavior change, no docs update beyond TRD. |

#### Architecture diagram description

A single ExUnit module owns the temp environment. It creates a fake `br` executable and evidence files, then spawns concurrent callers into `SystemBrRunner.cmd/3`. Each caller goes through production argv construction and `with_database_lock/2` before the port starts fake `br`. The fake executable records critical-section entry/exit. Assertions flow back from evidence files to ExUnit, proving whether same database paths serialize and different paths remain independent.

## Master Task List

### PR 1: Deterministic same-path serialization proof

**Shippable State:** Maintainers running `mix test` get a focused failure if two same-database `SystemBrRunner.cmd/3` calls overlap inside fake `br`.

- [ ] **TRD-001** Build a deterministic fake-`br` evidence harness in `system_br_runner_test.exs` (4h) [satisfies REQ-004] [satisfies REQ-007] [satisfies REQ-008] [satisfies REQ-009]
  - **Validates PRD ACs:** AC-004-1, AC-004-2, AC-004-3, AC-007-1, AC-007-2, AC-008-1, AC-008-2, AC-009-1, AC-009-2
  - **Implementation AC checklist:**
    - Given two callers are launched, when each reaches the runner call site, then the parent process receives an attempted-execution marker before final assertions.
    - Given a caller or fake `br` hangs, when the bounded wait expires, then the failure names the missing marker/evidence file.
    - Given the fake `br` runs, when evidence is written, then all files live under the ExUnit temp dir and `PATH` is restored in `on_exit`/`after` cleanup.

- [ ] **TRD-001-TEST** Add harness self-check coverage for bounded waits and fake-`br` evidence shape (2h) [verifies TRD-001] [satisfies REQ-004] [satisfies REQ-007] [satisfies REQ-008] [satisfies REQ-009] [depends: TRD-001]
  - **Validates PRD ACs:** AC-004-1, AC-004-2, AC-007-1, AC-008-2, AC-009-2
  - **Implementation AC checklist:**
    - Given the fake `br` emits events, when helper parsing runs, then two successful invocations produce parseable start/finish evidence.
    - Given required evidence is absent, when helper waits expire, then ExUnit reports the missing caller or evidence name.

- [ ] **TRD-002** Replace or harden the existing same-path concurrency test so it asserts max concurrency `1` and no overlapping intervals across the full fake-`br` body (4h) [satisfies REQ-001] [satisfies REQ-005] [satisfies REQ-006] [satisfies REQ-009] [satisfies REQ-012] [depends: TRD-001]
  - **Validates PRD ACs:** AC-001-1, AC-001-2, AC-001-3, AC-005-1, AC-005-2, AC-006-1, AC-006-2, AC-009-1, AC-009-2, AC-012-1
  - **Implementation AC checklist:**
    - Given two `SystemBrRunner.cmd/3` calls share a non-empty `database_path`, when both finish, then observed max fake-`br` concurrency is exactly `1`.
    - Given the first fake `br` is inside its body, when the second same-path caller starts, then no second `CALL`/body marker appears before the first `DONE` marker.
    - Given the assertion fails, when ExUnit prints the failure, then it includes max concurrency and ordered call log.

- [ ] **TRD-002-TEST** Add mutation-sensitive regression assertions for same-path lock bypass behavior (2h) [verifies TRD-002] [satisfies REQ-001] [satisfies REQ-005] [satisfies REQ-006] [satisfies REQ-012] [depends: TRD-002]
  - **Validates PRD ACs:** AC-001-1, AC-001-2, AC-005-1, AC-005-2, AC-006-1, AC-006-2, AC-012-1
  - **Implementation AC checklist:**
    - Given the same-path test evidence is inspected, when max concurrency exceeds `1`, then the test fails without relying on task completion order.
    - Given ordered events show overlap, when assertion output is generated, then the log is included for diagnosis.

### PR 2: Lock-key scope and no-lock compatibility

**Shippable State:** Maintainers can see CI distinguish same-database serialization from different-database parallelism and no-database-path compatibility.

- [ ] **TRD-003** Add different-database-path concurrency coverage proving independent DB paths may overlap (3h) [satisfies REQ-002] [satisfies REQ-004] [satisfies REQ-006] [satisfies REQ-008] [depends: TRD-001]
  - **Validates PRD ACs:** AC-002-1, AC-002-2, AC-004-1, AC-004-3, AC-006-1, AC-008-1
  - **Implementation AC checklist:**
    - Given two concurrent calls use distinct non-empty `database_path` values, when fake `br` blocks inside each body, then evidence shows overlap is allowed.
    - Given two calls use the same path in the companion test, when compared to distinct-path evidence, then only same-path calls serialize.

- [ ] **TRD-003-TEST** Add assertions that different-path evidence proves lock key scope, not scheduler accident (2h) [verifies TRD-003] [satisfies REQ-002] [satisfies REQ-004] [depends: TRD-003]
  - **Validates PRD ACs:** AC-002-1, AC-002-2, AC-004-1, AC-004-3
  - **Implementation AC checklist:**
    - Given both distinct-path callers have attempted execution, when fake `br` events are parsed, then there is an interval where both bodies are active.
    - Given events arrive in either order, when overlap is computed, then the assertion remains order-independent.

- [ ] **TRD-004** Add no-database-path and empty-string database-path tests preserving the existing no-lock branch (2h) [satisfies REQ-003] [satisfies REQ-008] [satisfies REQ-011] [depends: TRD-001]
  - **Validates PRD ACs:** AC-003-1, AC-003-2, AC-008-1, AC-008-2, AC-011-1, AC-011-2
  - **Implementation AC checklist:**
    - Given `SystemBrRunner.cmd/3` runs an action that does not require a DB path, when project config omits `database_path`, then fake `br` executes successfully.
    - Given project config has `database_path: ""`, when a no-DB action runs, then fake `br` executes on the same no-lock path.
    - Given the new tests finish or fail, when cleanup runs, then `PATH` and temp files are isolated.

- [ ] **TRD-004-TEST** Run existing `SystemBrRunner` test cases with the new harness to prove command-shape, timeout, and cleanup behavior still passes (2h) [verifies TRD-004] [satisfies REQ-011] [satisfies REQ-008] [depends: TRD-004]
  - **Validates PRD ACs:** AC-008-1, AC-008-2, AC-011-1, AC-011-2
  - **Implementation AC checklist:**
    - Given existing success, timeout, temp-file, shell-quote, and argv tests run, when the new locking tests are present, then they still pass unchanged.
    - Given fake `br` exits non-zero or times out in existing tests, when results return, then existing error envelopes remain unchanged.

### PR 3: Maintainability and diagnostics

**Shippable State:** Maintainers get clear test comments and failure messages explaining the same-database max-concurrency invariant.

- [ ] **TRD-005** Add comments and helper names that document the concurrency contract and why fake-`br` evidence is used (1h) [satisfies REQ-010] [satisfies REQ-012] [depends: TRD-002]
  - **Validates PRD ACs:** AC-010-1, AC-012-1
  - **Implementation AC checklist:**
    - Given a maintainer reads the test, when they inspect comments near the same-path assertion, then they see that same `database_path` must keep max concurrency at `1` for the whole fake-`br` body.
    - Given a failure occurs, when assertion text prints, then it distinguishes overlap from missing fake-command setup evidence.

- [ ] **TRD-005-TEST** Add/verify assertion-message coverage by structuring failure helpers with explicit diagnostic strings (1h) [verifies TRD-005] [satisfies REQ-010] [satisfies REQ-012] [depends: TRD-005]
  - **Validates PRD ACs:** AC-010-1, AC-012-1
  - **Implementation AC checklist:**
    - Given assertion helpers compare expected and observed concurrency, when they fail, then the message includes observed max concurrency and recorded log.
    - Given fake setup fails before any event is recorded, when the helper fails, then the message names setup/evidence absence rather than reporting a false overlap.

- [ ] **TRD-006** Validate the final focused test command and avoid living documentation changes unless implementation changes maintainer/operator behavior (1h) [satisfies REQ-008] [satisfies REQ-011] [satisfies ARCH] [depends: TRD-003, TRD-004, TRD-005]
  - **Validates PRD ACs:** AC-008-1, AC-008-2, AC-011-1, AC-011-2
  - **Implementation AC checklist:**
    - Given implementation is complete, when `mix test test/foreman_server/task_providers/system_br_runner_test.exs` is run from `packages/foreman_server`, then all tests pass locally without network or real Beads.
    - Given living docs are reviewed, when no operator-visible behavior changed, then no README/user-guide/CLI reference change is made.

- [ ] **TRD-006-TEST** Record validation evidence for the SystemBrRunner focused suite and documentation decision (1h) [verifies TRD-006] [satisfies REQ-008] [satisfies REQ-011] [depends: TRD-006]
  - **Validates PRD ACs:** AC-008-1, AC-008-2, AC-011-1, AC-011-2
  - **Implementation AC checklist:**
    - Given the focused suite passes, when implementation report is written, then it includes the exact command and outcome.
    - Given docs are unchanged, when final review runs, then it notes the test-only/no-operator-behavior-change rationale.

## 4. Dependency Mapping and PR Boundary Design

### Dependency graph

```text
TRD-001 -> TRD-001-TEST
TRD-001 -> TRD-002 -> TRD-002-TEST
TRD-001 -> TRD-003 -> TRD-003-TEST
TRD-001 -> TRD-004 -> TRD-004-TEST
TRD-002 -> TRD-005 -> TRD-005-TEST
TRD-003, TRD-004, TRD-005 -> TRD-006 -> TRD-006-TEST
```

Critical path: `TRD-001 -> TRD-002 -> TRD-005 -> TRD-006 -> TRD-006-TEST`. Max depth is 5 including test/validation tasks, but production-code depth is low because all work is one localized test module. No circular dependencies identified.

### Estimate review

Total estimate: 25h.

| Task group | Estimate | Notes |
|---|---:|---|
| PR 1 same-path proof | 12h | Highest complexity due concurrency determinism and failure diagnostics. |
| PR 2 scope/no-lock compatibility | 9h | Reuses harness; validates lock key and no-lock behavior. |
| PR 3 maintainability/validation | 4h | Comments, messages, focused suite evidence, docs decision. |

No individual task is 8h+. Similar helper/test tasks are consistently 1-2h; concurrency feature tasks are 3-4h.

### PR shippability checks

| PR | Independent reviewable outcome | Tests in isolation | Deferred-feature risk |
|---|---|---|---|
| PR 1 | Same-path overlap regression fails in CI. | Focused `SystemBrRunnerTest` same-path cases. | None; no public API/route changed. |
| PR 2 | Lock scope and no-lock compatibility are visible in CI. | Same focused test file plus existing runner tests. | None; no user-facing feature exposed. |
| PR 3 | Diagnostics/comments/validation evidence complete. | Focused suite final run. | None; test-only slice complete. |

## Sprint Planning

## Sprint 1: Same-path lock proof

- PR 1: deterministic harness and same-path non-overlap assertions.

## Sprint 2: Scope and compatibility

- PR 2: distinct-path overlap and no/empty database-path compatibility.

## Sprint 3: Diagnostics and validation

- PR 3: comments, failure output, focused suite validation, docs decision.

## 5. MCP Enhancement

MCP enhancement: skipped (no MCP tools detected in the available tool set).

## 6. Acceptance Criteria Traceability

| REQ | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 | Prove same database paths serialize through `:global.trans` | TRD-002 | TRD-002-TEST |
| REQ-002 | Scope the lock key to the Beads database path | TRD-003 | TRD-003-TEST |
| REQ-003 | Preserve no-database-path command behavior | TRD-004 | TRD-004-TEST |
| REQ-004 | Use a deterministic concurrency harness | TRD-001, TRD-003 | TRD-001-TEST, TRD-003-TEST |
| REQ-005 | Assert lock lifetime covers the whole `br` invocation | TRD-002 | TRD-002-TEST |
| REQ-006 | Fail if the backstop is bypassed or removed | TRD-002, TRD-003 | TRD-002-TEST |
| REQ-007 | Avoid real Beads database mutation in the test | TRD-001 | TRD-001-TEST |
| REQ-008 | Keep the test local and CI-safe | TRD-001, TRD-003, TRD-004, TRD-006 | TRD-001-TEST, TRD-004-TEST, TRD-006-TEST |
| REQ-009 | Locate coverage at the correct boundary | TRD-001, TRD-002 | TRD-001-TEST |
| REQ-010 | Document the test's concurrency contract in code comments | TRD-005 | TRD-005-TEST |
| REQ-011 | Preserve existing task-provider behavior while adding coverage | TRD-004, TRD-006 | TRD-004-TEST, TRD-006-TEST |
| REQ-012 | Expose actionable failure output | TRD-002, TRD-005 | TRD-002-TEST, TRD-005-TEST |

Traceability check: 12 requirements covered, 0 uncovered, 0 orphaned annotations.

## 7. Adversarial Review

### 7.1 Architecture self-critique

| Issue | Impact | Recommended resolution | Disposition |
|---|---|---|---|
| File-backed shell counters can race if distinct-path tests write the same counter without atomic updates. | Could make overlap evidence flaky or false. | Use append-only event logs plus interval parsing as primary proof; use max counter only as supplemental same-path diagnostic. | Applied to TRD-001/TRD-003. |
| Fake `br` can prove port-body overlap but not private function entry unless the test uses `SystemBrRunner.cmd/3`. | A copied helper could create false confidence. | All tests call `SystemBrRunner.cmd/3`; helpers observe external fake command only. | Applied to TRD-001/TRD-002. |
| `PATH` mutation is process-global in the BEAM. | Async tests could call wrong binary or leak env. | Keep module `async: false`, restore original `PATH` in `after`/`on_exit`, and use temp dirs per test. | Applied to TRD-001/TRD-004. |

### 7.2 Task coverage analysis

| Issue | Impact | Recommended resolution | Disposition |
|---|---|---|---|
| Existing same-path test alone does not cover REQ-002 or REQ-003. | Lock could become over-broad or no-path behavior could regress unnoticed. | Add distinct-path overlap and no/empty path tests in PR 2. | Applied to TRD-003/TRD-004. |
| Concurrency proof can pass accidentally if both caller processes do not actually contend. | False green if scheduler serializes setup before lock is tested. | Require caller-attempt markers and bounded waits before final evidence assertions. | Applied to TRD-001/TRD-002. |
| Task parser can miss tasks if checkbox prefix is absent. | Implement-trd-beads could create zero beads. | Every task line begins with `- [ ] **TRD-...**`; draft parser check performed before final output. | Applied. |

### 7.3 Dependency and estimate review

| Issue | Impact | Recommended resolution | Disposition |
|---|---|---|---|
| Harness quality gates all later assertions. | Weak harness invalidates same-path, distinct-path, and no-lock tests. | Make TRD-001 the explicit prerequisite for all concurrency and compatibility tasks. | Applied. |
| Same-path and distinct-path assertions share helpers but prove opposite outcomes. | Helper mistakes could encode the wrong invariant. | Separate assertion helpers/messages: one checks non-overlap/max `1`, another checks at least one overlap interval. | Applied to TRD-002/TRD-003. |
| PR 1 estimate may look high for a test-only change. | Underestimation risk from concurrency flake debugging. | Keep tasks under 4h and reserve explicit harness/test hardening time. | Applied. |

### 7.4 Testability review

| Issue | Impact | Recommended resolution | Disposition |
|---|---|---|---|
| Subjective wording like “deterministic enough” is not directly pass/fail. | Ambiguous completion. | Convert to bounded waits, explicit attempted markers, max concurrency, and interval assertions. | Applied. |
| “Actionable failure output” could be vague. | Maintainers may not distinguish setup failure from overlap. | Require failure messages to include observed max concurrency, ordered log, and missing evidence names. | Applied. |

## 8. Design Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Architecture completeness | 5 | Components, data flow, integration points, temp env, and production boundary are defined. |
| Task coverage | 5 | All 12 PRD requirements have implementation and test-task coverage. |
| Dependency clarity | 4 | Dependencies are explicit and acyclic; critical path depth is acceptable for test-only work. |
| Estimate confidence | 4 | All tasks are 1-4h; concurrency debugging remains the main uncertainty. |

Overall score: 4.5 — PASS

Gate decision: PASS. Proceed to implementation only after user/Foreman approval.

## 9. Implementation Notes and Guardrails

- Do not change `SystemBrRunner` production locking behavior for this PRD unless implementation discovers the current production code cannot satisfy the tests; if that happens, stop and report scope change.
- Keep fake `br` test-only and earlier on `PATH` than any real Beads executable.
- Prefer append-only event logs and interval parsing over sleep-only assertions.
- Preserve existing `SystemBrRunner` result envelopes and timeout behavior.
- Review living docs at finalization. Expected decision: no README/user-guide/CLI reference update because this is test-only and operator-visible behavior is unchanged.

## 10. Suggested Next Steps

```bash
/ensemble-configure-team docs/TRD/TRD-2026-49310ba5-global-trans-test-1.md
/ensemble-implement-trd-beads docs/TRD/TRD-2026-49310ba5-global-trans-test-1.md
```
