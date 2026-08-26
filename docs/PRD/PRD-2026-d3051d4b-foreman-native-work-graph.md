---
document_id: PRD-2026-d3051d4b
label: prd-foreman-native-work-graph
version: 1.0.0
status: Draft
date: 2026-08-15
scale_depth: STANDARD
total_requirements: 17
total_acceptance_criteria: 55
readiness_score: 4.2
---

# PRD: Foreman-Native Work Graph (Phase B)

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 12 |
| Should | 4 |
| Could | 1 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 17/17 (100%) |
| Risk flags | 8 |
| Dependencies | 7 |
| Open ambiguity markers | 0 |
| TRD decisions required | 5 |

## 1. Executive Summary

Foreman has no concept of one piece of work depending on another. There is no ready-set computation, no eligibility check, no topological sort anywhere in `foreman_server`. `Aggregates.Task` models `task.add_dependency` and folds `TaskDependencyAdded` into `state.dependencies` — and that command is never dispatched, and that state is never read. The concept was designed and abandoned.

Beads owns dependency resolution entirely, through `br ready` and `bv`, outside Foreman. And because it does, **parallelism today is agent-internal**: `implement-trd-beads` is one Foreman run, one phase, one agent, looping over `br ready` and fanning out subagents it manages itself. Foreman supervises a single subprocess and contributes nothing to the scheduling of the dozens of units of work inside it.

This PRD moves the execution DAG into Foreman. The observation it rests on is that Beads is doing two separable jobs:

- A **durable, human-editable backlog** — issues with priorities, comments, and cross-tool identity, diffable in git, surviving Foreman entirely. Foreman should not reimplement this and this PRD does not.
- An **execution DAG** — what is unblocked right now, run those concurrently. This is small, and shelling out to a CLI for it is the odd choice given Foreman is an event-sourced orchestrator with a supervision tree.

Taking the second gives Foreman something it cannot get any other way: parallelism becomes **OTP-native**. Each node is a real run with its own worktree, its own PR association, its own slot in the global run-slot limiter, and its own supervision. The visibility problem Phase A solves at the phase level disappears at the graph level, because there is no longer an opaque "inside the phase" where dozens of units of work hide.

Scope: dependency edges on work submission, atomic batch submission with cycle detection, ready-set computation in a projection, automatic admission on dependency satisfaction, failure propagation policy, fair scheduling across concurrent graphs, and agent-emitted subgraphs so a planning run can decompose work into a graph Foreman then schedules.

## 2. Background and Evidence

### 2.1 There is no dependency machinery in Foreman

- `Aggregates.Task` handles `task.add_dependency`, emits `TaskDependencyAdded`, and folds it into `state.dependencies`. The command has no dispatch site anywhere in `lib/`, and nothing reads `state.dependencies` to gate `task.approve`, `task.dispatch`, or admission. `Task.handle_command/2` for `task.dispatch` checks only `require_dispatchable/1` — status, `run_id`, `approval_id`. Dependencies are inert.
- A broad search for ready-set, eligibility, topological, blocked-by, or DAG computation across `lib/` returns nothing. `ProjectionStore.list_workflow_tasks/0` filters by status and has no callers. `RunBlocked` is a run-level terminal status unrelated to dependency graphs.
- `Aggregates.BoardItemStateMachine` is a complete kanban state machine — `backlog → in_progress → in_review → done`, plus `blocked` — with zero dispatch sites. It is the closest existing thing to a work-graph node state and it was never connected.
- `Aggregates.Scheduler` and `Aggregates.PlanningFlow` are likewise fully dead. `Aggregates.SchedulerIntent` is dispatched only from `ForemanServer.Recovery`, which itself has no callers and is not supervised. None of these relate to dependency scheduling — `SchedulerIntent` tracks cron-style external trigger fires.

### 2.2 Parallelism is currently the agent's job, not Foreman's

`priv/defaults/workflows/implement-trd-beads.yaml` declares exactly one phase, invoking one skill with one command. `RunExecutor` emits `PhaseStarted`, blocks on a single `pi` invocation for the duration, and emits `PhaseCompleted`. `config/dev.exs` carries a one-hour timeout override for it, with a comment noting one such TRD had 48 tasks over roughly 90 hours of estimated work.

So Foreman's entire contribution to scheduling 48 interdependent units of work is: start one process, wait up to an hour, record the result.

