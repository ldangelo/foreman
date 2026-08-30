---
document_id: PRD-2026-017
version: 1.0.0
status: Draft
date: 2026-08-16
scale_depth: STANDARD
author: Lead Agent
total_requirements: 14
readiness_score: 0.0
readiness_gate: PENDING
depends_on: PRD-2026-016
---

# PRD-2026-017: jido_signal Inter-Agent Messaging — Phase 2

## PRD Health Summary

| Metric | Value |
|--------|-------|
| **Total Requirements** | 14 (REQ-017-001 through REQ-017-014) |
| **Must** | 10 |
| **Should** | 3 |
| **Could** | 1 |
| **Won't (this release)** | 0 |
| **AC Coverage** | 0/14 (0%) |
| **Risk Flags** | 0 |
| **Cross-Requirement Dependencies** | 0 |
| **Readiness Score** | 0.0 / 5.0 |
| **Ambiguity Markers** | 0 |

---

## 1. Executive Summary

### 1.1 Problem Statement

Foreman's internal processes (RunActor, PhaseActor, VCSAgent, RecoveryAgent) communicate via ad-hoc `send/2` to registered PIDs, raw `GenServer.call/cast`, and the `Inbox` module for async messages. This produces:
- Untyped message shapes — no schema validation at send time
- No causality tracking — "which message caused this response?" is unanswerable
- No replay — messages are fire-and-forget; dead-letter handling is manual
- Tight coupling — processes must know recipient PIDs, not just signal types
- No cross-node story — current design assumes single-node BEAM

### 1.2 Solution Overview

Introduce `jido_signal` as the messaging nervous system for Foreman's internal agents. Replace ad-hoc `send/2` and `GenServer.call/cast` with typed `Jido.Signal` envelopes published to a `Jido.Signal.Bus`. The signal bus provides pub/sub with pattern-matched routing, CloudEvents-compliant envelopes, causality chains, journal replay, and nine dispatch adapters.

This phase also adds a **request/response layer** on top of the signal bus — a `ForemanSignal.RPC` module that provides blocking call/response semantics for coordinator-to-agent coordination. This is the gap jido_signal leaves to consumers and the novel contribution Foreman makes upstream.

### 1.3 Value Proposition

- **Typed message envelopes** — signal schemas validated at publish time, not runtime.
- **Causality tracking** — every signal carries `cause` chain; trace which signal triggered a response.
- **Replay from journal** — replay a conversation between agents from the bus history.
- **Loose coupling** — agents subscribe to signal patterns (`"run.phase.*"`), not PIDs.
- **Dead Letter Queue** — undeliverable signals are preserved, not dropped.
- **Cross-node ready** — HTTP/webhook dispatch adapters exist; multi-node is a config change.
- **Upstream contribution** — `ForemanSignal.RPC` proposes a first-class request/response over signals to jido_signal upstream.

---

## 2. User Analysis

### 2.1 Primary Users

| Role | Description | How Phase 2 Helps |
|------|-------------|-------------------|
| **Developer** | Traces why a run failed at a specific phase | Causality chain shows which signal caused the failure |
| **Maintainer** | Debugs agent coordination | Signal journal replay shows full conversation |
| **Operator** | Observes system behavior | Structured signal types replace unstructured log lines |

### 2.2 Current Flow (before Phase 2)

```text
RunActor
  → GenServer.call(via("phase_actor_#{phase_id}"), {:run_phase, spec})
  → send(via("recovery_agent"), {:run_failed, run_id, reason})
  Inbox.handle_message(pid, :run_failed, payload)  # raw pid coupling

PhaseActor
  → GenServer.cast(self(), :next_phase)  # self-coupling
  → send(InboxPid, {:phase_completed, phase_id, result})  # global inbox
```

### 2.3 Desired Flow (after Phase 2)

```text
RunActor
  → ForemanSignal.Bus.publish(:foreman_bus, [Signal.new!("run.phase.started", %{run_id: r, phase: p})])
  → ForemanSignal.RPC.call(:phase_agent, RunPhase, %{phase_id: p, spec: s}, timeout: 300_000)
  → ForemanSignal.Bus.publish(:foreman_bus, [Signal.new!("run.failed", %{run_id: r, reason: e}, cause: signal)])

PhaseActor
  → handles Signal of type "run.phase.started"
  → ForemanSignal.RPC.call(:coordinator, PhaseCompleted, %{phase: p, result: r})
  → Bus.publish("phase.completed", %{phase_id: p, result: r})
```

