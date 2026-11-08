---
document_id: TRD-2026-a804d1c7
label: trd-phase-0-durable-execution
version: 1.0.0
status: Draft
date: 2026-11-08
source_prd: PRD-2026-a804d1c7
prd_reference: docs/PRD/PRD-2026-a804d1c7-phase-0-durable-execution.md
prd_version_locked: 1.1.6
kind: trd
design_readiness_score: 4.0
---

# TRD: Phase 0 — Durable Execution and Safety Foundation

## TRD Health Summary

| Metric | Value |
|---|---|
| Source PRD | docs/PRD/PRD-2026-a804d1c7-phase-0-durable-execution.md (PRD-2026-a804d1c7 v1.1.6: 7 requirements, 30 acceptance criteria) |
| Implementation tasks | 24 |
| Test tasks | 24 |
| Total estimate | 186.5h |
| PR boundaries | 9 |
| Open technical decisions | 4 (see §11) |
| Design Readiness Score | 4.0 (PASS) |

## 1. Context

Phase 0 of the SunStone software factory (umbrella `PRD-2026-b7c2e941`) is a **prove-and-close-gaps** phase, not a redesign. The PRD fixes the expected outcome: extend Foreman's event-sourced engine; Temporal or Conductor are admissible only for a criterion that cannot be closed in it. This TRD designs the smallest change that makes each PRD criterion true and provable, and plans the decision record (REQ-001) last, citing the evidence the earlier tasks produce.

Every design claim below was read from source on 2026-11-08 and carries a `path:line`. Preparing this TRD corrected the PRD six times (v1.1.1 to v1.1.6); each correction is a place where a plausible assumption was wrong, so the TRD re-verifies rather than inherits.

## 2. Scope and Non-Goals

In scope: restart/resume proof and gap closure (REQ-002), human-wait durability (REQ-003), effect reconciliation for PR create, branch push and task-provider state change (REQ-004), stage provenance and project-context identity on the existing projections (REQ-005), an inspectable isolation profile with fail-closed rules (REQ-006), skill preflight at kickoff (REQ-007), and the engine decision record (REQ-001).

Non-goals: replacing the engine; a new workflow-manifest key (`PhaseSpec.@fields` is closed); Kubernetes; `kata` or `herdr` as isolation backends; **building host filesystem confinement** (the PRD requires it to be recorded as unenforced, AC-006-6); phase-level retry policy and `PhaseRetryExhausted` (owned by `PRD-2026-af25d0cb`); auto-merge, idea cultivation, external memory, chat adapters.

## 3. Reused Capabilities

The foundational-capability registry (`trd-graph-cli capabilities docs/TRD`) is empty, so no TRD is reused. Reuse is of existing Foreman modules, called out per task: `Idempotency.KeyStore`/`CrashRecovery`/`BootReconciliation`, the `Phase` and `Run` aggregates, `ProjectionStore`, `EventCodec`, `RunExecutor.kickoff_preflight/1`, `Jobsite.NetworkPolicy`, `Workflow.Validator`, `PreflightFailure`, and the test-support helpers `DispatcherRestart`, `RunDrain`, `TestApplication`, `KeyStoreReset`, `UniqueIds`, `ProjectionLeakGuard`.

Ownership boundaries with existing PRDs: retry policy to `PRD-2026-af25d0cb`; slot/queue recovery to `PRD-2026-d3051d4b` and `PRD-2026-0eac69b3`; model/provider preflight to `PRD-2026-44b49f94`; credential scoping to `PRD-2026-aba4b79c`; task work-log comment content to `PRD-2026-3a76a0f0`.

## 4. Binding Design Constraints

From `docs/standards/constitution.md` and `AGENTS.md`; they apply to every task.

- Only `CommandRouter` appends to the EventStore; aggregate handlers return event specs (constitution §4). `packages/foreman_server/test/foreman_server_web/architecture/event_store_enforcement_test.exs` enumerates allowed append sites.
- Every domain event is a module in `lib/foreman_server/events/` with `@enforce_keys` and `@type t`, registered with `EventCodec` so replay works (`event_codec.ex:113`). New fields on an existing event are optional (default `nil`) so old streams still decode. Aggregate state is a typed struct; `apply_event` uses struct-update syntax.
- Extend existing projections and events; add no parallel store. The run status DTO (`mcp/tools.ex`) is one boundary shared by MCP, HTTP and CLI (AGENTS.md §5.7).
- Total result handling (§5.2): no catch-all that turns an unknown value into success. Absent is not malformed (§5.3).
- Phase execution stays on the Jobsite engine; no second phase loop in `RunExecutor`. The workflow vocabulary stays closed.
- Tests: a failing test is a failed build. Recovery tests are `async: false`, use `UniqueIds`, never `Application.stop`, and reset projections with the sanctioned helpers (`docs/lessons/run-logs-known-issues.md`, `packages/foreman_server/test/support/projection_leak_guard.ex`). Run one file with `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test <path>'`.

## 5. Evidence Baseline (what the source actually does)

Each row is a fact the design depends on; the PRD's claims that turned out wrong are marked.

| Fact | Source |
|---|---|
| `emit_phase_start` hard-codes `attempt: 1` and dispatches `phase.start` with command id `phase:<run>:<phase_id>`, identical for every attempt | `workflow/run_executor.ex:1286,1298` |
| The `Phase` aggregate rejects a second `phase.start` (`:phase_already_started`) and allows `phase.retry` only from `failed`, `timed_out` or `retrying`; `PhaseStarted` leaves `attempt` at 0 | `aggregates/phase.ex:28,69,119,128` |
| `PhaseRetried` has no typed event module, is not registered in `EventCodec`, and nothing dispatches `phase.retry` | `events/` (no file), `projection_store.ex:2860`, `aggregates/run.ex:321` |
| Recovery re-dispatch is capped at 5 by a pure function, but the count lives in ETS `:boot_recon_dispatch_attempts`, and reaching the cap logs and emits telemetry only | `idempotency/restart_backoff.ex`, `workflow/boot_reconciliation.ex:71,1294-1342` |
| A resumed run with no worktree entry logs a warning and provisions a fresh worktree | `run_executor.ex:722` |
| Idempotency keys are written only around agent-phase dispatch; `AutoPR`, `PhasePR`, `PrCreate` never reference a key | `jobsite/runners/overwatch.ex:131`, `workflow/auto_pr.ex:227,254`, `workflow/phase_pr.ex:188`, `pr_create.ex` |
| `CrashRecovery.has_no_side_effects?/1` checks only PR association and worktrees; `:side_effects_present` marks the key completed and allows retry | `idempotency/crash_recovery.ex:6,98-130` |
| Orphaned `started` keys are marked `ambiguous` at boot, then reconciled | `workflow/boot_reconciliation.ex:680-780` |
| Task-provider effects are invoked from `RunExecutor` | `run_executor.ex:125,138,154` |
| No PR comment or review post call site exists in `lib/` | grep, 2026-11-08 |
| `Bundle` carries `sections`, `truncated`, `bytes`, `sha256`, `redactions`, but is only logged and archived; it is built in `build_agent_launch`, **after** `PhaseStarted` | `project_context/bundle.ex:22`, `run_executor.ex:1479-1489` |
| `PhaseStarted` is folded into `state.phases` by `phase_id`; `phases_for_run/1` feeds the DTO attempt field | `projection_store.ex:2777`, `mcp/tools.ex:3583` |
| **PRD-wrong:** `VfsIsolation.allowed?/2` has no caller outside tests; `bind_vfs` is fail-open; `JidoShellRunner` does not confine host commands | `agents/vfs_isolation.ex:61`, `run_executor.ex:4559-4590`, `agents/jido_shell_runner.ex:84-97` |
| `NetworkPolicy` enforces on the docker jobsite only and returns `:network_policy_unsupported` on host | `jobsite/network_policy.ex:21-26` |
| **PRD-wrong:** a `command:` phase is an agent slash command; `bash:` phases are refused at lowering | `workflow/lowering.ex:125,134`, `priv/defaults/workflows/prd.yaml:46` |
| `Workflow.Validator` checks a skill name only against a hard-coded list | `workflow/validator.ex:15,117` |
| Question expiry is a durable `QuestionExpired`, applied idempotently by the sweeper and the fast-path timer | `approvals/timeout_policy.ex:1-25`, `approvals/sweeper.ex:61` |
| A repeated `command_id` never appends; the actor answers with the first event marked `replayed: true` | `aggregate/actor.ex:860-872` |
| `PhaseStarted.attempt` appears in the DTO; the DTO has no provenance, profile or recovery fields | `mcp/tools.ex:3583` |

