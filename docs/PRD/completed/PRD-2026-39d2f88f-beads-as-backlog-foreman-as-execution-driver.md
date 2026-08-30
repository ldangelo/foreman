---
document_id: PRD-2026-39d2f88f
label: prd-beads-as-backlog-foreman-as-execution-driver
version: 1.0.0
status: Draft
date: 2026-08-15
scale_depth: STANDARD
total_requirements: 14
total_acceptance_criteria: 41
readiness_score: 4.0
---

# PRD: Beads as Backlog, Foreman as Execution Driver (Phase C)

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 9 |
| Should | 4 |
| Could | 1 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 14/14 (100%) |
| Risk flags | 8 |
| Dependencies | 6 |
| Open ambiguity markers | 0 |
| TRD decisions required | 4 |

## 1. Executive Summary

Phases A and B give Foreman its own progress channel and its own execution DAG. This phase decides what Beads is *for* afterwards, and — critically — refuses to make that decision on architectural preference alone.

The proposition is a split, not a removal. Beads keeps the job it is genuinely good at: a durable, human-editable, git-diffable backlog with cross-tool and cross-session identity, usable outside Foreman entirely. Foreman takes the job it is structurally better suited to: scheduling and executing a dependency graph under supervision, with slots, worktrees, retries, and reconciliation it already owns.

The central requirement of this PRD is therefore not a migration. It is a **gate**. Phase B's design assumes that decomposing a TRD into N supervised runs beats one long-lived agent looping over `br ready`. That assumption is untested and plausibly wrong: N nodes means N agent cold starts, N worktrees, and N losses of accumulated context, against one warm agent that keeps everything in working memory. Before Foreman-native execution becomes the default for anything, this phase requires a measured comparison on real work — wall-clock, token cost, and success rate — and it requires the result to be published whichever way it falls.

Only if the gate passes does the rest follow: a Foreman-native replacement for `implement-trd-beads`, one-way export from the Foreman work graph into Beads so humans keep the backlog view they have today, and a deprecation path for the old workflow that leaves it working until it is provably unnecessary.

This PRD is also where the accumulated dead machinery gets a verdict. Six aggregates in `foreman_server` are fully built and never dispatched. Leaving them is a standing tax on every future reader.

## 2. Background and Evidence

### 2.1 What Beads does that Foreman should not reimplement

`ForemanServer.TaskProvider` declares twelve callbacks — `name/0`, `capabilities/0`, `available?/0`, `create/2`, `list_ready/2`, `get/2`, `claim/3`, `complete/3`, `fail/3`, `reopen/3`, `set_priority/3`, `add_dependency/3` — and `BeadsAdapter` implements them against a real tracker. Priorities, assignees, comments, dependency editing, and a JSONL store that lives in git and diffs cleanly are all things a person interacts with directly, between runs and outside Foreman.

Notably, `create/2` exists. An export path from Foreman into Beads does not need new adapter surface.

### 2.2 What Beads does today that Phases A and B replace

Two things, both of which exist only because Foreman could not do them:

- **Intra-run feedback.** Foreman emits nothing between `PhaseStarted` and `PhaseCompleted`; the agent's `br` writes are the only progress signal, reaching Foreman by way of `BeadsWatcher` tailing the Beads store. Phase A replaces this with direct reporting into the run's own stream.
- **Dependency resolution and fan-out.** No ready-set, eligibility, or topological computation exists anywhere in `foreman_server`; `br ready` and `bv` own it, and parallelism is managed by the agent inside a single Foreman run. Phase B replaces this with an event-sourced graph scheduled against the existing `RunSlots` budget.

### 2.3 The current shape of a TRD implementation

`priv/defaults/workflows/implement-trd-beads.yaml` declares one phase invoking one skill. `config/dev.exs` carries a one-hour timeout for it and notes a TRD with 48 tasks across roughly 90 estimated hours. Foreman's contribution is: start one subprocess, wait, record the outcome.

That is the baseline any Foreman-native replacement must beat, and "beat" has to mean something measurable.

### 2.4 Foreman has no TRD parser

The Go CLI implements `project`, `task`, `run`, `workflow`, and `init`. There is no `sling` subcommand and no TRD parsing anywhere in `packages/`. The `parseTrd()` / `trd-graph-cli` machinery referenced by the ensemble skills lives in the ensemble repo as Node tooling.

This matters: a Foreman-native replacement must not acquire a second TRD parser. The graph should arrive from a planning agent via Phase B's batch submission, which keeps parsing where it already works.

### 2.5 The dead-aggregate inventory