---

## 3. Goals and Non-Goals

### 3.1 Goals

| ID | Goal | Success Metric |
|----|------|----------------|
| G-017-1 | Vendor `jido_signal` under `packages/jido_signal` | Package builds and tests pass |
| G-017-2 | Replace Inbox `send/2` with `ForemanSignal.Bus.publish/2` | Zero direct `send/2` calls in new agent code |
| G-017-3 | Implement `ForemanSignal.RPC` for request/response over signal bus | Coordinator can block-wait for agent response with timeout |
| G-017-4 | Migrate RunActor ↔ PhaseActor communication to signal bus | RunActor does not hold PhaseActor PID; uses signal routing |
| G-017-5 | Add signal journal with ETS adapter for replay | `ForemanSignal.Journal.replay/3` recovers conversation history |
| G-017-6 | Emit causality chains on all signal publishes | Every signal's `cause` field traces back to trigger |
| G-017-7 | Contribute `ForemanSignal.RPC` design upstream to jido_signal | GitHub issue + POC PR to jido_signal before Phase 3 |

### 3.2 Non-Goals

- jido core agent migration (Phase 3).
- Behavior tree phase sequencing (Phase 4).
- Full orchestration cutover (Phase 5).
- Removing Inbox module in Phase 2 — migrated progressively through Phase 4.
- Multi-node deployment (Phase 5 at earliest).
- Behavior tree signal integration — Phase 4.
- Full jido agent lifecycle (start/stop/restart) managed by jido_signal — Phase 3.

---

## 4. Proposed Architecture

### 4.1 Package Layout

```
packages/
  jido_signal/           # NEW: vendored jido_signal
    mix.exs
    lib/
      jido_signal/
    ...
  jido_harness/          # Phase 1

  foreman_signal/        # NEW: Foreman's signal extensions
    mix.exs
    lib/
      foreman_signal/
        application.ex
        bus.ex             # ForemanSignal.Bus — Jido.Signal.Bus wrapper
        rpc.ex             # ForemanSignal.RPC — request/response over bus
        signals/
          run.ex           # RunStarted, RunFailed, RunCompleted
          phase.ex         # PhaseStarted, PhaseCompleted, PhaseFailed
          task.ex          # TaskApproved, TaskUpdated
          vcs.ex           # BranchCreated, PROpened
        subscriptions.ex   # ForemanSignal.Subscriptions — pattern routing
        journal.ex         # ForemanSignal.Journal — replay API
        telemetry.ex       # Signal emission hooks
```

### 4.2 ForemanSignal.Bus

```elixir
defmodule ForemanSignal.Bus do
  @moduledoc """
  Foreman's signal bus. Thin wrapper around Jido.Signal.Bus.

  All internal agent-to-agent messages flow through here.
  No direct send/2 between Foreman agents after Phase 2.
  """

  alias Jido.Signal

  @bus_name :foreman_bus

  def start_link(opts \\ []) do
    Jido.Signal.Bus.start_link(
      name: Keyword.get(opts, :name, @bus_name),
      middleware: [ForemanSignal.Telemetry.Middleware]
    )
  end

  @doc """
  Publish one or more signals to the bus. Signals are CloudEvents-compliant.
  """
  @spec publish([Signal.t()]) :: :ok | {:error, Signal.error()}
  def publish(signals) when is_list(signals) do
    Jido.Signal.Bus.publish(@bus_name, signals)
  end

  def publish(signal), do: publish([signal])

  @doc """
  Subscribe to signal patterns. Pattern uses CloudEvents type matching
  with wildcard support (* single-level, ** multi-level).
  """
  @spec subscribe(pid(), String.t(), keyword()) :: {:ok, String.t()}
  def subscribe(subscriber, pattern, opts \\ []) do
    dispatch = {:pid, target: subscriber, delivery_mode: :async}
    Jido.Signal.Bus.subscribe(@bus_name, pattern, dispatch: dispatch)
  end
end
```

### 4.3 ForemanSignal.RPC (Novel Contribution)

This is the key gap jido_signal leaves to consumers. Foreman designs and implements it first; if it proves general enough, it gets proposed upstream.

