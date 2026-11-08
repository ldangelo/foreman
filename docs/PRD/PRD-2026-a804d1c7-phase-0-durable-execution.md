---
document_id: PRD-2026-a804d1c7
label: prd-phase-0-durable-execution
version: 1.1.7
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
| REQ-006 | Make the executor isolation contract explicit and enforced | Must | High | 6 |
| REQ-007 | Preflight the capabilities a run needs | Should | Medium | 2 |

**Sizing note.** The series convention is 4–5 requirements per phase. Phase 0 has 7 because the v1.0.0 requirements bundled distinct observable behaviors (restart, human wait and effect reconciliation were one requirement; provenance and context identity another). Each REQ below states one behavior and names the proof that closes it. `scale_depth` stays STANDARD to match the other five phase PRDs and the umbrella, even though the count exceeds the series norm. Evidence cited here was read from source on 2026-11-08; the TRD must re-validate it (umbrella §Current baseline).

## 1. Executive Summary

Before Foreman adds more factory automation, it needs evidence that long-lived work recovers safely from process failure, restart and human wait states. Foreman already has most of the machinery: typed, `command_id`-deduplicated events; actors that rehydrate via `Aggregate.load/2`; `resume_from_index` skipping completed phases; question events; durable idempotency keys with a crash-recovery reconciler; and a fail-closed docker network policy. Filesystem confinement of a host agent is **not** among them (see §2). Phase 0 therefore **establishes and proves guarantees and closes the specific gaps below**; it is not a redesign.

The expected outcome is to extend the current engine. Temporal or Conductor are admissible only for a criterion the evidence shows cannot be closed in the current engine (umbrella §Portfolio sequencing). The phase does not implement the idea-to-PR lifecycle, risk-tiered merging, Kubernetes or external memory.

## 2. Users and Problem

* **Foreman operator:** needs runs to survive restarts and human waits without lost state or duplicated work.
* **Factory maintainer:** needs proof of the recovery guarantees before adding stages.
* **Project owner:** needs project context and execution boundaries to be explicit and auditable.

Verified gaps this PRD closes (source in each requirement):

* Crash reconciliation checks only PR association and worktrees, and `:side_effects_present` still allows a retry.
* Project-context identity (`sha256`, bytes, truncation, redactions) reaches only a log line and an optional archive file.
* Phases record their output artifact hash but not their inputs.
* A host (workflow-door) run cannot enforce a network policy, and nothing records that fact on the run.
* Filesystem confinement of a host agent is not enforced: `VfsIsolation.allowed?/2` has no caller outside its tests, `RunExecutor.bind_vfs/2` is fail-open, and `JidoShellRunner` is an in-memory mount whose own documentation says host commands run via `System.cmd` against the real filesystem.

## 3. Scope

### In scope

* Prove restart recovery, human-wait durability, retry exhaustion and run cancellation with automated tests; close gaps found.
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
Owns: restart/resume semantics, including durable attempt counting, the recovery re-dispatch limit and cancellation surviving a restart. Defers: slot/queue recovery to PRD-2026-d3051d4b and PRD-2026-0eac69b3; phase-level retry policy, its maximum-attempt setting and the `PhaseRetryExhausted` event to PRD-2026-af25d0cb, which is Draft and unimplemented, so phase-level retry exhaustion is a named blocking prerequisite on that PRD and not a Phase 0 guarantee.
Evidence: `Dispatcher.resume_from_index/2` (`dispatcher.ex:1052`) skips phases whose projection status is `completed`; `rehydrate_resume_context` fails with `:resume_context_unresolvable` when the base cannot be resolved (`run_executor.ex:719`) and, when no worktree entry exists for a resumed run, logs a warning and provisions a fresh worktree (`run_executor.ex:722`); tests under `test/foreman_server/idempotency/` and `workflow/dispatcher_crash_recovery_test.exs`. Retry limits and cancellation are not yet proven across a restart.
Evidence (attempts): `PhaseStarted.attempt` is hard-coded to `1` (`run_executor.ex:1286`), so a resumed phase never records a second attempt. No `PhaseRetrying` or `PhaseRetryExhausted` event exists. Recovery re-dispatch is capped at 5 by `RestartBackoff` (`idempotency/restart_backoff.ex`), but `BootReconciliation` counts attempts in the in-memory ETS table `:boot_recon_dispatch_attempts` (`boot_reconciliation.ex:71,1335`), so a restart resets the budget, and reaching the cap emits only a log line and telemetry (`boot_reconciliation.ex:1310-1331`) and deletes the counter.