Fully built, zero production dispatch sites: `Aggregates.ToolCall`, `Aggregates.ArtifactReport`, `Aggregates.BoardItemStateMachine`, `Aggregates.PlanningFlow`, `Aggregates.Scheduler`, `Aggregates.ProjectRunLimit`. Transitively dead: `Aggregates.SchedulerIntent`, dispatched only from `ForemanServer.Recovery`, which has no callers and is not supervised. Built but disconnected from the execution path and disabled outside dev: the entire `Overwatch` subsystem and `Aggregates.Worker`.

Phases A and B will claim some of these. Whatever they do not claim should be deleted rather than left as a fourth generation of the same confusion.

## 3. Personas

### 3.1 Engineer deciding whether to switch (primary)

Will not move a working pipeline onto a new execution model on the strength of an architecture argument. Wants a number: same TRD, both paths, wall-clock and cost and outcome.

### 3.2 Human backlog user (primary)

Edits priorities, reads comments, greps the JSONL, works with Beads between runs and from other tools. Must not lose any of that regardless of how execution changes.

### 3.3 Foreman maintainer (secondary)

Wants one execution model rather than two indefinitely, and wants the dead aggregates resolved.

## 4. Requirements

### 4a. The Measurement Gate

### REQ-001: Must | High | Comparative benchmark before any default changes
Foreman-native execution MUST NOT become the default for any workflow before a measured comparison exists.

- AC-001-1: Given a representative TRD of at least 30 tasks, when it is executed both by `implement-trd-beads` and by the Foreman-native path, then wall-clock duration, total token cost, and task-level success rate are recorded for both.
- AC-001-2: Given the comparison is run, when results are recorded, then each path is executed at least three times, and variance is reported alongside means — a single run of each does not satisfy this requirement.
- AC-001-3: Given the results, when they are published, then they are committed to the repository as a dated report regardless of which path wins.
- AC-001-4: Given the Foreman-native path is slower or more expensive by more than a threshold agreed before the benchmark is run, when the result is known, then the default does not change and the remaining requirements in this PRD are deferred rather than implemented.
- AC-001-5: Given the benchmark, when it is designed, then the granularity used for the Foreman-native path is stated explicitly, because node size is the dominant variable and a result is meaningless without it.

### REQ-002: Should | High | Granularity sweep
The benchmark SHOULD test more than one node size.

- AC-002-1: Given the Foreman-native path, when it is benchmarked, then at least two granularities are measured — one node per task and one node per story or PR-sized group.
- AC-002-2: Given the sweep, when results are reported, then the recommended default granularity is stated with its rationale.

### 4b. Foreman-Native TRD Execution

### REQ-003: Must | High | A plan-then-graph workflow
There MUST be a Foreman-native workflow that decomposes a TRD into a work graph and executes it.

- AC-003-1: Given a TRD path, when the workflow runs, then its first phase produces a decomposition and submits it as a work graph through Phase B's batch submission.
- AC-003-2: Given the graph is submitted, when the planning phase completes, then Foreman schedules the nodes and the planning agent does not remain resident driving execution.
- AC-003-3: Given decomposition fails or produces an invalid graph, when it is rejected, then the failure names the reason and no partial graph exists.
- AC-003-4: Given the workflow executes, when it does, then no TRD parser is added to `foreman_server` — the decomposition is produced by the planning agent.

### REQ-004: Must | High | Node execution carries the same guarantees as today
A node MUST NOT be a weaker execution context than a phase is today.

- AC-004-1: Given a node executes, when it runs, then it has a worktree, an artifact, PR association, retry, and stuck detection on the same terms as any other run.
- AC-004-2: Given a node fails, when it is retried, then retry semantics match the existing `task.retry` contract — a bound terminal run, an acknowledgement, and a fresh run id.
- AC-004-3: Given nodes execute concurrently, when they contend for the same Beads database, when applicable, then the existing per-database lease still applies.

### REQ-005: Must | Medium | Branch and PR strategy across a graph
A graph MUST have a defined branching model rather than producing one PR per node by accident.

- AC-005-1: Given a graph executes, when its branching model is applied, then it is one of a stated set — a branch per node, a stacked branch per graph, or a single shared branch — chosen at submission and recorded on the graph.
- AC-005-2: Given the default model, when it is chosen, then it does not produce one PR per node unless the submitter explicitly asks for that.
- AC-005-3: Given nodes share a branch, when they execute concurrently, then write conflicts are prevented by the same worktree isolation and containment rules that exist today, or concurrency within that branch is serialized.

### 4c. Beads as Backlog

### REQ-006: Must | High | One-way export from the work graph to Beads
Humans MUST keep the backlog view they have today.

