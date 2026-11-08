---
document_id: PRD-2026-a804d1c7
label: prd-phase-0-durable-execution
version: 1.1.0
status: Draft
date: 2026-11-08
scale_depth: STANDARD
total_requirements: 7
total_acceptance_criteria: 24
readiness_score: 4.0
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
| Open clarification markers | 5 |

| REQ | Description | Priority | Complexity | ACs |
|---|---|---|---|---:|
| REQ-001 | Record an evidence-backed engine decision | Must | High | 3 |
| REQ-002 | Resume runs across a restart without repeating completed work | Must | Medium | 4 |
| REQ-003 | Human waits survive restart and are answered once | Must | Medium | 4 |
| REQ-004 | Reconcile or block uncertain external effects | Must | High | 4 |
| REQ-005 | Record stage provenance and project-context identity | Must | Medium | 3 |
| REQ-006 | Make the executor isolation contract explicit and enforced | Must | High | 4 |
| REQ-007 | Preflight the capabilities a run needs | Should | Medium | 2 |

**Sizing note.** The series convention is 4–5 requirements per phase. Phase 0 has 7 because the v1.0.0 requirements bundled distinct observable behaviors (restart, human wait and effect reconciliation were one requirement; provenance and context identity another). Each REQ below states one behavior and names the proof that closes it. Evidence cited here was read from source on 2026-11-08; the TRD must re-validate it (umbrella §Current baseline).

## 1. Executive Summary

Before Foreman adds more factory automation, it needs evidence that long-lived work recovers safely from process failure, restart and human wait states. Foreman already has most of the machinery: typed, `command_id`-deduplicated events; actors that rehydrate via `Aggregate.load/2`; `resume_from_index` skipping completed phases; question events; durable idempotency keys with a crash-recovery reconciler; a worktree-scoped VFS guard; and a fail-closed docker network policy. Phase 0 therefore **establishes and proves guarantees and closes the specific gaps below**; it is not a redesign.

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

## 3. Scope

### In scope

* Prove restart recovery, human-wait durability and retry limits with automated tests; close gaps found.
* Extend existing projections and events with stage input references and context identity. Do not add a parallel store.
* Make the isolation profile of each launch inspectable, and block runs whose required properties the backend cannot enforce.
* Extend run-admission preflight to the capabilities a run needs.
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
Owns: restart/resume semantics. Defers: slot/queue recovery to PRD-2026-d3051d4b and PRD-2026-0eac69b3.
Evidence: `Dispatcher.resume_from_index/2` (`dispatcher.ex:1052`) skips phases whose projection status is `completed`; `rehydrate_resume_context` fails with `:resume_context_unresolvable` when the base cannot be resolved (`run_executor.ex:719`); tests under `test/foreman_server/idempotency/` and `workflow/dispatcher_crash_recovery_test.exs`.

* AC-002-1: Given a server restart at each boundary — before a phase starts, after `PhaseStarted` and before completion, after `PhaseCompleted` and before the next phase, while waiting on a human, and after the last phase and before the terminal event — when the service recovers, then status, artifact references and attempt are reconstructed from the event stream and no phase that has `PhaseCompleted` is launched again. One automated test per boundary fails if a completed phase relaunches.
* AC-002-2: Given a restart during an in-flight phase, when the run resumes, then orphaned agents of the earlier attempt are reaped before relaunch and the new attempt is recorded and visible.
* AC-002-3: Given the resume base cannot be determined, when recovery runs, then the run ends with a typed reason and is never started from a guessed base.
* AC-002-4: Given a server restart, when recovery completes, then time from boot to resumed-or-blocked is measured and reported against a target [NEEDS CLARIFICATION: what recovery-time and availability target must a production factory deployment guarantee? This is an operator decision the code cannot answer].