* AC-002-1: Given a server restart at each boundary — before a phase starts, after `PhaseStarted` and before completion, after `PhaseCompleted` and before the next phase, while waiting on a human, and after the last phase and before the terminal event — when the service recovers, then status, artifact references and attempt are reconstructed from the event stream and no phase that has `PhaseCompleted` is launched again. One automated test per boundary fails if a completed phase relaunches.
* AC-002-2: Given a restart during an in-flight phase, when the run resumes, then orphaned agents of the earlier attempt are reaped before relaunch and the phase records its next attempt number, derived from its durable `PhaseStarted` history and not from process memory, visible on the run projection.
* AC-002-3: Given the resume base cannot be determined, when recovery runs, then the run ends with a typed reason and is never started from a guessed base.
* AC-002-4: Given a server restart, when recovery completes, then the time from boot to resumed-or-blocked is measured, recorded on the run and reported; the pass/fail threshold is set by the TRD's operating plan, not by this PRD.
* AC-002-5: Given a resumed run's worktree no longer exists, when recovery provisions a fresh one, then the run projection records that prior working-tree changes were not carried over and the warning names the discarded worktree path; the run is never silently restarted as if nothing was lost.
* AC-002-6: Given recovery has re-dispatched a run up to the `RestartBackoff` limit, when the server restarts, then the attempt count survives because it is derived from durable events, and a run that reached the limit stays blocked with a durable, operator-visible reason and is not re-dispatched with a fresh budget.
* AC-002-7: Given an operator cancels a run, when the cancel is processed and again after a later restart, then the run is in the terminal cancelled state (`RunCancelled` on the event stream) and recovery does not resume it; the agent has been signalled and the harness's SIGTERM/SIGKILL escalation is allowed to complete; and any process still alive afterwards is reaped by `Workflow.OrphanReaper` and is observable. "The agent is stopped" is asserted only after escalation and reaping, never at cancel time, because `Run.cancel/1` finalizes the run once it has signalled the agent.

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
Owns: deciding whether an external effect already happened, and blocking or retrying accordingly, for PR create, branch push and task-provider state change (claim, complete, fail, reopen, annotate). GitHub PR comment/review posting has no call site in `lib/` today; the phase that introduces it (Phase 1 risk comments) must register its reconciler before shipping, and AC-004-3 keeps it fail-closed until then. Defers: authoring task work-log comments to PRD-2026-3a76a0f0; retry policy and the default-safety rule for non-idempotent work (REQ-011, REQ-012) to PRD-2026-af25d0cb.
Evidence: keys move `started → completed | ambiguous | failed` (`idempotency/key_store.ex`); keys are written only around agent-phase dispatch by the Overwatch runner (`jobsite/runners/overwatch.ex:131`), and `AutoPR`, `PhasePR` and `PrCreate` (which run `git push` and `gh pr create`) never reference a key, so a crash during those effects leaves no ambiguous key at all; `CrashRecovery.has_no_side_effects?/1` checks only PR association and created worktrees, and `{:retry, :side_effects_present}` marks the key completed and **allows retry** (`idempotency/crash_recovery.ex:6`). `KeyStore` falls back to an in-process ETS table when the repo is not configured.