### 2.3 The scheduling primitives already exist or are already planned

This is what makes the phase tractable:

- `PRD-2026-0eac69b3` introduces `work.submit` and a `WorkRequest` aggregate as the pre-run identity for agentic submissions, plus a `RunSlots` aggregate providing a durable global concurrency budget with a FIFO waiter queue and atomic promote-on-release.
- `RunSlots` is precisely the parallelism budget a graph scheduler needs. Phase B does not add concurrency control; it adds *eligibility*, and lets the existing budget do the rest.
- Runs already execute concurrently under `RunSupervisor`, each with its own worktree via `Workflow.Worktree` and its own PR association keyed by `run_id`.

### 2.4 What must not be rebuilt

`ForemanServer.TaskProvider` declares `create/2`, `list_ready/2`, `get/2`, `claim/3`, `complete/3`, `fail/3`, `reopen/3`, `set_priority/3`, and `add_dependency/3`. That is an issue-tracker contract, and `BeadsAdapter` implements it against a real tracker with real human affordances. Reimplementing priorities, assignees, comments, and a git-diffable backlog inside Foreman would be a strictly worse version of something that already works. Phase B builds a scheduler, not a tracker.

## 3. Personas

### 3.1 Planning agent (primary)

Has decomposed a TRD or a large request into units of work with an ordering between them. Wants to hand Foreman the whole graph in one call and let Foreman schedule it, rather than staying resident for an hour driving execution itself.

### 3.2 Agentic client (primary)

Submits a batch of related work and wants to know overall graph progress — how many nodes are done, what is running, what is blocked and on what.

### 3.3 Foreman operator (secondary)

Runs several graphs concurrently against a small slot budget. Needs one large graph not to starve everything else, and needs to see why a node is not running.

## 4. Requirements

### 4a. Graph Structure

### REQ-001: Must | High | Dependency edges on work submission
A work request MUST be able to declare that it depends on other work requests.

- AC-001-1: Given `work.submit` carries `depends_on` with a list of work ids, when the submission is accepted, then those edges are recorded durably on the work request.
- AC-001-2: Given a work request has unsatisfied dependencies, when it is submitted, then no run is started for it and its status is `blocked`.
- AC-001-3: Given a work request declares a dependency on a work id that does not exist, when it is validated, then the submission is rejected and no event is appended.
- AC-001-4: Given a work request declares itself as its own dependency, when it is validated, then the submission is rejected.
- AC-001-5: Given `depends_on` is absent or empty, when the submission is accepted, then behaviour is identical to `PRD-2026-0eac69b3`'s — the node is immediately eligible.

### REQ-002: Must | High | Atomic batch submission
A graph MUST be submittable as a unit so it is never partially created.

- AC-002-1: Given `work.submit_batch` with N nodes and their edges, when every node validates, then all N are created and the batch returns their ids together with which are immediately eligible.
- AC-002-2: Given any node in a batch fails validation, when the batch is processed, then **no** node is created and the error names the offending node.
- AC-002-3: Given a batch declares edges between nodes within the batch, when it is validated, then forward references within the batch are permitted — a node may depend on a sibling declared later in the list.
- AC-002-4: Given a batch declares an edge to a node outside the batch, when it is validated, then that node must already exist or the batch is rejected.

### REQ-003: Must | High | Cycle detection
A submitted graph MUST be acyclic.

- AC-003-1: Given a batch whose edges form a cycle, when it is validated, then it is rejected with an error naming the nodes in the cycle and nothing is created.
- AC-003-2: Given a single `work.submit` whose edge would close a cycle against already-existing nodes, when it is validated, then it is rejected before any event is appended.
- AC-003-3: Given a graph of the largest supported size, when cycle detection runs, then it completes within the command's timeout budget — detection is not permitted to be the reason a submission times out.

### REQ-004: Should | Medium | Graph identity and parentage
Related nodes SHOULD be addressable as a unit.

- AC-004-1: Given a batch is submitted, when it is created, then every node carries a shared `graph_id` and the batch returns it.
- AC-004-2: Given a node is emitted by a running work request, when it is created, then it carries `parent_work_id` and inherits the parent's `graph_id`.
- AC-004-3: Given a `graph_id`, when the graph is queried, then it returns every node, its status, its edges, and the graph's aggregate progress.