## 6. Architecture Decision

### Alternatives considered

**Option A — record-only.** Add the profile, provenance and loss fields as log lines and telemetry, and write tests. Smallest, but AC-002-2/5/6 and AC-005-2 require *durable, inspectable* records, and a log line does not survive a restart or reach the status DTO. Rejected.

**Option B — new durable-execution substrate.** Adopt an external engine (Temporal or Conductor) or add a new effect-intent event store and execution model. Satisfies the criteria but is not justified by evidence: every gap found is closable in the current engine, and the constitution's "one boundary, one module" rule argues against a second effect record beside `KeyStore`. Rejected; this is also the REQ-001 conclusion.

**Option C — extend the existing seams (chosen).** Close each gap inside the module that already owns the concern. The two decisions that were open were confirmed by the product owner on 2026-11-08: durable attempt counting with phase-level exhaustion deferred to `PRD-2026-af25d0cb`, and intent key plus external-truth reconciliation for effects.

### Components and changes

1. **Phase attempts (REQ-002).** Register a typed `PhaseRetried` event; let `phase.retry` apply to an in-flight phase when `reason: "resumed"`; set `attempt` in `PhaseStarted`'s apply; `RunExecutor` dispatches `phase.retry` after reaping orphans when it resumes an in-progress phase. The attempt is then derived from the stream. Not a policy retry; it only records that a crash abandoned the earlier attempt. `PRD-2026-af25d0cb` builds its scheduled retries on the same event.
2. **Recovery attempts (REQ-002).** A typed `RunRecoveryAttempted` event on the run stream replaces the ETS counter: `attempt`, `outcome` (`dispatched | failed | blocked`), `kind`, `reason`, `elapsed_since_boot_ms`. The projection folds the latest value into `run.recovery`. `BootReconciliation` reads the count from the projection and appends the event; a `blocked` outcome is durable and operator-visible, and recovery stops re-dispatching it.
3. **Worktree loss and context identity (REQ-002, REQ-005).** Optional `prior_worktree_discarded` and `input_artifacts` fields on `PhaseStarted` and `PhaseRetried`; a new `PhaseContextRecorded` event emitted from `build_agent_launch` (the bundle exists only there). All fold into the existing `state.phases` entry and the DTO.
4. **Effects (REQ-004).** `Idempotency.Effect.run/4` writes a `started` intent key before an effect and `completed`/`failed` after; boot already marks orphaned `started` keys `ambiguous`. A `Reconciler` behaviour registered by key class replaces the PR/worktree guess in `CrashRecovery` for effect keys: effect present or unknown yields `blocked`, never retry; an unregistered class yields `blocked` (fail closed). Three classes: PR create, branch push, task-provider state change.
5. **Isolation profile (REQ-006).** `Jobsite.ExecutionProfile` resolves `{backend, filesystem, network, credentials, cleanup}` each as `enforced | unenforced(reason)` from the real backend, is recorded on `PhaseStarted`, and kickoff preflight blocks a host run when the project requires a network policy the host cannot enforce.
6. **Skill preflight (REQ-007).** `SkillResolver` checks the skill a `command:` names against the harness's skill directories on a host run; `PreflightFailure` gains a class; unverifiable is reported, never available.
7. **Decision record (REQ-001).** `docs/decisions/phase-0-durable-execution-engine.md`, the repo's only decision-record location (`docs/decisions/project-delete.md` is the single precedent: plain Markdown, no front matter).

### Data flow

```
crash -> boot -> BootReconciliation ──reads run.recovery (projection)──▶ dispatch?
                     │ ambiguous keys ──▶ CrashRecovery ──▶ Reconciler[class] ──▶ blocked | retry
                     └ append RunRecoveryAttempted (CommandRouter)
resume ─▶ RunExecutor ─ reap orphans ─▶ phase.retry(reason: resumed) ─▶ PhaseRetried (attempt+1)
launch ─▶ build_agent_launch ─▶ PhaseContextRecorded ; ExecutionProfile ─▶ PhaseStarted fields
effect ─▶ Effect.run(class, key, fun): started key ─▶ fun ─▶ completed|failed
```

## 7. Design Principles for Every Task

- A proof task is a real run: its `-TEST` sibling states the mutation that must make it fail (revert the guarded behavior in a scratch copy and observe red), so a green test cannot pass vacuously.
- No stub reconciler, no fake backend result, no placeholder event. A class without a call site is not given a reconciler (the PR-comment class stays fail-closed under AC-004-3).
- New event fields are optional; existing streams must replay. Each event change includes a codec round-trip test.

## Master Task List

Task ids are hyphenated (`TRD-NNN`, tests `TRD-NNN-TEST`); estimates are `(Nh)`. Target paths are relative to the repository root; files marked "(new)" do not exist yet.

### PR 1: A resumed run records which attempt it is on, and a restart no longer resets the recovery budget

**Shippable State:** An operator inspecting a run after a restart sees which attempt each in-flight phase is on, any uncommitted work lost to a re-provisioned worktree, how long recovery took, and how many recovery attempts the run has used; a run that reached the recovery limit stays blocked across a restart instead of being re-dispatched with a fresh budget.

- [ ] **TRD-001**: Register a typed `PhaseRetried` event and make resume-retry real: new `events/phase_retried.ex` (`run_id`, `phase_id`, `index`, `attempt`, `reason`, optional `prior_worktree_discarded`), register it in `EventCodec`, set `attempt` in `Phase`'s `PhaseStarted` apply, let `phase.retry` apply to an `in_progress` phase when `reason: "resumed"`, and fold `PhaseRetried` into the phase projection (attempt, status stays `in_progress`). [satisfies REQ-002] (5h)
  - Validates PRD ACs: AC-002-2
  - Target Files: `packages/foreman_server/lib/foreman_server/events/phase_retried.ex` (new), `packages/foreman_server/lib/foreman_server/event_codec.ex`, `packages/foreman_server/lib/foreman_server/aggregates/phase.ex`, `packages/foreman_server/lib/foreman_server/aggregates/run.ex`, `packages/foreman_server/lib/foreman_server/projection_store.ex`
  - Implementation AC:
    - [ ] Given a phase in `in_progress`, when `phase.retry` arrives with `reason: "resumed"`, then a `PhaseRetried` is appended with `attempt` one greater than the current attempt and the phase stays `in_progress`.
    - [ ] Given a phase in `completed`, when `phase.retry` arrives, then it is rejected with `:phase_not_retryable` and nothing is appended.
    - [ ] Given a pre-existing stream with no `PhaseRetried`, when it replays, then it decodes unchanged.
