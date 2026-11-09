---
document_id: PRD-2026-b7c2e941
label: prd-sunstone-software-factory-roadmap
version: 2.0.0
status: Draft
date: 2026-11-08
scale_depth: STANDARD
phase_prds: 6
readiness_score: 4.2
---

# SunStone Partners Software Factory for Foreman — Product Roadmap

> This document is the portfolio roadmap and navigation index, **not a single implementation PRD**. Each phase has its own independently reviewable PRD and can be refined, approved, and implemented as a separate change. The phase PRDs are the authoritative scope and acceptance criteria for their respective increments.

## Product vision

Evolve Foreman into a safe, auditable software factory that can cultivate an idea, produce approved product/technical specifications, implement changes in isolated workspaces, verify quality, review risk, and deliver a PR with an appropriate human or automated merge disposition.

The roadmap deliberately separates value into incremental releases. Durable execution is an explicit prerequisite; quality enforcement precedes any merge automation; idea cultivation and conversational learning follow as separately shippable capabilities; Kubernetes and external memory are evaluation gates, not assumed infrastructure investments.

## Current baseline

Foreman already has event-sourced run orchestration, project context and native project memory, worktree-based workflow runs, review workflows, PR creation, a SHA-pinned human merge gate, outbound notifications, LiteLLM configuration, and OpenTelemetry support. Important gaps include durable stage-level recovery guarantees, server-enforced check evidence for generated PRs, risk-tiered decisions, first-class idea cultivation, inbound chat response handling, post-run learning, and decisions about execution scale and external semantic memory.

The baseline is described in the original design at `packages/foreman_server/docs/sotware_factory.md` and in the repository review that informed the phase PRDs. Re-validate implementation details during each phase’s TRD work.

## Phase roadmap

| Phase | PRD | Incremental outcome | Dependency |
|---|---|---|---|
| **0 — Durable execution and safety foundation** | [Phase 0 PRD](PRD-2026-a804d1c7-phase-0-durable-execution.md) | Assess and establish durable workflow semantics, stage provenance, project context, baseline isolation, and the execution-engine decision. | Foundation; prerequisite to the other phases. |
| **1 — Trustworthy PR delivery** | [Phase 1 PRD](PRD-2026-c12e5f93-phase-1-trustworthy-pr-delivery.md) | Enforce machine-verifiable quality evidence; publish structured risk findings; keep all merges human-approved. | Phase 0. |
| **2 — Bounded merge automation** | [Phase 2 PRD](PRD-2026-9b7306a2-phase-2-bounded-merge-automation.md) | Opt-in MEDIUM/LOW auto-merge only under explicit, verified safeguards. | Phase 1 exit criteria. |
| **3 — Idea-to-spec lifecycle** | [Phase 3 PRD](PRD-2026-e4f18c60-phase-3-idea-to-spec.md) | Add idea cultivation/go-no-go and independently reviewable PRD/TRD stages. | Phase 0; does not require Phase 2. |
| **4 — Operator interaction and learning** | [Phase 4 PRD](PRD-2026-71d0ab45-phase-4-operator-interaction-learning.md) | Resume waiting work through authenticated conversations and turn run outcomes into governed improvement proposals. | Phase 0; Phase 3 provides an early use case but is not required for all capabilities. |
| **5 — Scale and memory evaluation** | [Phase 5 PRD](PRD-2026-2cf96e18-phase-5-scale-memory-evaluation.md) | Benchmark Kubernetes/executor needs and evaluate optional external semantic memory without replacing native project memory. | Phase 0; independent decision gates. |

## Portfolio sequencing

* Phase 0 explicitly includes a **durable execution engine assessment and decision**. Extend Foreman’s current event-sourced orchestration if it meets the requirements. Temporal or Conductor are alternatives to evaluate only when concrete gaps are demonstrated; neither is the default choice.
* Phase 1 preserves human approval for every merge. Do not enable auto-merge until Phase 1 is complete and Phase 2 is separately approved.
* Phase 3 can proceed after the Phase 0 foundation and can deliver value without auto-merge.
* Phase 4’s conversational adapters must not acquire approval/merge authority. Post-run learning produces proposals, never autonomous policy changes.
* Phase 5 may conclude that Kubernetes or an external memory service is not justified. Foreman’s native project memory remains canonical.
* Each phase is a separate approval and delivery unit. A later phase does not block delivery of an earlier completed phase.

## Shared product constraints

* Project constitution, instructions, repositories, and native memory remain project-owned context; server-side authorization and safety rules remain authoritative.
* Worktree separation is required but does not alone constitute process/filesystem/network sandboxing. Execution isolation must be explicit and enforced.
* Missing, stale, ambiguous, or untrusted evidence fails closed at quality and merge boundaries.
* HIGH-risk changes always require human approval pinned to the current PR head.
* External services are optional adapters, isolated by project/tenant, with provenance, redaction, deletion, retention, and bounded-outage behavior.
* Prefer existing Unix tools and integrations (Git, GitHub CLI, worktree tooling, Kata, Herdr, LiteLLM, Ensemble, and supported coding harnesses) over parallel bespoke systems.

## Research references

* Temporal Durable AI: <https://docs.temporal.io/ai>
* Conductor OSS AI orchestration: <https://conductor-oss.github.io/conductor/devguide/ai/index.html>
* LiteLLM memory API: <https://docs.litellm.ai/docs/memory_management>
* AgentMemory: <https://github.com/flaber411/agentmemory>

Candidate maturity, licensing, API and tenancy guarantees, supported versions, and operational fit must be verified in the relevant phase before adoption.

## Approval

This roadmap does not authorize implementation of all phases as one change. Each phase PRD must be refined, reviewed, and approved independently. Phase 0 approval authorizes only its defined discovery/foundation scope; subsequent phase work requires its own acceptance and prioritization.