```elixir
defmodule ForemanSignal.RPC do
  @moduledoc """
  Request/response over Jido.Signal.Bus.

  Provides blocking call semantics — a coordinator sends a signal and blocks
  waiting for a correlated response, with timeout and cancellation.

  Signal envelope:
    - request signal has type "foreman.rpc.request.<action>"
    - response signal has type "foreman.rpc.response.<action>" and
      references the request's id in correlation: field

  This is the primitive that enables:
    CoordinatorAgent → RPC.call(:phase_agent, RunPhase, spec, timeout: 300_000)
                    ← %Signal{type: "foreman.rpc.response.run_phase", data: result}
  """

  @doc """
  Send a request signal and wait for a correlated response.

  - `agent` — atom naming the target agent (resolved via Registry)
  - `action` — module name of the action to invoke
  - `params` — action params
  - `opts` — timeout, metadata
  """
  @spec call(atom(), module(), map(), keyword()) ::
          {:ok, Signal.t()} | {:error, :timeout | :cancelled | Signal.error()}
  def call(agent, action, params, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    request_id = UUID.uuid4()

    # Publish request signal
    request = Signal.new!(
      "foreman.rpc.request.#{action}",
      %{params: params, request_id: request_id},
      source: "/coordinator/#{inspect(self())}",
      extensions: %{correlation: request_id}
    )

    # Subscribe to response pattern for this request_id
    # ... (see implementation in REQ-017-003)

    # Wait for response
    receive do
      {:signal, response} ->
        if response.extensions[:correlation] == request_id do
          {:ok, response}
        else
          # Wrong correlation — continue waiting
          receive_loop(request_id, timeout)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Reply to an RPC request. Publishes a correlated response signal.
  """
  @spec reply(Signal.t(), map()) :: :ok
  def reply(request_signal, result_data) do
    response = Signal.new!(
      "foreman.rpc.response.#{action_module(request_signal)}",
      Map.put(result_data, :request_id, request_signal.extensions[:correlation]),
      source: "/agent/#{inspect(self())}",
      extensions: %{correlation: request_signal.extensions[:correlation]}
    )

    ForemanSignal.Bus.publish(response)
  end
end
```

### 4.4 Signal Type Catalog

| Signal Type | Direction | Data Fields |
|-------------|-----------|-------------|
| `run.started` | RunActor → Bus | run_id, task_id, spec |
| `run.failed` | RunActor → Bus | run_id, phase_id, reason, cause |
| `run.completed` | RunActor → Bus | run_id, artifacts |
| `phase.started` | PhaseActor → Bus | run_id, phase_id, spec |
| `phase.completed` | PhaseActor → Bus | run_id, phase_id, result |
| `phase.failed` | PhaseActor → Bus | run_id, phase_id, error, cause |
| `task.approved` | Coordinator → Bus | task_id, approved_by |
| `task.updated` | TaskAgent → Bus | task_id, changes |
| `vcs.branch.created` | VCSEgent → Bus | run_id, branch, base_commit |
| `vcs.pr.opened` | VCSEgent → Bus | run_id, pr_url, branch |
| `recovery.run_detected` | RecoveryAgent → Bus | run_id, detected_at |

---

## 5. Functional Requirements

### REQ-017-001: jido_signal Vendoring

**Priority:** Must  
**Complexity:** Low  
**Type:** Infrastructure  
**Risk:** [RISK: fork maintenance burden]

Foreman shall vendor `jido_signal` under `packages/jido_signal`.

- AC-017-001-1: Given `packages/jido_signal/mix.exs` exists, when `mix deps.get` runs, then all jido_signal dependencies resolve without external network access.
- AC-017-001-2: Given the vendored jido_signal, when `mix test` runs, then all 120+ jido_signal tests pass.

### REQ-017-002: ForemanSignal.Bus Startup

**Priority:** Must  
**Complexity:** Low  
**Type:** Functional  
**Risk:** [RISK: trivial]

Foreman shall start `ForemanSignal.Bus` in the application supervision tree.

- AC-017-002-1: Given ForemanServer starts, when it initializes, then `ForemanSignal.Bus` is started as a child with `name: :foreman_bus`.
- AC-017-002-2: Given `ForemanSignal.Bus` is running, when `ForemanSignal.Bus.publish([signal])` is called, then the signal is routed to all matching subscribers.
- AC-017-002-3: Given a subscriber is registered for pattern `"run.*"`, when `run.started` is published, then the subscriber receives the signal via `{:signal, signal}`.

### REQ-017-003: ForemanSignal.RPC Implementation

**Priority:** Must  
**Complexity:** High  
**Type:** Functional  
**Risk:** [RISK: novel contribution; may need redesign after upstream feedback]

Foreman shall implement `ForemanSignal.RPC` providing blocking request/response over the signal bus.

