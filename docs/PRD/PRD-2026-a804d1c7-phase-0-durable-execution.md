---
document_id: PRD-2026-a804d1c7
label: prd-phase-0-durable-execution
version: 1.1.12
status: Draft
date: 2026-11-08
scale_depth: STANDARD
total_requirements: 7
total_acceptance_criteria: 30
readiness_score: 4.25
---

# PRD: Phase 0 — Durable Execution and Safety Foundation

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 6 |
| Should | 1 |
| Could | 0 |
| Won't (this phase) | 4 (listed under Out of scope, not numbered) |

| Metric | Value |
|---|---:|
| Requirement coverage | 7/7 have acceptance criteria (100%) |
| Risk flags | 7 |
| Cross-requirement dependencies | 7 |
| Open clarification markers | 0 |

| REQ | Description | Priority | Complexity | ACs |
|---|---|---|---|---:|
| REQ-001 | Record an evidence-backed engine decision | Must | High | 3 |
| REQ-002 | Resume runs across a restart without repeating completed work | Must | Medium | 7 |
| REQ-003 | Human waits survive restart and are answered once | Must | Medium | 4 |
| REQ-004 | Reconcile or block uncertain external effects | Must | High | 5 |
| REQ-005 | Record stage provenance and project-context identity | Must | Medium | 3 |
| REQ-006 | Make executor isolation explicit, enforced where the backend can enforce it, and recorded where it cannot | Must | High | 6 |
| REQ-007 | Preflight the capabilities a run needs | Should | Medium | 2 |

**Sizing note.** The series convention is 4–5 requirements per phase. Phase 0 has 7 because the v1.0.0 requirements bundled distinct observable behaviors (restart, human wait and effect reconciliation were one requirement; provenance and context identity another). Each REQ below states one behavior and names the proof that closes it. `scale_depth` stays STANDARD to match the other five phase PRDs and the umbrella, even though the count exceeds the series norm. Evidence cited here was read from source on 2026-11-08; the TRD must re-validate it (umbrella §Current baseline).

## 1. Executive Summary

Before Foreman adds more factory automation, it needs evidence that long-lived work recovers safely from process failure, restart and human wait states. Foreman already has most of the machinery: typed, `command_id`-deduplicated events; actors that rehydrate via `Aggregate.load/2`; `resume_from_index` skipping completed phases; question events; durable idempotency keys with a crash-recovery reconciler; and a fail-closed docker network policy. Filesystem confinement of a host agent is **not** among them (see §2). Phase 0 therefore **establishes and proves guarantees and closes the specific gaps below**; it is not a redesign.

The expected outcome is to extend the current engine. Temporal or Conductor are admissible only for a criterion the evidence shows cannot be closed in the current engine (umbrella §Portfolio sequencing). The phase does not implement the idea-to-PR lifecycle, risk-tiered merging, Kubernetes or external memory.

## 2. Users and Problem

* **Foreman operator:** needs runs to survive restarts and human waits without lost state or duplicated work.
* **Factory maintainer:** needs proof of the recovery guarantees before adding stages.
* **Project owner:** needs project context and execution boundaries to be explicit and auditable.

Verified gaps this PRD closes or records (source in each requirement):

* Crash reconciliation checks only PR association and worktrees, and `:side_effects_present` still allows a retry.
* Project-context identity (`sha256`, bytes, truncation, redactions) reaches only a log line and an optional archive file.
* Phases record their output artifact hash but not their inputs.
* Recorded, not closed: a host (workflow-door) run cannot enforce a network policy, and nothing records that fact on the run. Phase 0 records it on the run and blocks only when a project requires a policy (AC-006-2, AC-006-5).
* Recorded, not closed for a host run: filesystem confinement of a host agent is not enforced: `VfsIsolation.allowed?/2` has no caller outside its tests, `RunExecutor.bind_vfs/2` is fail-open, and `JidoShellRunner` is an in-memory mount whose own documentation says host commands run via `System.cmd` against the real filesystem. Phase 0 records it as unenforced (AC-006-6); the docker jobsite's bind mount is the one real boundary (AC-006-3).

The umbrella constraint (PRD-2026-b7c2e941, Shared product constraints) says `Execution isolation must be explicit and enforced`. Phase 0 makes isolation explicit everywhere and enforces it where the backend can enforce it; the host workflow door cannot enforce network or filesystem confinement, so it is an explicit, recorded exception to that constraint, not a closed gap.

## 3. Scope

### In scope

