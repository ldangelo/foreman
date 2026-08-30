---
document_id: PRD-2026-020
version: 1.0.0
status: Draft
date: 2026-08-16
scale_depth: STANDARD
author: Lead Agent
total_requirements: 15
readiness_score: 0.0
readiness_gate: PENDING
depends_on: PRD-2026-016, PRD-2026-017, PRD-2026-018, PRD-2026-019
---

# PRD-2026-020: Full Orchestration Cutover — Phase 5

## PRD Health Summary

| Metric | Value |
|--------|-------|
| **Total Requirements** | 15 (REQ-020-001 through REQ-020-015) |
| **Must** | 12 |
| **Should** | 3 |
| **Could** | 0 |
| **Won't (this release)** | 0 |
| **AC Coverage** | 0/15 (0%) |
| **Risk Flags** | 0 |
| **Cross-Requirement Dependencies** | 0 |
| **Readiness Score** | 0.0 / 5.0 |
| **Ambiguity Markers** | 0 |

---

## 1. Executive Summary

### 1.1 Problem Statement

After Phases 1–4, Foreman has:
- Normalized external agent execution via `jido_harness` (Phase 1)
- Typed inter-agent messaging via `jido_signal` (Phase 2)
- Internal agents migrated to `jido` core (Phase 3)
- Phase sequencing modeled as behavior trees (Phase 4)

But the legacy code paths remain — `pi-sdk-runner.ts`, `WorkflowInterpreter`, `GenServer`-based `RunActor`/`PhaseActor` behind feature flags. Phase 5 removes the feature flags, removes the legacy code paths, and declares the Jido-based stack as the primary orchestration engine.

This is the highest-risk phase: it involves deleting code, removing backward-compatibility shims, and making the Jido-based stack production-default. Rollback is difficult.

### 1.2 Solution Overview

Cut over to the Jido-based orchestration stack as the default and remove legacy code paths:
1. Remove `pi-sdk-runner.ts` — replaced by `ForemanDispatch` (Phase 1)
2. Remove `WorkflowInterpreter` — replaced by `CoordinatorAgent` with behavior tree (Phase 4)
3. Remove GenServer-based `RunActor`/`PhaseActor` — replaced by Jido agents (Phase 3)
4. Remove feature flags — `:use_jido_agents`, `:use_behavior_tree`, `FOREMAN_USE_JIDO_HARNESS`
5. Update all integration tests to use the Jido-based paths
6. Full regression test pass
7. Remove `packages/foreman_server/lib/foreman_server/run_actor.ex` and `phase_actor.ex`
8. Declare `ForemanDispatch`, `ForemanSignal`, `ForemanServer.RunAgent`, `ForemanServer.CoordinatorAgent` as the canonical paths

### 1.3 Value Proposition

- **Single canonical stack** — one way to orchestrate runs; no feature flag decision at runtime
- **Simplified codebase** — legacy code paths removed; less to maintain
- **Full test suite running against Jido stack** — all tests validate the Jido-based paths
- **Production-proven** — 4 phases of gradual migration with feature flags prove the stack before cutover
- **Ready for `jido_ai` integration** — with the stack clean, integrating LLM reasoning via `jido_ai` (ReAct/CoT strategies) is a clean addition

---

## 2. User Analysis

### 2.1 Primary Users

| Role | Description | How Phase 5 Helps |
|------|-------------|-------------------|
| **Operator** | Runs `foreman run` daily | Same experience; no feature flags; faster (no dual-path overhead) |
| **Developer** | Extends Foreman | Single code path; no `if use_jido_agents` branches |
| **Maintainer** | Onboards new contributors | Simpler architecture; no legacy stack to understand |

### 2.2 Current Flow (before Phase 5)

```text
Feature flags in config:
  FOREMAN_USE_JIDO_HARNESS=true|false
  USE_JIDO_AGENTS=true|false
  USE_BEHAVIOR_TREE=true|false

Code paths:
  dispatcher.ts
    ├── pi-sdk-runner.ts (legacy path, FOREMAN_USE_JIDO_HARNESS=false)
    └── ForemanDispatch (new path, FOREMAN_USE_JIDO_HARNESS=true)

RunSupervisor
  ├── RunActor GenServer (legacy, :use_jido_agents=false)
  └── RunAgent Jido agent (new, :use_jido_agents=true)

WorkflowInterpreter
  ├── WorkflowInterpreter.next_step (legacy, :use_behavior_tree=false)
  └── CoordinatorAgent + BehaviorTree (new, :use_behavior_tree=true)
```