- [ ] **TRD-001-TEST**: Aggregate, codec round-trip and projection tests for `PhaseRetried`, including the rejection cases and replay of a stream recorded before the event existed. [verifies TRD-001] [satisfies REQ-002] [depends: TRD-001] (3h)
  - Validates PRD ACs: AC-002-2
  - Target Files: `packages/foreman_server/test/foreman_server/aggregates/phase_test.exs`, `packages/foreman_server/test/foreman_server/projection_store_test.exs`
  - Test AC:
    - [ ] Given the Phase aggregate allowed `phase.retry` from `completed`, when the suite runs, then the rejection test fails.
- [ ] **TRD-002**: Make `RunExecutor` record the attempt on resume: after `reap_orphaned_agents` and before relaunch, when the resume phase's projection status is `in_progress`, dispatch `phase.retry` with `reason: "resumed"` and a deterministic command id including the target attempt, so a repeated resume cannot double-count. [satisfies REQ-002] [depends: TRD-001] (4h)
  - Validates PRD ACs: AC-002-2
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
  - Implementation AC:
    - [ ] Given a restart during an in-flight phase, when the run resumes, then orphaned agents are reaped before `PhaseRetried` is appended and the phase projection shows attempt 2.
    - [ ] Given the same resume is processed twice, when both complete, then exactly one `PhaseRetried` exists.
- [ ] **TRD-002-TEST**: Drive a run to `PhaseStarted`, crash the dispatcher boundary, resume, and assert reap order, attempt 2 in `phases_for_run/1`, and exactly one `PhaseRetried` after a second resume. [verifies TRD-002] [satisfies REQ-002] [depends: TRD-002] (3h)
  - Validates PRD ACs: AC-002-2
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_executor_resume_attempt_test.exs` (new)
  - Test AC:
    - [ ] Given `TRD-002`'s dispatch is removed, when the test runs, then the attempt assertion fails.
- [ ] **TRD-003**: Make the recovery budget durable. New typed `RunRecoveryAttempted` event (`run_id`, `attempt`, `outcome` in `dispatched|failed|blocked`, `kind`, `reason`, `elapsed_since_boot_ms`) with a `run.recovery_attempt` command on the Run aggregate, a `run.recovery` field in the run projection, and `BootReconciliation` reading and appending it instead of the ETS `:boot_recon_dispatch_attempts` table. A `blocked` outcome is durable, stops re-dispatch, and carries an operator-visible reason. [satisfies REQ-002] (7h)
  - Validates PRD ACs: AC-002-6, AC-002-4
  - Target Files: `packages/foreman_server/lib/foreman_server/events/run_recovery_attempted.ex` (new), `packages/foreman_server/lib/foreman_server/event_codec.ex`, `packages/foreman_server/lib/foreman_server/aggregates/run.ex`, `packages/foreman_server/lib/foreman_server/projection_store.ex`, `packages/foreman_server/lib/foreman_server/workflow/boot_reconciliation.ex`, `packages/foreman_server/lib/foreman_server/idempotency/restart_backoff.ex`
  - Implementation AC:
    - [ ] Given recovery has failed to dispatch a run 5 times, when the server restarts, then the run is still blocked and is not re-dispatched.
    - [ ] Given a blocked run, when an operator resumes it manually, then the counter starts again and the block is cleared by an event.
    - [ ] Given a dispatch succeeds, when the event is appended, then it carries `elapsed_since_boot_ms` measured from application start.
- [ ] **TRD-003-TEST**: Extend the dispatch-backoff tests: five failures, restart via `DispatcherRestart`, assert still blocked with a durable reason; success resets; the ETS table no longer exists. [verifies TRD-003] [satisfies REQ-002] [depends: TRD-003] (4h)
  - Validates PRD ACs: AC-002-6
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/boot_reconciliation_dispatch_backoff_test.exs`
  - Test AC:
    - [ ] Given the counter is restored to ETS, when the restart test runs, then it fails because the budget resets.
- [ ] **TRD-004**: Record work lost to a re-provisioned worktree: when `rehydrate_resume_context` finds no worktree entry and provisions a fresh one, carry the discarded path in the optional `prior_worktree_discarded` field of the next `PhaseStarted` or `PhaseRetried`, fold it into the phase projection, and expose it in the status DTO and the warning. [satisfies REQ-002] [depends: TRD-001] (4h)
  - Validates PRD ACs: AC-002-5
  - Target Files: `packages/foreman_server/lib/foreman_server/events/phase_started.ex`, `packages/foreman_server/lib/foreman_server/events/phase_retried.ex` (created by TRD-001), `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`, `packages/foreman_server/lib/foreman_server/projection_store.ex`, `packages/foreman_server/lib/foreman_server/mcp/tools.ex`
  - Implementation AC:
    - [ ] Given a resumed run whose worktree entry is gone, when a fresh worktree is provisioned, then the next phase event names the discarded path and the DTO shows it.
    - [ ] Given a resumed run whose worktree still exists, when it resumes, then the field is absent.
- [ ] **TRD-004-TEST**: Resume with and without a worktree entry and assert the projection and DTO field, plus codec decode of an old `PhaseStarted`. [verifies TRD-004] [satisfies REQ-002] [depends: TRD-004] (2h)
  - Validates PRD ACs: AC-002-5
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_executor_resume_attempt_test.exs` (new)
  - Test AC:
    - [ ] Given the field is not set on re-provision, when the test runs, then the DTO assertion fails.
- [ ] **TRD-005**: Report recovery: surface `run.recovery` (attempts used, limit, outcome, `elapsed_since_boot_ms`, blocked reason) in the status DTO and emit it as telemetry; state the operating threshold in the decision record (30s boot-to-resumed-or-blocked, matching the existing NFR-03 test) without making it a pass/fail gate on the run. [satisfies REQ-002] [depends: TRD-003] (3h)
  - Validates PRD ACs: AC-002-4
  - Target Files: `packages/foreman_server/lib/foreman_server/mcp/tools.ex`, `packages/foreman_server/lib/foreman_server/workflow/boot_reconciliation.ex`
  - Implementation AC:
    - [ ] Given a recovered run, when its status is read, then `recovery.elapsed_since_boot_ms` and `recovery.attempts` are present.
    - [ ] Given a run that never needed recovery, when its status is read, then `recovery` is `nil`.
- [ ] **TRD-005-TEST**: Extend the NFR timing test: boot with N orphaned runs, assert every one reaches resumed-or-blocked and each records a duration, reported against the 30s operating target. [verifies TRD-005] [satisfies REQ-002] [depends: TRD-005] (2h)
  - Validates PRD ACs: AC-002-4
  - Target Files: `packages/foreman_server/test/foreman_server/idempotency/resumption_time_test.exs`
  - Test AC:
    - [ ] Given a run is skipped by recovery, when the test runs, then the missing duration fails it.

### PR 2: Restart boundaries, unresolvable bases and cancellation are proven by tests that can fail

**Shippable State:** A restart at any of five stage boundaries never relaunches a completed phase, a run whose base cannot be resolved ends with a typed reason, and a cancelled run is never resumed; each guarantee is covered by a test shown to fail when the guarded behavior is removed.

- [ ] **TRD-006**: Write the five-boundary restart suite (before a phase starts; after `PhaseStarted` before completion; after `PhaseCompleted` before the next phase; while waiting on a human; after the last phase before the terminal event) using `DispatcherRestart`, `RunDrain`, `TestApplication` and `UniqueIds`; each asserts status, artifact references and attempt are reconstructed and no `PhaseCompleted` phase relaunches. Fix any gap a boundary exposes. [satisfies REQ-002] [depends: TRD-002] (7h)
  - Validates PRD ACs: AC-002-1
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_resume_boundaries_test.exs` (new), `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex`
  - Implementation AC:
    - [ ] Given a restart at each of the five boundaries, when the service recovers, then no phase that has `PhaseCompleted` is launched again.
    - [ ] Given the "waiting on a human" boundary, when the question is answered after recovery, then only that run resumes.
