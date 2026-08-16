---
document_id: PRD-2026-018
version: 1.0.0
status: Draft
date: 2026-08-16
scale_depth: STANDARD
author: Lead Agent
total_requirements: 16
readiness_score: 0.0
readiness_gate: PENDING
depends_on: PRD-2026-016, PRD-2026-017
---

# PRD-2026-018: jido Core Agent Migration — Phase 3

## PRD Health Summary

| Metric | Value |
|--------|-------|
| **Total Requirements** | 16 (REQ-018-001 through REQ-018-016) |
| **Must** | 11 |
| **Should** | 4 |
| **Could** | 1 |
| **Won't (this release)** | 0 |
| **AC Coverage** | 0/16 (0%) |
| **Risk Flags** | 0 |
| **Cross-Requirement Dependencies** | 0 |
| **Readiness Score** | 0.0 / 5.0 |
| **Ambiguity Markers** | 0 |

---

## 1. Executive Summary

### 1.1 Problem Statement

Foreman's internal agents (RunActor, PhaseActor, VCSEgent, RecoveryAgent, CoordinatorAgent) are implemented as plain `GenServer` modules with implicit state transitions, ad-hoc error handling, mixed business logic in callbacks, and no standardized action/directive separation. Testing requires spawning processes and sending messages — unit testing is possible but not ergonomic. Adding a new agent type requires duplicating the GenServer pattern.

The work done in Phase 2 (signal bus) enables loose coupling between agents. Phase 3 makes each agent a **first-class Jido agent** with:
- Immutable state structs with schema validation
- Pure `cmd/2` decision functions — fully unit-testable without spawning processes
- Actions as the unit of work
- Directives for runtime-owned effects
- Pluggable strategies (Direct, FSM, ReAct, BehaviorTree)

### 1.2 Solution Overview

Migrate Foreman's internal agents to `Jido.Agent` with `Jido.Agent.cmd/2` as the core operation. Each agent becomes a data struct with schema-validated state. Decision logic is pure and testable. Actions transform state; directives describe effects the runtime executes. `Jido.AgentServer` wraps agents in supervised GenServers with signal routing.

This phase does **not** remove the existing GenServer-based agents. It adds Jido agents alongside them with a feature flag, enabling incremental migration and rollback.

### 1.3 Value Proposition

- **Pure unit tests** — `MyAgent.cmd(agent, action)` is a pure function; test every decision without processes or LLM calls.
- **Schema-validated state** — agent state is validated at construction and after every `cmd/2` call.
- **Standardized action interface** — every capability is a `Jido.Action` module with compile-time schema validation.
- **Directive-based effects** — side effects are described as typed directives; the runtime owns execution.
- **Pluggable strategies** — swap `Direct` for `FSM` or `BehaviorTree` without changing agent logic.
- **Inheritance via `use Jido.Agent`** — new agent types get supervision, signal routing, and directive execution for free.
- **Foreman upstream contribution** — `ForemanAgent` base module with Foreman-specific plugins, telemetry, and action libraries gets proposed as `jido_foreman` or contributed to jido core.

---

## 2. User Analysis

### 2.1 Primary Users

| Role | Description | How Phase 3 Helps |
|------|-------------|-------------------|
| **Developer** | Adds a new agent type (e.g., JiraSyncAgent) | Inherits supervision + signal routing; writes only the action logic |
| **Maintainer** | Tests agent decision logic | Tests are pure function calls; no GenServer mocking |
| **Operator** | Observes agent health | Jido.AgentServer telemetry shows agent state, directive queue depth |

### 2.2 Current Flow (before Phase 3)

```elixir
# RunActor — GenServer with implicit state
defmodule ForemanServer.RunActor do
  use GenServer
  def init(spec) -> {:ok, %{run_id: spec.run_id, phase: nil, status: :idle}}
  def handle_call({:run_phase, phase_id, spec}, _, state) ->
    # business logic mixed in callback
    {:reply, {:ok, result}, %{state | phase: phase_id, status: :running}}
  end
end
```