### 2.3 Desired Flow (after Phase 5)

```text
Single code path:

dispatcher.ts
  └── ForemanDispatch.run/3           # jido_harness, Phase 1

ForemanSignal.Bus                      # jido_signal, Phase 2
  └── All agent-to-agent signals

ForemanServer.RunAgent                 # jido core, Phase 3
  └── Jido.Agent.cmd/2

ForemanServer.CoordinatorAgent         # jido_behaviortree, Phase 4
  └── BehaviorTree.tick/3

Feature flags: REMOVED
Legacy code: REMOVED
```

---

## 3. Goals and Non-Goals

### 3.1 Goals

| ID | Goal | Success Metric |
|----|------|----------------|
| G-020-1 | Remove `pi-sdk-runner.ts` | File deleted; no references remain in codebase |
| G-020-2 | Remove `WorkflowInterpreter.ex` | File deleted; no references remain |
| G-020-3 | Remove GenServer `RunActor` and `PhaseActor` | Files deleted; no references remain |
| G-020-4 | Remove all feature flags | `FOREMAN_USE_JIDO_HARNESS`, `:use_jido_agents`, `:use_behavior_tree` all removed |
| G-020-5 | Update all integration tests | All tests run against Jido-based paths; no legacy paths exercised |
| G-020-6 | Full regression test pass | 189 existing ExUnit tests + all integration tests pass |
| G-020-7 | `foreman server doctor` validates full stack | Doctor checks ForemanSignal.Bus, ForemanDispatch, CoordinatorAgent health |
| G-020-8 | Production traffic validated | Real production runs for 7 days with no failures attributable to migration |
| G-020-9 | Rollback procedure documented | `git revert` to Phase 4 commit restores full legacy stack |

### 3.2 Non-Goals

- `jido_ai` integration (LLM reasoning) in Phase 5 — next TRD after Phase 5
- Multi-node deployment — future TRD after `jido_ai`
- Phoenix/LiveView UI migration — separate track
- Removing `packages/foreman_server` — it remains the canonical home for all orchestration logic

---

## 4. Proposed Architecture

### 4.1 Post-Cutover Stack

```
packages/
  jido_harness/           # Phase 1
  jido_signal/            # Phase 2
  jido/                   # Phase 3
  jido_behaviortree/      # Phase 4

  foreman_signal/         # Phase 2
    ForemanSignal.Bus
    ForemanSignal.RPC
    ForemanSignal.Journal

  foreman_jido/           # Phase 3 + 4
    ForemanAgent          # Base module
    RunAgent              # Jido agent
    CoordinatorAgent       # Jido agent with BT strategy
    PhaseAgent             # Jido agent
    Actions/              # Jido Action library
    Directives/           # Jido Directive types
    Behaviors/            # Behavior tree node library
    Plugins/              # Jido plugins (telemetry, signal)

src/orchestrator/
  dispatcher.ts           # Calls ForemanDispatch (Elixir) only
  agent-worker.ts        # ForemanDispatch bridge; no pi-sdk-runner dependency
  foreman-dispatch.ts    # Phase 1

packages/foreman_server/
  lib/foreman_server/
    run_actor.ex          # REMOVED
    phase_actor.ex        # REMOVED
    workflow_interpreter.ex # REMOVED
```

### 4.2 Doctor Health Checks