- [ ] **TRD-006-TEST**: Mutation probe: in a scratch copy make `resume_from_index/2` ignore `completed`, and confirm boundary 3 fails; record the red run in the PR description. [verifies TRD-006] [satisfies REQ-002] [depends: TRD-006] (2h)
  - Validates PRD ACs: AC-002-1
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_resume_boundaries_test.exs` (new)
  - Test AC:
    - [ ] Given `resume_from_index/2` ignores completed phases, when the suite runs, then at least one boundary test fails.
- [ ] **TRD-007**: Prove an unresolvable resume base ends the run with `:resume_context_unresolvable` and is never started from a guessed base. [satisfies REQ-002] (2h)
  - Validates PRD ACs: AC-002-3
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_executor_resume_context_test.exs` (new), `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
  - Implementation AC:
    - [ ] Given the base ref cannot be resolved on resume, when recovery runs, then the terminal reason is `{:resume_context_unresolvable, _}` and no phase is started.
- [ ] **TRD-007-TEST**: Mutation probe: make `resolve_run_base` fall back to the default branch and confirm the test fails. [verifies TRD-007] [satisfies REQ-002] [depends: TRD-007] (1h)
  - Validates PRD ACs: AC-002-3
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_executor_resume_context_test.exs` (new)
  - Test AC:
    - [ ] Given a guessed base is used, when the test runs, then it fails.
- [ ] **TRD-008**: Prove cancellation survives a restart: the run reaches `RunCancelled` durably and neither `BootReconciliation` nor the dispatcher resumes it; the agent is signalled, the harness SIGTERM/SIGKILL escalation completes, and any survivor is reaped by `OrphanReaper` and observable. "Stopped" is asserted only after escalation and reaping, never at cancel time. [satisfies REQ-002] (5h)
  - Validates PRD ACs: AC-002-7
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_executor_cancel_reap_test.exs`, `packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/driver_await_exit_test.exs`, `packages/foreman_server/lib/foreman_server/workflow/boot_reconciliation.ex`
  - Implementation AC:
    - [ ] Given a cancelled run, when the server restarts, then it stays `cancelled` and no phase is launched.
    - [ ] Given a cancel is processed, when the test waits for `Driver.await_exit`, then no agent process remains.
- [ ] **TRD-008-TEST**: Mutation probe: let recovery resume a `cancelled` run and confirm the test fails. [verifies TRD-008] [satisfies REQ-002] [depends: TRD-008] (2h)
  - Validates PRD ACs: AC-002-7
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_executor_cancel_reap_test.exs`
  - Test AC:
    - [ ] Given recovery resumes a cancelled run, when the test runs, then it fails.

### PR 3: Human waits survive a restart and are answered exactly once

**Shippable State:** A question that is open when the server restarts is still pending and listed afterwards, an answer is recorded once whether it is repeated or contradicted, and a question that expires while the server is down is expired once and shown as waiting on the operator.

- [ ] **TRD-009**: Prove human-wait durability across a restart: an unanswered question is still pending and listed; a repeated answer with the same `command_id` returns the first result marked `replayed` and appends nothing; a second answer with a different `command_id` is rejected with the typed `{:question_not_open, status}` error; exactly one `QuestionAnswered` exists and the run resumes once. [satisfies REQ-003] (6h)
  - Validates PRD ACs: AC-003-1, AC-003-2, AC-003-3
  - Target Files: `packages/foreman_server/test/foreman_server/questions/restart_durability_test.exs` (new), `packages/foreman_server/lib/foreman_server/aggregates/operator_question.ex`
  - Implementation AC:
    - [ ] Given an open question and a restart, when the question list is read, then it is still pending and only its run resumes on answer.
    - [ ] Given the same `command_id` is repeated after a restart, when it arrives, then it is `replayed` and no second `QuestionAnswered` exists.
    - [ ] Given a different `command_id` on an answered question, when it arrives, then it is rejected with a typed not-open error.
- [ ] **TRD-009-TEST**: Mutation probe: drop the `command_id` dedupe in a scratch copy and confirm the replay test fails; drop the `question_not_open` guard and confirm the rejection test fails. [verifies TRD-009] [satisfies REQ-003] [depends: TRD-009] (2h)
  - Validates PRD ACs: AC-003-2, AC-003-3
  - Target Files: `packages/foreman_server/test/foreman_server/questions/restart_durability_test.exs` (new)
  - Test AC:
    - [ ] Given either guard is removed, when the suite runs, then the matching test fails.
- [ ] **TRD-010**: Prove expiry across a restart: a question that expires while the server is down is expired exactly once by the boot sweep (deterministic `expire:question:<run>:<id>` command id), surfaces as waiting on the operator with `question_expired`, and is not asked again silently. [satisfies REQ-003] (4h)
  - Validates PRD ACs: AC-003-4
  - Target Files: `packages/foreman_server/test/foreman_server/approvals/sweeper_test.exs`, `packages/foreman_server/lib/foreman_server/approvals/sweeper.ex`
  - Implementation AC:
    - [ ] Given a question past its deadline at boot, when the sweeper runs twice, then one `QuestionExpired` exists.
    - [ ] Given the expired question, when the Overview is read, then the thread is waiting on the operator with reason `question_expired`.
- [ ] **TRD-010-TEST**: Mutation probe: remove the deterministic command id and confirm a double sweep appends two events. [verifies TRD-010] [satisfies REQ-003] [depends: TRD-010] (1.5h)
  - Validates PRD ACs: AC-003-4
  - Target Files: `packages/foreman_server/test/foreman_server/approvals/sweeper_test.exs`
  - Test AC:
    - [ ] Given the command id is random, when the test runs, then it fails.

### PR 4: Push and PR-create effects are keyed, and an ambiguous effect is reconciled or blocked, never repeated

**Shippable State:** A crash during `git push` or `gh pr create` leaves a durable record that recovery checks against GitHub; if the push or PR already happened, or its outcome cannot be established, the run blocks with an operator-visible reason instead of repeating it, and the server reports at boot when the idempotency store is not durable.

- [ ] **TRD-011**: Add `Idempotency.Effect.run(class, key, fun, meta)`: write a `started` key (`effect:<class>:<run_id>:<discriminator>`) before the effect, `completed` or `failed` after, and return the effect's own result unchanged. Return `{:error, {:intent_not_recorded, reason}}` and do **not** run the effect if the key cannot be written. [satisfies REQ-004] (5h)
  - Validates PRD ACs: AC-004-5
  - Target Files: `packages/foreman_server/lib/foreman_server/idempotency/effect.ex` (new), `packages/foreman_server/lib/foreman_server/idempotency/key_store.ex`
  - Implementation AC:
    - [ ] Given an effect, when it starts, then a `started` key exists before the function runs.
    - [ ] Given the key cannot be written, when the effect is requested, then the function is not called and a typed error is returned.
    - [ ] Given the process dies mid-effect, when the server boots, then the key is `started` and boot marks it `ambiguous`.