### 2.3 Desired Flow (after Phase 3)

```elixir
# RunAgent — Jido Agent with pure decision logic
defmodule ForemanServer.RunAgent do
  use Jido.Agent,
    name: "run",
    description: "Manages a run through its lifecycle",
    schema: [
      run_id: [type: :string, required: true],
      phase: [type: :string, default: nil],
      status: [type: :atom, default: :idle]
    ],
    signal_routes: [
      {"run.phase.started", ForemanServer.Actions.RunPhaseStarted}
    ],
    actions: [
      ForemanServer.Actions.InitializeRun,
      ForemanServer.Actions.CompletePhase,
      ForemanServer.Actions.FailRun
    ]

  # Pure function — fully testable
  def cmd(agent, action), do: Jido.Agent.cmd(agent, action)
end

# Test — no GenServer, no mocking
test "run agent completes phase" do
  agent = ForemanServer.RunAgent.new!(run_id: "run_123")
  {agent, []} = ForemanServer.RunAgent.cmd(agent, {CompletePhase, phase_id: "phase_1"})
  assert agent.state.phase == "phase_1"
  assert agent.state.status == :running
end
```

---

## 3. Goals and Non-Goals

### 3.1 Goals

| ID | Goal | Success Metric |
|----|------|----------------|
| G-018-1 | Vendor `jido` under `packages/jido` | Package builds and tests pass |
| G-018-2 | Create `ForemanServer.ForemanAgent` base module | All Foreman agents inherit from it |
| G-018-3 | Migrate RunActor to `ForemanServer.RunAgent` as Jido agent | `RunAgent.cmd/2` replaces `GenServer.call` for new runs |
| G-018-4 | Migrate PhaseActor to `ForemanServer.PhaseAgent` | Phase sequencing via `Jido.Agent.cmd/2` |
| G-018-5 | Create `ForemanServer.Actions` library | Reusable actions: `InitializeRun`, `CompletePhase`, `FailRun`, `EmitSignal`, `SpawnWorker` |
| G-018-6 | 100% decision-logic test coverage for migrated agents | `mix test` on actions covers every state transition |
| G-018-7 | Contribute `ForemanAgent` base module upstream | Propose as `jido_foreman` package or jido core plugin |

### 3.2 Non-Goals

- Behavior tree phase sequencing (Phase 4).
- Full orchestration cutover (Phase 5).
- Removing existing GenServer-based agents in Phase 3 — they coexist behind a feature flag.
- Migrating all agents in Phase 3 — RunAgent and PhaseAgent are the Phase 3 scope; VCSEgent and RecoveryAgent migrate in Phase 4 or 5.
- `jido_ai` integration (LLM reasoning) in Phase 3 — strategy remains `Direct`; ReAct/CoT come later.

---

## 4. Proposed Architecture

### 4.1 Package Layout

```
packages/
  jido/                    # NEW: vendored jido core
    mix.exs
    lib/
      jido/
      ...

  foreman_jido/            # NEW: Foreman's jido extensions
    mix.exs
    lib/
      foreman_jido/
        application.ex
        foreman_agent.ex     # Base module: use Jido.Agent + Foreman plugins
        agents/
          run_agent.ex        # Jido agent for run lifecycle
          phase_agent.ex       # Jido agent for phase execution
          coordinator_agent.ex # Jido agent for task coordination (Phase 4)
        actions/
          initialize_run.ex
          complete_phase.ex
          fail_run.ex
          emit_signal.ex       # Wraps ForemanSignal.Bus.publish
          spawn_worker.ex      # Wraps ForemanDispatch
          schedule_retry.ex
        directives/
          emit_signal.ex       # Jido directive for signal publishing
          spawn_worker.ex       # Jido directive for agent dispatch
        plugins/
          foreman_telemetry.ex  # Jido plugin for Foreman telemetry
          foreman_signal.ex      # Jido plugin: signal routing to ForemanSignal.Bus
```

### 4.2 ForemanAgent Base Module