- AC-006-1: Given a work graph is created, when export is enabled, then a corresponding issue is created in the project's tracker through the existing `TaskProvider.create/2` callback, with the dependency edges mapped through `add_dependency/3`.
- AC-006-2: Given a node changes state, when export is enabled, then the corresponding issue's state is updated through the existing lifecycle callbacks.
- AC-006-3: Given export fails for any node, when the failure occurs, then execution is unaffected — export is best-effort and never gates a run.
- AC-006-4: Given export is disabled by configuration, when a graph executes, then no tracker call is made at all.

### REQ-007: Must | High | Export is one-way
The direction of authority MUST be unambiguous.

- AC-007-1: Given a Foreman-native graph is executing, when a human edits the exported issue in the tracker, then that edit does not alter graph execution.
- AC-007-2: Given a node and its exported issue disagree, when they are reconciled, then Foreman's state is authoritative for execution and the divergence is reported rather than silently resolved.
- AC-007-3: Given `BeadsWatcher`'s reverse-sync, when a graph-exported issue appears in the Beads store, then it does **not** synthesize a `task.create` — exported issues are excluded from reverse-sync, or the resulting loop is otherwise structurally prevented.

### REQ-008: Should | Medium | Beads remains fully usable as today
Nothing in this phase SHOULD reduce what Beads can do.

- AC-008-1: Given a project that does not adopt Foreman-native execution, when it runs, then the Task and Beads path behaves exactly as before.
- AC-008-2: Given a human uses `br` directly, when they do, then every operation available today remains available.

### 4d. Deprecation

### REQ-009: Must | Medium | The old workflow keeps working until it is proven unnecessary
`implement-trd-beads` MUST NOT be removed on a schedule.

- AC-009-1: Given the Foreman-native workflow exists, when both are installed, then a project chooses per submission which to use, and neither is removed.
- AC-009-2: Given the benchmark gate has passed and a stated adoption period has elapsed, when removal is proposed, then it is proposed as a separate change with its own evidence, not as part of this one.
- AC-009-3: Given `implement-trd-beads` is eventually removed, when it is, then runs already executing against it are unaffected because their snapshots are frozen.

### REQ-010: Should | Medium | Migration guidance
Adopters SHOULD be told how to move.

- AC-010-1: Given the documentation, when it is written, then it states which workflow to use when, the recommended node granularity, and the branching model implications.
- AC-010-2: Given a project has in-flight Beads work, when it adopts the native path, then the documented procedure does not require abandoning or re-creating that work.

### 4e. Cleanup

### REQ-011: Must | Medium | Every dead aggregate gets a verdict
The abandoned machinery MUST stop being ambiguous.

- AC-011-1: Given `ToolCall`, `ArtifactReport`, `BoardItemStateMachine`, `PlanningFlow`, `Scheduler`, `SchedulerIntent`, and `ProjectRunLimit`, when this phase completes, then each is either connected to a production path or deleted — none remains defined-but-undispatched.
- AC-011-2: Given any aggregate is deleted, when it is removed, then its `apply_event/2` clauses and `event_codec.ex` entries are retained if any historical stream could contain its events, so no stream becomes undecodable.
- AC-011-3: Given `ForemanServer.Recovery`, when it is dispositioned, then it is either supervised and called or removed — it does not remain an unreachable module dispatching to an otherwise-dead aggregate.
- AC-011-4: Given `Overwatch` and `Aggregates.Worker`, when Phase A's decision is known, then whatever Phase A did not adopt is deleted or explicitly documented as intentionally dormant with a reason.

### REQ-012: Should | Low | An architecture test prevents recurrence
The pattern that produced seven dead aggregates SHOULD be made visible.

- AC-012-1: Given the test suite, when it runs, then it fails on any aggregate whose command types have no dispatch site outside the aggregate and its own tests, unless the aggregate is on an explicit allow-list with a stated reason.
- AC-012-2: Given a new aggregate is added, when it has no caller, then the build fails rather than the aggregate silently joining the inventory.

### 4f. Cross-Cutting

### REQ-013: Must | Medium | Reversibility
Adopting the native path MUST be reversible.

- AC-013-1: Given a project has adopted Foreman-native execution, when it switches back, then it does so by configuration and submission choice, with no data migration required.
- AC-013-2: Given both paths have been used in one project, when its history is read, then work from each is distinguishable by its originating surface.

### REQ-014: Could | Low | Cost telemetry per node
Cost SHOULD become observable rather than being measured only during the benchmark.