- [ ] **TRD-011-TEST**: Unit tests with `KeyStoreReset`: ordering (key before effect), completion and failure marking, write-failure refusal, and the crash-mid-effect path through `BootReconciliation`. [verifies TRD-011] [satisfies REQ-004] [depends: TRD-011] (3h)
  - Validates PRD ACs: AC-004-5
  - Target Files: `packages/foreman_server/test/foreman_server/idempotency/effect_test.exs` (new)
  - Test AC:
    - [ ] Given the key is written after the effect, when the ordering test runs, then it fails.
- [ ] **TRD-012**: Add the `Idempotency.Reconciler` behaviour and a class registry consulted by `CrashRecovery` for `effect:` keys: a registered reconciler returns `:not_done | :done | :unknown`; `:not_done` allows retry, `:done` and `:unknown` block with an operator-visible reason, and an unregistered class blocks (fail closed). Record a block as `RunRecoveryAttempted(outcome: blocked, kind: :effect)`. Leave agent-phase keys on their existing path. [satisfies REQ-004] [depends: TRD-003] [depends: TRD-011] (6h)
  - Validates PRD ACs: AC-004-2, AC-004-3
  - Target Files: `packages/foreman_server/lib/foreman_server/idempotency/reconciler.ex` (new), `packages/foreman_server/lib/foreman_server/idempotency/crash_recovery.ex`, `packages/foreman_server/lib/foreman_server/workflow/boot_reconciliation.ex`
  - Implementation AC:
    - [ ] Given an ambiguous `effect:` key whose reconciler returns `:done`, when recovery runs, then the run blocks and nothing is repeated.
    - [ ] Given an ambiguous `effect:` key of an unregistered class, when recovery runs, then it blocks.
    - [ ] Given an ambiguous agent-phase key, when recovery runs, then its existing behavior is unchanged.
- [ ] **TRD-012-TEST**: Registry tests for `:not_done`, `:done`, `:unknown` and unregistered classes, plus the unchanged agent-phase path against the existing characterization test. [verifies TRD-012] [satisfies REQ-004] [depends: TRD-012] (4h)
  - Validates PRD ACs: AC-004-2, AC-004-3
  - Target Files: `packages/foreman_server/test/foreman_server/idempotency/crash_recovery_test.exs`, `packages/foreman_server/test/foreman_server/workflow/boot_reconciliation_ambiguous_keys_test.exs`
  - Test AC:
    - [ ] Given an unregistered class retries, when the suite runs, then the fail-closed test fails.
- [ ] **TRD-013**: Wrap branch push (`auto_pr.ex:227`, `phase_pr.ex:188`) and PR create (`auto_pr.ex:254`, `phase_pr.ex:210`, `pr_create.ex`) in `Effect.run` and register two reconcilers: PR create asks GitHub for an existing PR on the head branch; branch push compares the remote head to the local head with `git ls-remote`. [satisfies REQ-004] [depends: TRD-012] (7h)
  - Validates PRD ACs: AC-004-1, AC-004-5
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex`, `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex`, `packages/foreman_server/lib/foreman_server/pr_create.ex`, `packages/foreman_server/lib/foreman_server/idempotency/reconcilers/pr_create.ex` (new), `packages/foreman_server/lib/foreman_server/idempotency/reconcilers/branch_push.ex` (new)
  - Implementation AC:
    - [ ] Given a crash after `gh pr create` succeeded and before the association was recorded, when recovery runs, then the existing PR is found and the run blocks without a second `gh pr create`.
    - [ ] Given a crash before the push reached the remote, when recovery runs, then the reconciler reports `:not_done` and the push is retried.
    - [ ] Given the remote head differs from the local head, when recovery runs, then the push class reports `:unknown` and blocks.
- [ ] **TRD-013-TEST**: Drive both effects through the injectable command runner (`PrCreate.set_command_runner`) with simulated crashes at each side of the effect, asserting no duplicate command is issued. [verifies TRD-013] [satisfies REQ-004] [depends: TRD-013] (5h)
  - Validates PRD ACs: AC-004-1, AC-004-5
  - Target Files: `packages/foreman_server/test/foreman_server/pr_create_test.exs`, `packages/foreman_server/test/foreman_server/workflow/auto_pr_test.exs`, `packages/foreman_server/test/foreman_server/workflow/phase_pr_test.exs`
  - Test AC:
    - [ ] Given the reconciler is bypassed, when the crash-after-create test runs, then a second create is issued and the test fails.
- [ ] **TRD-014**: Report a non-durable idempotency store: expose `KeyStore.durable?/0`, log an error and emit telemetry at boot when the Postgres repo is unavailable and the ETS fallback is active, and add the line to `foreman_doctor`. [satisfies REQ-004] (3h)
  - Validates PRD ACs: AC-004-4
  - Target Files: `packages/foreman_server/lib/foreman_server/idempotency/key_store.ex`, `packages/foreman_server/lib/foreman_server_web/mcp/tools/doctor.ex`
  - Implementation AC:
    - [ ] Given the ETS fallback is active, when the server boots, then an error is logged and `foreman_doctor` reports the store as non-durable.
    - [ ] Given the repo is configured, when the server boots, then the store is reported durable.
- [ ] **TRD-014-TEST**: Boot with and without a configured repo and assert the log, telemetry and doctor output. [verifies TRD-014] [satisfies REQ-004] [depends: TRD-014] (2h)
  - Validates PRD ACs: AC-004-4
  - Target Files: `packages/foreman_server/test/foreman_server/idempotency/key_store_durability_test.exs` (new)
  - Test AC:
    - [ ] Given the fallback is silent, when the test runs, then it fails.

### PR 5: Task-provider state changes are keyed and reconciled

**Shippable State:** A crash during a task claim, completion, failure, reopen or annotation leaves a durable record that recovery checks against the task provider; a change that already took effect, or whose outcome is unknown, blocks the run with a reason instead of being repeated.

- [ ] **TRD-015**: Wrap the `claim`, `complete` and `fail` calls in `RunExecutor` (`:125`, `:138`, `:154`) and the boot-reconciliation `reopen` and `annotate` calls in `Effect.run`, and register a task-provider reconciler that reads the issue's current state through `provider.get/2` and reports `:done`, `:not_done` or `:unknown`. [satisfies REQ-004] [depends: TRD-012] (7h)
  - Validates PRD ACs: AC-004-1, AC-004-5
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`, `packages/foreman_server/lib/foreman_server/workflow/boot_reconciliation.ex`, `packages/foreman_server/lib/foreman_server/idempotency/reconcilers/task_provider.ex` (new)
  - Implementation AC:
    - [ ] Given a crash after `complete` reached the provider and before the run recorded it, when recovery runs, then the provider shows the issue closed and the run blocks without a second `complete`.
    - [ ] Given the provider cannot be reached during reconciliation, when recovery runs, then the reconciler reports `:unknown` and blocks.
