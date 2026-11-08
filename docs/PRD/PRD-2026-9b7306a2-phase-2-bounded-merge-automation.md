---
document_id: PRD-2026-9b7306a2
label: prd-phase-2-bounded-merge-automation
version: 1.0.0
status: Draft
date: 2026-11-08
scale_depth: STANDARD
total_requirements: 4
total_acceptance_criteria: 9
readiness_score: 3.8
---

# PRD: Phase 2 — Bounded MEDIUM/LOW Merge Automation

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 4 |
| Should | 0 |
| Could | 0 |
| Won't (this phase) | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 4/4 (100%) |
| Acceptance-criteria coverage | 4/4 (100%) |
| Risk flags | 4 |
| Open clarification markers | 3 |

## 1. Executive Summary

This phase introduces narrowly bounded, opt-in auto-merge for eligible MEDIUM/LOW PRs only after Phase 1 has established machine-verifiable checks, structured risk evidence, and head freshness. It preserves human approval for HIGH, ambiguous, and unsupported cases. Automation is off by default, cannot be enabled by agents, and must have an immediate operator kill switch.

The goal is incremental cycle-time improvement without weakening the existing human approval boundary until project policy explicitly permits it.

## 2. Scope

### In scope

* Project/repository opt-in and authorization to enable MEDIUM/LOW auto-merge.
* Evaluation of all required checks, risk evidence, SHA freshness, repository protection, and merge policy immediately before merge.
* Safe failure, audit, and kill-switch behavior.

### Out of scope

* HIGH-risk auto-merge.
* Auto-merge when required evidence is missing, stale, ambiguous, or failed.
* Agent-controlled policy changes or self-approval.

## 3. Requirements

### REQ-001: Keep automated merge disabled by default and operator-controlled

Priority: Must; Complexity: High. Risk: Accidental opt-in expands the blast radius of policy errors.

* AC-001-1: Given a project/repository has no explicit authorized opt-in, when an eligible PR is reviewed, then Foreman does not auto-merge it.
* AC-001-2: Given an authorized operator enables or disables the feature, when the setting changes, then actor, scope, time, and policy version are audited.
* AC-001-3: Given an agent attempts to alter auto-merge policy or approve its own change, when the command is evaluated, then Foreman rejects it.

### REQ-002: Auto-merge only current, eligible MEDIUM/LOW PRs

Priority: Must; Complexity: High. Risk: Race conditions or incorrect risk tiers may merge unsafe code.

* AC-002-1: Given risk is MEDIUM/LOW and every Phase 1 check, policy, repository protection, and freshness condition passes on the current SHA, when merge runs, then Foreman performs the configured merge operation and records its outcome.
* AC-002-2: Given risk is HIGH, missing, conflicting, or stale, or any check fails/is missing, when evaluated, then auto-merge is refused.
* AC-002-3: Given the PR head changes between eligibility evaluation and merge, when the merge operation detects the mismatch, then it aborts and requires fresh evidence.

### REQ-003: Provide an immediate kill switch and human fallback

Priority: Must; Complexity: Medium. Risk: Operators need to stop automation during an incident.

* AC-003-1: Given an authorized operator disables automation, when a pending PR is evaluated, then no subsequent automatic merge occurs and the PR follows the configured human-review path.
* AC-003-2: Given GitHub or an integration returns an uncertain result, when the operation is reconciled, then Foreman verifies actual PR state and never reports success based only on a request response.

### REQ-004: Audit each automated merge decision

Priority: Must; Complexity: Medium. Risk: Unexplained automated decisions undermine incident response and governance.

* AC-004-1: Given an auto-merge decision is made, when the run is inspected, then it exposes policy version, actor/configuration scope, risk report, exact SHA, checks, repository response, and final disposition.

## 4. Dependencies and Exit Criteria

**Prerequisite:** Phase 1 exit criteria are fully met. Before enabling this phase, resolve merge authority, project/repository scope, branch protection, risk rubric, supported merge methods, and required-check behavior. Exit when opt-in, kill switch, stale-head protection, auditability, and adversarial failure tests pass. Do not enable globally as a rollout shortcut.

## 5. Open Decisions

* [NEEDS CLARIFICATION: Which operator roles may enable auto-merge and at what scope?]
* [NEEDS CLARIFICATION: Which GitHub branch-protection and status-check policies are mandatory?]
* [NEEDS CLARIFICATION: Which merge methods and conflict/retry behaviors are supported?]

## 6. Readiness Gate

Completeness 4/5; Testability 4/5; Clarity 3/5; Feasibility 4/5. **Overall 3.8/5 — CONCERNS.** This PRD is intentionally not ready for implementation until the open authorization and repository-policy decisions are resolved in refinement/TRD.
