---
document_id: PRD-2026-44b49f94
label: prd-beads-watcher-model-preflight
version: 1.0.1
status: Locked
date: 2026-10-15
scale_depth: STANDARD
author: Lead Agent
total_requirements: 12
readiness_score: 4.5
readiness_gate: PASS
---

# PRD: BeadsWatcher Dispatch Must Not Die on Model Preflight

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 6 |
| Should | 4 |
| Could | 1 |
| Won't | 1 |

| Metric | Value |
|---|---:|
| Requirement coverage | 12/12 (100%) |
| Risk flags | 4 |
| Dependencies | 11 |
| Open ambiguity markers | 2 |
| External dependencies | 2 (local `pi` CLI model catalog; GitHub issue tracker for the observed failure) |

## Acceptance Criteria Summary

| REQ | Description | Priority | AC Count |
|---|---|---|---:|
| REQ-001 | A dispatch-gated bead reaches a runnable workflow | Must | 3 |
| REQ-002 | Inability to dispatch is visible on the bead and in the run | Must | 2 |
| REQ-003 | A dispatched run reports its outcome truthfully | Must | 2 |
| REQ-004 | Preflight distinguishes "not installed" from "not in catalog" | Must | 2 |
| REQ-005 | Preflight failure evidence names the phase and the reason | Must | 2 |
| REQ-006 | Default model selection is resolved, not invented | Must | 2 |
| REQ-007 | Catalog-unavailable must not read as model-not-found | Should | 2 |
| REQ-008 | Beads outside the dispatch-gated types are explicitly triaged | Should | 2 |
| REQ-009 | Operator-recoverable failure path is documented | Should | 1 |
| REQ-010 | Preflight stays a fail-closed gate | Could | 2 |
| REQ-011 | A catalog check is bounded | Won't (this release) | 1 |
| REQ-012 | No parallel dispatch path is added | Should | 1 |

## Context

Foreman's inbound dispatch path is Beads: a bead labeled `foreman-exec` that
transitions to `status: open` is picked up by BeadsWatcher, turned into a task,
auto-approved, and run as a workflow. Observed failure (run-0381b526…, bead
foreman-8qge): the run terminated before any phase executed with
`:provider_model_preflight_failed / :model_not_found` for the model
`minimax/MiniMax-M2.7`. Whether that run was dispatched from a `task`-type bead
or a `bug`-type bead cannot be read back from any durable record today, and the
two take different paths to the same visible symptom; that missing record is
what REQ-005 closes, not a question this document can answer.

Root cause is **not yet determined**, and this document treats that as a
first-class fact rather than an inconvenience: every requirement below is
written so that the failure becomes reproducible, attributable and recoverable
regardless of which of the candidate causes (section "Problem Statement") turns
out to be the real one. No requirement here presumes the answer.

Two independent candidate causes are on the table and both survive current
evidence:

- **C1 — model choice.** The workflows that declare a default model name one
  specific model. Whether that model exists in the local catalog of the machine
  running the server is an environment property the workflow author cannot see
  from the manifest.
- **C2 — reachability of a runnable workflow.** The type-to-workflow mapping
  covers only a few bead types. A bead of any other type either never gets
  dispatched at all, or gets pushed onto a workflow that no operator would have
  chosen for it.

Both produce "a bead did not result in useful work". Only one of them produces
the exact preflight error observed.

## Users

- **Primary: the operator running a Foreman server with BeadsWatcher enabled.**
  They create work by writing beads and expect the bead to become either
  completed work or an unmistakable failure. Today they get the latter with no
  actionable detail, or silence.
- **Secondary: the person or automation triaging a bead queue.** They need to
  know, without reading server source, whether a given bead is Foreman's work or
  somebody else's.
- **Tertiary: the on-call responder for a stalled queue.** BeadsWatcher retries
  an unmapped bead every poll indefinitely; nobody is paged, and the queue
  silently stops moving.

## Problem Statement

### Pain 1: a dispatched run dies before doing any work, and the reason is not actionable

The run reports a failure class that names a model id but not the phase, the
provider, or what about the model was unacceptable. The operator cannot tell
"this model is not installed here" from "this model id is spelled wrong" from
"the catalog query itself failed".

### Pain 2: the root cause is unknown and the current evidence cannot resolve it

The failure was observed once, against one run id, with no retained record of
which workflow was selected, which copy of that workflow was loaded, or what the
catalog printed at that moment. Without those, any fix is a guess, and a guess
that makes the error message quieter is worse than no fix: it would hide the
failure rather than resolve it. [RISK: fixing the symptom (silencing or
relaxing preflight) without identifying the cause leaves the next model or
workflow mismatch undispatched and equally unexplained.]

### Pain 3: whether a bead is dispatchable is implicit