- [ ] **TRD-015-TEST**: Fake `TaskProvider` implementations drive each callback through a crash on each side of the call, asserting no repeated call and that an unreachable provider blocks. [verifies TRD-015] [satisfies REQ-004] [depends: TRD-015] (5h)
  - Validates PRD ACs: AC-004-1, AC-004-5
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_executor_task_effects_test.exs` (new)
  - Test AC:
    - [ ] Given the reconciler treats an unreachable provider as `:not_done`, when the test runs, then it fails.

### PR 6: A phase's inputs and the project context it was given are inspectable after the fact

**Shippable State:** The run status shows, for every phase, which artifacts it read (source phase, path, sha256), and which project-context sections, hash, byte count, truncations and redaction count it was launched with, all readable after a restart; redaction is reported as what was applied and never as proof that no secret was stored.

- [ ] **TRD-016**: Record each phase's input artifact references: add optional `input_artifacts` (`[%{index, path, sha256}]`) to `PhaseStarted` and `PhaseRetried`, filled from the previous phase's `PhaseCompleted` in the projection, folded into the phase entry and exposed in the status DTO with the existing correlation identifiers (`run_id`, `phase_id`, `task_id`). [satisfies REQ-005] [depends: TRD-004] (6h)
  - Validates PRD ACs: AC-005-1
  - Target Files: `packages/foreman_server/lib/foreman_server/events/phase_started.ex`, `packages/foreman_server/lib/foreman_server/events/phase_retried.ex` (created by TRD-001), `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`, `packages/foreman_server/lib/foreman_server/projection_store.ex`, `packages/foreman_server/lib/foreman_server/mcp/tools.ex`
  - Implementation AC:
    - [ ] Given phase 2 starts after phase 1 completed, when the run is inspected, then phase 2 lists phase 1's artifact path and sha256 as an input.
    - [ ] Given phase 1, when it is inspected, then its input list is empty.
    - [ ] Given an old stream, when it replays, then `input_artifacts` is absent and decoding succeeds.
- [ ] **TRD-016-TEST**: Two-phase run asserting inputs, the empty first phase, restart-survival of the projection, and decode of a pre-change `PhaseStarted`. [verifies TRD-016] [satisfies REQ-005] [depends: TRD-016] (3h)
  - Validates PRD ACs: AC-005-1
  - Target Files: `packages/foreman_server/test/foreman_server/projection_store_test.exs`, `packages/foreman_server/test/foreman_server/mcp/run_status_test.exs` (new)
  - Test AC:
    - [ ] Given inputs are not recorded, when the test runs, then it fails.
- [ ] **TRD-017**: Record project-context identity: new `PhaseContextRecorded` event (`run_id`, `phase_id`, `sections` as `[%{id, bytes}]`, `sha256`, `bytes`, `truncated`, `redactions`, `redaction_scope`) with a `phase.context` command on the Phase aggregate, emitted from `build_agent_launch` right after the bundle is built; fold into the phase entry and the DTO. `redaction_scope` states `project_context_sections`; no field reports a "no secrets" boolean. [satisfies REQ-005] [depends: TRD-016] (7h)
  - Validates PRD ACs: AC-005-2, AC-005-3
  - Target Files: `packages/foreman_server/lib/foreman_server/events/phase_context_recorded.ex` (new), `packages/foreman_server/lib/foreman_server/event_codec.ex`, `packages/foreman_server/lib/foreman_server/aggregates/phase.ex`, `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`, `packages/foreman_server/lib/foreman_server/projection_store.ex`, `packages/foreman_server/lib/foreman_server/mcp/tools.ex`
  - Implementation AC:
    - [ ] Given a launch builds a bundle, when the run is inspected after a restart, then sections, `sha256`, bytes, truncations and the redaction count are present.
    - [ ] Given a project with no context, when a phase launches, then no `PhaseContextRecorded` is appended.
    - [ ] Given the DTO, when its fields are listed, then none claims that no secret was stored.
- [ ] **TRD-017-TEST**: Extend the existing launch-context suite: launch with a bundle that truncates and redacts, assert the recorded fields and restart-survival; assert the DTO shape carries `redaction_scope` and no secrets-clean field; codec round-trip. [verifies TRD-017] [satisfies REQ-005] [depends: TRD-017] (4h)
  - Validates PRD ACs: AC-005-2, AC-005-3
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_executor_project_context_test.exs`, `packages/foreman_server/test/foreman_server/mcp/run_status_test.exs` (new)
  - Test AC:
    - [ ] Given the event is not appended, when the restart-survival test runs, then it fails.

### PR 7: Every launch records what its executor does and does not enforce, and an unenforceable network policy blocks the run

**Shippable State:** The run status shows, per phase, the backend and whether filesystem, network, credentials and cleanup are enforced or unenforced with a reason; a project that requires a network policy is blocked before any agent code runs when the host workflow door cannot enforce it; and a host run is never reported as filesystem-confined.

- [ ] **TRD-018**: Add `Jobsite.ExecutionProfile` resolving `{backend, filesystem, network, credentials, cleanup}` as `enforced | {:unenforced, reason}` from the actual backend: host workflow door reports filesystem and network unenforced (`VfsIsolation` registry is not an enforcement point); docker jobsite derives filesystem from its mount list and network from `NetworkPolicy.network_enforced_on/0`; credentials point at `PRD-2026-aba4b79c`; cleanup comes from the worktree spec. Record it in an optional `execution_profile` field on `PhaseStarted`, fold it, and expose it in the DTO. [satisfies REQ-006] [depends: TRD-016] (7h)
  - Validates PRD ACs: AC-006-1, AC-006-5, AC-006-6
  - Target Files: `packages/foreman_server/lib/foreman_server/jobsite/execution_profile.ex` (new), `packages/foreman_server/lib/foreman_server/jobsite/network_policy.ex`, `packages/foreman_server/lib/foreman_server/events/phase_started.ex`, `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`, `packages/foreman_server/lib/foreman_server/projection_store.ex`, `packages/foreman_server/lib/foreman_server/mcp/tools.ex`
  - Implementation AC:
    - [ ] Given a host workflow run with no network policy, when it launches, then it proceeds and its profile records network and filesystem as unenforced with reasons.
    - [ ] Given any host run, when its profile is read, then filesystem is never `enforced`.
    - [ ] Given a docker jobsite, when its profile is resolved, then filesystem reflects only the paths actually mounted.
- [ ] **TRD-018-TEST**: Profile resolution tests per backend, the "host is never filesystem-enforced" invariant, and projection/DTO survival. [verifies TRD-018] [satisfies REQ-006] [depends: TRD-018] (4h)
  - Validates PRD ACs: AC-006-1, AC-006-5, AC-006-6
  - Target Files: `packages/foreman_server/test/foreman_server/jobsite/execution_profile_test.exs` (new)
  - Test AC:
    - [ ] Given the host profile reports filesystem enforced, when the invariant test runs, then it fails.
- [ ] **TRD-019**: Fail closed on the workflow door: in `kickoff_preflight`, read the project's `environment.network` policy and, when it is non-default and the backend is the host, end the run before the task claim with `{:isolation_unsupported, :network, :host_workflow}`; a project with no policy proceeds. [satisfies REQ-006] [depends: TRD-018] (5h)
  - Validates PRD ACs: AC-006-2
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`, `packages/foreman_server/lib/foreman_server/jobsite/network_policy.ex`
  - Implementation AC:
    - [ ] Given a project requiring `allowlist` and a host run, when the run starts, then it ends before any agent code runs with the typed reason and no task claim or worktree.
    - [ ] Given a project with the default policy, when the run starts, then it proceeds.
- [ ] **TRD-019-TEST**: Kickoff with `none`, `allowlist` and default policies on the host door, asserting zero `PhaseStarted`, no claim and no worktree for the first two. [verifies TRD-019] [satisfies REQ-006] [depends: TRD-019] (3h)
  - Validates PRD ACs: AC-006-2
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_executor_isolation_test.exs` (new)
  - Test AC:
    - [ ] Given the check is removed, when the `allowlist` test runs, then a phase starts and the test fails.