* Prove restart recovery, human-wait durability, durable exhaustion of the boot cleanup of orphaned run slots (the recovery re-dispatch limit) and run cancellation with automated tests; close gaps found. Phase-level retry exhaustion stays with PRD-2026-af25d0cb.
* Extend existing projections and events with stage input references and context identity. Do not add a parallel store.
* Make the isolation profile of each launch inspectable, and block runs whose required properties the backend cannot enforce.
* Extend run-admission preflight to the harnesses and the skills named by `command:` phases a run needs.
* Record the engine decision with evidence and migration/rollback implications.

### Out of scope (Won't, this phase)

* Replacing the orchestration engine, or adopting Temporal or Conductor by implication.
* A new workflow-manifest key for declaring tools or skills. `PhaseSpec.@fields` is a closed vocabulary; adding one needs its own approved change with Interpreter validation and docs.
* Kubernetes, horizontal scale-out, `kata` or `herdr` as isolation backends. Neither is a filesystem or network sandbox.
* Auto-merge, idea cultivation, external memory, and inbound chat adapters (Phases 2–5).

## 4. Requirements

Each requirement states what it **owns** and what it **defers** to an existing PRD, so Phase 0 does not become a second owner of the same behavior.

### REQ-001: Record an evidence-backed engine decision

Priority: Must; Complexity: High. [RISK: an unsupported decision causes needless migration, or ships known recovery gaps.]
Owns: the decision record. Defers: criteria themselves to REQ-002…REQ-006.

* AC-001-1: Given REQ-002…REQ-006 criteria, when Phase 0 exits, then a decision record maps each criterion to source and test evidence with a pass/fail result and any remaining gap.
* AC-001-2: Given a criterion fails and cannot be closed in the current engine, when the decision is recorded, then it names that criterion, compares extending the engine with Temporal and Conductor, and states migration, operational and rollback cost.
* AC-001-3: Given every criterion passes or is closed, when Phase 0 exits, then the record states "extend the current engine" and lists no adoption work.

### REQ-002: Resume runs across a restart without repeating completed work

Priority: Must; Complexity: Medium. [RISK: duplicate phase execution corrupts repository state.]
Owns: restart/resume semantics, including durable attempt counting, the durable recovery re-dispatch limit on the boot cleanup of orphaned run-slot entries (the budget only, not slot or queue recovery itself) and cancellation surviving a restart. Defers: slot/queue recovery to PRD-2026-d3051d4b and PRD-2026-0eac69b3; phase-level retry policy, its maximum-attempt setting and the `PhaseRetryExhausted` event to PRD-2026-af25d0cb, which is Draft and unimplemented, so phase-level retry exhaustion is a named blocking prerequisite on that PRD and not a Phase 0 guarantee.
Evidence: `Dispatcher.resume_from_index/2` (`dispatcher.ex:1052`) skips phases whose projection status is `completed`; `rehydrate_resume_context` (`run_executor.ex:719`) returns `{:error, reason}` when the base cannot be resolved (`resolve_run_base`, `run_executor.ex:734`) or an orphaned agent survives SIGKILL, and the caller ends the run with the 2-tuple `{:resume_context_unresolvable, reason}` (`run_executor.ex:466`); when no worktree entry exists for a resumed run it logs a warning and provisions a fresh worktree (`run_executor.ex:723`); tests under `test/foreman_server/idempotency/` and `workflow/dispatcher_crash_recovery_test.exs`. Retry limits and cancellation are not yet proven across a restart.
Evidence (attempts): `PhaseStarted.attempt` is hard-coded to `1` (`run_executor.ex:1286`), so a resumed phase never records a second attempt. The Phase aggregate defines a `PhaseRetried` event and a `phase.retry` command that increments the attempt (`aggregates/phase.ex:50,89`), but nothing in `lib/` dispatches `phase.retry`, and no `PhaseRetrying` or `PhaseRetryExhausted` event exists. Recovery re-dispatch is capped at 5 by `RestartBackoff` (`idempotency/restart_backoff.ex`), but `BootReconciliation` counts attempts in the in-memory ETS table `:boot_recon_dispatch_attempts` (`boot_reconciliation.ex:71,1335`), so a restart resets the budget, and reaching the cap emits only a log line and telemetry (`boot_reconciliation.ex:1310-1331`) and deletes the counter. That counter guards only the release of an orphaned run-slot holder and the removal of an orphaned run-slot waiter (`release_run_slot/2` and `remove_run_slot_waiter/2`, the only callers of `handle_dispatch_failure/4`, `boot_reconciliation.ex:873,904,1294`), which boot dispatches only for a run that is absent from the projection or already terminal (`run_absent_or_terminal?/1`, `boot_reconciliation.ex:812,823,836-843`). It never re-dispatches a live run, and a terminal run rejects `run.block` (`aggregates/run.ex:766-771,1348-1349`), so no run can be blocked by it. The global run-slot stream (`run_slots:global`, `aggregates/run_slots.ex`) always exists and survives a restart.