### 4b. Scheduling

### REQ-005: Must | High | Ready-set computation
Foreman MUST compute which work is unblocked, without shelling out.

- AC-005-1: Given a set of work requests with edges, when the ready set is computed, then it contains exactly those that are not started and whose every dependency has terminated successfully.
- AC-005-2: Given the ready set is computed, when it is derived, then it comes from a projection over the event stream, not from an external process or database.
- AC-005-3: Given a dependency is still running, when eligibility is evaluated, then its dependents are not eligible.

### REQ-006: Must | High | Automatic admission on dependency satisfaction
Satisfying a dependency MUST admit its dependents without operator or agent action.

- AC-006-1: Given a work request completes successfully, when its completion is observed, then every dependent whose remaining dependencies are all satisfied is submitted for admission.
- AC-006-2: Given admission is attempted and the global slot budget is exhausted, when the node is queued, then it queues in the existing run-slot waiter queue rather than in a second parallel queue.
- AC-006-3: Given the promotion path fails transiently, when the periodic reconciler next sweeps, then the eligible-but-unadmitted node is detected and admitted, so a dropped broadcast cannot strand a graph.
- AC-006-4: Given the server restarts with a partially-executed graph, when it boots, then the ready set is recomputed from the event stream and eligible nodes are admitted without manual intervention.

### REQ-007: Must | High | Failure propagation policy
A failed node MUST have a defined, configurable effect on its dependents.

- AC-007-1: Given a node fails and the graph's policy is `block` (the default), when the failure is observed, then its transitive dependents move to `blocked_by_failure` and are not started, while unrelated branches of the graph continue running.
- AC-007-2: Given the policy is `cancel`, when a node fails, then its transitive dependents are cancelled and reach a terminal state rather than waiting indefinitely.
- AC-007-3: Given the policy is `halt`, when a node fails, then every unstarted node in the graph is cancelled regardless of whether it depends on the failure.
- AC-007-4: Given a failed node is retried and succeeds, when it completes, then its `blocked_by_failure` dependents become eligible again — the block is a state, not a terminal outcome.
- AC-007-5: Given any policy, when a node is blocked or cancelled by propagation, then the reason names the originating failed node, so a stalled graph is diagnosable without reading the event log.

### REQ-008: Must | High | Fair scheduling across graphs
One large graph MUST NOT starve other work.

- AC-008-1: Given two graphs are eligible and the slot budget is smaller than either graph's ready set, when slots are allocated, then both graphs make progress rather than the first-submitted graph consuming every slot until it completes.
- AC-008-2: Given a standalone work request with no graph is submitted while a large graph is running, when slots free, then it is admitted within a bounded number of promotions rather than waiting for the graph to finish.
- AC-008-3: Given fairness is applied, when a graph's nodes are chosen, then the choice within a graph remains deterministic and reproducible from the event stream.
- AC-008-4: Given only one graph is eligible, when slots free, then it may consume the entire budget — fairness reserves nothing when there is no contention.

### REQ-009: Should | Medium | Graph-level cancellation
Cancelling a graph SHOULD be one operation.

- AC-009-1: Given a `graph_id` is cancelled, when the cancellation is processed, then every unstarted node is cancelled and removed from any waiter queue.
- AC-009-2: Given nodes are already running, when the graph is cancelled, then each delegates to the existing `run.cancel` path and the graph reaches a terminal state once they settle.
- AC-009-3: Given a graph is cancelled twice, when the second cancellation arrives, then it is an idempotent no-op.

### 4c. Agent-Emitted Graphs

### REQ-010: Must | High | A running work request can emit children
A planning run MUST be able to decompose its work into a graph Foreman then schedules.

- AC-010-1: Given a running work request holding a run-scoped credential, when it calls the batch submission tool, then the created nodes carry it as `parent_work_id` and share its `graph_id`.
- AC-010-2: Given a parent emits children, when the parent's own run completes, then the parent is not considered terminal until its children have terminated — a parent's success is the success of its subtree.
- AC-010-3: Given a parent emits a child that depends on a node outside its own subtree, when it is validated, then it is rejected — a subtree may not reach into the wider graph.
- AC-010-4: Given emission depth exceeds a configured limit, when a child attempts to emit further children, then it is refused, so a runaway decomposition cannot expand without bound.
- AC-010-5: Given a parent emits N children, when N exceeds a configured fan-out limit, then the batch is refused with an error naming the limit.