- [ ] **TRD-020**: Prove the docker jobsite's enforced properties and cleanup: a path outside the mounted worktree is unreachable from the sandbox and a `vfs_denied`-class denial is recorded where Foreman mediates access; containers and the network are removed on every exit route and swept at boot after a crash. Tagged `:docker` like the existing network-policy tests. [satisfies REQ-006] [depends: TRD-018] (5h)
  - Validates PRD ACs: AC-006-3, AC-006-4
  - Target Files: `packages/foreman_server/test/foreman_server/jobsite/network_policy_docker_test.exs`, `packages/foreman_server/test/foreman_server/jobsite/boot_recovery_test.exs`
  - Implementation AC:
    - [ ] Given a docker jobsite, when the agent reads a path outside its mounts, then the read fails.
    - [ ] Given a server crash, when the server next boots, then orphaned containers and networks carrying Foreman's labels are removed.
- [ ] **TRD-020-TEST**: Mutation probe: mount the host root into the sandbox in a scratch copy and confirm the outside-path test fails; skip the boot sweep and confirm the orphan test fails. [verifies TRD-020] [satisfies REQ-006] [depends: TRD-020] (2h)
  - Validates PRD ACs: AC-006-3, AC-006-4
  - Target Files: `packages/foreman_server/test/foreman_server/jobsite/network_policy_docker_test.exs`
  - Test AC:
    - [ ] Given a wider mount, when the docker suite runs, then the outside-path test fails.

### PR 8: A run whose workflow names a skill the harness cannot find is refused before it starts

**Shippable State:** A workflow whose `command:` phase names a skill that does not exist in the harness's skill directories is refused at admission with the phase and skill named, before any task claim or worktree; a skill Foreman cannot check on a backend is reported as unverifiable and never as available.

- [ ] **TRD-021**: Add `AgentRuntime.JidoHarness.SkillResolver.resolve(provider, skill, backend)` returning `:available | :missing | :unverifiable` over the harness's skill directories (host only; any other backend is `:unverifiable`), make `Workflow.Validator.skill_from_command/1` public so the skill is extracted in one place, and add a `:skill_not_found` class to `PreflightFailure` with its `summarize/1` phrase. [satisfies REQ-007] [depends: TRD-018] (6h)
  - Validates PRD ACs: AC-007-1
  - Target Files: `packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/skill_resolver.ex` (new), `packages/foreman_server/lib/foreman_server/workflow/validator.ex`, `packages/foreman_server/lib/foreman_server/workflow/preflight_failure.ex`
  - Implementation AC:
    - [ ] Given a skill present in a known skill directory, when it is resolved on a host run, then it is `:available`.
    - [ ] Given a skill in none of the directories, when it is resolved, then it is `:missing`.
    - [ ] Given a non-host backend, when any skill is resolved, then it is `:unverifiable`, never `:available`.
- [ ] **TRD-021-TEST**: Resolver tests with temporary skill directories for each state and backend, and `PreflightFailure` class/summary tests. [verifies TRD-021] [satisfies REQ-007] [depends: TRD-021] (3h)
  - Validates PRD ACs: AC-007-1
  - Target Files: `packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs` (new), `packages/foreman_server/test/foreman_server/workflow/preflight_failure_test.exs`
  - Test AC:
    - [ ] Given `:unverifiable` is returned as `:available`, when the backend test runs, then it fails.
- [ ] **TRD-022**: Wire skill preflight into `kickoff_preflight/1` after the provider/model check and before `maybe_claim_task`: a `:missing` skill ends the run with a `PreflightFailure` naming the phase, skill and backend; `:unverifiable` is recorded in the phase's execution profile and does not block. [satisfies REQ-007] [depends: TRD-021] (3h)
  - Validates PRD ACs: AC-007-2
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
  - Implementation AC:
    - [ ] Given a missing skill, when the run is admitted, then it ends before the claim, worktree and first phase with the typed reason.
    - [ ] Given an unverifiable skill, when the run is admitted, then it proceeds and the profile records it.
