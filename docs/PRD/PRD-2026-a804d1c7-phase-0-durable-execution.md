---
document_id: PRD-2026-a804d1c7
label: prd-phase-0-durable-execution
version: 1.0.0
status: Draft
date: 2026-11-08
scale_depth: STANDARD
total_requirements: 5
total_acceptance_criteria: 12
readiness_score: 4.0
---

# PRD: Phase 0 — Durable Execution and Safety Foundation

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 5 |
| Should | 0 |
| Could | 0 |
| Won't (this phase) | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 5/5 (100%) |
| Acceptance-criteria coverage | 5/5 (100%) |
| Risk flags | 5 |
| Open clarification markers | 2 |

## 1. Executive Summary

Before Foreman adds more factory automation, it needs evidence that long-lived work can recover safely from process failure, restart, deployment, and human wait states. This phase assesses Foreman’s existing event-sourced run orchestration against explicit durable-execution requirements, closes critical gaps needed by later stages, and records a deliberate engine decision. The expected outcome is to extend the current engine if it passes; Temporal or Conductor are candidates only if measured gaps justify adopting one.

Phase 0 also establishes the minimum stage/run provenance, context capture, executor isolation contract, and capability preflight needed by later increments. It does not implement the full idea-to-PR lifecycle, risk-tiered merging, Kubernetes, or external memory.

## 2. Users and Problem

* **Foreman operator:** needs runs to survive restarts and human decision waits without losing state or duplicating work.
* **Factory maintainer:** needs evidence about the current orchestration’s recovery guarantees before adding stages and automation.
* **Project owner:** needs project context and repository execution boundaries to be explicit and auditable.

## 3. Scope

### In scope

* Assess durable semantics: persisted progress, restart recovery, retry limits, idempotent external effects, cancellation, and waiting for human decisions.
* Add the smallest stage/provenance representation required to resume and inspect a factory run.
* Capture project context identity/redaction/truncation and establish a documented executor isolation profile.
* Add capability preflight for tools required by a workflow.
* Record a decision to extend Foreman’s engine or pursue an alternative, with evidence and migration/rollback implications.

### Out of scope

* Replacing Foreman’s orchestration engine without a separate approved architecture decision.
* Full Kubernetes deployment or horizontal scale-out.
* Automatic PR merge, idea cultivation, external memory deployment, or chat-provider inbound integrations.

## 4. Requirements

### REQ-001: Assess and decide on the durable execution engine

Priority: Must; Complexity: High. Risk: An unsupported engine decision creates unnecessary migration or leaves known recovery gaps.

* AC-001-1: Given the current run/event model, when the assessment completes, then each durability criterion is mapped to source/test evidence, a pass/fail result, and any gap.
* AC-001-2: Given gaps exist, when the decision is recorded, then it compares extending the current engine with alternatives including Temporal and Conductor, and documents migration, operational, and rollback costs.
* AC-001-3: Given assessment evidence shows the current engine meets requirements, when Phase 0 exits, then the recorded decision is to extend it; no alternative engine is adopted by implication.

### REQ-002: Recover runs and human waits durably

Priority: Must; Complexity: High. Risk: Duplicate side effects or lost human decisions can corrupt repository state.

* AC-002-1: Given a server restart at each supported stage boundary, when the service recovers, then run/stage status, artifacts, decisions, and retry state are reconstructed without a second execution of completed work.
* AC-002-2: Given a run is waiting on a human decision, when the server restarts and the operator responds, then only the matching pending stage resumes and the response is recorded once.
* AC-002-3: Given an external side effect has an uncertain outcome after a crash, when recovery occurs, then Foreman reconciles or blocks for operator action instead of blindly repeating it.

### REQ-003: Record stage provenance and project context

Priority: Must; Complexity: Medium. Risk: Later phases cannot prove what inputs produced an artifact or decision.

* AC-003-1: Given a stage starts and completes, when its run is inspected, then its input/output artifact references, source run, stage status, timestamps, and correlation identifiers are available.
* AC-003-2: Given project context is injected, when the launch is recorded, then included sections, source identity/hash where available, truncation, and redaction indicators are captured.

### REQ-004: Define and enforce an executor isolation contract

Priority: Must; Complexity: High. Risk: A Git worktree is mistaken for a security sandbox.

* AC-004-1: Given an agent starts, when its execution profile is selected, then filesystem, network, credentials, and cleanup behavior are explicit and inspectable.
* AC-004-2: Given a required isolation property is unsupported by the selected backend, when provisioning occurs, then Foreman blocks before executing agent code and reports the missing capability.

### REQ-005: Preflight workflow capabilities

Priority: Must; Complexity: Medium. Risk: A workflow may silently run with missing or incompatible tools/skills.

* AC-005-1: Given a workflow declares required tools, harnesses, or skills, when a run is admitted, then Foreman reports available/missing capabilities and versions before execution.
* AC-005-2: Given a required capability is unavailable, when preflight finishes, then the run is blocked with an actionable reason and no partial side effect.

## 5. Dependencies and Exit Criteria

This phase is foundational. Exit only when the durability assessment and engine decision are documented, restart/wait recovery behavior is covered by automated tests, stage provenance is inspectable, and executor limitations are explicit. Any unmet guarantee must be either closed or named as a blocking prerequisite for the phase that depends on it.

| Requirement | Depends on | Notes |
|---|---|---|
| REQ-001 | Existing event/run architecture | Evidence-based decision, not a vendor preference. |
| REQ-002 | REQ-001 | Recovery semantics must match chosen engine path. |
| REQ-003 | Existing project context and run records | Prefer extending existing event/projection boundaries. |
| REQ-004 | Existing workflow/jobsite execution | Host execution risks need explicit treatment. |
| REQ-005 | Existing workflow catalog | Enables deterministic operator setup. |

## 6. Open Decisions

* [NEEDS CLARIFICATION: Which recovery duration and availability targets should be guaranteed for a production factory deployment?]
* [NEEDS CLARIFICATION: What minimum network/filesystem isolation profile is mandatory before running untrusted project code?]

## 7. Readiness Gate

Completeness 4/5; Testability 4/5; Clarity 4/5; Feasibility 4/5. **Overall 4.0/5 — PASS with concerns.** Resolve recovery SLO and minimum isolation policy in TRD. This PRD authorizes Phase 0 refinement only, not an engine replacement.