- AC-017-003-1: Given `ForemanSignal.RPC.call(:phase_agent, PhaseActor.RunPhase, %{phase_id: p}, timeout: 60_000)`, when the phase agent is running, then it returns `{:ok, response_signal}` within the timeout.
- AC-017-003-2: Given `ForemanSignal.RPC.call/4` with a non-existent agent, when called, then it returns `{:error, :agent_not_found}` within 5 seconds.
- AC-017-003-3: Given `ForemanSignal.RPC.call/4` and the agent crashes mid-execution, when the agent is restarted, then the call returns `{:error, :agent_crashed}` (not hangs indefinitely).
- AC-017-003-4: Given `ForemanSignal.RPC.reply/2` is called with a request signal and result data, when `RPC.call/4` is awaiting the response, then the caller's `receive` receives the response with matching `correlation` ID.

### REQ-017-004: RunActor ↔ PhaseActor via Signals

**Priority:** Must  
**Complexity:** High  
**Type:** Functional  
**Risk:** [RISK: migrating existing GenServer.call/cast paths]

RunActor and PhaseActor shall communicate exclusively via `ForemanSignal.Bus` and `ForemanSignal.RPC`.

- AC-017-004-1: Given RunActor starts a phase, when it dispatches work, then it uses `ForemanSignal.RPC.call(:phase_actor, PhaseActor.RunPhase, spec)` and does not hold the PhaseActor PID.
- AC-017-004-2: Given PhaseActor completes a phase, when it reports back, then it uses `ForemanSignal.RPC.reply(request_signal, %{phase: p, result: r})`.
- AC-017-004-3: Given RunActor receives a phase completion, when it processes the result, then it has the full `Signal` envelope with `cause` field tracing back to the original `run.phase.started` signal.

### REQ-017-005: Causality Chains

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: cause field must be threaded through all signal publishes]

All signals published to `ForemanSignal.Bus` shall carry a `cause` extension tracing the triggering signal.

- AC-017-005-1: Given a `phase.failed` signal is published, when the signal has `cause: parent_signal_id`, then tracing the `cause` chain reaches the original `run.started` signal.
- AC-017-005-2: Given `ForemanSignal.Bus.publish/2` is called without an explicit `cause`, when the bus processes the publish, then it automatically sets `cause` to the current process's most recent received signal ID (if any).
- AC-017-005-3: Given a signal without a traceable cause (first signal in a conversation), when it is published, then `cause` is `nil` and this is semantically correct.

### REQ-017-006: Signal Journal and Replay

**Priority:** Must  
**Complexity:** High  
**Type:** Functional  
**Risk:** [RISK: journal replay during recovery could cause infinite loops]

Foreman shall provide `ForemanSignal.Journal` backed by ETS for replay of agent conversations.

- AC-017-006-1: Given a `run.failed` event, when `ForemanSignal.Journal.replay(run_id, "run.*")` is called, then it returns all signals for that run_id in temporal order.
- AC-017-006-2: Given the signal journal is enabled, when any signal is published, then it is persisted to the ETS journal before dispatch.
- AC-017-006-3: Given the journal is at capacity (configurable max entries), when a new signal is published, then the oldest signals are evicted in FIFO order.

### REQ-017-007: Dead Letter Queue

**Priority:** Should  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: DLQ handling adds failure modes]

Undeliverable signals shall be routed to a Dead Letter Queue.

- AC-017-007-1: Given a signal is published with no matching subscribers, when it is dispatched, then it is placed in the DLQ with `reason: :no_subscribers`.
- AC-017-007-2: Given a signal in the DLQ, when `ForemanSignal.Journal.dlq_list()` is called, then it returns all dead letters with their original signal and reason.
- AC-017-007-3: Given an operator re-subscribes a pattern that would match DLQ signals, when the subscription is established, then the DLQ is checked and matching dead letters are re-dispatched.

### REQ-017-008: Telemetry Integration

**Priority:** Should  
**Complexity:** Low  
**Type:** Functional  
**Risk:** [RISK: low-risk telemetry]

Foreman shall emit telemetry for signal bus operations.

- AC-017-008-1: Given a signal is published, when `ForemanSignal.Bus.publish/2` completes, then `[:foreman_signal, :bus, :publish, :stop]` is emitted with signal type, bus name, and subscriber count.
- AC-017-008-2: Given an RPC call is made, when `ForemanSignal.RPC.call/4` returns, then `[:foreman_signal, :rpc, :call, :stop]` is emitted with action, status, and duration_ms.
- AC-017-008-3: Given a signal is placed in the DLQ, when this occurs, then `[:foreman_signal, :dlq, :signal, :dead]` is emitted.