```elixir
defmodule ForemanServer.ForemanAgent do
  @moduledoc """
  Base module for all Foreman Jido agents.

  Provides:
  - Jido.Agent behavior with Foreman-specific defaults
  - ForemanSignal plugin: all agent signals routed to ForemanSignal.Bus
  - ForemanTelemetry plugin: cmd/2 calls emit structured telemetry
  - Directive execution: EmitSignal, SpawnWorker, ScheduleRetry

  Agents inherit this with:

      defmodule ForemanServer.RunAgent do
        use ForemanServer.ForemanAgent,
          name: "run",
          actions: [InitializeRun, CompletePhase, FailRun]
      end
  """

  defmacro __using__(opts) do
    quote do
      use Jido.Agent,
        name: unquote(opts[:name]),
        description: unquote(opts[:description]),
        schema: unquote(opts[:schema]),
        actions: unquote(opts[:actions]),
        signal_routes: unquote(opts[:signal_routes]),
        strategy: Jido.Agent.Strategy.Direct,
        plugins: [
          ForemanServer.Plugins.ForemanTelemetry,
          ForemanServer.Plugins.ForemanSignal
        ]

      alias ForemanServer.Actions
      alias ForemanServer.Directives
    end
  end
end
```

### 4.3 Actions Library

```elixir
defmodule ForemanServer.Actions.CompletePhase do
  use Jido.Action,
    name: "complete_phase",
    description: "Marks a phase as completed and emits the result",
    schema: [
      phase_id: [type: :string, required: true],
      result: [type: :map, default: %{}]
    ]

  def run(params, context) do
    # Pure state transformation
    {:ok,
     %{
       phase: params.phase_id,
       result: params.result,
       status: :phase_completed
     }}
  end
end

defmodule ForemanServer.Actions.EmitSignal do
  use Jido.Action,
    name: "emit_signal",
    description: "Emits a signal to ForemanSignal.Bus as a directive",
    schema: [
      signal_type: [type: :string, required: true],
      data: [type: :map, required: true],
      cause: [type: :string, default: nil]
    ]

  def run(params, context) do
    # Returns a directive for the runtime to execute
    {:ok, %{},
     directives: [
       %ForemanServer.Directives.EmitSignal{
         signal_type: params.signal_type,
         data: params.data,
         cause: params.cause || context.current_signal_id
       }
     ]}
  end
end
```

### 4.4 Migration Coexistence Strategy

```elixir
# Feature flag: :use_jido_agents (default: false until Phase 5)
config :foreman_server, :use_jido_agents, false

# In ForemanServer.RunSupervisor:
def start_run(spec) do
  if Application.get_env(:foreman_server, :use_jido_agents) do
    # Phase 3: Jido agent path
    {:ok, pid} = ForemanServer.RunAgent.start_link(run_id: spec.run_id)
    pid
  else
    # Phase 1-2: Existing GenServer path
    {:ok, pid} = ForemanServer.RunActor.start_run(spec)
    pid
  end
end
```

---

## 5. Functional Requirements

### REQ-018-001: jido Vendoring

**Priority:** Must  
**Complexity:** Low  
**Type:** Infrastructure  
**Risk:** [RISK: fork maintenance burden]

Foreman shall vendor `jido` under `packages/jido`.

- AC-018-001-1: Given `packages/jido/mix.exs` exists, when `mix deps.get` runs, then all jido dependencies resolve without external network access.
- AC-018-001-2: Given the vendored jido, when `mix test` runs, then the core jido test suite passes.

### REQ-018-002: ForemanAgent Base Module

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: base module must be general enough for all agents]

Foreman shall provide `ForemanServer.ForemanAgent` as the base for all Foreman Jido agents.

- AC-018-002-1: Given `use ForemanServer.ForemanAgent` with an agent definition, when the agent module is compiled, then it defines a `new!/1` function returning a validated `%Jido.Agent{}` struct.
- AC-018-002-2: Given `ForemanServer.ForemanAgent` defines `signal_routes`, when a signal matching a route is delivered to `ForemanAgentServer`, then the corresponding action is queued.
- AC-018-002-3: Given `ForemanServer.ForemanAgent` defines `actions`, when `Agent.cmd/2` is called with an unknown action, then it returns `{:error, :unknown_action}`.