- AC-014-1: Given a node executes, when it completes, then token cost and duration are recorded on its terminal event where the adapter reports them.
- AC-014-2: Given a graph completes, when it is queried, then its aggregate cost is available, so the REQ-001 comparison can be re-run at any time rather than being a one-off exercise.

## 5. Ambiguity Resolution Status

| Ambiguity | Resolution |
|---|---|
| Is Beads being removed? | No. It becomes the human backlog and an export target. Execution scheduling moves to Foreman only if REQ-001's gate passes. |
| Who parses the TRD? | The planning agent. No TRD parser is added to Foreman (REQ-003-4); none exists there today. |
| Which direction does data flow? | Foreman → Beads, one way, best-effort, never gating execution (REQ-006, REQ-007). |
| When is `implement-trd-beads` removed? | Not by this PRD. Removal is a separate change with its own evidence (REQ-009). |
| What happens to the dead aggregates? | Every one gets an explicit verdict, and an architecture test prevents a recurrence (REQ-011, REQ-012). |

## 6. Dependency Map

| Dependency | Kind | Notes |
|---|---|---|
| `PRD-2026-aba4b79c` (Phase A) | Internal, **hard** | Without native progress reporting, moving off Beads loses visibility. Phase A must land first. |
| `PRD-2026-d3051d4b` (Phase B) | Internal, **hard** | Supplies the graph, the ready set, and the scheduling. Phase C is meaningless without it. |
| `PRD-2026-0eac69b3` | Internal, **hard** | Supplies `WorkRequest`, `RunSlots`, and the MCP surface both later phases build on. |
| `ForemanServer.TaskProvider` / `BeadsAdapter` | Internal | Export uses the existing `create/2`, `add_dependency/3`, and lifecycle callbacks. No new adapter surface. |
| `TaskProviders.BeadsWatcher` | Internal | Must not reverse-sync exported issues back into tasks (REQ-007-3). |
| The ensemble skills and `trd-graph-cli` | External | The planning agent that produces the decomposition lives there, not here. |

## 7. Risks and Open Questions

### Risks

1. **The gate may fail, and this PRD should be prepared for that.** If one warm agent beats N cold ones on a real TRD, Phase B's premise is wrong at task granularity and possibly at every granularity. REQ-001-4 makes that outcome a legitimate stopping point rather than an inconvenience to be argued around — but it does mean substantial Phase B work could be built and not adopted.
2. **Export creates a loop risk.** `BeadsWatcher` synthesizes `task.create` from new beads. Exporting graph nodes into Beads without excluding them re-imports Foreman's own work as Foreman tasks. REQ-007-3 names this; it is the single most likely way to break production in this phase.
3. **Two execution models coexisting indefinitely.** REQ-009 is deliberately permissive about removal, which is the right call for safety and the wrong one for maintenance cost. The adoption period needs an owner, not just a mention.
4. **Branch strategy is the unsolved problem.** REQ-005 requires a decision but the options each have real costs: a branch per node fragments review, a shared branch serializes work and undercuts the parallelism the whole programme is for, and stacking is operationally complex.
5. **The benchmark is expensive.** Three runs of each path on a 30-task TRD is a lot of agent time and tokens, and it must be re-run whenever either path changes materially.
6. **Deleting aggregates touches the event codec.** REQ-011-2 keeps decode paths, but judging which historical streams could contain which events requires inspecting a real event store, not just the code.
7. **Cost telemetry depends on the adapter reporting it.** `PiAdapter` returns text and metadata; whether token counts are available at all is unverified, which is why REQ-014 is a Could.
8. **Success rate is hard to define.** REQ-001-1 asks for task-level success rate, but a task that "succeeded" and produced poor code is not a success. Any honest comparison needs a quality dimension the requirement does not currently specify.

### Open Questions

1. What is the pass threshold for REQ-001-4? It must be agreed before the benchmark runs, or the result will be rationalized after the fact.
2. Should export be per-project opt-in or per-graph? v1 assumes per-project configuration.
3. Should the Foreman-native workflow be a new manifest name, or a variant flag on the existing one? A new name is cleaner for REQ-009's coexistence.
4. Does quality assessment belong in the benchmark, and if so, who judges?

### Known out-of-scope gaps

- Removing Beads from the repository or from the ensemble tooling.
- Bidirectional sync between Foreman and any tracker.
- Migrating historical Beads issues into Foreman work graphs.
- Any change to `PRD-2026-0eac69b3`'s ingress or admission behaviour.

## 8. Self-Critique

