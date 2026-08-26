---
document_id: PRD-2026-aba4b79c
label: prd-foreman-native-execution-telemetry
version: 1.0.0
status: Draft
date: 2026-08-15
scale_depth: STANDARD
total_requirements: 16
total_acceptance_criteria: 48
readiness_score: 4.3
---

# PRD: Foreman-Native Execution Telemetry (Phase A)

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 11 |
| Should | 4 |
| Could | 1 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 16/16 (100%) |
| Risk flags | 7 |
| Dependencies | 6 |
| Open ambiguity markers | 0 |
| TRD decisions required | 4 |

## 1. Executive Summary

Foreman cannot see inside a running phase. The complete event sequence it emits for a run is:

```
RunStarted → PhaseStarted → ……… silence ……… → PhaseCompleted → RunCompleted
```

For `implement-trd-beads` — one phase, one `pi` invocation, a one-hour timeout, dozens of units of work inside — that silence is the entire implementation of a TRD.

Beads is what fills it today. Not as a convenience: as the only intra-run feedback channel Foreman has. The agent shells out to `br` on every state change, and Foreman learns about progress by tailing someone else's SQLite database through `BeadsWatcher`. Any plan to reduce Foreman's dependence on Beads that does not first replace this channel removes visibility rather than relocating it.

This PRD builds the replacement, and does it in a way that helps immediately regardless of what happens to Beads:

1. **The agent reports in over MCP.** Structured step events, appended to the run's own event stream, attributed by a run-scoped credential injected into the worktree environment. This is the same feedback loop Beads provides, with the transport changed from "a database the agent writes and Foreman polls" to "a call into the orchestrator that owns the run."
2. **Raw agent output stops being swallowed.** `PiAdapter` currently accumulates the entire subprocess stdout and returns it once at exit. Streaming it makes a live tail possible and gives `StuckDetector` real activity signal instead of a fixed deadline.
3. **What Foreman already knows becomes visible.** PubSub carries the event instead of a content-free ping, the four debug LiveViews become a real authenticated operator surface, and an SSE endpoint plus a `run.watch` MCP tool serve non-browser clients.

Phase A deliberately changes no scheduling behaviour and adds no domain concepts to work submission. It is observation only, and it improves visibility for **existing Beads-driven runs** on day one, which is what makes it safe to ship before anything else.

## 2. Background and Evidence

### 2.1 Nothing is emitted during a phase

`Workflow.RunExecutor` dispatches exactly two lifecycle commands per phase — `phase.start` → `PhaseStarted` and `phase.complete` → `PhaseCompleted` (or `phase.fail` → `PhaseFailed`) — and between them blocks synchronously in `execute_agent/4` on `AgentRuntime.execute/3`. No event, no telemetry, no PubSub message is emitted in between.

The one exception is not progress: `RunExecutorLiveness.record/3` writes a deadline into an ETS table so `StuckDetector` can flag a run whose deadline has passed. `StuckDetector` defaults to a 15-minute threshold scanned every 60 seconds. It detects *absence*, not activity.

### 2.2 `PiAdapter` buffers the entire run

`receive_loop/4` accumulates port output as `acc <> data` until `{:exit_status, _}` and returns the whole blob once. `normalize_output/1` then strips terminal control codes from that final blob. Nothing incremental reaches any caller. `AgentRuntime.execute/3` wraps the call in `[:foreman, :agent_runtime, :execute, :start]` and `:stop` telemetry — duration and status, not content.

This is the physical reason a live tail is impossible today, and it is a small change to fix.

### 2.3 The vocabulary for all of this already exists, disconnected

This is the striking part. Foreman has already modelled everything this PRD needs, and none of it is wired:

- `Aggregates.Worker` handles `worker.record` with a sequenced event family: `WorkerStarted`, `WorkerHeartbeat`, `WorkerExited`, `WorkerCrashed`, `ToolCallFinished`, `AssistantMessage`, `WorkerStdout`, `WorkerStderr`. It is dispatched only by `Overwatch.Tracker.dispatch_lifecycle/3`, reached only from `Overwatch.WorkerProtocol.emit/2`, reached only from `Overwatch.LaunchWorker`. And `Overwatch.start_phase/2` — the sole production entry point into that subsystem — is never called by `RunExecutor` or anything else in `lib/`. Its only call sites are in `test/foreman_server/overwatch_test.exs`. Overwatch is additionally enabled only in `config/dev.exs`, so it does not start in production at all.
- `Aggregates.ToolCall` (`tool.request` / `tool.approve` / `tool.deny` / `tool.finish`) has zero dispatch sites.
- `Aggregates.ArtifactReport` (`phase.report.produce` / `phase.verdict`) has zero dispatch sites.
- `Aggregates.BoardItemStateMachine` — a kanban state machine, `backlog → in_progress → in_review → done`, with a `blocked` state — has zero dispatch sites.

