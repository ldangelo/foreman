---
document_id: PRD-2026-019
version: 1.0.0
status: Draft
date: 2026-08-16
scale_depth: STANDARD
author: Lead Agent
total_requirements: 13
readiness_score: 0.0
readiness_gate: PENDING
depends_on: PRD-2026-016, PRD-2026-017, PRD-2026-018
---

# PRD-2026-019: jido_behaviortree Phase Sequencing — Phase 4

## PRD Health Summary

| Metric | Value |
|--------|-------|
| **Total Requirements** | 13 (REQ-019-001 through REQ-019-013) |
| **Must** | 9 |
| **Should** | 3 |
| **Could** | 1 |
| **Won't (this release)** | 0 |
| **AC Coverage** | 0/13 (0%) |
| **Risk Flags** | 0 |
| **Cross-Requirement Dependencies** | 0 |
| **Readiness Score** | 0.0 / 5.0 |
| **Ambiguity Markers** | 0 |

---

## 1. Executive Summary

### 1.1 Problem Statement

Foreman's workflow phase sequencing is encoded in the `WorkflowInterpreter` module — a large, imperative function that evaluates the current phase, decides what to do next, and emits the next step. It mixes:
- Phase sequencing logic (which phase comes next)
- Tool execution (via ForemanDispatch)
- Guard evaluation (is the PR approved? are checks passing?)
- Failure recovery (retry? abort? escalate?)
- Signal emission (what to publish to the bus)

This makes it:
- Hard to test in isolation — requires the full workflow state machine
- Hard to visualize — the control flow is implicit in pattern matching
- Hard to extend — adding a new phase type requires modifying the interpreter
- Hard to reuse — workflow patterns from one project can't be shared

### 1.2 Solution Overview

Model Foreman's workflow phase sequencing as a **behavior tree** using `jido_behaviortree`. Each phase is a node in the tree. The behavior tree provides:
- **Composability** — sequence, selector, parallel, decorator nodes compose naturally
- **Visibility** — tree structure is directly renderable; execution path is traceable
- **Testability** — behavior trees are deterministic; same tree, same blackboard, same result
- **Reuse** — shared subtrees become shared node definitions
- **Guard support** — guard functions are first-class; no special-casing

The tree is a Jido strategy (`Jido.Agent.Strategy.BehaviorTree`) that drives `cmd/2` calls in `ForemanServer.CoordinatorAgent`.

### 1.3 Value Proposition

- **Visualizable workflows** — render the behavior tree as a graph; operators see exactly what runs when.
- **Composable phase logic** — Sequence, Selector, Parallel, and decorator nodes replace ad-hoc case/if chains.
- **Deterministic execution** — same tree + same blackboard = same result every time; no surprises.
- **Testable guards** — guard functions are pure; test them independently of the tree.
- **Reusable subtrees** — a "PR gate" subtree used in 5 workflows becomes one node definition.
- **Jido strategy integration** — the tree drives `cmd/2`; each node executes a `Jido.Action`; the full Jido action library is available in nodes.

---

## 2. User Analysis

### 2.1 Primary Users

| Role | Description | How Phase 4 Helps |
|------|-------------|-------------------|
| **Operator** | Understands what a workflow will do before running | Visualizable tree; execution path highlighted in real-time |
| **Developer** | Adds a new phase type or guard | One new node definition + one subtree; no interpreter modification |
| **Maintainer** | Designs reusable workflow patterns | Shared subtrees become first-class nodes |

### 2.2 Current Flow (before Phase 4)

```elixir
# WorkflowInterpreter — imperative, hard to follow
def next_step(%WorkflowState{} = state) do
  case state.current_phase do
    :validate ->
      if valid?(state), do: {:next, :execute}, else: {:abort, :validation_failed}
    :execute ->
      if state.approved?, do: {:dispatch, :pi}, else: {:wait, :approval}
    :review ->
      if state.checks_passed?, do: {:next, :finalize}, else: {:retry, :checks_pending}
    ...
  end
end
```

### 2.3 Desired Flow (after Phase 4)