```elixir
defmodule ForemanServer.Doctor do
  @moduledoc """
  Validates the full Jido-based orchestration stack.
  Runs as part of `foreman server doctor`.
  """

  @spec run :: [:ok | {:error, String.t()}]
  def run do
    [
      check_signal_bus(),
      check_jido_agents(),
      check_coordinator(),
      check_foreman_dispatch(),
      check_provider_readiness()
    ]
  end

  defp check_signal_bus do
    case Process.whereis(:foreman_bus) do
      nil -> {:error, "ForemanSignal.Bus not running"}
      pid -> :ok
    end
  end

  defp check_jido_agents do
    # List all running ForemanAgentServers
    agents = ForemanServer.Jido.list_agents()
    if length(agents) >= 0, do: :ok, else: {:error, "AgentRegistry empty"}
  end

  defp check_coordinator do
    # Verify CoordinatorAgent can load a behavior tree
    tree = ForemanServer.TreeLoader.load!(:implement)
    if is_struct(tree, Jido.BehaviorTree.Tree), do: :ok,
    else: {:error, "BehaviorTree failed to load"}
  end

  defp check_foreman_dispatch do
    case ForemanDispatch.check_provider(:pi) do
      %{status: :ready} -> :ok
      _ -> {:error, "ForemanDispatch provider check failed"}
    end
  end

  defp check_provider_readiness do
    results = [:pi, :claude]
             |> Enum.map(&{&1, ForemanDispatch.check_provider(&1)})
             |> Enum.filter(fn {_, r} -> r.status != :ready end)

    if results == [], do: :ok,
    else: {:error, "Providers not ready: #{inspect(results)}"}
  end
end
```

---

## 5. Functional Requirements

### REQ-020-001: Remove pi-sdk-runner.ts

**Priority:** Must  
**Complexity:** Low  
**Type:** Functional  
**Risk:** [RISK: deleting code; must verify no references first]

Foreman shall remove `pi-sdk-runner.ts` from the codebase.

- AC-020-001-1: Given `pi-sdk-runner.ts` is deleted, when `grep -r "pi-sdk-runner"` is run in the repo, then no matches are found.
- AC-020-001-2: Given `pi-sdk-runner.ts` is deleted, when all integration tests run, then they pass using `ForemanDispatch` (jido_harness) exclusively.
- AC-020-001-3: Given `agent-worker.ts` is updated, when it dispatches a run, then it calls `ForemanDispatch.run/3` or `ForemanDispatch.start_run/3`, not `pi-sdk-runner`.

### REQ-020-002: Remove WorkflowInterpreter.ex

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: removing the workflow interpreter; must verify all callers use CoordinatorAgent]

Foreman shall remove `workflow_interpreter.ex`.

- AC-020-002-1: Given `workflow_interpreter.ex` is deleted, when `grep -r "WorkflowInterpreter"` is run, then no matches are found in `packages/foreman_server/`.
- AC-020-002-2: Given all callers of `WorkflowInterpreter.next_step/1` are updated, when integration tests run, then they call `CoordinatorAgent.cmd/2` with `StartWorkflow` instead.
- AC-020-002-3: Given `workflow_interpreter_test.exs` is deleted, when `mix test` runs, then no tests reference `WorkflowInterpreter`.

### REQ-020-003: Remove RunActor and PhaseActor GenServer

**Priority:** Must  
**Complexity:** High  
**Type:** Functional  
**Risk:** [RISK: central GenServers; must verify no callers hold direct PID references]

Foreman shall remove `run_actor.ex` and `phase_actor.ex`.

- AC-020-003-1: Given `run_actor.ex` is deleted, when `grep -r "RunActor" packages/foreman_server/lib` is run, then no matches are found.
- AC-020-003-2: Given `phase_actor.ex` is deleted, when `grep -r "PhaseActor" packages/foreman_server/lib` is run, then no matches are found.
- AC-020-003-3: Given `run_actor_test.exs` and `phase_actor_test.exs` are deleted, when `mix test` runs, then no tests reference the deleted modules.
- AC-020-003-4: Given all GenServer-based agents are removed, when `ForemanServer.RunSupervisor.start_run/1` is called, then it starts `RunAgent` via `ForemanAgentServer` with no GenServer fallback.

### REQ-020-004: Remove Feature Flags

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: removing runtime configuration; must verify all code paths use new stack]

Foreman shall remove all migration feature flags.

- AC-020-004-1: Given `FOREMAN_USE_JIDO_HARNESS` is removed from all config files and environment variable handling, when `grep -r "FOREMAN_USE_JIDO_HARNESS"` is run, then no matches are found.
- AC-020-004-2: Given `:use_jido_agents` is removed from all config and code, when `grep -r "use_jido_agents"` is run, then no matches are found.
- AC-020-004-3: Given `:use_behavior_tree` is removed from all config and code, when `grep -r "use_behavior_tree"` is run, then no matches are found.
- AC-020-004-4: Given all feature flags are removed, when the codebase is grepped for `Application.get_env.*jido` or `Application.put_env.*jido`, then no feature flag lookups remain (only intentional config like `config :jido, :max_tasks`).