### REQ-018-003: RunAgent as Jido Agent

**Priority:** Must  
**Complexity:** High  
**Type:** Functional  
**Risk:** [RISK: RunActor is central; migration must be incremental]

Foreman shall implement `ForemanServer.RunAgent` as a Jido agent.

- AC-018-003-1: Given `RunAgent.new!(run_id: "run_123")`, when the agent is created, then its state has `run_id: "run_123"`, `status: :idle`, and `phase: nil`.
- AC-018-003-2: Given `RunAgent.cmd(agent, {InitializeRun, task_id: "t1", spec: %{}})`, when the action is called, then the returned agent state has `status: :initialized` and the action result contains the run metadata.
- AC-018-003-3: Given `RunAgent.cmd(agent, {CompletePhase, phase_id: "p1", result: %{}})`, when the action is called, then the returned agent state has `status: :phase_completed` and `phase: "p1"`.
- AC-018-003-4: Given `RunAgent.cmd(agent, {FailRun, reason: :timeout})`, when the action is called, then the returned agent state has `status: :failed` and a directive to emit `run.failed` to `ForemanSignal.Bus` is present.

### REQ-018-004: PhaseAgent as Jido Agent

**Priority:** Must  
**Complexity:** High  
**Type:** Functional  
**Risk:** [RISK: PhaseActor has complex state machine; Phase 3 keeps it simple]

Foreman shall implement `ForemanServer.PhaseAgent` as a Jido agent.

- AC-018-004-1: Given `PhaseAgent.new!(phase_id: "p1", spec: spec)`, when the agent is created, then its state has `phase_id: "p1"`, `status: :idle`, and `attempts: 0`.
- AC-018-004-2: Given `PhaseAgent.cmd(agent, {StartPhase, dispatch: :foreman_dispatch})`, when the action is called, then it returns a directive to call `ForemanDispatch.run/3` for the configured provider.
- AC-018-004-3: Given `PhaseAgent.cmd(agent, {RecordAttempt, tool: :read, result: :ok})`, when called, then the returned agent state increments `attempts` and records the tool call in `tool_history`.
- AC-018-004-4: Given `PhaseAgent.cmd(agent, {FailPhase, error: %{code: :timeout}})`, when called, then the returned agent state has `status: :failed` and a directive to emit `phase.failed` is present.

### REQ-018-005: Actions Library

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: action schema must match existing field names]

Foreman shall provide a library of reusable actions in `ForemanServer.Actions`.

- AC-018-005-1: Given `ForemanServer.Actions.InitializeRun.run/2` is called with `task_id: "t1"`, when the action executes, then it returns `{:ok, run_metadata}` with `run_id`, `task_id`, `started_at`.
- AC-018-005-2: Given `ForemanServer.Actions.EmitSignal.run/2` is called, when the action executes, then it returns `{:ok, %{}, [directive]}` with an EmitSignal directive.
- AC-018-005-3: Given `ForemanServer.Actions.SpawnWorker.run/2` is called with `provider: :pi, prompt: p`, when the action executes, then it returns `{:ok, %{worker_id: _}, [directive]}` with a SpawnWorker directive.
- AC-018-005-4: Given all actions in the library are tested, when `mix test` runs on the actions suite, then all tests pass with 100% decision coverage.

### REQ-018-006: Directives Library

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: directive execution must be correct or side effects are silently dropped]

Foreman shall provide directive types that `ForemanAgentServer` executes.

