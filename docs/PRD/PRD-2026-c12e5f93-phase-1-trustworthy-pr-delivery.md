---
document_id: PRD-2026-c12e5f93
label: prd-phase-1-trustworthy-pr-delivery
version: 1.0.0
status: Draft
date: 2026-11-08
scale_depth: STANDARD
total_requirements: 5
total_acceptance_criteria: 12
readiness_score: 4.0
---

# PRD: Phase 1 — Trustworthy PR Delivery

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

Foreman’s current review prompts request tests and static checks, but prompt instructions are not proof that checks ran or passed. This phase makes PR quality and review evidence machine-verifiable, tied to the exact PR head, and visible to operators and reviewers. It adds a structured risk decision with rationale and actionable PR review instructions while preserving the current human approval requirement for every merge.

This phase intentionally does **not** enable auto-merge. Its outcome is a trustworthy foundation for deciding whether a later, separately approved phase can safely automate eligible MEDIUM/LOW PRs.

## 2. Users

* **Project owner:** configures required checks for generated PRs.
* **Human reviewer:** needs findings, risk rationale, and proof tied to the PR head.
* **Foreman operator:** needs fail-closed behavior when checks are missing, stale, or ambiguous.

## 3. Scope

### In scope

* Discover/configure required project check sources and record machine-verifiable results.
* Bind checks, review outputs, unresolved findings, and risk classification to the exact PR head SHA.
* Publish structured risk rationale and specific human review instructions to the PR.
* Invalidate quality/review evidence when the PR head changes.
* Keep all merges operator-approved and SHA-pinned.

### Out of scope

* Automatic merge, which belongs to Phase 2.
* Raw idea cultivation or PRD/TRD lifecycle, which belongs to Phase 3.
* Model-only quality claims without machine-verifiable check evidence.

## 4. Requirements

### REQ-001: Collect required check evidence for the PR head

Priority: Must; Complexity: High. Risk: A claimed pass can be unverified or belong to another commit.

* AC-001-1: Given a configured check passes, when Foreman records it, then provider/command, check identity, result, completion time, and exact head SHA are stored.
* AC-001-2: Given any required check fails, is missing, stale, or tied to another SHA, when eligibility is evaluated, then the PR is blocked from advancing and the operator sees the reason.
* AC-001-3: Given a project has no configured checks, when verification runs, then Foreman does not infer success from a review prompt and requires an explicit fallback policy or operator disposition.

### REQ-002: Produce structured review findings

Priority: Must; Complexity: High. Risk: Unresolved findings can be lost in unstructured artifacts.

* AC-002-1: Given automated review completes, when findings are recorded, then severity, location, description, disposition, source, and head SHA are machine-readable.
* AC-002-2: Given required review evidence is missing or malformed, when the phase completes, then the run remains ineligible and presents the defect for operator action.

### REQ-003: Classify PR risk and publish actionable guidance

Priority: Must; Complexity: High. Risk: Under-classification may suppress necessary human scrutiny.

* AC-003-1: Given review completes, when risk is recorded, then it includes HIGH/MEDIUM/LOW, rubric version, rationale, evidence, unresolved findings, human-review instructions, and head SHA.
* AC-003-2: Given risk is ambiguous, missing, or conflicting, when eligibility is evaluated, then it follows the conservative HIGH/blocked path and cannot authorize automation.
* AC-003-3: Given a report is valid, when Foreman publishes it, then the PR receives an actionable comment; a changed head invalidates the old report and requires refresh.

### REQ-004: Keep merging human-approved in Phase 1

Priority: Must; Complexity: High. Risk: Enabling automation before evidence and policy are validated could merge unsafe changes.

* AC-004-1: Given any PR completes Phase 1 review, when a merge is requested without operator approval pinned to its current head SHA, then Foreman refuses the merge.
* AC-004-2: Given the head changes after approval, when merge is attempted, then approval is considered stale and a new human decision is required.

### REQ-005: Expose the evidence and gate status

Priority: Must; Complexity: Medium. Risk: Invisible blocked conditions invite manual bypass.

* AC-005-1: Given a PR is blocked or eligible for human review, when an operator inspects it, then required checks, stale/missing evidence, findings, risk rationale, and next actions are visible.
* AC-005-2: Given evidence is updated, when projections refresh, then the displayed decision corresponds to the latest PR head and policy version.

## 5. Dependencies and Exit Criteria

**Prerequisite:** Phase 0 durable run and provenance guarantees. Exit when quality checks and risk evidence are machine-verifiable, tied to the current SHA, changed heads invalidate prior evidence, and every merge still requires human approval. Adversarial tests must cover missing results, spoofed/stale results, and head changes.

| Requirement | Depends on |
|---|---|
| REQ-001 | Phase 0 provenance and execution capability |
| REQ-002 | Review workflow and durable artifacts |
| REQ-003 | REQ-001, REQ-002, PR comment integration |
| REQ-004 | Existing SHA-pinned human merge gate |
| REQ-005 | Evidence projection and operator interface |

## 6. Open Decisions

* [NEEDS CLARIFICATION: Which check providers and project-specific check configuration format are in the first release?]
* [NEEDS CLARIFICATION: What rubric inputs and thresholds classify a PR as HIGH, MEDIUM, or LOW?]

## 7. Readiness Gate

Completeness 4/5; Testability 4/5; Clarity 4/5; Feasibility 4/5. **Overall 4.0/5 — PASS with concerns.** Resolve provider selection and risk rubric during TRD. This phase preserves human approval for every merge.