The conclusion is not "Foreman lacks a telemetry model." It is "Foreman has a telemetry model nobody connected to the execution path." A TRD should treat reuse of these aggregates as the default and justify any new one.

### 2.4 Live push exists but carries nothing

`ProjectionStore.subscribe/0` is a plain `send/2` fan-out — the GenServer monitors subscriber pids and sends `{:projection_event, event}` with the full decoded event on every `apply_events` call. This is in-process only and is what `Workflow.Dispatcher` consumes.

Separately, `Phoenix.PubSub` **is** configured and started in `application.ex`, and `CommandRouter.broadcast_debug_updates/1` runs after every successful command append, broadcasting to topics `runs`, `runs:<run_id>`, `phases`, `phases:<phase_id>`, `workers`, `workers:<worker_id>`. But the payload is a bare `{:debug_state_changed, topic}` — no event content. The four LiveViews (`DebugDashboardLive`, `RunDebugLive`, `PhaseDebugLive`, `WorkerDebugLive`) subscribe, ignore the message body entirely, and re-fetch aggregate state, with a one-minute poll as a fallback. They are gated by `if Mix.env() == :dev` in the router.

There is no SSE, WebSocket, or chunked HTTP surface for run progress. `GET /api/runs/:id` is a snapshot read.

### 2.5 Final output is already durable

`RunExecutor` writes the agent's returned text to disk per phase via `ArtifactTemplate.write/4`, then records `sha256` and size via `ArtifactTemplate.describe/1`. This matters for scoping: the durable record of what an agent produced already exists as an artifact file. Streaming exists to serve *liveness*, not durability, which is what lets this PRD keep raw output out of the event store.

## 3. Personas

### 3.1 Operator watching a long run (primary)

Has a run that will take an hour. Wants to know it is progressing, roughly how far along it is, and what it is doing right now — without tailing a SQLite database or reading `pi` logs on the host.

### 3.2 Agentic client (primary)

Submitted work over MCP and wants to stream progress back to its own user. Needs a machine-readable event feed, not an HTML page.

### 3.3 The executing agent (new, and the important one)

Currently reports its state by shelling out to `br`. Needs a first-class way to tell the orchestrator what it is doing, scoped so it can only speak for its own run.

### 3.4 Foreman maintainer (secondary)

Needs this built out of the aggregates that already exist rather than a parallel telemetry stack, and needs the event store not to fill with subprocess noise.

## 4. Requirements

### 4a. Agent-to-Foreman Progress Reporting

### REQ-001: Must | High | Structured step reporting over MCP
The executing agent MUST be able to report structured progress to Foreman through MCP tools that append durable events to the run's stream.

- AC-001-1: Given an agent holding a valid run-scoped credential, when it calls `foreman_step_start` with a step label and optional parent step, then a durable event is appended attributing that step to the correct `run_id` and `phase_id`, and the run projection reflects it within the same call's response.
- AC-001-2: Given a started step, when the agent calls `foreman_step_complete` or `foreman_step_fail`, then the step's terminal state and, for failure, its reason are recorded durably.
- AC-001-3: Given an agent calls `foreman_step_note` with free text, when the note is accepted, then it is attached to the current step if one is open and to the phase otherwise.
- AC-001-4: Given a step report arrives for a run that has already reached a terminal state, when it is processed, then it is rejected with a structured error and no event is appended.
- AC-001-5: Given steps are reported, when they are read back, then they carry a monotonically increasing per-run sequence number so a consumer can detect gaps and order events without relying on wall-clock timestamps.

### REQ-002: Must | High | Run-scoped credentials
An agent MUST only be able to report progress for the run it is executing.