- The strongest part of this PRD is REQ-001. Making the whole phase conditional on a measured result, with a pre-agreed threshold and a commitment to publish either way, is the discipline that the two preceding phases lack — and it is a deliberate correction to the fact that Phase B argues for OTP-native parallelism without evidence.
- The weakest part is REQ-005. Branch strategy across a graph is a genuinely hard problem that this PRD raises and does not solve, and it may be large enough to deserve its own document. If the answer turns out to be "one shared branch, serialized," that quietly negates much of Phase B.
- REQ-008 is nearly vacuous as written. "Nothing gets worse" is not a testable requirement so much as a statement of intent, and its two ACs are weak.
- Risk 8 identifies a real hole in REQ-001: a success-rate metric that ignores output quality can be gamed by a path that fails fast and marks things done. The benchmark design needs a quality dimension before it is run.
- The PRD assumes Phases A and B will both have shipped. If the programme stalls after Phase A — which is a plausible and even reasonable outcome, since Phase A delivers most of the visibility value — then most of this document is moot and only REQ-011 and REQ-012 remain worth doing.

## 9. Acceptance Criteria Summary

| Requirement | Priority | ACs | Theme |
|---|---|---:|---|
| REQ-001 | Must | 5 | Benchmark gate |
| REQ-002 | Should | 2 | Granularity sweep |
| REQ-003 | Must | 4 | Plan-then-graph workflow |
| REQ-004 | Must | 3 | Node execution guarantees |
| REQ-005 | Must | 3 | Branch and PR strategy |
| REQ-006 | Must | 4 | Export to Beads |
| REQ-007 | Must | 3 | Export is one-way |
| REQ-008 | Should | 2 | Beads unreduced |
| REQ-009 | Must | 3 | Deprecation discipline |
| REQ-010 | Should | 2 | Migration guidance |
| REQ-011 | Must | 4 | Dead aggregate verdicts |
| REQ-012 | Should | 2 | Architecture test |
| REQ-013 | Must | 2 | Reversibility |
| REQ-014 | Could | 2 | Cost telemetry |

Total: 14 requirements, 41 acceptance criteria.

## 10. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Problem clarity | 5 | The split between backlog and execution scheduler is stated precisely, and what each side keeps is grounded in the actual `TaskProvider` contract. |
| Requirement testability | 3 | REQ-001's threshold is undefined, REQ-008 is weak, and success rate lacks a quality dimension. This is the dimension to fix in refinement. |
| Scope discipline | 5 | No TRD parser, no bidirectional sync, no removal of Beads, no schedule-driven deprecation. |
| Evidence quality | 5 | The dead-aggregate inventory, the absent TRD parser, the `TaskProvider` contract, and the single-phase workflow were each verified against source. |
| Risk coverage | 4 | Eight risks. The export loop (Risk 2) and the branch strategy (Risk 4) are both named as likely failure points rather than glossed. |

**Overall score: 4.0 — PASS at the boundary.** Testability is the weak dimension and REQ-001's threshold must be agreed before the benchmark runs.

## Appendix A: Evidence Index

| Claim | Location |
|---|---|
| `TaskProvider` is a twelve-callback tracker contract including `create/2` | `lib/foreman_server/task_provider.ex` |
| Nothing emitted between phase start and end | `lib/foreman_server/workflow/run_executor.ex` |
| Reverse-sync synthesizes `task.create` from new beads | `lib/foreman_server/task_providers/beads_watcher.ex` |
| Orphan janitor decides on task status | `lib/foreman_server/task_providers/beads_orphan_janitor.ex` |
| No ready-set computation anywhere | tree-wide search of `packages/foreman_server/lib/` |
| One phase per TRD implementation | `priv/defaults/workflows/implement-trd-beads.yaml` |
| One-hour timeout, 48-task reference | `config/dev.exs` |
| No TRD parser in this repo | `packages/foreman_cli/cmd/foreman/main.go` — subcommands are project, task, run, workflow, init |
| Dead aggregates | `lib/foreman_server/aggregates/{tool_call,artifact_report,board_item_state_machine,planning_flow,scheduler,project_run_limit}.ex` |
| `Recovery` has no callers | `lib/foreman_server/recovery.ex` |
| Overwatch disconnected and dev-only | `lib/foreman_server/overwatch.ex`; `config/dev.exs` |

## Changelog

### 1.0.0 — 2026-08-15 — Initial PRD

Phase C of a three-phase programme, following `PRD-2026-aba4b79c` (telemetry) and `PRD-2026-d3051d4b` (work graph), all three building on `PRD-2026-0eac69b3` (MCP ingress and run-slot queue). Structured as a gate rather than a migration: the comparative benchmark in REQ-001 decides whether the preceding phase's central assumption holds, and a failing result is an accepted outcome that defers the rest of this document.