### REQ-017-009: Replace Inbox `send/2`

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: Inbox is used throughout; migration is incremental]

The `Inbox` module shall be updated to use `ForemanSignal.Bus` internally.

- AC-017-009-1: Given `Inbox.handle_message/3` is called, when it processes the message, then it publishes a typed signal to `ForemanSignal.Bus` instead of calling `send/2`.
- AC-017-009-2: Given existing Inbox consumers call `Inbox.watch/1`, when this continues to work, then the Inbox watch API is preserved while the underlying implementation uses signal subscriptions.
- AC-017-009-3: Given zero direct `send/2` calls exist in new agent code (Phase 2 onward), when a code review is done, then no `send/2` appears in new `foreman_server` modules.

### REQ-017-010: Upstream Contribution

**Priority:** Should  
**Complexity:** High  
**Type:** Process  
**Risk:** [RISK: upstream may reject the RPC design]

Foreman shall propose `ForemanSignal.RPC` as a first-class `Jido.Signal.RPC` module upstream.

- AC-017-010-1: Given `ForemanSignal.RPC` is implemented and tested, when a GitHub issue is opened on `agentjido/jido_signal`, then it describes the RPC use case with the full signal envelope design.
- AC-017-010-2: Given the issue is open, when a POC PR implementing `Jido.Signal.RPC` is submitted, then it passes jido_signal's existing test suite and the new RPC tests.
- AC-017-010-3: Given upstream accepts the RPC concept, when jido_signal releases with `Jido.Signal.RPC`, then ForemanSignal.RPC becomes a thin wrapper and the core implementation is upstream.

### REQ-017-011: Cross-Node Readiness

**Priority:** Could  
**Complexity:** High  
**Type:** Non-Functional  
**Risk:** [RISK: multi-node is Phase 5; architecture must not preclude it]

The signal bus architecture shall not preclude future multi-node deployment.

- AC-017-011-1: Given the current single-node design, when a node is added with the same bus name, then no partition tolerance issues arise because the two buses are independent (explicit non-goal: Phase 2 does not implement cross-node bus).
- AC-017-011-2: Given `ForemanSignal.RPC` is designed, when it is reviewed, then the design does not assume local PID delivery (uses dispatch adapters that could target HTTP endpoints for cross-node).

### REQ-017-012: Integration Test Coverage

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: signal-based coordination is harder to integration test than GenServer.call]

Phase 2 integration tests shall cover signal-based coordination paths.

- AC-017-012-1: Given RunActor and PhaseActor are started, when RunActor dispatches a phase via `RPC.call/4`, then the test asserts the PhaseActor receives the signal and the RunActor receives the response.
- AC-017-012-2: Given the signal journal is enabled, when 10 signals are published, then `ForemanSignal.Journal.replay/3` returns all 10 in order.
- AC-017-012-3: Given `ForemanSignal.RPC.call/4` is called with a 1-second timeout against a never-responding agent, then the call returns `{:error, :timeout}` within 2 seconds.

### REQ-017-013: Documentation

**Priority:** Should  
**Complexity:** Low  
**Type:** Documentation  
**Risk:** [RISK: documentation debt]

- AC-017-013-1: Given Phase 2 is complete, when a developer adds a new signal type, they follow the pattern in `foreman_signal/lib/signals/` and the signal type is added to the catalog in this PRD.
- AC-017-013-2: Given an engineer reads `docs/PRDs/PRD-2026-017-jido-signal-inter-agent-messaging.md`, they understand the signal type catalog, the RPC protocol, and the migration path from `send/2`.

### REQ-017-014: Existing Test Compatibility

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: existing GenServer-based tests must still pass]

Existing Foreman tests shall continue to pass after signal bus introduction.

- AC-017-014-1: Given existing `run_actor_test.exs`, when they run after Phase 2, then they pass without modification (the GenServer structure is unchanged; only the message layer changes underneath).
- AC-017-014-2: Given existing integration tests that use `Inbox.watch/1`, when they run after Phase 2, then they pass because the Inbox API is preserved.

---

## 6. Dependencies and Risks