```elixir
# Behavior tree — declarative, composable, visualizable
alias Jido.BehaviorTree
alias Jido.BehaviorTree.Nodes

workflow_tree = BehaviorTree.new(
  Sequence.new([
    # Validate phase
    Action.new(ValidateSpec, %{spec: :from_blackboard}),
    # Execute phase
    Sequence.new([
      Selector.new([
        Sequence.new([CheckPrApproved, %{}]),     # wait branch
        Action.new(DispatchAgent, %{provider: :pi}) # proceed branch
      ])
    ]),
    # Review phase
    Sequence.new([
      Action.new(WaitForChecks, %{timeout: 300_000}),
      Selector.new([
        Sequence.new([ChecksPassed, %{}]),         # success branch
        Action.new(EmitRetrySignal, %{delay: 60_000})
      ])
    ]),
    # Finalize phase
    Action.new(FinalizeRun, %{})
  ])
)

# Run via Jido strategy — CoordinatorAgent drives the tree
tick = BehaviorTree.tick()
{status, updated_tree} = BehaviorTree.tick(workflow_tree, tick, blackboard: %{spec: spec})
```

---

## 3. Goals and Non-Goals

### 3.1 Goals

| ID | Goal | Success Metric |
|----|------|----------------|
| G-019-1 | Vendor `jido_behaviortree` under `packages/jido_behaviortree` | Package builds and tests pass |
| G-019-2 | Create Foreman phase node library | All Foreman phases as behavior tree nodes |
| G-019-3 | Model existing `implement` workflow as a behavior tree | Tree produces same results as `WorkflowInterpreter` for all test cases |
| G-019-4 | Render behavior tree as workflow visualization | `foreman workflow show --tree <name>` renders ASCII tree |
| G-019-5 | Migrate `WorkflowInterpreter` to use behavior tree strategy | `WorkflowInterpreter` calls `BehaviorTree.tick/3`; interpreter logic moves to nodes |
| G-019-6 | 100% tree path coverage for existing workflows | All branches exercised by existing integration tests |

### 3.2 Non-Goals

- Full orchestration cutover (Phase 5).
- Removing existing `WorkflowInterpreter` in Phase 4 — it coexists as the fallback.
- `jido_ai` integration (LLM reasoning) in nodes — nodes execute Jido Actions, not LLM calls.
- Dynamic tree modification at runtime — trees are static definitions; dynamic routing via Selector nodes.
- Visual editor for behavior trees — rendering is read-only ASCII; future phases may add an editor.

---

## 4. Proposed Architecture

### 4.1 Package Layout

```
packages/
  jido_behaviortree/   # NEW: vendored jido_behaviortree
    mix.exs
    lib/
      jido_behaviortree/
      ...

  foreman_jido/        # Phase 3
    lib/
      foreman_jido/
        agents/
          coordinator_agent.ex   # Phase 4: drives behavior tree
        behaviors/              # NEW: behavior tree node library
          phase_nodes.ex
          guard_nodes.ex
          composite_nodes.ex
          decorator_nodes.ex
        actions/
          validate_spec.ex
          dispatch_agent.ex
          wait_for_checks.ex
          checks_passed.ex
          emit_retry_signal.ex
          finalize_run.ex
        blackboard.ex           # Shared state between tree nodes
        tree_loader.ex          # Loads workflow YAML → behavior tree
```

### 4.2 Foreman Phase Node Library

```elixir
defmodule ForemanServer.Behaviors.PhaseNodes do
  @moduledoc """
  Jido Behavior Tree nodes for Foreman phase execution.
  Each node wraps a Jido Action and maps the action result
  to behavior tree status (success/failure/running).
  """

  # Root sequence: validate → execute → review → finalize
  def implement_workflow(spec) do
    alias Jido.BehaviorTree.Nodes

    Nodes.Sequence.new([
      Nodes.Action.new(ForemanServer.Actions.ValidateSpec, %{spec: :from_blackboard}),
      execute_phase(),
      review_phase(),
      Nodes.Action.new(ForemanServer.Actions.FinalizeRun, %{})
    ])
  end

  # Branch: wait for PR approval OR dispatch agent
  defp execute_phase do
    alias Jido.BehaviorTree.Nodes

    Nodes.Sequence.new([
      Nodes.Selector.new([
        # Wait branch: check if PR is approved, retry until yes
        Nodes.Sequence.new([
          Nodes.Action.new(ForemanServer.Actions.CheckPrApproved, %{}),
          Nodes.Repeat.new(
            Nodes.Action.new(ForemanServer.Actions.CheckPrApproved, %{}),
            max_repeats: 120,  # 1/hour * 120 = 2 hours
            interval_ms: 30_000
          )
        ]),
        # Proceed branch: dispatch agent
        Nodes.Action.new(ForemanServer.Actions.DispatchAgent, %{provider: :pi})
      ])
    ])
  end

  # Branch: wait for checks OR retry
  defp review_phase do
    alias Jido.BehaviorTree.Nodes

    Nodes.Sequence.new([
      Nodes.Action.new(ForemanServer.Actions.WaitForChecks, %{timeout: 300_000}),
      Nodes.Selector.new([
        Nodes.Sequence.new([
          Nodes.Action.new(ForemanServer.Actions.ChecksPassed, %{}),
          Nodes.Succeeder.new(Nodes.Action.new(ForemanServer.Actions.MarkRunSuccess, %{}))
        ]),
        Nodes.Action.new(ForemanServer.Actions.EmitRetrySignal, %{delay: 60_000})
      ])
    ])
  end
end
```