- AC-002-1: Given a run starts, when its execution environment is built, then `FOREMAN_MCP_URL` and a run-scoped token are injected alongside the existing `FOREMAN_RUN_ID`, `FOREMAN_WORKTREE`, and `FOREMAN_SOURCE_REVISION` variables.
- AC-002-2: Given a run-scoped token, when it is presented to any reporting tool, then the `run_id` is derived from the token and any `run_id` supplied in the arguments is ignored rather than trusted.
- AC-002-3: Given a run-scoped token for run A, when it is used to report against run B, then the call is refused and a `[:foreman_server, :telemetry, :scope_violation]` event is emitted.
- AC-002-4: Given a run reaches a terminal state, when its token is presented afterwards, then it is refused — tokens do not outlive their run.
- AC-002-5: Given tokens are minted, when they are logged or emitted in telemetry, then the token value never appears in either.

### REQ-003: Must | Medium | Reporting is optional and degrades cleanly
Runs whose agents report nothing MUST behave exactly as they do today.

- AC-003-1: Given a workflow whose agent makes no reporting calls, when it executes, then the run completes normally and its projection is byte-identical in every field that exists today.
- AC-003-2: Given an agent reports some steps and then stops reporting, when the phase completes normally, then any open steps are closed as `unknown` at phase completion rather than left dangling forever.
- AC-003-3: Given the MCP server is disabled or unreachable, when an agent attempts to report, then the run is unaffected — reporting failures never fail a run.

### REQ-004: Must | Medium | Reporting is rate-limited and bounded
A misbehaving agent MUST NOT be able to flood the event store.

- AC-004-1: Given an agent exceeds a configured step-report rate, when further reports arrive, then they are rejected with a structured throttle error and a telemetry event, and the run continues.
- AC-004-2: Given a step label or note exceeds a configured byte limit, when it is accepted, then it is truncated at that limit with an explicit truncation marker rather than rejected.
- AC-004-3: Given a run exceeds a configured total step count, when further steps are reported, then they are refused and the run is annotated once, so the cap is visible rather than silent.

### REQ-005: Should | Medium | Step reports refresh liveness
Progress reports SHOULD feed the existing stuck detection rather than sitting beside it.

- AC-005-1: Given a step report is accepted, when it is processed, then the run's liveness deadline is extended, so an agent that is demonstrably working is not flagged stuck.
- AC-005-2: Given a run reports no steps at all, when its deadline passes, then `StuckDetector` behaves exactly as it does today.

### 4b. Agent Output Streaming

### REQ-006: Must | High | Incremental agent output
The agent's subprocess output MUST be observable while the agent is running.

- AC-006-1: Given `PiAdapter` is executing, when the subprocess emits output, then each chunk is surfaced to a live channel as it arrives rather than only at exit.
- AC-006-2: Given streaming is active, when the phase completes, then the value returned to `RunExecutor` is byte-identical to what it receives today, so artifact writing and downstream behaviour are unchanged.
- AC-006-3: Given streamed output, when it is delivered, then terminal control codes are normalized the same way the final blob is normalized today.

### REQ-007: Must | High | Raw output is ephemeral; structured progress is durable
Streamed subprocess output MUST NOT be appended to the event store.

- AC-007-1: Given a run produces megabytes of subprocess output, when the run completes, then the event store contains no event carrying that raw output.
- AC-007-2: Given a consumer needs the full output after the fact, when it looks for it, then it finds the per-phase artifact `ArtifactTemplate.write/4` already writes, referenced by path, sha256, and size in the phase's completion record.
- AC-007-3: Given a live consumer attaches midway through a phase, when it subscribes, then it receives output from the point of attachment onward and is explicitly told it has joined mid-stream rather than being silently given a partial history.

### REQ-008: Could | Low | Bounded replay buffer
A late-attaching consumer COULD receive recent context rather than nothing.

- AC-008-1: Given a configured replay-buffer size, when a consumer attaches mid-phase, then it receives up to that many bytes of recent output before live output resumes.
- AC-008-2: Given the buffer is disabled, when a consumer attaches, then behaviour matches AC-007-3 exactly.

### 4c. Distribution and Surfaces

### REQ-009: Must | High | PubSub carries the event
Broadcasts MUST carry enough information to render without a re-fetch.

- AC-009-1: Given a command append broadcasts a change, when a subscriber receives it, then the message carries the event type and payload rather than a bare `{:debug_state_changed, topic}`.
- AC-009-2: Given existing subscribers, when the payload shape changes, then they continue to function — the change is additive and the old topic names are preserved.
- AC-009-3: Given a LiveView receives a broadcast, when it renders, then it does not re-fetch aggregate state for events whose payload is sufficient.