### REQ-011: Must | Medium | Emission is credential-scoped
A running agent MUST only be able to emit into its own subtree.

- AC-011-1: Given a run-scoped credential, when it is used to emit children, then `parent_work_id` is derived from the credential and any value supplied in the arguments is ignored.
- AC-011-2: Given a credential for a terminated run, when emission is attempted, then it is refused.

### 4d. Observability and Control

### REQ-012: Must | Medium | Graph status is queryable
The state of a graph MUST be legible without reading the event store.

- AC-012-1: Given a graph is queried, when it returns, then it reports per-node status, edges, and counts of succeeded, failed, running, queued, and blocked nodes.
- AC-012-2: Given a node is not running, when it is inspected, then the reason is explicit — `blocked` naming the unsatisfied dependencies, `queued` with its position, or `blocked_by_failure` naming the originating failure.
- AC-012-3: Given a graph is queried over MCP, when it returns, then the same structure is available as over HTTP.

### REQ-013: Should | Medium | Graph progress is visible live
Graph state SHOULD reach the surfaces Phase A builds.

- AC-013-1: Given a node changes state, when the change is broadcast, then subscribers to the graph receive it through the same channel Phase A establishes for run progress.
- AC-013-2: Given a graph is watched, when a node completes, then the graph's aggregate counts update without the consumer polling.

### REQ-014: Should | Medium | Node granularity is controllable
The cost of one-run-per-node MUST be manageable.

- AC-014-1: Given a node, when it is submitted, then it may carry more than one unit of work in its prompt, so a submitter can choose a coarser granularity without changing the graph model.
- AC-014-2: Given guidance is published, when a submitter chooses granularity, then the documented recommendation is to cut nodes where a PR would be cut, and the rationale — agent cold-start and lost context — is stated.

### REQ-015: Could | Low | Dead scheduling aggregates are dispositioned
The abandoned graph-adjacent aggregates SHOULD stop being ambiguous.

- AC-015-1: Given `BoardItemStateMachine`, when the TRD is written, then it states whether the aggregate becomes the node state machine or is deleted, and does not leave it dormant.
- AC-015-2: Given `task.add_dependency` and `TaskDependencyAdded`, when this phase lands, then the write path is removed if `PRD-2026-0eac69b3`'s pruning has not already removed it, while event decode is retained.

### 4e. Cross-Cutting

### REQ-016: Must | High | Existing paths are unaffected
Adding the graph MUST NOT change how ungraphed work behaves.

- AC-016-1: Given a work request with no edges, when it is submitted and executed, then its behaviour is identical to `PRD-2026-0eac69b3`'s in every observable respect.
- AC-016-2: Given the Task and Beads path, when this phase lands, then it is unchanged — no Task acquires dependency enforcement and no `TaskProvider` callback is added or altered.
- AC-016-3: Given the global slot budget, when graphs are scheduled, then the budget is the one `RunSlots` already enforces — this phase introduces no second concurrency control.

### REQ-017: Must | Medium | Bounded graph size
A graph MUST have an enforced maximum size.

- AC-017-1: Given a configured maximum node count per graph, when a batch or emission would exceed it, then it is refused with an error naming the limit and the current count.
- AC-017-2: Given the limit is reached, when the refusal is emitted, then it carries telemetry so an operator can see graphs pressing against the ceiling.

## 5. Ambiguity Resolution Status

| Ambiguity | Resolution |
|---|---|
| Does Foreman become an issue tracker? | No. It gains an execution DAG. Priorities, assignees, comments, and a human-editable backlog stay in Beads (§2.4). |
| Where does concurrency control live? | In `RunSlots` from `PRD-2026-0eac69b3`. This phase adds eligibility only (REQ-016-3). |
| Who builds the graph? | Either a client via `work.submit_batch`, or a running planning agent via credential-scoped emission (REQ-010). Foreman does not parse TRDs. |
| What happens when a node fails? | Configurable per graph, defaulting to blocking transitive dependents while unrelated branches continue (REQ-007). |
| Can one graph monopolize the slots? | No — fair allocation across graphs is a Must (REQ-008). |

## 6. Dependency Map