[NEEDS CLARIFICATION: when a resumed run's worktree is gone, Foreman today provisions a fresh one and logs a warning (`run_executor.ex:722`), discarding uncommitted prior work — should it keep doing so, or block for the operator?]

### REQ-003: Human waits survive restart and are answered once

Priority: Must; Complexity: Medium. [RISK: a lost or doubled decision resumes the wrong stage.]
Owns: wait durability. Defers: the merge gate (operator-only, SHA-pinned) and chat-channel delivery to Phase 1 and Phase 4.
Evidence: `QuestionOpened`, `QuestionAnswered`, `QuestionExpired`, `QuestionAnswerUndelivered` are typed events; the actor answers a repeated `command_id` with the first result instead of appending (`aggregate/actor.ex:864`).

* AC-003-1: Given a run waiting on an unanswered question, when the server restarts, then the question is still pending and listed, and only the matching run resumes when it is answered.
* AC-003-2: Given an answer is re-submitted with the same `command_id` after a restart, when it reaches the server, then the first result is returned as an idempotent success and no second `QuestionAnswered` is appended.
* AC-003-3: Given a second answer with a different `command_id` arrives for an already-answered question, when it reaches the server, then it is rejected with a typed not-pending error, exactly one `QuestionAnswered` exists, and the run resumes once.
* AC-003-4: Given a question expires while the server is down, when it boots, then expiry is recorded once and the run follows its configured policy rather than being asked again silently.

### REQ-004: Reconcile or block uncertain external effects

Priority: Must; Complexity: High. [RISK: blindly repeating a push, PR or comment after a crash duplicates or corrupts external state.]
Owns: effect reconciliation for run-level effects. Defers: provider-side comments to PRD-2026-3a76a0f0.
Evidence: keys move `started → completed | ambiguous | failed` (`idempotency/key_store.ex`); keys are written by the Overwatch runner (`jobsite/runners/overwatch.ex:131`); `CrashRecovery.has_no_side_effects?/1` checks only PR association and created worktrees, and `{:retry, :side_effects_present}` marks the key completed and **allows retry** (`idempotency/crash_recovery.ex:6`). `KeyStore` falls back to an in-process ETS table when the repo is not configured.

* AC-004-1: Given a crash leaves a key ambiguous for an effect class in the enumerated set, when recovery runs, then Foreman consults external truth for that class before any retry [NEEDS CLARIFICATION: which effect classes are in scope — branch push, PR create, PR comment/review post, task-provider state change?].
* AC-004-2: Given reconciliation finds the effect already present or cannot establish the outcome, when recovery finishes, then the run blocks with an operator-visible reason and nothing is repeated.
* AC-004-3: Given an ambiguous key for an effect class that has no reconciler, when recovery runs, then it fails closed (blocks) and never retries.
* AC-004-4: Given a production configuration with the durable key store unavailable and the ETS fallback active, when the server boots, then it reports the idempotency store as non-durable instead of claiming crash safety.

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
Evidence: `VfsIsolation.allowed?/2` binds an agent to worktree roots and emits `[:foreman_server, :security, :vfs_denied]`; `NetworkPolicy` enforces `none` and `allowlist` on the **docker jobsite only** (`network_enforced_on/0`), returns `:network_policy_unsupported` for a non-default policy on the host sandbox, and sweeps orphans at boot; the workflow door runs agents on the server host and cannot enforce network policy. The harness pi profile uses `sandbox_mode: :read_only`.

* AC-006-1: Given an agent starts, when its execution profile is resolved, then the backend (docker jobsite or host workflow) and, for filesystem, network, credentials and cleanup, whether each property is enforced or unenforced-with-reason are recorded and inspectable after launch.
* AC-006-2: Given a project requires a network policy other than default and the selected backend cannot enforce it, when provisioning occurs, then the run is blocked before any agent code runs with a typed unsupported reason — on the workflow door as well as the jobsite.
* AC-006-3: Given an agent accesses a path outside its bound worktree roots, when the access is attempted, then it is denied and a `vfs_denied` event is emitted; a negative test proves it.
* AC-006-4: Given a jobsite ends by any route, including a server crash, when cleanup runs or the server next boots, then its containers and network are removed.

[NEEDS CLARIFICATION: what minimum filesystem/network profile is mandatory before untrusted project code may run, and is an unenforced property a block or a recorded warning? Filesystem enforcement above is code-answerable; this policy decision is not.]

### REQ-007: Preflight the capabilities a run needs

Priority: Should; Complexity: Medium. [RISK: a run starts without a harness or tool it needs and fails midway.]
Owns: harness and executable availability at admission. Defers: model and provider-catalog preflight to PRD-2026-44b49f94 (Locked).
Evidence: `kickoff_preflight/1` (`run_executor.ex:424`) already runs before the task claim and the first phase; it checks provider readiness (`ReadinessCheck.installed?/1`, `run_executor.ex:825`) and models. No manifest field declares tools or skills.

* AC-007-1: Given a run is admitted, when kickoff preflight runs, then it reports available and missing capabilities, with versions where obtainable, for the harness providers the workflow uses [NEEDS CLARIFICATION: also verify the executables named by `command:`/`bash:` phases are on PATH, since there is no manifest key to declare tools?].
* AC-007-2: Given a required capability is unavailable, when preflight finishes, then the run ends before the task claim, worktree creation or first phase with a typed reason naming the phase and capability.

## 5. Dependencies and Exit Criteria

Phase 0 exits only when every row below is demonstrably met. An unmet guarantee is either closed or named as a blocking prerequisite of the phase that depends on it.

| Later phase | Names as its Phase 0 prerequisite | Met by |
|---|---|---|
| Phase 1 (PR delivery) | durable run and provenance guarantees; execution capability | REQ-002, REQ-005, REQ-006, REQ-007 |
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

Exit also requires: the decision record exists; the REQ-002 boundary tests and REQ-003/REQ-004 tests pass in isolation and in the full suite; stage provenance is inspectable through the existing status surface; and executor limitations are recorded on each run.

## 6. Open Decisions

Five `[NEEDS CLARIFICATION]` markers remain, all in §4: recovery-time target (REQ-002), worktree-missing behavior (REQ-002), effect classes in scope (REQ-004), minimum isolation policy (REQ-006), and executable-on-PATH preflight (REQ-007). The TRD must resolve each or carry it as an explicit prerequisite.

## 7. Readiness Gate

* Completeness 4/5 — each Phase 0 outcome named by the umbrella and by Phases 1, 3 and 4 maps to a requirement; seven requirements (not five) is justified in the sizing note.
* Testability 4/5 — every AC names an observable event, field, typed error or test; REQ-002/003 depend on a decided recovery-time target.
* Clarity 4/5 — ownership lines separate Phase 0 from three existing PRDs; five open markers remain.
* Feasibility 4/5 — each requirement extends a named existing seam; REQ-004 and REQ-006 need cross-backend work.

**Overall 4.0/5 — PASS with concerns.** This PRD authorizes Phase 0 refinement only, not an engine replacement.