### REQ-010: Must | High | Server-sent events for run progress
A non-browser client MUST be able to stream a run's progress over HTTP.

- AC-010-1: Given `GET /api/runs/:id/events`, when a client connects, then it receives an SSE stream of that run's lifecycle events, step reports, and output chunks, bearer-authenticated on the same boundary as the rest of `/api`.
- AC-010-2: Given the run reaches a terminal state, when the stream is open, then a terminal event is sent and the stream is closed by the server.
- AC-010-3: Given a client disconnects, when it does, then its subscription is released and no process leaks.
- AC-010-4: Given a client requests a run that does not exist, when it connects, then it receives a 404 rather than an empty stream that never terminates.

### REQ-011: Must | Medium | `run.watch` MCP tool
Agentic clients MUST be able to follow a run through MCP rather than by polling.

- AC-011-1: Given `foreman_run_watch` is called with a run id, when the run produces events, then they are delivered to the client as they occur.
- AC-011-2: Given the run is already terminal when the tool is called, when it responds, then it returns the terminal state immediately rather than blocking.
- AC-011-3: Given the tool is invoked, when it streams, then it consumes the same channel as SSE — there is one progress source, not two.

### REQ-012: Should | Medium | Operator run view
Operators SHOULD have a real run view rather than a development-only debug page.

- AC-012-1: Given the run views, when they are served, then they are no longer gated behind `Mix.env() == :dev` and are authenticated on the same boundary as `/api`.
- AC-012-2: Given a run is executing, when an operator opens its view, then they see phases, current step, recent output, elapsed time, and the run's queue position if it is waiting.
- AC-012-3: Given the view is open, when events arrive, then it updates from the broadcast payload without polling.
- AC-012-4: Given a deployment does not want the view exposed, when the feature is disabled by config, then the routes are absent rather than merely unlinked.

### REQ-013: Should | Medium | Progress is visible for Beads-driven runs
This phase SHOULD deliver its value without any change to work submission, so it is useful before Phase B and independent of it.

- AC-013-1: Given an existing `implement-trd-beads` run whose agent has been taught to report steps, when it executes, then its progress is visible through every surface in this PRD with no change to task creation, approval, or dispatch.
- AC-013-2: Given the same run, when it also updates Beads as it does today, then both records exist and neither interferes with the other.

### 4d. Cross-Cutting

### REQ-014: Must | High | No sensitive content in logs or telemetry
Progress data MUST follow the same discipline as prompts and tokens.

- AC-014-1: Given step labels, notes, and output chunks, when telemetry is emitted for them, then metadata carries identifiers, counts, and sizes only — never the content.
- AC-014-2: Given any reporting call, when it is logged, then neither the credential nor the reported content appears in the log line.

### REQ-015: Must | Medium | Reuse the existing telemetry aggregates
New event families MUST be justified against what already exists.

- AC-015-1: Given the TRD is written, when it specifies where step and output events live, then it explicitly evaluates `Aggregates.Worker`'s existing event family and `Aggregates.ToolCall`, and states why each is reused or rejected.
- AC-015-2: Given `Overwatch` is evaluated, when the decision is recorded, then it states whether the subsystem is connected to `RunExecutor` or left dormant, and what happens to it either way — it does not remain silently disconnected without a decision.

### REQ-016: Should | Low | Progress appears in the work and task projections
A caller holding only a work or task id SHOULD see progress without resolving the run.

- AC-016-1: Given a work or task projection is read, when the underlying run has reported steps, then the projection carries the current step label and a completed/total count where a total is known.
- AC-016-2: Given no steps have been reported, when the projection is read, then these fields are absent rather than zero, so "not reporting" is distinguishable from "no progress."

## 5. Ambiguity Resolution Status

| Ambiguity | Resolution |
|---|---|
| Does raw agent output go into the event store? | No. Structured steps are durable; raw output is a live channel only, with the existing per-phase artifact as the durable record (REQ-007). |
| Do we revive Overwatch and the Worker aggregate? | Not decided here — but the TRD must decide explicitly rather than leaving it disconnected (REQ-015). |
| Is reporting mandatory? | No. Runs that report nothing behave exactly as today (REQ-003). |
| How does an agent prove which run it is? | A run-scoped token injected into the worktree environment; the `run_id` comes from the token, never from the arguments (REQ-002). |
| Does this phase change scheduling? | No. Phase A is observation only. |