| ID | Dependency / Risk | Mitigation |
|----|--------------------|------------|
| DEP-017-01 | Phase 2 depends on: Phase 1 (jido_harness) completing | Gate: no jido_signal work until PRD-2026-016 acceptance tests green |
| DEP-017-02 | `ForemanSignal.RPC` depends on: Registry for agent name → PID resolution | Use existing Foreman `ProjectRegistry`; design RPC to work with Registry |
| RISK-017-01 | `ForemanSignal.RPC` design may be rejected upstream | Implement as Foreman-local first; only propose upstream after proven in production |
| RISK-017-02 | Signal journal ETS size management | Configure with `max_entries: 50_000` per run; configurable per project |
| RISK-017-03 | Causality chain threading is manual | Code review enforcement; lint rule to flag signals without cause |
| RISK-017-04 | Phase 3 (jido core) will change signal routing significantly | Design `ForemanSignal.Bus` as a stable facade; jido core uses jido_signal directly underneath |

---

## 7. Acceptance Criteria Checklist

- [ ] REQ-017-001-1: `mix deps.get` in `packages/jido_signal` resolves without network
- [ ] REQ-017-001-2: `mix test` passes in vendored jido_signal
- [ ] REQ-017-002-1: `ForemanSignal.Bus` starts as child of ForemanServer supervisor
- [ ] REQ-017-002-2: `ForemanSignal.Bus.publish/1` routes to subscribers
- [ ] REQ-017-002-3: Subscriber receives `{:signal, signal}` for matching patterns
- [ ] REQ-017-003-1: `RPC.call/4` returns response within timeout
- [ ] REQ-017-003-2: `RPC.call/4` to non-existent agent returns `{:error, :agent_not_found}`
- [ ] REQ-017-003-3: `RPC.call/4` to crashed agent returns `{:error, :agent_crashed}`
- [ ] REQ-017-003-4: `RPC.reply/2` delivers response with matching correlation ID
- [ ] REQ-017-004-1: RunActor uses `RPC.call/4` without holding PhaseActor PID
- [ ] REQ-017-004-2: PhaseActor uses `RPC.reply/2` for results
- [ ] REQ-017-004-3: RunActor's phase completion has traceable `cause` chain
- [ ] REQ-017-005-1: `phase.failed` signal has `cause` tracing to `run.started`
- [ ] REQ-017-005-2: Auto-cause from current process's last received signal
- [ ] REQ-017-005-3: First signal in conversation has `cause: nil`
- [ ] REQ-017-006-1: `Journal.replay/3` returns all signals for a run_id in order
- [ ] REQ-017-006-2: Signals persisted to ETS journal before dispatch
- [ ] REQ-017-006-3: Oldest signals evicted when at capacity
- [ ] REQ-017-007-1: Undeliverable signals placed in DLQ with reason
- [ ] REQ-017-007-2: `Journal.dlq_list/0` returns dead letters
- [ ] REQ-017-007-3: Re-subscription re-dispatches matching DLQ signals
- [ ] REQ-017-008-1: `[:foreman_signal, :bus, :publish, :stop]` telemetry emitted
- [ ] REQ-017-008-2: `[:foreman_signal, :rpc, :call, :stop]` telemetry emitted
- [ ] REQ-017-008-3: `[:foreman_signal, :dlq, :signal, :dead]` telemetry emitted
- [ ] REQ-017-009-1: `Inbox.handle_message/3` publishes typed signal to bus
- [ ] REQ-017-009-2: `Inbox.watch/1` API preserved with signal subscription underneath
- [ ] REQ-017-009-3: Zero `send/2` calls in new `foreman_server` modules
- [ ] REQ-017-010-1: GitHub issue opened on `agentjido/jido_signal` with RPC design
- [ ] REQ-017-010-2: POC PR for `Jido.Signal.RPC` submitted
- [ ] REQ-017-010-3: If accepted, `ForemanSignal.RPC` wraps upstream `Jido.Signal.RPC`
- [ ] REQ-017-011-1: No partition tolerance issues in single-node design
- [ ] REQ-017-011-2: RPC design does not assume local PID delivery
- [ ] REQ-017-012-1: RunActor↔PhaseActor RPC integration test passes
- [ ] REQ-017-012-2: Journal replay returns 10 signals in order
- [ ] REQ-017-012-3: RPC timeout returns `{:error, :timeout}` within 2 seconds
- [ ] REQ-017-013-1: New signal type pattern documented and followed
- [ ] REQ-017-013-2: PRD-2026-017 is current and accurate
- [ ] REQ-017-014-1: Existing `run_actor_test.exs` pass after Phase 2
- [ ] REQ-017-014-2: Existing `Inbox.watch/1` tests pass