### 4.3 CoordinatorAgent with BehaviorTree Strategy

```elixir
defmodule ForemanServer.CoordinatorAgent do
  use ForemanServer.ForemanAgent,
    name: "coordinator",
    description: "Orchestrates a run through its workflow behavior tree",
    schema: [
      run_id: [type: :string, required: true],
      workflow: [type: :atom, default: :implement],
      blackboard: [type: :map, default: %{}]
    ],
    actions: [],
    signal_routes: [
      {"run.started", ForemanServer.Actions.StartWorkflow}
    ]

  # Behavior tree strategy drives cmd/2 calls
  @impl true
  def strategy, do: Jido.Agent.Strategy.BehaviorTree

  # Tree is constructed from workflow name and blackboard
  @impl true
  def build_tree(agent) do
    ForemanServer.Behaviors.PhaseNodes.implement_workflow(agent.state.blackboard[:spec])
  end
end
```

### 4.4 Workflow YAML → Behavior Tree Loader

```elixir
defmodule ForemanServer.TreeLoader do
  @moduledoc """
  Loads a workflow YAML file and compiles it into a behavior tree.

  Example workflow YAML:

  ```yaml
  name: implement
  root: sequence
  nodes:
    - id: validate
      type: action
      action: ValidateSpec
    - id: execute
      type: selector
      children:
        - id: wait_approval
          type: sequence
          children:
            - id: check_approved
              type: action
              action: CheckPrApproved
        - id: dispatch
          type: action
          action: DispatchAgent
    - id: review
      type: sequence
      children:
        - id: wait_checks
          type: action
          action: WaitForChecks
        - id: gate
          type: selector
          children:
            - id: success
              type: action
              action: MarkRunSuccess
            - id: retry
              type: action
              action: EmitRetrySignal
    - id: finalize
      type: action
      action: FinalizeRun
  ```
  """

  @spec load!(atom()) :: BehaviorTree.t()
  def load!(workflow_name) when is_atom(workflow_name) do
    path = Application.app_dir(:foreman_server, "priv/defaults/workflows/#{workflow_name}.yaml")
    load_from_file!(path)
  end

  @spec load_from_file!(String.t()) :: BehaviorTree.t()
  def load_from_file!(path) do
    with {:ok, yaml} <- YmlEx.parse_file(path),
         {:ok, tree} <- compile(yaml) do
      tree
    else
      {:error, reason} -> raise "Failed to load workflow: #{inspect(reason)}"
    end
  end

  defp compile(%{"root" => root_type, "nodes" => nodes}) do
    node_map = Enum.into(nodes, %{}, fn %{"id" => id} = n -> {id, build_node(n)} end)
    root = node_map["root"] || Map.fetch!(node_map, root_type)
    {:ok, BehaviorTree.new(root)}
  end
end
```

---

## 5. Functional Requirements

### REQ-019-001: jido_behaviortree Vendoring

**Priority:** Must  
**Complexity:** Low  
**Type:** Infrastructure  
**Risk:** [RISK: fork maintenance burden]

Foreman shall vendor `jido_behaviortree` under `packages/jido_behaviortree`.