* AC-004-1: Given a crash leaves a key ambiguous for an effect class in the enumerated set — PR create, branch push, and task-provider state change — when recovery runs, then Foreman consults external truth for that class (the existing PR, the remote branch head, the provider's current state) before any retry; one automated test per class proves it.
* AC-004-2: Given reconciliation finds the effect already present or cannot establish the outcome, when recovery finishes, then the run blocks with an operator-visible reason and nothing is repeated.
* AC-004-3: Given an ambiguous key for an effect class that has no reconciler, when recovery runs, then it fails closed (blocks) and never retries.
* AC-004-4: Given a production configuration with the durable key store unavailable and the ETS fallback active, when the server boots, then it reports the idempotency store as non-durable instead of claiming crash safety.
* AC-004-5: Given an effect in the enumerated set is about to run, when it starts, then an intent key is durably recorded before the effect runs and marked completed or failed after it, so that a crash during the effect leaves an ambiguous key for recovery to reconcile; adding an effect class later requires registering its reconciler (AC-004-3).

### REQ-005: Record stage provenance and project-context identity

Priority: Must; Complexity: Medium. [RISK: later phases cannot prove which inputs produced an artifact or decision.]
Owns: extending the existing `ProjectionStore.phases_for_run/1` and `foreman_run_status` DTO. Defers: stall facts to `RunStallReported`; per-chunk redaction soundness to foreman-l30ao.5.
Evidence: `PhaseCompleted` carries `artifact_path`, `artifact_sha256`, `artifact_bytes`; `PhaseStarted` carries `attempt`; no input reference exists. The context bundle holds `sha256`, `bytes`, `truncated` and a redaction count, but `log_project_context` (`run_executor.ex:2379`) writes only a log line and `Review.Capture` writes only when archive capture is enabled.

* AC-005-1: Given a phase starts and completes, when the run is inspected through the existing projection and status DTO, then input artifact references (source phase, path, sha256), the output reference, attempt, timestamps and correlation identifiers are returned, with no second provenance store.
* AC-005-2: Given project context is built for a launch, when the launch is recorded, then included sections, `sha256`, bytes, truncation and redaction counts are on the durable event stream and readable after a restart.
* AC-005-3: Given a secret is split across output chunks, when provenance reports redaction, then it states what was applied and is never presented as proof that no secret was stored (`WorkerLogPolicy` redacts per chunk today).

### REQ-006: Make the executor isolation contract explicit and enforced

Priority: Must; Complexity: High. [RISK: a git worktree is mistaken for a security sandbox.]
Owns: the inspectable profile and the fail-closed rule. Defers: credential scoping to PRD-2026-aba4b79c.
Evidence (policy surface): `Aggregates.Project.Environment` accepts only the keys `vars`, `setup_script` and `network` (`@record_keys`), so a project can require a network policy but cannot require filesystem confinement; AC-006-2 therefore blocks on network only, and a host run is never blocked for filesystem in Phase 0, only recorded as unenforced (AC-006-6). The one real filesystem boundary is the docker jobsite's bind mount of the worktree.
Evidence: `NetworkPolicy` enforces `none` and `allowlist` on the **docker jobsite only** (`network_enforced_on/0`), returns `:network_policy_unsupported` for a non-default policy on the host sandbox, and sweeps orphans at boot; the workflow door runs agents on the server host and cannot enforce network policy. `VfsIsolation` keeps a per-agent registry of worktree roots and emits `[:foreman_server, :security, :vfs_denied]` from `allowed?/2`, but nothing in `lib/` calls `allowed?/2` (`run_executor.ex:4578` only binds, and a refused bind logs a warning and continues, `run_executor.ex:4559-4590`); `JidoShellRunner` does not confine real host commands (`jido_shell_runner.ex:84-97`). The harness pi profile uses `sandbox_mode: :read_only`. The TRD must establish which backend, if any, genuinely confines filesystem access.

* AC-006-1: Given an agent starts, when its execution profile is resolved, then the backend (docker jobsite or host workflow) and, for filesystem, network, credentials and cleanup, whether each property is enforced or unenforced-with-reason are recorded and inspectable after launch.
* AC-006-2: Given a project requires a network policy other than default and the selected backend cannot enforce it, when provisioning occurs, then the run is blocked before any agent code runs with a typed unsupported reason — on the workflow door as well as the jobsite.
* AC-006-3: Given a backend whose profile records filesystem as enforced, when an agent accesses a path outside its worktree roots, then the access is denied at an enforcement point (not only recorded in a registry) and a `vfs_denied` event is emitted; a negative test proves it.
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

Phase 0 exits only when every row below is demonstrably met. An unmet guarantee is either closed or named as a blocking prerequisite of the phase that depends on it.

| Later phase | Names as its Phase 0 prerequisite | Met by |
|---|---|---|
| Phase 1 (PR delivery) | durable run and provenance guarantees; execution capability | REQ-002, REQ-005, REQ-006 |
| Phase 3 (idea-to-spec) | durable stage state and provenance | REQ-002, REQ-005 |
| Phase 4 (operator interaction) | durable waits and provenance | REQ-003, REQ-005 |
| Phase 5 (scale/memory) | measured recovery and isolation results (umbrella row) | REQ-002, REQ-006 |

| Requirement | Depends on | Notes |
|---|---|---|
| REQ-001 | REQ-002…REQ-006 | Decision cites their outcomes; extend-by-default. |
| REQ-002 | Existing event/run architecture | Recovery tests must be order-independent: the shared `ProjectionStore` leaks state across tests and the suite is not yet seed-stable (`docs/lessons/run-logs-known-issues.md`), so a recovery test must isolate its own state. |
| REQ-003 | REQ-002 | Wait recovery reuses the resume path. |
| REQ-004 | REQ-002 | Reconciliation runs inside recovery. |
| REQ-005 | Existing projections | Extends, never duplicates, the run/phase projection (§5.7). |
| REQ-006 | Existing jobsite and workflow execution | Host-run limits become explicit, not hidden. |
| REQ-007 | Existing kickoff preflight | Extends the same seam. |

Exit also requires: the decision record exists; the REQ-002 boundary, recovery-attempt and cancellation tests, the REQ-003 tests, and one REQ-004 reconciliation test per enumerated effect class pass in isolation and in the full suite; stage provenance is inspectable through the existing status surface; and executor limitations are recorded on each run. Phase-level retry exhaustion is explicitly not an exit criterion; it is a prerequisite owned by PRD-2026-af25d0cb.

## 6. Open Decisions

No `[NEEDS CLARIFICATION]` markers remain. Decisions resolved in v1.1.1 (2026-11-08):

| Decision | Resolution | Where |
|---|---|---|
| Recovery-time target | Measure, record and report boot-to-resumed time; threshold set by the TRD operating plan | AC-002-4 |
| Resumed run with missing worktree | Provision a fresh worktree and record the loss | AC-002-5 |
| Effect classes reconciled | PR create, branch push, task-provider state change; PR comment/review post is deferred to the phase that first posts one, and stays fail-closed until its reconciler is registered | AC-004-1, AC-004-3 |
| Isolation policy | Block only when the project requires a policy the backend cannot enforce; otherwise record | AC-006-2, AC-006-5 |
| Skill preflight | Check the skill each `command:` names resolves in the harness's skill directories on a host run; report unverifiable (never available) elsewhere. `command:` is an agent slash command, not an executable | AC-007-1, AC-007-2 |

For the TRD to settle: the recovery-time threshold for boot-to-resumed-or-blocked (the existing 30s NFR-03 bounds only the reconcile decision layer). The phase-level maximum-attempt setting is not settled here: it stays owned by PRD-2026-af25d0cb. What Phase 0 makes durable is the phase attempt number (AC-002-2) and the recovery re-dispatch budget already capped at 5 by `RestartBackoff` (AC-002-6); these are two separate budgets.

## 7. Readiness Gate

* Completeness 5/5 — every Phase 0 outcome named by the umbrella and by Phases 1, 3 and 4 maps to a requirement, and the retry-limit and cancellation scope gap is closed; seven requirements (not five) is justified in the sizing note.
* Testability 4/5 — every AC names an observable event, field, typed error or test; the recovery-time threshold is left to the TRD operating plan.
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