- [ ] **TRD-022-TEST**: Kickoff test with a missing, an available and an unverifiable skill, asserting zero `PhaseStarted`, no claim and no worktree for the first. [verifies TRD-022] [satisfies REQ-007] [depends: TRD-022] (2h)
  - Validates PRD ACs: AC-007-2
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_executor_skill_preflight_test.exs` (new)
  - Test AC:
    - [ ] Given the preflight is removed, when the missing-skill test runs, then a phase starts and the test fails.

### PR 9: The engine decision is recorded with evidence, and the documentation matches the code

**Shippable State:** A decision record maps every durability criterion to source and test evidence with a pass or fail, states the decision to extend the current engine, links from the umbrella roadmap, and the operator documentation describes the new status fields, preflight failure and doctor line.

- [ ] **TRD-023**: Write `docs/decisions/phase-0-durable-execution-engine.md` in the house style of `docs/decisions/project-delete.md` (context, decision, consequences): a table of criteria (REQ-002 to REQ-006) with source and test evidence, pass/fail and remaining gaps; the comparison of extending the engine against Temporal and Conductor with migration, operational and rollback cost; the decision ("extend the current engine"); the 30s recovery operating target; and the named prerequisite on `PRD-2026-af25d0cb`. Add a forward-pointer line to the umbrella PRD's Phase 0 row. [satisfies REQ-001] [depends: TRD-005] [depends: TRD-008] [depends: TRD-010] [depends: TRD-015] [depends: TRD-017] [depends: TRD-020] [depends: TRD-022] (4h)
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3
  - Target Files: `docs/decisions/phase-0-durable-execution-engine.md` (new), `docs/PRD/PRD-2026-b7c2e941-sunstone-software-factory.md`
  - Implementation AC:
    - [ ] Given the record, when each criterion is read, then it names source and test evidence and a result.
    - [ ] Given a criterion that fails and cannot be closed in the engine, when it is read, then it names the alternatives and their migration, operational and rollback cost.
    - [ ] Given every criterion passes or is closed, when the decision is read, then it says "extend the current engine" and lists no adoption work.
- [ ] **TRD-023-TEST**: A script check that every path and test name cited in the record exists on disk, run in the PR description. [verifies TRD-023] [satisfies REQ-001] [depends: TRD-023] (2h)
  - Validates PRD ACs: AC-001-1
  - Target Files: `docs/decisions/phase-0-durable-execution-engine.md` (new)
  - Test AC:
    - [ ] Given a cited path does not exist, when the check runs, then it names it and fails.
- [ ] **TRD-024**: Documentation gate: add the new status fields (`recovery`, per-phase `input_artifacts`, `context`, `execution_profile`, `prior_worktree_discarded`), the `:skill_not_found` preflight failure, the `foreman_doctor` store-durability line and the cancel/escalation semantics to `docs/user-guide.md` and `docs/cli-reference.md`, and annotate any stale reference in `CLAUDE.md` and `README.md`; state in the PR which of the four files needed edits. [satisfies REQ-001] [depends: TRD-023] (3h)
  - Validates PRD ACs: AC-001-1
  - Target Files: `docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`, `README.md`
  - Implementation AC:
    - [ ] Given each added or renamed identifier, when the four documents are searched, then it is documented where its predecessor was.
- [ ] **TRD-024-TEST**: Grep each added identifier in the four documents and fail if one is absent. [verifies TRD-024] [satisfies REQ-001] [depends: TRD-024] (1h)
  - Validates PRD ACs: AC-001-1
  - Target Files: `docs/user-guide.md`
  - Test AC:
    - [ ] Given a new status field is undocumented, when the grep runs, then it fails.

## 9. Sprint Planning

Informational only; `implement-trd-beads` does not parse this section.

## Sprint 1: Durable attempts and recovery proof

PR 1 and PR 2. Delivers the attempt counter, the durable recovery budget, worktree-loss recording and the restart-boundary suite. Longest chain: TRD-001 → TRD-002 → TRD-006.

## Sprint 2: Waits and effects

PR 3 and PR 4. Human-wait proofs run in parallel with the effect framework; PR 5 follows once `Effect` and the reconciler registry exist.

## Sprint 3: Provenance, isolation, preflight

PR 6, PR 7 and PR 8. PR 7 and PR 8 depend on the profile field from TRD-018.

## Sprint 4: Decision record and documentation

PR 9, last, because it cites the evidence PRs 1 to 8 produce.

## 10. Acceptance Criteria Traceability

| REQ | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 | Record an evidence-backed engine decision | TRD-023, TRD-024 | TRD-023-TEST, TRD-024-TEST |
| REQ-002 | Resume runs across a restart without repeating completed work | TRD-001, TRD-002, TRD-003, TRD-004, TRD-005, TRD-006, TRD-007, TRD-008 | TRD-001-TEST, TRD-002-TEST, TRD-003-TEST, TRD-004-TEST, TRD-005-TEST, TRD-006-TEST, TRD-007-TEST, TRD-008-TEST |
| REQ-003 | Human waits survive restart and are answered once | TRD-009, TRD-010 | TRD-009-TEST, TRD-010-TEST |
| REQ-004 | Reconcile or block uncertain external effects | TRD-011, TRD-012, TRD-013, TRD-014, TRD-015 | TRD-011-TEST, TRD-012-TEST, TRD-013-TEST, TRD-014-TEST, TRD-015-TEST |
| REQ-005 | Record stage provenance and project-context identity | TRD-016, TRD-017 | TRD-016-TEST, TRD-017-TEST |
| REQ-006 | Make the executor isolation contract explicit and enforced | TRD-018, TRD-019, TRD-020 | TRD-018-TEST, TRD-019-TEST, TRD-020-TEST |
| REQ-007 | Preflight the capabilities a run needs | TRD-021, TRD-022 | TRD-021-TEST, TRD-022-TEST |

## 11. Open Technical Decisions

| # | Decision | Recommendation | Owner |
|---|---|---|---|
| OTD-1 | `PhaseRetried` is reused for resume-retry, and `PRD-2026-af25d0cb` plans its own `PhaseRetrying`/`PhaseRetryExhausted`. Do the two coexist? | Yes. `PhaseRetried reason: resumed` records a crash-abandoned attempt; af25d0cb's events record policy retries. af25d0cb's TRD must build on this event, not redefine it. Confirm when that TRD starts. | Phase 0 / af25d0cb owner |
| OTD-2 | AC-006-3 can be proven only on a docker jobsite, which CI may not run. | Tag `:docker` like the existing network-policy tests, run locally before merge, and state in the decision record that filesystem confinement is proven on the docker jobsite only and is **unenforced on the host door**. | Phase 0 |
| OTD-3 | Skill directories per harness are not listed by either CLI. A false `:missing` would block a valid run. | Resolve over a superset of known directories (`~/.pi/agent/skills`, `~/.omp/agent/skills`, `~/.claude/skills`, `~/.foreman/skills`, and `.pi/skills` / `.claude/skills` in the worktree) and block only when a skill is in none; accept that a false `:available` still fails later, as today. | Phase 0 |
| OTD-4 | `VfsIsolation` is a registry nothing queries and `bind_vfs` is fail-open. Remove it, enforce it, or leave it? | Leave it in Phase 0 (not required by any AC); the profile records the truth. File a follow-up for the owner of the host-sandbox decision in Phase 5. | Product owner |

## 12. Testing Plan

- Unit: aggregate, codec round-trip, projection, reconciler registry, `Effect`, `SkillResolver`, `ExecutionProfile`.
- Integration: restart-boundary suite, resume-attempt, recovery-budget durability, human-wait durability, effect crash-on-each-side tests, kickoff preflight tests.
- Mutation probes: each proof task has a `-TEST` sibling that names the mutation which must turn it red.
- Docker: `:docker`-tagged tests for AC-006-3 and AC-006-4, excluded from the default run.
- Gates: the architecture test (`event_store_enforcement_test.exs`) and codec tests must stay green with the three new events; one targeted file per task, then the full suite once per PR, in isolation and with `--seed` varied, because the suite is not yet seed-stable.

## 13. Rollout and Rollback

All changes are additive: three new events (`PhaseRetried` and `RunRecoveryAttempted` in PR 1, `PhaseContextRecorded` in PR 6), optional fields on one existing event (`PhaseStarted`), one new behaviour, one new profile module. Old streams replay unchanged (optional fields). Rollback is reverting a PR; a stream containing a new event type would then fail to decode on the older code, so the PR 1 and PR 6 events must not be written in production until the whole of that PR is deployed (events are only emitted by the code that registers them). The ETS `:boot_recon_dispatch_attempts` table is removed in TRD-003 with no migration, since its contents are intentionally transient.

## 14. Self-Review Findings

Architecture:
1. `PhaseStarted` gains three optional fields (`input_artifacts`, `prior_worktree_discarded`, `execution_profile`). A typed event with several optional fields is a smell. Kept, because splitting each into its own event multiplies commands and aggregate paths for data that is read together; revisit if a fourth field appears.
2. Boot-time dispatch of `run.recovery_attempt` must pass the system dispatch authorisation like other `BootReconciliation` commands (`safe_dispatch_system`); TRD-003 must use that path, not the operator gateway.
3. The `PhaseRetried` reuse crosses into `PRD-2026-af25d0cb` territory; OTD-1 records the boundary.

Coverage:
1. AC-006-3 is provable only on docker (OTD-2); the host door is explicitly unenforced, which AC-006-6 allows.
2. The "waiting on a human" restart boundary in TRD-006 overlaps TRD-009; they share fixtures, not assertions.

Dependency and estimate:
1. TRD-023 depends on seven tasks (depth > 3) by design: it is the last deliverable and cites their evidence.
2. TRD-003, TRD-013 and TRD-015 are the largest estimates (7h each) and the riskiest (new event plus aggregate path; two reconcilers that call out to GitHub; every `TaskProvider` callback). Estimates assume the injectable command runner and fake providers already used by existing tests.

## 15. Design Readiness Scorecard

| Dimension | Score | Basis |
|---|---:|---|
| Architecture completeness | 4 | Components, data flow and the three new events are defined; host filesystem confinement is deliberately out of scope (OTD-4). |
| Task coverage | 5 | All 30 PRD ACs map to a task and every implementation task has a `-TEST` sibling; verified by script. |
| Dependency clarity | 4 | Explicit and acyclic; TRD-023 has depth > 3 by design. |
| Estimate confidence | 3 | Three 7h tasks cross new-event, aggregate and external-call boundaries; docker proof depends on a local run. |

**Overall 4.0/5 — PASS.** Estimate confidence is the weak dimension; the three 7h tasks are the first candidates to split if their first spike runs long.