- AC-019-001-1: Given `packages/jido_behaviortree/mix.exs` exists, when `mix deps.get` runs, then all dependencies resolve without external network access.
- AC-019-001-2: Given the vendored `jido_behaviortree`, when `mix test` runs, then the test suite passes.

### REQ-019-002: Foreman Phase Node Library

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: node library must cover all existing phase types]

Foreman shall provide a library of behavior tree nodes for all existing phase types.

- AC-019-002-1: Given `ForemanServer.Behaviors.PhaseNodes.execute_phase/0`, when it is ticked, then it has a Selector at the top with a "wait for approval" branch and a "dispatch" branch.
- AC-019-002-2: Given a `CheckPrApproved` node returns `:failure` (PR not approved), when the Selector is ticked, then it proceeds to the dispatch branch.
- AC-019-002-3: Given a `CheckPrApproved` node returns `:success` (PR approved), when the Selector is ticked, then it proceeds to the wait branch (retry loop).
- AC-019-002-4: Given all phase nodes in the library, when `mix test` runs on the behaviors suite, then all node definitions are exercised.

### REQ-019-003: implement Workflow as Behavior Tree

**Priority:** Must  
**Complexity:** High  
**Type:** Functional  
**Risk:** [RISK: tree must produce identical results to WorkflowInterpreter]

Foreman's `implement` workflow shall produce identical results when executed via a behavior tree versus `WorkflowInterpreter`.

- AC-019-003-1: Given the `implement` workflow tree is executed against a valid spec, when the tree completes, then the worktree contains the same files as when executed via `WorkflowInterpreter`.
- AC-019-003-2: Given the `implement` workflow tree is executed and the PR is not approved, when the PR becomes approved, then the tree proceeds to the dispatch phase (not stuck).
- AC-019-003-3: Given the `implement` workflow tree is executed and checks fail, when checks fail repeatedly, then the retry node emits the retry signal and the tree does not return `:success`.
- AC-019-003-4: Given all existing `implement` workflow test cases are run against the tree, when assertions are made, then all 42 existing workflow integration test cases pass with the tree.

### REQ-019-004: Behavior Tree Visualization

**Priority:** Should  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: ASCII rendering is simple; future phases may enhance]

Foreman shall render a behavior tree as ASCII for CLI visualization.

- AC-019-004-1: Given `foreman workflow show implement`, when the command runs, then it outputs an ASCII tree showing the sequence/selector/action structure.
- AC-019-004-2: Given `foreman workflow show implement --highlight run_id`, when a run is in progress, then the currently executing node is highlighted in the tree output.
- AC-019-004-3: Given a workflow has a guard node, when the tree is rendered, then the guard condition is shown inline next to the node.

### REQ-019-005: Blackboard Pattern

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: shared state between nodes must be correctly managed]

Foreman shall use the behavior tree's blackboard for shared state between nodes.

- AC-019-005-1: Given `ValidateSpec` node sets `:spec_valid` to `true` on the blackboard, when `DispatchAgent` node is ticked, then it can read `:spec_valid` from the blackboard.
- AC-019-005-2: Given `DispatchAgent` node sets `:worker_id` on the blackboard, when `WaitForChecks` node is ticked, then it can read `:worker_id` and use it in its parameters.
- AC-019-005-3: Given `ForemanServer.Blackboard` module is used, when multiple tree ticks run concurrently, then each tick has its own blackboard scope (no cross-contamination).

### REQ-019-006: Tree Loader from Workflow YAML

**Priority:** Should  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: YAML schema must match existing workflow YAML format]

Foreman shall compile workflow YAML files into behavior trees via `TreeLoader`.

- AC-019-006-1: Given `TreeLoader.load!(:implement)` is called, when the YAML file exists, then it returns a `BehaviorTree.t()` with the correct node structure.
- AC-019-006-2: Given `TreeLoader.load_from_file!/1` is called with a path to a non-existent YAML file, when it is called, then it raises with a descriptive error message.
- AC-019-006-3: Given a new workflow YAML is added to `priv/defaults/workflows/`, when `TreeLoader.load!/1` is called with its name, then it compiles without modification to the tree loader code.

### REQ-019-007: Guard Nodes

**Priority:** Should  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: guard functions must be pure to preserve determinism]

Foreman shall provide guard functions as first-class behavior tree nodes.