* AC-002-1: Given a server restart at each boundary — before a phase starts, after `PhaseStarted` and before completion, after `PhaseCompleted` and before the next phase, while waiting on a human, and after the last phase and before the terminal event — when the service recovers, then status, artifact references and attempt are reconstructed from the event stream and no phase that has `PhaseCompleted` is launched again. One automated test per boundary fails if a completed phase relaunches.
* AC-002-2: Given a restart during an in-flight phase, when the run resumes, then orphaned agents of the earlier attempt are reaped before relaunch and the phase records its next attempt number, derived from its durable `PhaseStarted` and `PhaseRetried` history (`PhaseRetried` is the increment) and not from process memory, visible on the run projection.
* AC-002-3: Given the resume base cannot be determined, when recovery runs, then the run ends with a typed reason and is never started from a guessed base.
* AC-002-4: Given a server restart, when a run is resumed, then the time from boot to its resumption is measured, recorded on the run and reported; a run that recovery blocks (only a run that is not terminal can be blocked, REQ-004) records the time from boot to the block the same way; the boot cleanup of an orphaned run-slot entry is neither a resumption nor a block and is outside this measure (AC-002-6). Phase 0 sets no pass/fail threshold on it (the existing 30s NFR-03 bounds only the reconcile decision layer), so the recorded values are the evidence a later phase uses to choose one.
* AC-002-5: Given a resumed run's worktree no longer exists (its directory is gone, or no worktree entry survives), when recovery provisions a fresh one, then the run projection records that prior working-tree changes were not carried over and the warning names the discarded worktree by name, and by path when an entry still recorded one; the run is never silently restarted as if nothing was lost.
* AC-002-6: Given boot cleanup of an orphaned run-slot holder or waiter (one whose run is absent or already terminal) has failed up to the `RestartBackoff` limit, when the server restarts, then the consecutive-failure count survives because it is derived from durable events on the global run-slot stream, and an entry that reached the limit is recorded as exhausted with a durable reason that an operator can read in the log, in telemetry and in the queue status, and is not re-dispatched with a fresh budget by restart or re-sweep. The count is cleared when a later dispatch succeeds or when the entry leaves the stream by any route (an exhausted entry is skipped by boot, so it clears only when another release path removes it); Phase 0 adds no operator verb to re-arm an exhausted entry. A run that is not terminal is unaffected: the budget caps slot cleanup, not a run, and no run is blocked by it.
* AC-002-7: Given an operator cancels a run, when the cancel is processed and again after a later restart, then the run is in the terminal cancelled state (`RunCancelled` on the event stream) and recovery does not resume it; the agent has been signalled and the harness's SIGINT, SIGTERM and SIGKILL escalation is allowed to complete; and any process still alive afterwards is reaped by `Workflow.OrphanReaper` and is observable. "The agent is stopped" is asserted only after escalation and reaping, never at cancel time, because `Run.cancel/1` finalizes the run once it has signalled the agent.

### REQ-003: Human waits survive restart and are answered once

Priority: Must; Complexity: Medium. [RISK: a lost or doubled decision resumes the wrong stage.]
Owns: wait durability. Defers: the merge gate (operator-only, SHA-pinned) and chat-channel delivery to Phase 1 and Phase 4.
Evidence: `QuestionOpened`, `QuestionAnswered`, `QuestionExpired`, `QuestionAnswerUndelivered` are typed events; the actor answers a repeated `command_id` with the first result instead of appending (`aggregate/actor.ex:864`).

* AC-003-1: Given a run waiting on an unanswered question, when the server restarts, then the question is still pending and listed, and only the matching run resumes when it is answered.
* AC-003-2: Given an answer is re-submitted with the same `command_id` after a restart, when it reaches the server, then the first result is returned as an idempotent success and no second `QuestionAnswered` is appended.
* AC-003-3: Given a second answer with a different `command_id` arrives for an already-answered question, when it reaches the server, then it is rejected with a typed not-pending error, exactly one `QuestionAnswered` exists, and the run resumes once.
* AC-003-4: Given a question expires while the server is down, when it boots, then expiry is recorded once and the run follows its configured policy rather than being asked again silently.