| Dependency | Kind | Notes |
|---|---|---|
| `PRD-2026-0eac69b3` `WorkRequest` | Internal, **hard** | Nodes are work requests. This phase cannot start before that PRD's PR 3 lands. |
| `PRD-2026-0eac69b3` `RunSlots` | Internal, **hard** | Supplies the parallelism budget and the durable waiter queue. REQ-008's fairness modifies its promotion choice. |
| `PRD-2026-aba4b79c` run-scoped credentials | Internal, **hard for REQ-010/011** | Agent-emitted subgraphs reuse Phase A's credential. Everything else in this PRD is independent of Phase A. |
| `PRD-2026-aba4b79c` live channel | Internal, soft | REQ-013 rides Phase A's broadcast surface; without it, graph status is poll-only. |
| `ForemanServer.Workflow.Dispatcher` | Internal | Observes terminal work events and admits newly-eligible dependents. |
| `ForemanServer.Workflow.BootReconciliation` | Internal | Must recompute the ready set at boot alongside its existing lease and slot scans. |
| `Aggregates.BoardItemStateMachine` | Internal | Existing dormant kanban state machine; a reuse candidate for node state (REQ-015-1). |

## 7. Risks and Open Questions

### Risks

1. **One run per node multiplies cost.** Forty-eight nodes means forty-eight worktrees, forty-eight agent cold starts, and forty-eight lots of context re-establishment, against one long-lived agent that keeps its context warm. This is the strongest argument against the whole phase. REQ-014 mitigates by making granularity a submitter choice, but it does not eliminate the cost and the tradeoff should be measured before committing — which is what Phase C's gate exists for.
2. **Fairness and determinism pull against each other.** REQ-008 wants round-robin across graphs; REQ-008-3 wants the choice reproducible from the event stream. Both are achievable but the allocation rule needs to be a recorded decision rather than emergent behaviour.
3. **Cycle detection cost at submit time.** REQ-003-3 sets the constraint but a large batch validated inside a command handler is a latency risk on a path that also holds an aggregate.
4. **A blocked graph can look identical to a stuck one.** `StuckDetector` reasons about runs, not graphs. A graph fully blocked behind a failure has no running run and will not be flagged by anything. REQ-007-5 makes the state diagnosable but nothing alerts on it.
5. **Parent-child completion semantics are subtle.** REQ-010-2 makes a parent non-terminal until its subtree finishes, which means a parent's run has completed while the parent has not. That is two different notions of done on one entity and it will confuse consumers unless the projection is explicit.
6. **Retry semantics across a graph are unspecified.** REQ-007-4 says a retried node unblocks its dependents, but nothing says what retry means for a node whose dependents already ran under the `cancel` policy.
7. **This is a second scheduler.** Foreman already has admission, leases, slots, and reconciliation. Adding eligibility means four interacting gates. The interaction matrix deserves a property test, not example tests.
8. **Graphs make the event store much busier.** Forty-eight nodes each producing work, run, phase, and slot events is a large multiple of today's volume for the same delivered work.

### Open Questions

1. Should a graph have a deadline, after which unstarted nodes are cancelled?
2. Should node priority exist within a graph, or is topological order plus submission order sufficient? v1 assumes the latter.
3. Should a failed node be retried automatically with a bounded policy, or always manually? v1 assumes manual, matching `task.retry`.
4. When a parent emits children, should the parent's worktree be shared with, or inherited by, its children? This materially affects Risk 1 and is a TRD decision.

### Known out-of-scope gaps

- Any change to the Task or Beads path.
- Retiring `implement-trd-beads` — Phase C.
- TRD parsing inside Foreman. No such parser exists in this repo and none is added; graphs arrive from clients or planning agents.
- Priorities, assignees, comments, and human backlog editing — these stay in Beads.

## 8. Self-Critique

- The strongest part is REQ-008. Fair scheduling across graphs is the requirement most likely to be omitted from a first implementation and most likely to be discovered painfully in production, because a single 48-node graph against a 3-slot budget will starve everything else for hours.
- The weakest part is that the PRD asserts OTP-native parallelism is better without measuring it. Risk 1 is real, and a graph of small nodes could plausibly be slower and more expensive than the agent-internal loop it replaces. This PRD should probably not be implemented before Phase C's measurement gate produces a number — which inverts the natural ordering and is worth confronting rather than hiding.
- REQ-010-2's parent completion semantics are underspecified relative to their subtlety. Two notions of "done" on one entity needs its own requirement, not a sub-clause.
- REQ-015 is scope-adjacent housekeeping and could be dropped without loss.
- Nothing here addresses what happens when a graph's nodes want to share a git branch. Forty-eight nodes producing forty-eight PRs is a plausible reading of the design and probably not what anyone wants; branch strategy across a graph is a genuine gap.