- AC-019-007-1: Given a guard node `ChecksPassed` returns `:success`, when the Selector parent is evaluated, then it proceeds to the success branch.
- AC-019-007-2: Given `ChecksPassed` returns `:failure`, when the Selector parent is evaluated, then it tries the next sibling (retry branch).
- AC-019-007-3: Given a guard function has invalid input, when it is called, then the node returns `{:error, reason}` and the tree halts gracefully.

### REQ-019-008: CoordinatorAgent with BehaviorTree Strategy

**Priority:** Must  
**Complexity:** High  
**Type:** Functional  
**Risk:** [RISK: CoordinatorAgent must integrate with Phase 3 ForemanAgent]

`ForemanServer.CoordinatorAgent` shall use `Jido.Agent.Strategy.BehaviorTree`.

- AC-019-008-1: Given `CoordinatorAgent.cmd/2` is called with `StartWorkflow`, when the action is processed, then it sets `behavior_tree` in agent state and sets mode to `:running`.
- AC-019-008-2: Given `CoordinatorAgent` is in `:running` mode, when `BehaviorTree.tick/3` is called, then the tree advances one node and the agent state blackboard is updated.
- AC-019-008-3: Given the tree returns `:success` or `:failure`, when `CoordinatorAgent` processes the tick result, then it emits the appropriate `run.completed` or `run.failed` signal.

### REQ-019-009: Feature Flag Coexistence

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: WorkflowInterpreter and behavior tree must coexist]

Existing `WorkflowInterpreter` and new behavior tree execution shall coexist behind `:use_behavior_tree`.

- AC-019-009-1: Given `:use_behavior_tree` is `false` (default), when `ForemanServer.RunSupervisor` runs a workflow, then it uses `WorkflowInterpreter.next_step/1`.
- AC-019-009-2: Given `:use_behavior_tree` is `true`, when `RunSupervisor` runs a workflow, then it uses `CoordinatorAgent` with the behavior tree.
- AC-019-009-3: Given both paths exist, when integration tests run with default settings, then they use the `WorkflowInterpreter` path (preserving backward compatibility).

### REQ-019-010: Path Coverage for Existing Workflows

**Priority:** Must  
**Complexity:** High  
**Type:** Functional  
**Risk:** [RISK: all tree branches must be exercised]

All behavior tree branches shall be exercised by the existing integration test suite.

- AC-019-010-1: Given the `implement` tree has 8 leaf nodes, when `mix test` runs on workflow integration tests, then all 8 nodes are exercised at least once.
- AC-019-010-2: Given the retry branch in `execute_phase`, when a PR never gets approved within the repeat limit (120 * 30s = 60min), then the tree returns `:failure` with `reason: :approval_timeout`.
- AC-019-010-3: Given the `wait_for_checks` node, when checks pass within the timeout, then the tree proceeds to the success branch.

### REQ-019-011: Jido BehaviorTree Signal Integration

**Priority:** Could  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: jido_behaviortree has built-in signal support]

Foreman shall use `jido_behaviortree`'s built-in signal routes for tree control.

- AC-019-011-1: Given the tree has a `WaitForChecks` node, when checks complete via `ForemanSignal.Bus` publishing `checks.completed`, then the tree's signal route receives the signal and the node's `:running` status transitions to `:success`.
- AC-019-011-2: Given the tree receives `run.halt` via `ForemanSignal.Bus`, when the signal is delivered, then the tree halts and the coordinator emits `run.halted`.

### REQ-019-012: Documentation

**Priority:** Should  
**Complexity:** Low  
**Type:** Documentation  
**Risk:** [RISK: documentation debt]

- AC-019-012-1: Given an engineer adds a new phase type, when they follow the pattern in `foreman_jido/lib/behaviors/`, then they can add the phase as a new node without modifying `CoordinatorAgent`.
- AC-019-012-2: Given an operator reads `foreman workflow show --help`, when they run the command, then the output describes the tree structure and current execution state.

### REQ-019-013: Upstream Contribution

**Priority:** Should  
**Complexity:** Low  
**Type:** Process  
**Risk:** [RISK: Foreman nodes may be too domain-specific for upstream]

Foreman shall contribute the phase node library design to `jido_behaviortree`.

- AC-019-013-1: Given `ForemanServer.Behaviors.PhaseNodes` is production-proven, when a guide is written for `jido_behaviortree` on building domain-specific node libraries, then it uses Foreman's phase nodes as the example.

