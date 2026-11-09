---
document_id: PRD-2026-2cf96e18
label: prd-phase-5-scale-memory-evaluation
version: 1.0.0
status: Draft
date: 2026-11-08
scale_depth: STANDARD
total_requirements: 5
total_acceptance_criteria: 12
readiness_score: 4.0
---

# PRD: Phase 5 — Scale and Memory Evaluation

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 4 |
| Should | 1 |
| Could | 0 |
| Won't (this phase) | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 5/5 (100%) |
| Acceptance-criteria coverage | 5/5 (100%) |
| Risk flags | 5 |
| Open clarification markers | 3 |

## 1. Executive Summary

This phase answers two scale questions with evidence before adding infrastructure: whether Foreman needs Kubernetes-backed agent execution, and whether an optional external memory service provides meaningful retrieval value beyond current project memory and LiteLLM capabilities. It is an evaluation and decision phase; it can conclude that neither service should be adopted.

Foreman’s native `.foreman/memory/` remains the canonical project notebook and audit boundary. Any external memory service is optional, project-scoped, and limited to semantic/episodic recall behind an adapter; it cannot override project policy or replace native memory.

## 2. Scope

### In scope

* Measure execution concurrency, isolation, scheduling, failure, and operational requirements against current host/Docker execution.
* Evaluate Kubernetes only against recorded workload and isolation requirements.
* Compare native project memory, LiteLLM memory capabilities, and at least one self-hosted external candidate on representative use cases.
* Review data isolation, auth, provenance, redaction, retention, deletion, backup/recovery, outage behavior, licensing, operational cost, and maintenance burden.
* Produce separate go/no-go decisions for Kubernetes and external memory.

### Out of scope

* Automatically deploying Kubernetes or an external memory service because it was evaluated.
* Replacing native project memory or moving canonical project notes out of Foreman.
* Sending project data to an external memory provider without explicit per-project enablement.

## 3. Requirements

### REQ-001: Establish evidence-based execution scale requirements

Priority: Must; Complexity: High. Risk: Premature Kubernetes adoption adds substantial operational complexity without value.

* AC-001-1: Given representative Foreman workloads, when a benchmark is completed, then it reports concurrency, queueing, resource use, startup time, failure recovery, and isolation results for current backends.
* AC-001-2: Given current backends meet declared workload/isolation needs, when the decision is recorded, then Kubernetes is not required for this phase’s outcome.
* AC-001-3: Given measured gaps justify a Kubernetes evaluation, when the proposal is presented, then it includes workload evidence, operational/security impact, migration and rollback approach, and explicit operator approval requirement.

### REQ-002: Evaluate Kubernetes as an optional executor

Priority: Should; Complexity: High. Risk: Kubernetes may create a new control plane and broader attack surface.

* AC-002-1: Given Kubernetes is evaluated, when the threat model and benchmark are reviewed, then the evaluation compares it against current alternatives using the same representative workloads and isolation requirements.
* AC-002-2: Given Kubernetes is selected for implementation, when the phase decision is approved, then deployment, namespace/network/credential isolation, upgrades, recovery, cost, and rollback have documented owners and acceptance gates.

### REQ-003: Keep native project memory canonical

Priority: Must; Complexity: Medium. Risk: A second source of truth can diverge or make project notes non-portable.

* AC-003-1: Given no external provider is configured, when an agent reads/writes project notes, then existing native memory behavior remains unchanged and no external service receives project content.
* AC-003-2: Given an external recall provider is enabled, when it returns content, then results are labeled as retrieved evidence with provenance and cannot override system/project authorization or native memory ownership.

### REQ-004: Benchmark external memory candidates securely

Priority: Must; Complexity: High. Risk: Cross-project retrieval, stale recall, or secret retention may expose confidential data.

* AC-004-1: Given candidates are assessed, when the bake-off runs, then native memory, LiteLLM memory API, and at least one external self-hosted candidate are evaluated on identical representative tasks for retrieval quality, latency, tenancy, provenance, deletion, redaction, outage behavior, operating cost, license, and maintenance.
* AC-004-2: Given a candidate cannot enforce/project-test tenant boundaries, provenance, deletion, or redaction requirements, when results are reviewed, then it is rejected for production use regardless of retrieval score.
* AC-004-3: Given no candidate materially improves a defined recall use case at acceptable operational/security cost, when the decision is recorded, then the recommendation is to retain native memory without deploying a service.

### REQ-005: Define optional-provider and bounded-failure behavior

Priority: Must; Complexity: High. Risk: Memory service outage could block unrelated factory work or cause unsafe fallback.

* AC-005-1: Given an external provider is eventually adopted, when it is disabled or unavailable, then native project memory continues to work and unrelated workflow stages fail or degrade only according to explicit bounded policy.
* AC-005-2: Given an external provider is enabled for a project, when data is written/recalled/deleted, then access is project-scoped, redacted, provenance-bearing, auditable, and subject to documented retention and backup/deletion controls.

## 4. Evaluation plan and exit criteria

Exit with separate signed decisions for execution scale and external memory, each supported by benchmark/security/operations evidence. “Do not adopt” is a successful outcome. No service deployment or data migration is implied by this PRD.

| Candidate | Evaluation focus |
|---|---|
| Current host/Docker executors | Isolation, concurrency, recovery, cost, operational complexity. |
| Kubernetes executor | Only if measured workload/isolation gaps warrant it; include cluster/network/credential operations. |
| Foreman native project memory | Canonical notebook, portability, ownership, audit, redaction, current retrieval limits. |
| LiteLLM memory API | Versioned API maturity, storage/retrieval semantics, authentication, tenant isolation, operations. |
| Self-hosted external candidate (e.g. AgentMemory) | API/license/security maturity, isolation, provenance, hybrid retrieval, deletion, deployment burden. |

Candidate references: <https://docs.litellm.ai/docs/memory_management> and <https://github.com/flaber411/agentmemory>. Verify current versions, licensing, security posture, and tenant guarantees during assessment.

## 5. Open Decisions

* [NEEDS CLARIFICATION: What target concurrency and workload profile should the executor benchmark represent?]
* [NEEDS CLARIFICATION: What data classes, regions, and retention/deletion obligations apply to any external memory service?]
* [NEEDS CLARIFICATION: Which operator owns production support for optional Kubernetes or memory services?]

## 6. Readiness Gate

Completeness 4/5; Testability 4/5; Clarity 4/5; Feasibility 4/5. **Overall 4.0/5 — PASS with concerns.** Define benchmark workload and data governance constraints before a TRD. Adoption is explicitly not pre-approved.