## 9. Acceptance Criteria Summary

| Requirement | Priority | ACs | Theme |
|---|---|---:|---|
| REQ-001 | Must | 5 | Dependency edges |
| REQ-002 | Must | 4 | Atomic batch submit |
| REQ-003 | Must | 3 | Cycle detection |
| REQ-004 | Should | 3 | Graph identity |
| REQ-005 | Must | 3 | Ready-set computation |
| REQ-006 | Must | 4 | Automatic admission |
| REQ-007 | Must | 5 | Failure propagation |
| REQ-008 | Must | 4 | Cross-graph fairness |
| REQ-009 | Should | 3 | Graph cancellation |
| REQ-010 | Must | 5 | Agent-emitted children |
| REQ-011 | Must | 2 | Emission scoping |
| REQ-012 | Must | 3 | Graph status |
| REQ-013 | Should | 2 | Live graph progress |
| REQ-014 | Should | 2 | Node granularity |
| REQ-015 | Could | 2 | Dead aggregate disposition |
| REQ-016 | Must | 3 | Existing paths unaffected |
| REQ-017 | Must | 2 | Bounded graph size |

Total: 17 requirements, 55 acceptance criteria.

## 10. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Problem clarity | 5 | The absence of any DAG machinery and the one-phase shape of `implement-trd-beads` are both verified against source. |
| Requirement testability | 4 | Most ACs are checkable. REQ-008's fairness needs a property test and the allocation rule is not yet specified enough to write one. |
| Scope discipline | 4 | Tracker concerns are explicitly excluded. But branch strategy across a graph is missing and is arguably in scope. |
| Evidence quality | 5 | The dead dependency machinery, the absent ready-set computation, and the single-phase workflow were each verified. |
| Risk coverage | 4 | Eight risks. Risk 1 is acknowledged as potentially disqualifying and deliberately deferred to Phase C's measurement rather than argued away. |

**Overall score: 4.2 — PASS with a caveat.** The design is ready, but §8 recommends obtaining Phase C's cost measurement before committing to implementation.

## Appendix A: Evidence Index

| Claim | Location |
|---|---|
| `task.add_dependency` never dispatched | `lib/foreman_server/aggregates/task.ex` |
| `state.dependencies` never read to gate anything | `lib/foreman_server/aggregates/task.ex` — `task.dispatch` clause, `require_dispatchable/1` |
| No ready-set or topological computation anywhere | tree-wide search of `packages/foreman_server/lib/` |
| `BoardItemStateMachine` is a dormant kanban aggregate | `lib/foreman_server/aggregates/board_item_state_machine.ex` |
| `Scheduler`, `PlanningFlow` dead; `SchedulerIntent` transitively dead | `lib/foreman_server/aggregates/{scheduler,planning_flow,scheduler_intent}.ex`; `lib/foreman_server/recovery.ex` |
| One phase for an entire TRD | `priv/defaults/workflows/implement-trd-beads.yaml` |
| One-hour timeout for that phase | `config/dev.exs` |
| Runs already isolate by worktree and associate PRs by `run_id` | `lib/foreman_server/workflow/worktree.ex`; `lib/foreman_server/pr_associate.ex` |
| `TaskProvider` is an issue-tracker contract | `lib/foreman_server/task_provider.ex` — 12 callbacks |
| No TRD parser exists in this repo | `packages/foreman_cli/cmd/foreman/main.go` — subcommands are project, task, run, workflow, init |

## Changelog

### 1.0.0 — 2026-08-15 — Initial PRD

Phase B of a three-phase programme. Depends hard on `PRD-2026-0eac69b3` for `WorkRequest` and `RunSlots`, and on `PRD-2026-aba4b79c` for the run-scoped credential that makes agent-emitted subgraphs possible. Phase C (`PRD-2026-39d2f88f`) supplies the measurement that should gate whether this phase is worth implementing at the granularity it assumes.