## 6. Dependency Map

| Dependency | Kind | Notes |
|---|---|---|
| `PRD-2026-0eac69b3` MCP server | Internal, **hard** | The reporting tools and `run.watch` are MCP tools. Phase A cannot ship its primary requirement before that PRD's PR 4 lands. Everything in §4b and §4c can proceed independently. |
| `ForemanServer.Workflow.RunExecutor` | Internal | Injects the credential into the worktree environment and closes dangling steps at phase completion. |
| `ForemanServer.AgentRuntime.Adapters.PiAdapter` | Internal | `receive_loop/4` is the single change point for streaming. |
| `ForemanServer.CommandRouter` | Internal | `broadcast_debug_updates/1` is where the payload becomes meaningful. |
| `ForemanServer.RunExecutorLiveness` / `StuckDetector` | Internal | Step reports extend the liveness deadline. |
| The `pi` CLI and the ensemble skills | External | Agents must actually call the reporting tools. Foreman can offer the channel; adoption is a change in the skills, and is the real gating item for value delivery. |

## 7. Risks and Open Questions

### Risks

1. **The channel is worthless until the skills use it.** Foreman can ship every requirement here and see no improvement if `implement-trd-beads` keeps reporting only to `br`. The ensemble-side change is small but it is not in this repo, and it should be sequenced deliberately rather than assumed.
2. **Streaming volume.** An hour-long agent can emit a lot of output. REQ-007 keeps it out of the event store, but the live fan-out path still needs backpressure or a slow consumer will accumulate messages until something dies.
3. **Reviving Overwatch is a bigger decision than it looks.** It is a complete worker-launch protocol that assumes it owns process spawning. Reusing only its *event vocabulary* while leaving its launch machinery dormant may be cleaner than connecting it — but that is a real fork and REQ-015 exists to force the choice.
4. **Run-scoped tokens are a new secret in the worktree environment.** They are low-value and short-lived, but they are written into an environment an agent controls, and agents write files. Scope and lifetime need to be tight.
5. **`{:debug_state_changed, topic}` may have consumers outside this repo.** REQ-009-2 requires additive change for that reason, but the assumption should be checked rather than trusted.
6. **Step semantics can drift into a second task model.** Steps are ephemeral execution telemetry, not schedulable units. If they acquire dependencies, assignees, or priorities, this has quietly become Phase B done badly.
7. **Two progress sources.** For a transitional period a Beads-driven run reports to both `br` and Foreman. They can disagree. REQ-013-2 requires coexistence but not reconciliation, which is the honest scope.

### Open Questions

1. Should step reporting support explicit total counts up front (`foreman_step_plan`), so a consumer can render "12 of 48" rather than a running count? Deferred; REQ-016-1 permits a total where one is known.
2. Should output streaming be per-phase or per-run when phases run sequentially? Currently phases are sequential, so the distinction is presentational.
3. Does the operator view belong in this repo at all, or should Foreman expose only SSE and let a separate UI consume it?

### Known out-of-scope gaps

- Any change to work submission, admission, or scheduling — that is `PRD-2026-0eac69b3` and Phase B.
- Dependency graphs and parallel fan-out — Phase B.
- Retiring Beads — Phase C.
- Historical backfill of progress for runs that already completed.

## 8. Self-Critique

- The strongest part is that every claim about what is missing was verified against source, including the uncomfortable one: the telemetry model exists and nobody connected it. That reframes this from "build observability" to "connect observability," which is a much smaller and more defensible piece of work.
- The weakest part is REQ-013. It is written as though teaching the ensemble skills to report is a detail, and it is actually the gating item for whether any of this delivers value. It arguably belongs in the ensemble repo's backlog as a paired requirement, and this PRD cannot enforce that.
- REQ-015 is unusual — a requirement on the TRD rather than on the system. It is included because the failure mode it prevents (a fourth disconnected telemetry aggregate) is exactly what this codebase has done three times already.
- The PRD does not specify what a "step" is precisely enough. Whether a step maps to a bead, a TRD task, a tool call, or an arbitrary agent-chosen unit is left open, and different answers imply different projections. This should be pinned in refinement.
- REQ-008 is marked Could and probably should not survive refinement. A replay buffer is a real feature with real memory implications, and "you joined mid-stream" is an acceptable v1 answer.