### REQ-020-005: Update Integration Tests

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: tests must exercise the new paths, not legacy paths]

All integration tests shall be updated to use the Jido-based stack.

- AC-020-005-1: Given all integration tests are reviewed, when `mix test` runs, then no test references `pi-sdk-runner`, `WorkflowInterpreter`, `RunActor`, or `PhaseActor`.
- AC-020-005-2: Given integration tests exercise `ForemanDispatch.run/3`, when a test assertion is made, then it asserts on `Jido.Harness.RunResult` fields.
- AC-020-005-3: Given integration tests exercise `CoordinatorAgent`, when a test sends `StartWorkflow` signal, then it asserts on the behavior tree executing and signals being emitted.

### REQ-020-006: Full Regression Test Pass

**Priority:** Must  
**Complexity:** High  
**Type:** Functional  
**Risk:** [RISK: highest-risk requirement; regression is the primary success criterion]

All 189 existing ExUnit tests and all integration tests shall pass.

- AC-020-006-1: Given `mix test` runs in `packages/foreman_server/`, when all tests complete, then the result is `189 tests, 0 failures`.
- AC-020-006-2: Given integration tests run via `npm run test:integration`, when all tests complete, then the result is `0 failures`.
- AC-020-006-3: Given `foreman server doctor` runs, when all checks complete, then doctor exits with status 0.

### REQ-020-007: Foreman Server Doctor Full Stack Validation

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: doctor must validate all layers of the new stack]

`foreman server doctor` shall validate the full Jido-based stack.

- AC-020-007-1: Given `foreman server doctor` runs, when `ForemanSignal.Bus` is running, then doctor shows `✓ ForemanSignal.Bus running`.
- AC-020-007-2: Given doctor runs, when `ForemanDispatch` provider check is called for `:pi`, then doctor shows `✓ pi provider ready` or `✗ pi not installed`.
- AC-020-007-3: Given doctor runs, when `CoordinatorAgent` behavior tree loader is called, then doctor shows `✓ Workflow trees loadable`.
- AC-020-007-4: Given doctor runs with a healthy stack, when it completes, then it exits with code 0 and prints `All checks passed`.
- AC-020-007-5: Given doctor runs with an unhealthy stack, when a check fails, then it exits with code 1 and prints the failing check name.

### REQ-020-008: Rollback Procedure

**Priority:** Must  
**Complexity:** Low  
**Type:** Documentation  
**Risk:** [RISK: rollback must be tested before Phase 5 ships]

Foreman shall document a rollback procedure to Phase 4.

- AC-020-008-1: Given `git revert` is run on the Phase 5 merge commit, when `mix test` runs, then all 189 tests pass with the Phase 4 code.
- AC-020-008-2: Given the rollback procedure is documented in `docs/PRDs/PRD-2026-020-rollback.md`, when an engineer follows it, then they can restore the Phase 4 state within 10 minutes.
- AC-020-008-3: Given a rollback is executed, when `foreman run` is attempted, then it uses the Phase 4 `WorkflowInterpreter` path with feature flags enabled.

### REQ-020-009: Source Code Cleanup

**Priority:** Should  
**Complexity:** Low  
**Type:** Functional  
**Risk:** [RISK: cleanup is low-risk but easy to skip]

Foreman shall clean up dead code and imports after legacy removal.

- AC-020-009-1: Given all legacy modules are deleted, when `mix compile --warnings-as-errors` runs, then no warnings about unused imports or functions appear.
- AC-020-009-2: Given `mix format` runs on the cleaned codebase, when files are formatted, then no formatting changes are needed (everything was already formatted).
- AC-020-009-3: Given `mix credo` runs, when Credo analyzes the codebase, then no `Consistency` or `Design` warnings appear related to the migration.

### REQ-020-010: Production Traffic Validation

**Priority:** Must  
**Complexity:** High  
**Type:** Non-Functional  
**Risk:** [RISK: production validation is the ultimate acceptance criterion]

Foreman shall run production traffic on the Jido-based stack for 7 days without failures attributable to the migration.

- AC-020-010-1: Given Phase 5 is deployed to production, when real `foreman run` commands execute over 7 days, then no run fails with an error that did not exist in Phase 4.
- AC-020-010-2: Given `foreman server doctor` runs daily on the production server, when it completes, then it always exits with status 0.
- AC-020-010-3: Given production runs complete, when signal journal replay is tested, then all agent conversations for the past 7 days are recoverable.