- AC-018-006-1: Given `ForemanServer.Directives.EmitSignal` is returned as a directive from an action, when `ForemanAgentServer` processes the directive, then it calls `ForemanSignal.Bus.publish/1` with the signal.
- AC-018-006-2: Given `ForemanServer.Directives.SpawnWorker` is returned, when processed, then it calls `ForemanDispatch.start_run/3` and stores the `worker_id` in agent state.
- AC-018-006-3: Given `ForemanServer.Directives.ScheduleRetry` is returned with `delay: 60_000`, when processed, then it schedules a `retry` signal to be published to the bus after 60 seconds.

### REQ-018-007: ForemanAgentServer

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: GenServer wrapping Jido agent is the production runtime]

Foreman shall provide `ForemanServer.ForemanAgentServer` — the supervised GenServer wrapper.

- AC-018-007-1: Given `ForemanAgentServer.start_link(agent: RunAgent, id: "run_123")`, when started, then a supervised GenServer is created and registered under `ForemanServer.RunAgents".
- AC-018-007-2: Given `ForemanAgentServer` receives a signal via `ForemanSignal.Bus`, when the signal matches a route, then `Agent.cmd/2` is called and the resulting directives are executed.
- AC-018-007-3: Given `ForemanAgentServer` crashes during `cmd/2`, when its supervisor restarts it, then the agent state is recovered from the last persisted checkpoint (if any).

### REQ-018-008: Plugin: ForemanTelemetry

**Priority:** Should  
**Complexity:** Low  
**Type:** Functional  
**Risk:** [RISK: telemetry is additive]

Foreman shall provide `ForemanServer.Plugins.ForemanTelemetry` as a Jido plugin.

- AC-018-008-1: Given `ForemanAgent.cmd/2` is called, when it executes, then `[:foreman, :agent, :cmd, :start]` and `[:foreman, :agent, :cmd, :stop]` telemetry events are emitted with action name, agent name, and duration_ms.
- AC-018-008-2: Given `ForemanAgent.cmd/2` returns directives, when processing completes, then `[:foreman, :agent, :directives, :emitted]` is emitted with directive count and types.

### REQ-018-009: Plugin: ForemanSignal

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: signal routing must not create infinite loops]

Foreman shall provide `ForemanServer.Plugins.ForemanSignal` as a Jido plugin.

- AC-018-009-1: Given `ForemanAgent` emits a directive `EmitSignal`, when the plugin processes it, then `ForemanSignal.Bus.publish/1` is called with the correct signal type and data.
- AC-018-009-2: Given `ForemanSignal.Bus` delivers a signal to `ForemanAgentServer`, when the signal matches a route, then the corresponding action is queued in the agent's directive processor.
- AC-018-009-3: Given the plugin processes a signal, when the agent emits an `EmitSignal` directive in response, then the plugin's `cause` field is set to the incoming signal's ID.

### REQ-018-010: Decision Logic Unit Tests

**Priority:** Must  
**Complexity:** High  
**Type:** Functional  
**Risk:** [RISK: high test coverage requirement]

All migrated agent decision logic shall have 100% unit test coverage.

- AC-018-010-1: Given `ForemanServer.RunAgent` action functions, when `mix test` runs on the RunAgent test file, then all clauses and branches are exercised.
- AC-018-010-2: Given `ForemanServer.PhaseAgent` action functions, when `mix test` runs, then all state transitions are covered.
- AC-018-010-3: Given an action has invalid input, when `Agent.cmd/2` is called, then `{:error, Jido.Action.Error}` is returned without raising.

### REQ-018-011: Feature Flag Coexistence

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: two code paths must stay in sync]

Existing GenServer-based agents and Jido agents shall coexist behind `:use_jido_agents`.

- AC-018-011-1: Given `:use_jido_agents` is `false` (default), when `ForemanServer.RunSupervisor.start_run/1` is called, then it starts `RunActor` (GenServer).
- AC-018-011-2: Given `:use_jido_agents` is `true`, when `start_run/1` is called, then it starts `RunAgent` (Jido agent via `ForemanAgentServer`).
- AC-018-011-3: Given `:use_jido_agents` is toggled at runtime via `Application.put_env`, when new runs are started, then they use the new path while existing runs complete on their original path.

### REQ-018-012: Integration with Phase 1 (jido_harness)

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: ForemanDispatch must work with both GenServer and Jido agent paths]

`ForemanDispatch` shall work with both the GenServer and Jido agent paths.

- AC-018-012-1: Given `ForemanDispatch.run/3` is called from a Jido action in `PhaseAgent`, when it completes, then the `SpawnWorker` directive's `on_complete` callback updates the agent state with the run result.
- AC-018-012-2: Given `ForemanDispatch.start_run/3` is called, when the detached run completes, then `ForemanSignal.Bus` receives a `worker.completed` signal that `PhaseAgent` routes and processes.

### REQ-018-013: Integration with Phase 2 (jido_signal)

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: jido signal plugin must use ForemanSignal.Bus]

`ForemanServer.Plugins.ForemanSignal` shall use `ForemanSignal.Bus` (not raw `Jido.Signal.Bus`).

- AC-018-013-1: Given `ForemanAgent` is running, when it emits an `EmitSignal` directive, then the signal is published to `:foreman_bus` (not a generic bus).
- AC-018-013-2: Given `ForemanSignal.RPC.call/4` is used to send work to an agent, when the agent processes the work and emits `phase.completed`, then the RPC receives the correlated response.

### REQ-018-014: Coexistence with Existing Tests

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: existing tests must not break]

Existing Foreman tests shall continue to pass after Phase 3.

- AC-018-014-1: Given existing `run_actor_test.exs` run after Phase 3, when `:use_jido_agents` is `false`, then they pass without modification.
- AC-018-014-2: Given existing integration tests run after Phase 3, when they exercise the full run lifecycle, then they pass because `ForemanDispatch` and `ForemanSignal.Bus` are shared.

### REQ-018-015: Upstream Contribution

**Priority:** Should  
**Complexity:** Medium  
**Type:** Process  
**Risk:** [RISK: upstream contribution may not align with jido's direction]

Foreman shall propose `ForemanAgent` base module as `jido_foreman` package.

- AC-018-015-1: Given `ForemanAgent` is production-proven, when a GitHub issue is opened on `agentjido/jido`, then it proposes `jido_foreman` as a community package.
- AC-018-015-2: Given the issue is open, when `packages/foreman_jido` is published to a public repo, then it is structured as a standard Hex package with its own `mix.exs` and docs.

### REQ-018-016: Documentation

**Priority:** Should  
**Complexity:** Low  
**Type:** Documentation  
**Risk:** [RISK: documentation debt]

- AC-018-016-1: Given a developer adds a new agent type, when they follow the pattern in `foreman_jido/lib/agents/`, then they can create a new agent with 10 lines of code.
- AC-018-016-2: Given a developer writes a new action, when they follow the pattern in `foreman_jido/lib/actions/`, then the action has compile-time schema validation and is automatically testable via `Agent.cmd/2`.

---

## 6. Dependencies and Risks

| ID | Dependency / Risk | Mitigation |
|----|--------------------|------------|
| DEP-018-01 | Phase 3 depends on: Phase 1 (jido_harness) + Phase 2 (jido_signal) | Gate: no jido core work until both Phases 1 and 2 acceptance tests green |
| DEP-018-02 | jido vendoring depends on: all 6 jido ecosystem packages (jido, jido_action, jido_ai, jido_signal, jido_behaviortree, req_llm) | Vendor all 6 packages in Phase 3 |
| RISK-018-01 | Two agent implementations (GenServer + Jido) must stay in sync | Feature flag is not permanent; Phase 5 removes GenServer path |
| RISK-018-02 | Directive execution in `ForemanAgentServer` is new code | Implement as separate module; test in isolation before integration |
| RISK-018-03 | Agent state persistence/checkpointing is not in scope for Phase 3 | Explicit non-goal; agent state loss on crash is acceptable until Phase 5 |
| RISK-018-04 | jido's `Agent.cmd/2` purity means directives don't execute in the test | Provide `Jido.Agent.TestHarness.cmd!/3` that executes directives in a test context |

---

## 7. Acceptance Criteria Checklist

- [ ] REQ-018-001-1: `mix deps.get` in `packages/jido` resolves without network
- [ ] REQ-018-001-2: `mix test` passes in vendored jido
- [ ] REQ-018-002-1: `use ForemanAgent` defines `new!/1` returning validated struct
- [ ] REQ-018-002-2: Signal routes deliver matching signals to corresponding actions
- [ ] REQ-018-002-3: Unknown action returns `{:error, :unknown_action}`
- [ ] REQ-018-003-1: `RunAgent.new!(run_id: "run_123")` creates agent with correct defaults
- [ ] REQ-018-003-2: `InitializeRun` action transitions state to `status: :initialized`
- [ ] REQ-018-003-3: `CompletePhase` action updates phase and status correctly
- [ ] REQ-018-003-4: `FailRun` action sets `status: :failed` and emits directive
- [ ] REQ-018-004-1: `PhaseAgent.new!(phase_id: "p1", spec: spec)` creates correct state
- [ ] REQ-018-004-2: `StartPhase` action returns `SpawnWorker` directive
- [ ] REQ-018-004-3: `RecordAttempt` increments `attempts` and records `tool_history`
- [ ] REQ-018-004-4: `FailPhase` sets `status: :failed` and emits directive
- [ ] REQ-018-005-1: `InitializeRun.run/2` returns valid run metadata
- [ ] REQ-018-005-2: `EmitSignal.run/2` returns directive
- [ ] REQ-018-005-3: `SpawnWorker.run/2` returns directive with worker_id
- [ ] REQ-018-005-4: 100% decision coverage on action tests
- [ ] REQ-018-006-1: EmitSignal directive calls `ForemanSignal.Bus.publish/1`
- [ ] REQ-018-006-2: SpawnWorker directive calls `ForemanDispatch.start_run/3`
- [ ] REQ-018-006-3: ScheduleRetry directive schedules signal publish after delay
- [ ] REQ-018-007-1: `ForemanAgentServer` starts supervised GenServer
- [ ] REQ-018-007-2: Bus signal matching route triggers `Agent.cmd/2`
- [ ] REQ-018-007-3: Restart recovers from last checkpoint (or restarts clean)
- [ ] REQ-018-008-1: `[:foreman, :agent, :cmd, :start/stop]` telemetry emitted
- [ ] REQ-018-008-2: `[:foreman, :agent, :directives, :emitted]` telemetry emitted
- [ ] REQ-018-009-1: EmitSignal directive uses `:foreman_bus`
- [ ] REQ-018-009-2: Bus signals matching routes are queued
- [ ] REQ-018-009-3: Cause field is threaded from incoming signal
- [ ] REQ-018-010-1: RunAgent tests have 100% decision coverage
- [ ] REQ-018-010-2: PhaseAgent tests have 100% decision coverage
- [ ] REQ-018-010-3: Invalid action input returns `Jido.Action.Error`
- [ ] REQ-018-011-1: `:use_jido_agents: false` starts `RunActor`
- [ ] REQ-018-011-2: `:use_jido_agents: true` starts `RunAgent`
- [ ] REQ-018-011-3: Runtime toggle works for new runs
- [ ] REQ-018-012-1: `SpawnWorker` directive `on_complete` updates agent state
- [ ] REQ-018-012-2: `worker.completed` signal routes to `PhaseAgent`
- [ ] REQ-018-013-1: All signals go to `:foreman_bus`
- [ ] REQ-018-013-2: `RPC.call/4` + agent response maintains correlation
- [ ] REQ-018-014-1: Existing tests pass with `:use_jido_agents: false`
- [ ] REQ-018-014-2: Integration tests pass with shared infrastructure
- [ ] REQ-018-015-1: GitHub issue proposing `jido_foreman` opened
- [ ] REQ-018-015-2: `packages/foreman_jido` structured as Hex package
- [ ] REQ-018-016-1: New agent creation pattern documented
- [ ] REQ-018-016-2: New action creation pattern documented