---

## 6. Dependencies and Risks

| ID | Dependency / Risk | Mitigation |
|----|--------------------|------------|
| DEP-019-01 | Phase 4 depends on: Phase 1 + 2 + 3 | Gate: no behavior tree work until all three Phases' acceptance tests green |
| DEP-019-02 | `TreeLoader` depends on: existing workflow YAML format | No schema change required; loader parses existing YAML |
| RISK-019-01 | Behavior tree must exactly match `WorkflowInterpreter` | Automated test: run both paths on 100 workflow inputs; assert identical results |
| RISK-019-02 | `CoordinatorAgent` with BT strategy must integrate with `ForemanAgent` base | Use existing `ForemanServer.ForemanAgent` base; strategy swap is a config change |
| RISK-019-03 | Tree visualization is ASCII only in Phase 4 | Explicit non-goal: visual editor comes in future phases |
| RISK-019-04 | Infinite retry loop in `WaitForChecks` without timeout guard | `Nodes.Repeat` has explicit `max_repeats`; test confirms failure after limit |

---

## 7. Acceptance Criteria Checklist

- [ ] REQ-019-001-1: `mix deps.get` in `packages/jido_behaviortree` resolves without network
- [ ] REQ-019-001-2: `mix test` passes in vendored `jido_behaviortree`
- [ ] REQ-019-002-1: `execute_phase/0` has Selector with two branches
- [ ] REQ-019-002-2: CheckPrApproved failure → dispatch branch
- [ ] REQ-019-002-3: CheckPrApproved success → wait branch
- [ ] REQ-019-002-4: All phase nodes exercised by test suite
- [ ] REQ-019-003-1: Tree output identical to `WorkflowInterpreter` for valid spec
- [ ] REQ-019-003-2: Tree proceeds to dispatch when PR approved
- [ ] REQ-019-003-3: Tree emits retry signal when checks fail
- [ ] REQ-019-003-4: All 42 workflow integration test cases pass with tree
- [ ] REQ-019-004-1: `foreman workflow show implement` renders ASCII tree
- [ ] REQ-019-004-2: `--highlight run_id` shows active node
- [ ] REQ-019-004-3: Guard conditions shown inline
- [ ] REQ-019-005-1: `:spec_valid` readable from blackboard across nodes
- [ ] REQ-019-005-2: `:worker_id` readable from blackboard across nodes
- [ ] REQ-019-005-3: Concurrent ticks have isolated blackboard scopes
- [ ] REQ-019-006-1: `TreeLoader.load!(:implement)` returns valid `BehaviorTree.t()`
- [ ] REQ-019-006-2: Non-existent file raises descriptive error
- [ ] REQ-019-006-3: New workflow YAML compiles without code changes
- [ ] REQ-019-007-1: Guard success → Selector proceeds to success branch
- [ ] REQ-019-007-2: Guard failure → Selector tries next sibling
- [ ] REQ-019-007-3: Guard error → tree halts gracefully
- [ ] REQ-019-008-1: `StartWorkflow` sets `behavior_tree` in state
- [ ] REQ-019-008-2: Tree tick advances and updates blackboard
- [ ] REQ-019-008-3: Tree success/failure emits `run.completed/failed` signal
- [ ] REQ-019-009-1: `:use_behavior_tree: false` uses `WorkflowInterpreter`
- [ ] REQ-019-009-2: `:use_behavior_tree: true` uses `CoordinatorAgent`
- [ ] REQ-019-009-3: Default settings use `WorkflowInterpreter` path
- [ ] REQ-019-010-1: All 8 leaf nodes exercised by integration tests
- [ ] REQ-019-010-2: Tree returns `:failure` with `approval_timeout` after 60min
- [ ] REQ-019-010-3: Checks pass within timeout → success branch
- [ ] REQ-019-011-1: `checks.completed` signal transitions `WaitForChecks` from running to success
- [ ] REQ-019-011-2: `run.halt` signal halts tree and emits `run.halted`
- [ ] REQ-019-012-1: New phase type pattern documented
- [ ] REQ-019-012-2: `foreman workflow show --help` documents tree output format
- [ ] REQ-019-013-1: Domain-specific node library guide submitted to `jido_behaviortree`