## 9. Acceptance Criteria Summary

| Requirement | Priority | ACs | Theme |
|---|---|---:|---|
| REQ-001 | Must | 5 | Step reporting tools |
| REQ-002 | Must | 5 | Run-scoped credentials |
| REQ-003 | Must | 3 | Optional, degrades cleanly |
| REQ-004 | Must | 3 | Rate and size bounds |
| REQ-005 | Should | 2 | Liveness integration |
| REQ-006 | Must | 3 | Incremental output |
| REQ-007 | Must | 3 | Ephemeral raw, durable structured |
| REQ-008 | Could | 2 | Replay buffer |
| REQ-009 | Must | 3 | PubSub payloads |
| REQ-010 | Must | 4 | SSE endpoint |
| REQ-011 | Must | 3 | `run.watch` tool |
| REQ-012 | Should | 4 | Operator run view |
| REQ-013 | Should | 2 | Works for Beads runs |
| REQ-014 | Must | 2 | No sensitive content |
| REQ-015 | Must | 2 | Reuse existing aggregates |
| REQ-016 | Should | 2 | Progress in work/task projections |

Total: 16 requirements, 48 acceptance criteria.

## 10. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Problem clarity | 5 | The silence between `PhaseStarted` and `PhaseCompleted` is verified, and the one-phase shape of `implement-trd-beads` makes its cost concrete. |
| Requirement testability | 4 | Most ACs are mechanically checkable. Streaming backpressure (Risk 2) has no AC and should gain one in refinement. |
| Scope discipline | 5 | Observation only. No scheduling, no submission, no Beads changes. |
| Evidence quality | 5 | The dead-aggregate inventory, the buffering adapter, the content-free PubSub payload, and the dev-gated LiveViews were each verified against source. |
| Risk coverage | 4 | Seven risks with mitigations. The ensemble-adoption dependency is named but cannot be resolved from this repo. |

**Overall score: 4.3 — PASS.** Ready for TRD.

## Appendix A: Evidence Index

| Claim | Location |
|---|---|
| Only two events per phase, nothing between | `lib/foreman_server/workflow/run_executor.ex` — `emit_phase_start/3`, `emit_phase_complete/3`, `execute_agent/4` |
| Liveness is a deadline, not activity | `lib/foreman_server/run_executor_liveness.ex`; `lib/foreman_server/stuck_detector.ex` |
| `pi` output is buffered to a single blob | `lib/foreman_server/agent_runtime/adapters/pi_adapter.ex` — `receive_loop/4`, `normalize_output/1` |
| Worker event family exists | `lib/foreman_server/aggregates/worker.ex` |
| Overwatch never invoked in production | `lib/foreman_server/overwatch.ex` — `start_phase/2`; enabled only in `config/dev.exs` |
| `ToolCall`, `ArtifactReport`, `BoardItemStateMachine` have no dispatch sites | `lib/foreman_server/aggregates/{tool_call,artifact_report,board_item_state_machine}.ex` |
| Projection fan-out is plain `send/2` | `lib/foreman_server/projection_store.ex` — `subscribe/0` |
| PubSub payload is content-free | `lib/foreman_server/command_router.ex` — `broadcast_debug_updates/1` |
| LiveViews are dev-gated and re-fetch | `lib/foreman_server/debug_views.ex`; `lib/foreman_server_web/router.ex` |
| Per-phase artifact is already durable | `lib/foreman_server/workflow/run_executor.ex` — `ArtifactTemplate.write/4`, `describe/1` |
| Worktree environment injection point | `lib/foreman_server/workflow/run_executor.ex` — worktree env construction |
| One phase for an entire TRD | `priv/defaults/workflows/implement-trd-beads.yaml`; `config/dev.exs` one-hour timeout override |

## Changelog

### 1.0.0 — 2026-08-15 — Initial PRD

Phase A of a three-phase programme. Phase B (`PRD-2026-d3051d4b`) adds the dependency graph and native parallelism; Phase C (`PRD-2026-39d2f88f`) retires Beads as the execution driver behind a measured gate. Phase A is independently valuable and improves visibility for existing Beads-driven runs without changing submission or scheduling.