### REQ-004: Reconcile or block uncertain external effects

Priority: Must; Complexity: High. [RISK: blindly repeating a push, PR create or provider change after a crash duplicates or corrupts external state. Three reconcilers touch three different code paths, and the task-provider class reaches every `TaskProvider` adapter.]
Owns: deciding whether an external effect already happened, and blocking or retrying accordingly, for PR create, branch push and task-provider state change (claim, complete, fail, reopen). `annotate` is not in the set and is deferred: a repeated annotation is a duplicate comment, not corrupted external state; its live callers (`mcp/tools.ex:3175`, `review/bead_sink.ex:134`) are operator and review paths outside recovery re-entry; and work-log authoring stays with PRD-2026-3a76a0f0. If an annotate effect is ever keyed without a reconciler it fails closed under AC-004-3. GitHub PR comment/review posting has no call site in `lib/` today; the phase that introduces it (Phase 1 risk comments) must register its reconciler before shipping, and AC-004-3 keeps it fail-closed until then. Defers: authoring task work-log comments to PRD-2026-3a76a0f0; retry policy and the default-safety rule for non-idempotent work (REQ-011, REQ-012) to PRD-2026-af25d0cb.
Evidence: keys move `started → completed | ambiguous | failed` (`idempotency/key_store.ex`); keys are written only around agent-phase dispatch by the Overwatch runner (`jobsite/runners/overwatch.ex:131`), and `AutoPR`, `PhasePR` and `PrCreate` (which run `git push` and `gh pr create`) never reference a key, so a crash during those effects leaves no ambiguous key at all; `CrashRecovery.has_no_side_effects?/1` checks only PR association and created worktrees, and `{:retry, :side_effects_present}` marks the key completed and **allows retry** (`idempotency/crash_recovery.ex:6`). `KeyStore` falls back to an in-process ETS table when the repo is not configured.

* AC-004-1: Given a crash leaves a key ambiguous for an effect class in the enumerated set — PR create, branch push, and task-provider state change (claim, complete, fail, reopen) — when recovery runs, then Foreman consults external truth for that class before any retry: the existing PR; for a push, the remote branch head, meaning the remote ref's commit SHA compared with the two SHAs recorded in the effect's intent key before the push (the remote SHA before the push and the local SHA being pushed), where equal to the pushed SHA means the push landed, equal to the pre-push SHA means it did not, and anything else is unknown; and the provider's current state. One automated test per class proves it, and the push test covers all three outcomes.
* AC-004-2: Given reconciliation finds the effect already present or cannot establish the outcome, when recovery finishes, then nothing is repeated and the operator can see which effect to inspect: a run that is not terminal blocks with an operator-visible reason; a run that is already terminal cannot be blocked, so its verdict is logged and counted in telemetry, the effect key stays unresolved (`ambiguous`), and the operator health report (`foreman_doctor`) lists that key with its effect class, identity and run id.
* AC-004-3: Given an ambiguous key for an effect class that has no reconciler, when recovery runs, then it fails closed as AC-004-2 describes (blocks a run that is not terminal; surfaces the key for a terminal run) and never retries.
* AC-004-4: Given a production configuration with the durable key store unavailable and the ETS fallback active, when the server boots, then it reports the idempotency store as non-durable instead of claiming crash safety.
* AC-004-5: Given an effect in the enumerated set is about to run, when it starts, then an intent key is durably recorded before the effect runs and marked completed or failed after it, so that a crash during the effect leaves an ambiguous key for recovery to reconcile; adding an effect class later requires registering its reconciler (AC-004-3).

### REQ-005: Record stage provenance and project-context identity

Priority: Must; Complexity: Medium. [RISK: later phases cannot prove which inputs produced an artifact or decision.]
Owns: extending the existing `ProjectionStore.phases_for_run/1` and `foreman_run_status` DTO. Defers: stall facts to `RunStallReported`; per-chunk redaction soundness to foreman-l30ao.5.
Evidence: `PhaseCompleted` carries `artifact_path`, `artifact_sha256`, `artifact_bytes`; `PhaseStarted` carries `attempt`; no input reference exists. The context bundle holds `sha256`, `bytes`, `truncated` and a redaction count, but `log_project_context` (`run_executor.ex:2379`) writes only a log line and `Review.Capture` writes only when archive capture is enabled.

