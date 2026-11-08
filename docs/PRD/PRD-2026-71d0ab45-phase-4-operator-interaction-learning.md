---
document_id: PRD-2026-71d0ab45
label: prd-phase-4-operator-interaction-learning
version: 1.0.0
status: Draft
date: 2026-11-08
scale_depth: STANDARD
total_requirements: 5
total_acceptance_criteria: 11
readiness_score: 4.0
---

# PRD: Phase 4 — Operator Interaction and Learning

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 3 |
| Should | 2 |
| Could | 0 |
| Won't (this phase) | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 5/5 (100%) |
| Acceptance-criteria coverage | 5/5 (100%) |
| Risk flags | 5 |
| Open clarification markers | 2 |

## 1. Executive Summary

This phase makes Foreman’s existing outbound operator notifications conversational: a user can answer a workflow question in Slack or Telegram and resume the correct durable wait state. It also adds a post-run audit and improvement proposal loop. The system records attributable lessons and recommendations, but does not self-modify workflows, code, model configuration, project memory, or merge policy.

## 2. Scope

### In scope

* Authenticated inbound Slack and Telegram events for responses to correlated pending questions.
* Identity mapping, deduplication, authorization, and durable resume behavior.
* Post-run audits based on run evidence and operator interventions.
* Improvement proposals for Foreman, Ensemble, LiteLLM, and projects with human disposition.

### Out of scope

* Chat-based merge approval or privilege escalation.
* Autonomous application of improvements.
* Replacing native project memory with a new service.

## 3. Requirements

### REQ-001: Correlate and authenticate inbound responses

Priority: Must; Complexity: High. Risk: Forged or misrouted events can resume the wrong run.

* AC-001-1: Given a workflow is waiting on a human response, when an outbound Slack/Telegram question is sent, then it includes an unguessable or authenticated correlation reference bound to the project, run, and question.
* AC-001-2: Given a signed provider event arrives from a configured mapped identity, when it matches a pending question, then Foreman records it once and resumes only that wait state.
* AC-001-3: Given signature, identity, correlation, or deduplication validation fails, when an event is received, then no run/task/merge state changes and the rejection is auditable without logging secrets.

### REQ-002: Preserve operator authorization boundaries

Priority: Must; Complexity: High. Risk: A chat adapter may accidentally become an alternate privileged command path.

* AC-002-1: Given a chat response is ordinary question input, when accepted, then it can provide the requested data but cannot approve merge, change policy, or authorize unrelated work.
* AC-002-2: Given an interaction requests a privileged action, when it lacks the existing required operator authorization, then it is rejected and directs the user to an authorized control surface.

### REQ-003: Deliver resilient channel operations

Priority: Should; Complexity: Medium. Risk: Provider outages can strand long-running workflows.

* AC-003-1: Given Slack or Telegram delivery fails or is rate-limited, when the failure is handled, then Foreman records retryability and keeps the workflow in a durable waiting state without duplicate question creation.
* AC-003-2: Given messaging is disabled, when a question is needed, then Foreman exposes the same pending question through the existing operator interface.

### REQ-004: Audit completed runs

Priority: Should; Complexity: Medium. Risk: Model summaries can be confused with verified run facts.

* AC-004-1: Given a run reaches a terminal state, when its audit is produced, then outcomes, failures, check evidence, findings, cost/latency where available, and operator interventions link back to source records.
* AC-004-2: Given the audit contains model-generated conclusions, when displayed, then they are labeled separately from recorded facts and source evidence.

### REQ-005: Propose, do not self-apply, improvements

Priority: Must; Complexity: High. Risk: Unreviewed self-modification can compound system errors.

* AC-005-1: Given an audit recommends an improvement, when it is presented, then an operator can accept, decline, or defer it with a recorded disposition.
* AC-005-2: Given a recommendation is accepted, when implementation begins, then it follows a separately authorized task, review, quality, and merge path; no audit directly changes production code, policy, workflow, memory, or model settings.

## 4. Dependencies and Exit Criteria

**Prerequisite:** Phase 0 durable waits and provenance. Existing outbound provider support is reused where possible. Exit when provider authenticity, identity mapping, event deduplication, exact wait correlation, and privilege boundaries are tested; post-run audits cite evidence; recommendations cannot self-apply.

## 5. Open Decisions

* [NEEDS CLARIFICATION: Which Slack/Telegram identities and workspaces may be mapped to Foreman operator roles?]
* [NEEDS CLARIFICATION: What default retry/expiry behavior should apply when an operator never answers?]

## 6. Readiness Gate

Completeness 4/5; Testability 4/5; Clarity 4/5; Feasibility 4/5. **Overall 4.0/5 — PASS with concerns.** Resolve identity mapping and wait-expiry policy during TRD.