Dispatch eligibility is decided by a mapping most operators have never read,
resting on a naming convention that the issue-tracker documentation and the
tracker's own type vocabulary do not agree with. [RISK: an operator labels a
bead `foreman-exec`, expects work, and the bead is retried forever with no
record of why.]

## Goals

1. Every bead that is labeled for Foreman ends in one of exactly three visible
   states: dispatched, refused-with-a-reason, or explicitly out-of-scope. Never
   "in limbo, retried silently".
2. A preflight failure names the thing that failed well enough to fix without
   reading server source.
3. The cause of the observed failure is identified from evidence the system
   retains, not re-derived from memory of the run.
4. Preflight remains a gate: it must not be relaxed into a warning.

## Non-Goals

- Adding new agents, providers, or model vendors.
- Changing the Beads data model, bead schema, or the `foreman-exec` label
  contract.
- Building a general-purpose model registry, remote catalog, or fallback
  ordering. [Won't this release: REQ-011 covers catalog query semantics only.]
- Reordering, renaming, or adding workflow stages.
- Making dispatch retryable in a way it is not today.

## Functional Requirements

### REQ-001: Every dispatch-gated bead resolves to a workflow that can run

**Priority:** Must

A bead carrying the Foreman execution label must resolve to exactly one
workflow, and that workflow must be one whose phases can execute in the
environment where the server is running. If no workflow resolves, the bead must
not be left in a state that reads as "queued and pending".

- AC-001-1: Given a labeled bead whose type maps to a bundled workflow, when BeadsWatcher processes it, then a run is created for that workflow and the bead's outcome is tied to that run.
- AC-001-2: Given a labeled bead whose type resolves to no workflow, when BeadsWatcher processes it, then the outcome is recorded with a reason naming the type that failed to resolve, and it is distinguishable from a run that started and failed.
- AC-001-3: Given a labeled bead that resolves to a workflow, when the run is created, then the workflow name and the resolved source of its definition are recorded with the run. [NEEDS CLARIFICATION: should untyped `task`/`feature`/`epic`/`chore` beads be given a default workflow, or be reported as out-of-scope-by-design? These are different operator expectations and the bead queue cannot serve both.]

### REQ-002: Refusal to dispatch is attributable to a named cause

**Priority:** Must

An absent state and a malformed state must not share one outcome. "This bead
carries no type" and "this bead carries a type nothing maps to" and "this bead's
type field is not a string" are three different operator actions.

- AC-002-1: Given each distinct cause of non-dispatch, when the bead is processed, then the recorded reason is unique to that cause and no two causes produce identical text.
- AC-002-2: Given a bead whose type field is present but unusable, when processed, then the outcome states the field is unusable rather than that no workflow exists.

### REQ-003: A dispatched run's outcome is truthful about work done

**Priority:** Must

A run that terminated before executing a phase must not report as though a phase
ran and failed.

- AC-003-1: Given a run rejected at preflight, when its outcome is read, then the record states that zero phases executed and names the gate that rejected it.
- AC-003-2: Given the same run, when its owning bead is inspected, then the bead's state reflects a failed dispatch and not a completed one.

### REQ-004: Preflight separates installation from catalog membership

**Priority:** Must

The two are different failures with different remedies: one is fixed on the
host, the other in the workflow definition.

- AC-004-1: Given a provider binary absent from the host, when preflight runs, then the reported failure names the provider as not installed and does not report a model problem.
- AC-004-2: Given a provider present but a model id absent from its catalog, when preflight runs, then the reported failure names the model, the provider it was checked against, and the phase that requested it.

### REQ-005: Preflight failure evidence is complete without re-running

**Priority:** Must

- AC-005-1: Given a preflight failure, when the run is inspected afterward, then the record contains the phase name, the declared model string exactly as written, the resolved provider, and the failure class.
- AC-005-2: Given a run that passed preflight, when inspected, then the evidence shows which model each phase actually ran with, so a later mismatch can be attributed. [NEEDS CLARIFICATION: is the retained evidence required to be durable beyond the server process (queryable after restart), or is a log record sufficient?]

### REQ-006: The default model for a phase is resolved from a stated precedence

**Priority:** Must

There must be one documented order that decides the model a phase runs with, and
it must not depend on whichever model happens to be installed on the server host.

- AC-006-1: Given a phase declaring no model, when it runs, then the model used comes from a precedence with one named winner, and that winner is recorded on the run.
- AC-006-2: Given a model supplied by the calling environment alongside a workflow-declared default, when the phase is prepared, then exactly one of them is used, the rule choosing between them is fixed and documented, and the run record names the winner. Auto-resolved under Foreman mode to the documented rule rather than left open: the declared precedence is workflow-declared default first, environment value only as a gap-filler for a phase that declares none. [RISK: a precedence that silently prefers the environment makes a run's behavior depend on host configuration and reproduces this defect in a new place; AC-006-2 exists to make any change to that ordering a visible decision rather than a side effect.]

### REQ-007: Catalog unavailability must not read as "model not found"

**Priority:** Should

A failed, timed-out, or unreadable catalog query is not evidence that a model is
absent. Reporting it as absence turns an infrastructure problem into a false
statement about the workflow, and pushes debugging toward the wrong artifact.

- AC-007-1: Given a catalog query that cannot be completed, when preflight runs, then the failure names the query as the problem, not the model.
- AC-007-2: Given a query that returns an empty or unparsable result, when preflight runs, then the distinction between "answered: not present" and "could not answer" is preserved in the outcome. Auto-resolved under Foreman mode: the run is **blocked** (fail closed), consistent with the current posture and with REQ-010, because a wasted dispatch is cheaper than a run that spends a worktree, a branch and a paid agent session on a model nothing has confirmed. The residual risk is real and is what REQ-007's naming requirement exists to contain: a flaky catalog query can stop all work, so "could not answer" must be loud enough that an operator recognises it as infrastructure rather than as a workflow defect.

### REQ-008: Bead types outside the dispatch-gated set are explicitly triaged

**Priority:** Should

- AC-008-1: Given the full set of bead types the tracker can produce, when dispatch eligibility is evaluated, then each type is either mapped or named in a documented not-applicable category.
- AC-008-2: Given an operator adds a new workflow, when eligibility is evaluated, then the mapping is complete by construction rather than by a hand-maintained list that can go stale.

### REQ-009: Recovery from a preflight failure is documented and non-destructive

**Priority:** Should

- AC-009-1: Given a run that failed preflight, when the operator corrects the cause, then the documented recovery does not require discarding the bead or the run's recorded history, and states what re-dispatch costs. Auto-resolved under Foreman mode to the recovery the system already supports without new machinery: correct the cause, then re-open the owning bead so dispatch re-enters through the normal path. Re-dispatch costs one new run record and one new branch; the failed run's history is retained and not reused.

> **Forward pointer (2026-10-27, preflight PR 3):** the auto-resolved recovery in AC-009-1
> ("re-open the owning bead") was verified not to re-dispatch; see
> `docs/user-guide.md` section 7.2 "Recovering from a preflight failure" for the path that
> does (`task.retry` then a fresh `task.approve`) and bead `foreman-pfta.1` for the defect.
> The requirement text is left as written (point-in-time spec).

### REQ-010: Preflight remains a hard gate

**Priority:** Could

- AC-010-1: Given a model that cannot be validated, when a run is created, then no phase executes and no worktree or branch is produced.
- AC-010-2: Given any change made for REQ-004/REQ-005/REQ-007, when tests run, then at least one test asserts that an invalid model still stops the run. [RISK: the fastest way to make this error disappear is to downgrade it to a warning. That is explicitly out of scope and must be refused in review.]

## Non-Functional Requirements

### REQ-011: Catalog checks must not be run per phase at dispatch time

**Priority:** Won't (this release) — recorded deliberately, not omitted.

Preflight currently queries once per distinct model across the run's phases.
Caching, batching, or a per-run budget for catalog queries is deferred; the
current behavior is acceptable and is not implicated in the observed failure.

- AC-011-1: Given a run whose phases repeat a model, when preflight runs, then the number of catalog queries is bounded by the number of distinct models and that bound is stated in code.

### REQ-012: No second dispatch path

**Priority:** Should

- AC-012-1: Given this work lands, when dispatch eligibility is evaluated for a bead, then exactly one code path decides it, and no parallel or legacy path remains that could report a different answer for the same bead.

## Business Integration Points

| System (by capability) | Business outcome served | Obligation / constraint |
|---|---|---|
| Issue tracker holding the work queue | Bead creation is the entry point for work | Tracker's type vocabulary is authoritative for what "dispatchable" can mean; it currently does not agree with the workflow-side naming rule |
| Local agent CLI providing the model catalog | The server must know a model is usable before spending a dispatch on it | Catalog is host-local; two servers on two hosts can legitimately disagree. Any "known good model" list must state which host it was true for |
| Source hosting (pull requests, run branches) | A successful run produces a reviewable change | A run that fails preflight must leave no branch or pull request behind |

## Requirement Sizing Note

Per the PRD contract, requirements carry MoSCoW priority only and deliberately
carry no complexity or effort estimates: sizing belongs to the TRD
(`/ensemble-create-trd`, "Assess Complexity"). The `[RISK: ...]` markers below
are the risk-indicator requirement for the Medium/High items the eventual TRD
will size.

## Dependency Map

| REQ | Depends On | Blocked By | Notes |
|---|---|---|---|
| REQ-001 | — | REQ-006 | Cannot promise a workflow "can run" until model resolution is defined |
| REQ-002 | REQ-001 | — | Absent vs malformed split |
| REQ-003 | REQ-001 | — | Outcome truthfulness |
| REQ-004 | REQ-003 | — | Splits the failure class |
| REQ-005 | REQ-004 | — | Evidence rides on the failure class existing |
| REQ-006 | — | — | Prerequisite for REQ-001 and this fix's root cause |
| REQ-007 | REQ-004 | — | Same failure-class vocabulary |
| REQ-008 | REQ-001 | — | Completeness of the mapping |
| REQ-009 | REQ-003, REQ-005 | — | Recovery text depends on what the record shows |
| REQ-010 | REQ-004 | — | Guard against the wrong fix |
| REQ-011 | — | — | Deferred |
| REQ-012 | REQ-001, REQ-008 | — | Single authority for eligibility |

## Assumptions (auto-applied under Foreman mode)

- The environment where the failure was observed is a normal operator host with
  the agent CLI installed and configured; the server was not running a build
  older than the code it claims to be.
- The bead in question carried the Foreman execution label.
- No change to the tracker's data format is in scope.

## Out-of-Scope

- Provider or model vendor additions; catalog caching; label semantics changes;
  scheduler, inbox, or messaging work; workflow stage reordering.

## Risks

| Risk | REQ | Mitigation |
|---|---|---|
| Fixing the message and not the cause | REQ-006 | REQ-006 and an explicit root-cause statement must land before REQ-004/REQ-005 are treated as done |
| Downgrading preflight to a warning to make the error disappear | REQ-010 | AC-010-2 makes the refusal a test, not a review opinion |
| Environment-dependent model defaults reproduce the defect elsewhere | REQ-006 | AC-006-2 forces the precedence to be stated |
| Type mapping grows stale as workflows are added | REQ-008 | AC-008-2 requires completeness by construction |

## Entry and Exit Criteria

**Entry:** the failing run's evidence is available or reconstructible (which
workflow was selected, which phases declared which models, what the catalog
answered); the bead's type and labels are known.

**Exit:** root cause named in this document's successor; a labeled bead that
cannot be dispatched produces a visible, uniquely-attributed outcome; a run
rejected at preflight names phase, provider, model, and failure class; tests
prove preflight still blocks an invalid model; operator-facing documentation
describes eligibility and recovery.

## Approvals and Decision Ownership

Approver: the Foreman operator / maintaining engineer. Acceptance is judged
against the Exit criteria and AC-010-2 above, by a reviewer who can run the
server and the local agent CLI; a change that only improves the error text does
not satisfy exit.

## Open Questions

Carried as inline `[NEEDS CLARIFICATION: ...]` markers; the count in the health
summary is authoritative.

## Ambiguity Markers

2 markers remain open, both genuinely needing a human decision: AC-001-3
(should untyped `task`/`feature`/`epic`/`chore` beads get a default workflow or
be reported out-of-scope-by-design) and AC-005-2 (must preflight evidence be
durable across a server restart, or is a log record sufficient).

Resolved during this refinement pass (Foreman mode, best-effort defaults,
recorded rather than silently dropped): the observed bead type (Context), the
environment-vs-workflow model precedence (AC-006-2), the catalog-unavailable
posture (AC-007-2), and the recovery path (AC-009-1). Requirement complexity
tags were not added to requirements by design — see "Requirement Sizing Note".

## Changelog

- 2026-10-15 — v1.0.1 (`prd_refine`, Foreman mode): readiness rescored
  4.25 → 4.5; 4 of 6 ambiguity markers auto-resolved with the resolution and its
  reasoning recorded in place; requirement sizing note added; PRD locked.
- 2026-10-15 — v1.0.0 (`prd_create`): initial PRD, 12 requirements,
  Implementation Readiness Gate 4.25 PASS, Constitution Gate PASSED.

## Constitution Compliance Mapping

| Article / section | Checks applied |
|---|---|
| §1 Core Principles — tests accompany features | REQ-010 / AC-010-2 require a test for the preserved gate |
| §1 Non-Negotiable Rules 2 — input validation at boundaries | REQ-002, REQ-008 validate the bead type at the dispatch boundary |
| §1 Non-Negotiable Rule 4 — event-sourced orchestration | REQ-003, REQ-005 make dispatch outcomes event/run-sourced rather than inferred from files or logs |
| §3 Quality Gates | REQ-005, REQ-009 evidence and recovery are gate-relevant |
| §4 Architecture Rules — CQRS, Go CLI boundaries | REQ-012 keeps one authoritative dispatch path |
| §8 Documentation Discipline | REQ-009 requires the documented recovery path |

## PRD Health Summary (detail)

- Requirements: 12 (Must 6, Should 4, Could 1, Won't 1)
- Acceptance criteria: 22
- Risk flags: 4
- Dependency edges: 11
- Open ambiguity markers: 2
- Constitution compliance: passed