* AC-005-1: Given a phase starts and completes, when the run is inspected through the existing projection and status DTO, then input artifact references (source phase, path, sha256), the output reference, attempt, timestamps and correlation identifiers are returned, with no second provenance store.
* AC-005-2: Given project context is built for a launch, when the launch is recorded, then included sections, `sha256`, bytes, truncation and redaction counts are on the durable event stream and readable after a restart.
* AC-005-3: Given project context is built for a launch, when provenance reports redaction, then it states the redaction count that was applied to the project context and does not present that count as proof that no secret was stored. Split-chunk and per-chunk worker-output redaction soundness (`WorkerLogPolicy` redacts per chunk today) is not claimed here; it stays deferred to foreman-l30ao.5 (see this requirement's Defers line).

### REQ-006: Make executor isolation explicit, enforced where the backend can enforce it, and recorded where it cannot

Priority: Must; Complexity: High. [RISK: a git worktree is mistaken for a security sandbox.]
Owns: the inspectable profile and the fail-closed rule. The host workflow door cannot enforce network or filesystem confinement, so it is an explicit, recorded exception to the umbrella constraint `Execution isolation must be explicit and enforced` (PRD-2026-b7c2e941, Shared product constraints), not a closed gap. Defers: credential scoping to PRD-2026-aba4b79c.
Evidence (policy surface): `Aggregates.Project.Environment` accepts only the keys `vars`, `setup_script` and `network` (`@record_keys`), so a project can require a network policy but cannot require filesystem confinement; AC-006-2 therefore blocks on network only, and a host run is never blocked for filesystem in Phase 0, only recorded as unenforced (AC-006-6). The one real filesystem boundary is the docker jobsite's bind mount of the worktree.
Evidence: `NetworkPolicy` enforces `none` and `allowlist` on the **docker jobsite only** (`network_enforced_on/0`), returns `:network_policy_unsupported` for a non-default policy on the host sandbox, and sweeps orphans at boot; the workflow door runs agents on the server host and cannot enforce network policy. `VfsIsolation` keeps a per-agent registry of worktree roots and emits `[:foreman_server, :security, :vfs_denied]` from `allowed?/2`, but nothing in `lib/` calls `allowed?/2` (`run_executor.ex:4578` only binds, and a refused bind logs a warning and continues, `run_executor.ex:4559-4590`); `JidoShellRunner` does not confine real host commands (`jido_shell_runner.ex:84-97`). The harness pi profile uses `sandbox_mode: :read_only`. The TRD must establish which backend, if any, genuinely confines filesystem access.

* AC-006-1: Given an agent starts, when its execution profile is resolved, then the backend (docker jobsite or host workflow) and, for filesystem, network, credentials and cleanup, whether each property is enforced or unenforced-with-reason are recorded and inspectable after launch.
* AC-006-2: Given a project requires a network policy other than default and the selected backend cannot enforce it, when provisioning occurs, then the run is blocked before any agent code runs with a typed unsupported reason. This is a check at the workflow door; the docker jobsite always enforces `none` and `allowlist`.
* AC-006-3: Given a backend whose profile records filesystem as enforced (in Phase 0, only the docker jobsite's bind mount of the worktree), when an agent reads a path outside its worktree, then the read fails on that backend, and a negative test on the docker jobsite proves it. A `vfs_denied` event is required only where Foreman itself mediates the access through `VfsIsolation.allowed?/2`; no Phase 0 backend routes access through it, so none is expected on the docker path.
* AC-006-4: Given a jobsite ends by any route, including a server crash, when cleanup runs or the server next boots, then its containers and network are removed.
* AC-006-5: Given a project sets no network policy and the run executes on the host workflow backend, when it launches, then the run proceeds and its profile records network as unenforced with the reason; this case is recorded, never blocked.
* AC-006-6: Given a backend with no filesystem enforcement point, when the profile is resolved, then filesystem is recorded as unenforced with the reason and is never reported as enforced.

### REQ-007: Preflight the capabilities a run needs

Priority: Should; Complexity: Medium. [RISK: a run starts without a harness or skill it needs and fails midway.]
Owns: harness and skill availability at admission. Defers: model and provider-catalog preflight to PRD-2026-44b49f94 (Locked).
Evidence: `kickoff_preflight/1` (`run_executor.ex:424`) already runs before the task claim and the first phase; it checks provider readiness (`ReadinessCheck.installed?/1`, `run_executor.ex:825`) and models. A `command:` phase is an agent slash command such as `/skill:ensemble-create-prd {{input.prompt}} --foreman` sent to the harness (`workflow/lowering.ex:134`), not a shell executable, and `bash:` phases are refused at lowering (`lowering.ex:125`). `Workflow.Validator` checks the named skill only against a hard-coded `@known_skills` list at manifest load (`workflow/validator.ex:15,117`), which says nothing about whether the harness can resolve it. Neither `pi` nor `claude` lists skills; both discover them from directories (for pi, `~/.pi/agent/skills/<name>/SKILL.md`). No manifest field declares tools or skills.

* AC-007-1: Given a run is admitted, when kickoff preflight runs, then it reports available and missing capabilities for the harness providers the workflow uses and, for each `command:` phase that names a skill, whether that skill resolves in the harness's skill directories on the host that will run it; on a backend where Foreman cannot see the execution environment (a docker jobsite image) the skill is reported as unverifiable and never as available.
* AC-007-2: Given a required harness is not installed, or a `command:` phase's skill does not resolve on a host run, when preflight finishes, then the run ends before the task claim, worktree creation or first phase with a typed reason naming the phase, the missing capability and the backend it was checked against; an unverifiable skill is recorded and does not block.

## 5. Dependencies and Exit Criteria

Phase 0 exits when all 30 acceptance criteria pass, or each failing criterion is named in the decision record together with the resulting engine decision (AC-001-2, AC-001-3). A criterion passes only when its test passes in isolation and in the full suite; a test that needs an environment the default run excludes (the `:docker`-tagged tests for AC-006-3 and AC-006-4, excluded by `test_helper.exs`) counts as passing when it passes in a run that includes its tag, and the decision record states how and when that run was made. The table below maps later phases to the requirements that meet the prerequisite each one names; it adds no exit condition.

| Later phase | Names as its Phase 0 prerequisite | Met by |
|---|---|---|
| Phase 1 (PR delivery) | durable run and provenance guarantees; execution capability | REQ-002, REQ-004, REQ-005, REQ-006 |
| Phase 3 (idea-to-spec) | durable stage state and provenance | REQ-002, REQ-005 |
| Phase 4 (operator interaction) | durable waits and provenance | REQ-003, REQ-005 |
| Phase 5 (scale/memory) | The umbrella lists only "Phase 0; independent decision gates" and the Phase 5 PRD names no specific Phase 0 guarantee; Phase 0 supplies measured recovery and recorded isolation results | REQ-002, REQ-006 |

| Requirement | Depends on | Notes |
|---|---|---|
| REQ-001 | REQ-002…REQ-006 | Decision cites their outcomes; extend-by-default. |
| REQ-002 | Existing event/run architecture | Recovery tests must be order-independent: the shared `ProjectionStore` leaks state across tests and the suite is not yet seed-stable (`docs/lessons/run-logs-known-issues.md`), so a recovery test must isolate its own state. |
| REQ-003 | REQ-002 | Wait recovery reuses the resume path. |
| REQ-004 | REQ-002 | Reconciliation runs inside recovery. |
| REQ-005 | Existing projections | Extends, never duplicates, the run/phase projection (AGENTS.md §5.7). |
| REQ-006 | Existing jobsite and workflow execution | Host-run limits become explicit, not hidden. |
| REQ-007 | Existing kickoff preflight | Extends the same seam. |

The exit rule is the one at the top of this section. Phase-level retry exhaustion is not one of the 30 criteria; it is a prerequisite owned by PRD-2026-af25d0cb.

## 6. Open Decisions

No `[NEEDS CLARIFICATION]` markers remain. Decisions resolved in v1.1.1 (2026-11-08), as amended through v1.1.12:

| Decision | Resolution | Where |
|---|---|---|
| Recovery-time target | Measure, record and report boot-to-resumed time for a resumed run, and boot-to-blocked time only for a run that recovery can block; no pass/fail threshold in Phase 0 | AC-002-4 |
| Resumed run with missing worktree | Provision a fresh worktree and record the loss | AC-002-5 |
| Effect classes reconciled | PR create, branch push, task-provider state change (claim, complete, fail, reopen). `annotate` is deferred (a repeated annotation is a duplicate comment, its callers are outside recovery re-entry, and work-log authoring stays with PRD-2026-3a76a0f0). PR comment/review post is deferred to the phase that first posts one, and stays fail-closed until its reconciler is registered | AC-004-1, AC-004-3 |
| Isolation policy | Block only when the project requires a policy the backend cannot enforce; otherwise record. The host workflow door is an explicit, recorded exception to the umbrella's "explicit and enforced" constraint | AC-006-2, AC-006-5 |
| Skill preflight | Check the skill each `command:` names resolves in the harness's skill directories on a host run; report unverifiable (never available) elsewhere. `command:` is an agent slash command, not an executable | AC-007-1, AC-007-2 |

Not settled here: the phase-level maximum-attempt setting stays owned by PRD-2026-af25d0cb. What Phase 0 makes durable is the phase attempt number (AC-002-2) and the recovery re-dispatch budget already capped at 5 by `RestartBackoff` on the boot cleanup of orphaned run-slot entries (AC-002-6); these are two separate budgets. An exhausted slot entry is not a blocked run, and Phase 0 gives it no operator re-arm verb: it clears when the entry leaves the stream. The recovery-time question is closed: it is measured and reported, not gated.

## 7. Readiness Gate

* Completeness 5/5 — every Phase 0 outcome named by the umbrella and by Phases 1, 3 and 4 maps to a requirement (Phase 5 names none), and the retry-limit and cancellation scope gap is closed; seven requirements (not five) is justified in the sizing note.
* Testability 4/5 — every AC names an observable behaviour (event, field, typed error, test or recorded value); the TRD fixes the channel through which the report-style ACs (AC-004-4, AC-006-1, AC-007-1) are observed. Recovery time is measured and reported with no pass/fail threshold, so AC-002-4 is verified by the recorded value existing, not by a limit.
* Clarity 4/5 — ownership lines separate Phase 0 from six existing PRDs; no open markers remain.
* Feasibility 4/5 — each requirement extends a named existing seam; REQ-004 (three reconcilers) and REQ-006 need cross-backend work.

**Overall 4.25/5 — PASS (was 4.0).** This PRD authorizes Phase 0 refinement only, not an engine replacement.

## 8. Changelog

| Version | Date | Changes |
|---|---|---|
| 1.0.0 | 2026-11-08 | Initial draft: 5 requirements, 12 ACs. |
| 1.1.0 | 2026-11-08 | Split into 7 single-behavior requirements (23 ACs); added source evidence, ownership lines, later-phase prerequisite map; narrowed preflight scope. |
| 1.1.0+ | 2026-11-08 | Split AC-003-2 into idempotent replay (AC-003-2) and different-`command_id` rejection (AC-003-3); expiry renumbered AC-003-4 (24 ACs). |
| 1.1.1 | 2026-11-08 | Refinement: resolved all five clarification markers; added AC-002-5 (missing worktree), AC-002-6 (retry exhaustion), AC-002-7 (cancellation), AC-006-5 (host run with no policy); enumerated effect classes in AC-004-1; `command:` executables in AC-007-1 (28 ACs). Readiness 4.0 → 4.25. |
| 1.1.2 | 2026-11-08 | Review fixes: AC-002-7 no longer asserts a synchronous agent stop (cancel finalizes at SIGINT; escalation and orphan reaping follow); AC-007-1/2 resolve executables in the phase's execution environment and name the backend; REQ-004 ownership scoped to reconciliation with retry policy deferred to PRD-2026-af25d0cb; REQ-007 (Should) removed from the Phase 1 prerequisite row; sizing note states the `scale_depth` choice. 28 ACs. |
| 1.1.3 | 2026-11-08 | Correction found while preparing the TRD: filesystem confinement of a host agent is not enforced (`VfsIsolation.allowed?/2` is never called; bind is fail-open; the shell runner is an in-memory mount). Removed the "worktree-scoped VFS guard" from the existing-machinery list; rewrote REQ-006 evidence; AC-006-3 now applies to a backend that records filesystem as enforced; added AC-006-6 (unenforced is recorded, never reported as enforced). 29 ACs. |
| 1.1.4 | 2026-11-08 | Retry scope and effect-design decisions applied. `PhaseStarted.attempt` is hard-coded to 1 and no retry events exist, so AC-002-2 now requires attempts derived from durable history; AC-002-6 is rewritten around the real gap (the recovery re-dispatch counter is in-memory and a block is log-only, so a restart resets the budget); phase-level retry exhaustion is a named prerequisite on PRD-2026-af25d0cb, not a Phase 0 guarantee. REQ-004: push, PR create, PR comment and provider effects hold no idempotency key today, so AC-004-5 requires an intent key written before each effect, and the evidence line says so. 30 ACs. |
| 1.1.5 | 2026-11-08 | Effect set narrowed from four classes to three. A search of `lib/` finds no `gh pr comment`/review post or any other PR comment call site, so a PR-comment reconciler would have nothing to reconcile and would be a stub. The enumerated set is now PR create, branch push and task-provider state change; the future PR-comment class is covered by AC-004-3 (fail closed with no reconciler) and must register its reconciler when Phase 1 adds the effect. 30 ACs. |
| 1.1.6 | 2026-11-08 | REQ-007 premise corrected. A `command:` phase is an agent slash command (`/skill:<name> ...`) and `bash:` phases are refused at lowering, so there is no executable to resolve on PATH. AC-007-1/2 now check that the named skill resolves in the harness's skill directories on a host run, and report it unverifiable on a backend whose environment Foreman cannot see; skill-name validation against the hard-coded `@known_skills` list stays with `Workflow.Validator`. 30 ACs. |
| 1.1.7 | 2026-11-08 | Review corrections. §6 no longer calls the maximum-attempt question closed: the phase-level setting stays with PRD-2026-af25d0cb, and the two durable budgets (phase attempt, recovery re-dispatch) are named separately. REQ-006 states that `Environment` has a closed key set, so no project can require filesystem confinement today. 30 ACs. |
| 1.1.8 | 2026-11-08 | Closed a dangling dependency. AC-002-4, §6 and the Readiness Gate deferred the recovery-time threshold to a TRD "operating plan" that no document contained. Phase 0 now only measures, records and reports boot-to-resumed-or-blocked time and sets no threshold. 30 ACs. |
| 1.1.9 | 2026-11-08 | Reviewer findings applied after source spot-check. AC-002-6: a run at the recovery limit is not re-armed by restart or recovery; operator `run.reset` is the one deliberate re-arm, recorded by `RunReset`. AC-002-2: attempt derived from `PhaseStarted` and `PhaseRetried` history. §3: "retry exhaustion" is "recovery re-dispatch exhaustion". Effect set: `annotate` removed from the enumerated set and recorded as deferred; state changes are claim, complete, fail, reopen. AC-004-1 defines "remote branch head" as the remote ref compared with both the pre-push remote SHA and the pushed local SHA recorded in the intent key (landed, not landed, unknown), and the push test covers all three. AC-005-3 narrowed to project-context redaction (per-chunk soundness stays with foreman-l30ao.5). AC-006-2 is a workflow-door check; AC-006-3 requires a negative read test on the docker jobsite and a `vfs_denied` event only where `VfsIsolation.allowed?/2` mediates access. REQ-006 retitled and §2 records the host workflow door as an exception to the umbrella constraint. §5 has one exit rule (all 30 ACs pass, or each failing AC is named with its engine decision), and the old exit-test list is removed; Phase 1 row adds REQ-004; Phase 5 row no longer cites an umbrella row that does not exist. §7 testability claim softened. Corrected the `{:resume_context_unresolvable, reason}` evidence and `AGENTS.md §5.7` citation. 30 ACs. |
| 1.1.10 | 2026-11-09 | §5 exit rule: a test the default run excludes (the `:docker`-tagged tests for AC-006-3 and AC-006-4) passes when it passes in a run that includes its tag, and the decision record states how and when that run was made. Under the earlier wording those two criteria could never pass. 30 ACs. |
| 1.1.11 | 2026-11-09 | AC-004-2 and AC-004-3 scoped to what the system can do. `run.block` is rejected for a terminal run, and a boot `reopen`'s run is usually terminal, so "the run blocks" could not hold there. A run that is not terminal still blocks with an operator-visible reason; for a terminal run the verdict is logged and counted in telemetry, the key stays `ambiguous` so nothing is repeated, and the doctor report lists the key with its class, identity and run id (the verdict itself is not stored). 30 ACs. |
| 1.1.12 | 2026-11-10 | AC-002-6 and AC-002-4 scoped to what the system can do: the same terminal-run defect as 1.1.11. The recovery re-dispatch limit (`RestartBackoff`, 5) guards only the boot release of an orphaned run-slot holder or waiter, whose run is absent or already terminal, so no run is ever blocked by it (an absent run has no aggregate, and `run.block` is rejected for a terminal run, `aggregates/run.ex:766-771,1348-1349`) and the durable count cannot live on a run. AC-002-6 now makes the count durable on the global run-slot stream and records an exhausted entry (log, telemetry, queue status) instead of a blocked run; the `run.reset` re-arm is dropped, because it applied only to a blocked run. AC-002-4 measures boot-to-resumed time for a resumed run and boot-to-blocked time only for a run recovery can block (REQ-004). Every other criterion is unchanged. 30 ACs. |
