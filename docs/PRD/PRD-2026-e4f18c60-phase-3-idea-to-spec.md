---
document_id: PRD-2026-e4f18c60
label: prd-phase-3-idea-to-spec
version: 1.0.0
status: Draft
date: 2026-11-08
scale_depth: STANDARD
total_requirements: 5
total_acceptance_criteria: 11
readiness_score: 4.0
---

# PRD: Phase 3 — Idea-to-Spec Lifecycle

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

This phase adds the front of the software factory: a raw idea becomes a sourced, uncertainty-aware recommendation, followed by an explicit operator go/no-go decision. Approved ideas proceed through separate Ensemble PRD and TRD stages with artifact lineage and configurable review/approval boundaries. This creates value without requiring merge automation or new memory infrastructure.

Foreman’s existing `assess` workflow is a starting point but does not itself provide the complete raw-idea/user/use-case/priority/go-no-go lifecycle required here.

## 2. Scope

### In scope

* Idea intake and structured cultivation report.
* Research alternatives and record source/provenance and uncertainty.
* Priority recommendation and explicit operator go/no-go.
* Independently inspectable PRD create/refine and TRD create/refine artifacts using Ensemble.
* Link approved specifications to the idea and downstream implementation task.

### Out of scope

* Automatic implementation or merge before approvals.
* Replacing Ensemble or building a second PRD authoring system.
* Inbound chat adapters (Phase 4).

## 3. Requirements

### REQ-001: Cultivate an idea into an evidence-aware recommendation

Priority: Must; Complexity: High. Risk: Invented market/user claims can misdirect investment.

* AC-001-1: Given a raw idea, when cultivation completes, then the report states the problem, target users, use cases, alternatives, priority rationale, assumptions, unknowns, and go/no-go recommendation.
* AC-001-2: Given external research is used, when claims are presented, then source links and retrieval date are included and unsupported claims are marked as hypotheses.
* AC-001-3: Given key information is unavailable, when the report is produced, then it identifies decision-relevant unknowns rather than silently inventing facts.

### REQ-002: Require an explicit go/no-go decision

Priority: Must; Complexity: High. Risk: Implementation may begin without investment authorization.

* AC-002-1: Given cultivation recommends proceeding, when the idea reaches its decision gate, then no PRD/TRD/implementation stage starts until an authorized operator records go, no-go, or request-more-information.
* AC-002-2: Given the operator requests more information or declines, when that decision is stored, then actor, timestamp, rationale, and source idea are retained and the workflow follows the selected disposition.

### REQ-003: Create/refine PRD as a discrete stage

Priority: Must; Complexity: Medium. Risk: A mutable or unapproved PRD can become the basis for untracked work.

* AC-003-1: Given go is recorded, when the Ensemble PRD stage completes, then its versioned artifact is stored in the configured project location and linked to the source idea and run.
* AC-003-2: Given PRD review is required by project policy, when the stage completes, then TRD work remains blocked until the authorized approval is recorded.

### REQ-004: Create/refine TRD as a discrete stage

Priority: Must; Complexity: Medium. Risk: Implementation can drift from approved product requirements.

* AC-004-1: Given an approved PRD, when the Ensemble TRD stage completes, then the TRD records its source PRD version and run provenance.
* AC-004-2: Given no approved TRD exists, when implementation is requested, then Foreman refuses to start or requires an explicit authorized exception.

### REQ-005: Preserve context, research provenance, and handoff

Priority: Must; Complexity: Medium. Risk: Stage handoffs may lose constraints or imply research permission that was not granted.

* AC-005-1: Given an idea/PRD/TRD stage starts, when its inputs are assembled, then configured project constitution and context are included with source and truncation/redaction metadata.
* AC-005-2: Given a phase completes, when the next stage is queued, then only the selected approved artifact version and its linked evidence are handed off.

## 4. Dependencies and Exit Criteria

**Prerequisite:** Phase 0 durable stage state and provenance. Exit when idea decisions are auditable and block downstream work correctly, source/uncertainty is explicit, and PRD/TRD outputs are discrete, linked, and approval-aware. Phase 2 auto-merge is not a prerequisite.

## 5. Open Decisions

* [NEEDS CLARIFICATION: Which external research sources are approved by default, and is public-web research opt-in per project?]
* [NEEDS CLARIFICATION: Which artifact review stages require explicit human approval versus configurable project policy?]

## 6. Readiness Gate

Completeness 4/5; Testability 4/5; Clarity 4/5; Feasibility 4/5. **Overall 4.0/5 — PASS with concerns.** Resolve research-source and artifact-approval policies during refinement/TRD.