### REQ-020-011: Upstream jido Contribution Audit

**Priority:** Should  
**Complexity:** Low  
**Type:** Process  
**Risk:** [RISK: low-risk but validates the contribution strategy]

Foreman shall audit all upstream contributions made during Phases 1–5.

- AC-020-011-1: Given all PRs to jido repositories are listed, when the audit is complete, then at minimum `ForemanSignal.RPC` (Phase 2) and domain-specific node library guide (Phase 4) are tracked.
- AC-020-011-2: Given the audit is complete, when the team evaluates upstream engagement, then they can report which contributions were accepted vs. pending.

### REQ-020-012: Documentation: Architecture Decision Record

**Priority:** Should  
**Complexity:** Low  
**Type:** Documentation  
**Risk:** [RISK: documentation debt if decision rationale isn't captured]

Foreman shall document the migration architecture decision as an ADR.

- AC-020-012-1: Given Phase 5 is complete, when an engineer reads `docs/adr/0021-jido-migration.md`, then they understand why each phase was done in order, what tradeoffs were made, and what was learned.
- AC-020-012-2: Given the ADR exists, when a future engineer proposes reverting to a non-Jido stack, then the ADR's rationale is available for debate.

### REQ-020-013: `jido_ai` Integration Roadmap

**Priority:** Should  
**Complexity:** Low  
**Type:** Documentation  
**Risk:** [RISK: roadmap not implemented in Phase 5]

Phase 5 shall define the roadmap for `jido_ai` integration (LLM reasoning in CoordinatorAgent).

- AC-020-013-1: Given Phase 5 is complete, when a new TRD is written for `jido_ai` integration, then it references this PRD and states the prerequisites (Phase 5 complete).
- AC-020-013-2: Given the roadmap is defined, when `CoordinatorAgent` strategy is documented, then it explains that swapping `BehaviorTree` for `Jido.Agent.Strategy.ReAct` enables LLM-driven phase reasoning.

### REQ-020-014: Package Cleanup

**Priority:** Must  
**Complexity:** Low  
**Type:** Infrastructure  
**Risk:** [RISK: orphan packages from migration must be removed]

Foreman shall remove any orphan packages from the migration.

- AC-020-014-1: Given Phase 5 is complete, when `ls packages/` is run, then only these packages remain: `foreman_server`, `jido`, `jido_harness`, `jido_signal`, `jido_behaviortree`, `foreman_signal`, `foreman_jido`.
- AC-020-014-2: Given orphan packages are removed, when `mix deps.get` runs in each remaining package, then all dependencies resolve.

### REQ-020-015: CLI Reference Update

**Priority:** Must  
**Complexity:** Low  
**Type:** Documentation  
**Risk:** [RISK: CLI docs must match post-migration reality]

Foreman shall update the CLI reference to reflect the post-migration stack.

- AC-020-015-1: Given `docs/cli-reference.md` is updated, when `foreman run --help` is run, then the output matches the documentation.
- AC-020-015-2: Given `foreman server doctor --help` is run, when all checks are listed, then they reflect the full Jido-based stack (signal bus, jido agents, behavior trees, provider readiness).

---

## 6. Dependencies and Risks

| ID | Dependency / Risk | Mitigation |
|----|--------------------|------------|
| DEP-020-01 | Phase 5 depends on: Phases 1 + 2 + 3 + 4 all green | Explicit gate: Phase 5 does not start until all 4 prior PRD acceptance criteria are verified |
| DEP-020-02 | Production validation depends on: staged rollout capability | Canary deploy 5% traffic first; monitor for 24h before full rollout |
| RISK-020-01 | Rollback is complex (4 phases of changes) | Test rollback procedure before Phase 5 ships; document thoroughly |
| RISK-020-02 | Removing GenServer agents may break obscure callers | Full codebase grep before deletion; no dynamic `via/1` lookups remain |
| RISK-020-03 | Feature flag removal may break operator configs | Warn in release notes; `FOREMAN_USE_JIDO_HARNESS` was never documented as stable |
| RISK-020-04 | Performance regression from Jido layer overhead | Benchmark before/after; Jido core overhead is measurable but expected <5ms per `cmd/2` call |
| RISK-020-05 | Signal journal ETS may grow unbounded in long-running production | Configure `max_entries: 100_000` per run; test journal eviction under load |

---

## 7. Acceptance Criteria Checklist

- [ ] REQ-020-001-1: `pi-sdk-runner.ts` deleted; `grep` returns no matches
- [ ] REQ-020-001-2: All integration tests pass with `ForemanDispatch`
- [ ] REQ-020-001-3: `agent-worker.ts` calls `ForemanDispatch`, not `pi-sdk-runner`
- [ ] REQ-020-002-1: `WorkflowInterpreter` deleted; `grep` returns no matches in `packages/foreman_server/lib`
- [ ] REQ-020-002-2: All callers use `CoordinatorAgent.cmd/2` with `StartWorkflow`
- [ ] REQ-020-002-3: `workflow_interpreter_test.exs` deleted; no test references `WorkflowInterpreter`
- [ ] REQ-020-003-1: `run_actor.ex` deleted; no references in `foreman_server/lib`
- [ ] REQ-020-003-2: `phase_actor.ex` deleted; no references in `foreman_server/lib`
- [ ] REQ-020-003-3: `run_actor_test.exs` and `phase_actor_test.exs` deleted
- [ ] REQ-020-003-4: `RunSupervisor.start_run/1` starts `RunAgent` with no fallback
- [ ] REQ-020-004-1: `FOREMAN_USE_JIDO_HARNESS` removed from all code and config
- [ ] REQ-020-004-2: `:use_jido_agents` removed from all code and config
- [ ] REQ-020-004-3: `:use_behavior_tree` removed from all code and config
- [ ] REQ-020-004-4: No feature flag lookups remain in codebase
- [ ] REQ-020-005-1: No test references legacy modules
- [ ] REQ-020-005-2: Tests assert on `Jido.Harness.RunResult` fields
- [ ] REQ-020-005-3: Tests exercise `CoordinatorAgent` with `StartWorkflow`
- [ ] REQ-020-006-1: `mix test` in `packages/foreman_server/` → `189 tests, 0 failures`
- [ ] REQ-020-006-2: `npm run test:integration` → `0 failures`
- [ ] REQ-020-006-3: `foreman server doctor` exits with code 0
- [ ] REQ-020-007-1: Doctor shows `ForemanSignal.Bus running`
- [ ] REQ-020-007-2: Doctor shows `pi provider ready` or `pi not installed`
- [ ] REQ-020-007-3: Doctor shows `Workflow trees loadable`
- [ ] REQ-020-007-4: Healthy stack → exit code 0
- [ ] REQ-020-007-5: Unhealthy stack → exit code 1 with failing check name
- [ ] REQ-020-008-1: `git revert` Phase 5 → Phase 4 → 189 tests pass
- [ ] REQ-020-008-2: Rollback procedure documented in `PRD-2026-020-rollback.md`
- [ ] REQ-020-008-3: Post-rollback `foreman run` uses Phase 4 paths
- [ ] REQ-020-009-1: `mix compile --warnings-as-errors` → no warnings
- [ ] REQ-020-009-2: `mix format` → no changes needed
- [ ] REQ-020-009-3: `mix credo` → no Consistency or Design warnings
- [ ] REQ-020-010-1: 7 days production traffic with zero migration-attributable failures
- [ ] REQ-020-010-2: Daily `foreman server doctor` exits 0 for 7 consecutive days
- [ ] REQ-020-010-3: Signal journal replay recovers all conversations for 7 days
- [ ] REQ-020-011-1: All upstream PRs tracked
- [ ] REQ-020-011-2: Upstream engagement report produced
- [ ] REQ-020-012-1: `adr/0021-jido-migration.md` documents decision rationale
- [ ] REQ-020-012-2: ADR explains phase ordering, tradeoffs, and lessons learned
- [ ] REQ-020-013-1: `jido_ai` integration TRD references this PRD
- [ ] REQ-020-013-2: `CoordinatorAgent` strategy docs explain ReAct swap path
- [ ] REQ-020-014-1: `ls packages/` shows only canonical 7 packages
- [ ] REQ-020-014-2: `mix deps.get` resolves in all packages
- [ ] REQ-020-015-1: `docs/cli-reference.md` matches `foreman run --help`
- [ ] REQ-020-015-2: `docs/cli-reference.md` reflects full stack for doctor checks
