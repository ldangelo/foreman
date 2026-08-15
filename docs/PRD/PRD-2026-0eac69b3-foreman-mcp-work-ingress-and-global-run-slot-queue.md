---
document_id: PRD-2026-0eac69b3
label: prd-foreman-mcp-work-ingress-and-global-run-slot-queue
version: 1.0.0
status: Draft
date: 2026-08-15
scale_depth: STANDARD
total_requirements: 22
total_acceptance_criteria: 78
readiness_score: 4.4
---

# PRD: Foreman MCP Work Ingress and Global Run-Slot Queue

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 16 |
| Should | 6 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 22/22 (100%) |
| Risk flags | 7 |
| Dependencies | 9 |
| Open ambiguity markers | 0 |
| TRD decisions required | 5 |

## 1. Executive Summary

Foreman today can only be driven through a Task lifecycle that was designed for end-user visibility into a Beads-backed issue tracker. An agentic client that simply wants to say *"run the `implement-trd` workflow against this prompt"* must instead create a task, approve it, and wait for a dispatcher to notice — and even then, **the prompt it supplied never reaches the agent**, because Foreman has no mechanism for caller-supplied prompt text.

This PRD adds a second, deliberately lean ingress that sits beside the existing Task path rather than replacing it:

1. **A `work.submit` command** that takes a workflow name and a prompt and mints a run directly — no task, no approval, no dispatcher round-trip.
2. **A first-class prompt channel** (`input.prompt`) that is frozen into the run's workflow snapshot at submit time and rendered into phase prompts and phase commands.
3. **A global run-slot limiter** — N concurrent runs (default 3), everything else durably queued and drained automatically as runs finish.
4. **An MCP server** exposing submit / observe / cancel plus workflow catalog management (list, get, validate, add, edit, remove).
5. **Pruning of the Task surface** that is provably dead, without touching the Beads reverse-sync path that is live and working.

The product invariant is strict, and it is the same one the earlier MCP PRD (`PRD-2026-e8d3f5f2`) set: MCP is a parallel ingress, not a second domain model. It dispatches through `CommandGateway`, it obeys the same auth boundary, and it never reaches into supervisor-owned command types.

## 2. Background and Evidence

### 2.1 There is no path today for a caller-supplied prompt

This is the finding that shapes the whole design, and it is not obvious from the outside.

- For `prompt`-type phases, `RunExecutor.read_phase_prompt/4` reads the phase's `prompt_path` — resolved by the Catalog from the manifest's `prompt:` filename — via `Catalog.read_prompt/1`. The body comes **exclusively** from an `.md` file on disk.
- That body is then substituted by `render_prompt_template/5` against a **closed, server-computed assigns map** built by `prompt_template_assigns/4`: `phase_id`, `run_id`, `task_id`, `working_directory`, `artifact_path`, `phase_index`, `phase_name`, `project_id`, `workflow_digest`, `workflow_name`, plus `plan_context` and the phase's own static YAML `context:` block. No entry in that map is caller-supplied free text.
- For `command`-type phases the picture is different and worth stating precisely, because it is easy to get wrong. `RunExecutor.execute_agent/4` takes the command verbatim from `phase_value(phase_spec, :command)` and **never** passes it through `render_prompt_template/5`. Command strings are instead rendered *earlier*, at approval time, by `CommandGateway.render_strict_fields/1` → `render_phase/2` → `render_command/2`, which freezes the rendered string into `workflow_snapshot`. That renderer is not general templating: it substitutes exactly two literal tokens, `{{implementation.trd_path_argument}}` and `{{implementation.source_revision}}`. Any other token in a `command:` string survives to the agent adapter unexpanded. Worse, `render_strict_fields/1` returns the snapshot untouched when the snapshot has no `implementation` block at all — so `plan.yaml`, whose phases are command-type and which has no implementation context, gets **no command rendering whatsoever**.
- `Workflow.PromptRenderer` is a cleaner, correct `{{key}}` renderer — and is called from nowhere in production. It is exercised only by its own test.
- The only free-text fields a caller supplies anywhere in the pipeline are `TaskCreated`'s `title` and `description`, and **no bundled prompt template references either one**.

Conclusion: "start workflow X with prompt Y" is not a thin wrapper over an existing capability. The prompt channel must be built.

### 2.2 "Three in parallel, queue the rest" does not exist and cannot be configured on

- The only live admission gate is `Aggregates.Project.reject_at_run_limit/1`, a hardcoded `@max_concurrent_runs 100` **per project**, with no configuration indirection and no cross-project accounting anywhere in the tree.
- `Aggregates.ProjectRunLimit` is a complete, well-formed event-sourced aggregate implementing exactly this concept — and the command types `run_limit.reserve` / `run_limit.release` are referenced nowhere outside the module and its own test. It is inert.
- `TaskProviders.ConcurrencyLimiter` is a correct per-project semaphore with a FIFO waiter queue — and is **never started**; it is absent from the `Application` supervision tree, and no `acquire/2` call site exists in production code. Its state is plain GenServer memory, so it would not survive a crash even if wired in.
- When the live cap *is* hit, the rejection is silently dropped. `Dispatcher.handle_task_dispatched/2` writes the reason to `put_in(state, [:pending, task_id], reason)`, and **nothing ever reads `state.pending`**. `RunLifecycleReconciler`'s 30-second sweep iterates `ProjectionStore.list_projects_with_active_runs/0`, which is populated exclusively from `ProjectRunReserved` events — and a run rejected at admission never produced one, so the reconciler never sees it. Recovery today is an operator running `foreman task retry` by hand.

### 2.3 One durable queue already exists, and it is the right pattern

`Aggregates.BeadsDbLease` is the model to generalize. Stream `beads_db_lease:<db_path>`, holder plus FIFO `Waiter` list, all in the event log:

- `lease.acquire` atomically either acquires or enqueues a waiter in a single command, which is what makes lost wakeups structurally impossible.
- `lease.release` emits a **single** `BeadsDbLeaseTransferred` event that releases the old holder and promotes the FIFO head in one atomic transition — no separate wake-up round trip.
- `Dispatcher.handle_lease_promoted/2` subscribes to that event and re-enters `RunAdmission.start/2` for the promoted run.
- `BootReconciliation.reconcile_lease_stream/1` re-derives live holders and waiters from the event log at boot and drops entries whose run is dead.

It is a 1-slot mutex per DB path. The requirement here is N global slots. The shape transfers directly.

### 2.4 Much of the Task complexity is already dead weight

- `task.block`, `task.close`, `task.update`, `task.annotate`, `task.add_dependency` are handled by the aggregate and have **zero production dispatch sites** — not via `dispatch_operator/2` (they are absent from `@allowed_operator_types`) and not via `dispatch_system/2`. Five of eleven commands are reachable only from unit tests.
- `TaskDependencyAdded` is recorded into `State.dependencies` and no code anywhere reads it to gate approval, dispatch, or admission. Dependency ordering is modeled but not enforced.
- `Commands.CreateTask`, `Commands.CloseTask`, and `Events.TaskClosed` are defined and referenced nowhere; `TaskClosed` is not even registered in `event_codec.ex`.
- `ProjectionStore.list_workflow_tasks/0` has no caller.

### 2.5 What Task genuinely does, and why we are not deleting it

Two responsibilities resist relocation, and both are real:

1. **Pre-run approval identity.** `run_id = Identity.run_id(task_id, approval_id)` — the run id is *derived from* the task id, so something must exist before a run can be named. `CommandGateway.enrich_operator_command/1` for `task.approve` is where the workflow manifest is resolved and `ImplementationContext` is frozen. That step must have a home.
2. **A retry-spanning anchor.** Each retry mints a new `run_id`, but `BeadsWatcher` dedupes new beads against `ProjectionStore.get_task(external_id:)` and `BeadsOrphanJanitor` decides whether an orphaned upstream issue is safe to auto-close based on task status. Both need an identity that outlives any single run.

Neither argues for putting the *agentic ingress* through that machinery. They argue for leaving the Beads path alone.

### 2.6 The existing MCP planning documents are stale

`PRD-2026-e8d3f5f2` / `TRD-2026-e8d3f5f2` propose a Foreman MCP server and remain unimplemented — a tree-wide case-insensitive grep for `mcp` finds no module, route, config key, or dependency. Their Bucket A inventory lists 5 operator command types; `CommandGateway.@allowed_operator_types` now holds 7 (`task.retry` and `run.cancel` were added, and the Go CLI already implements both). This PRD supersedes their scope for the work-submission and workflow-management surfaces and inherits their bucket policy for everything else.

### 2.7 Bearer auth is currently inert

`Plugs.BearerAuth` reads `Application.get_env(:foreman_server, :api_bearer_token)` and, when it is unset or empty, **passes the request through with no check**. No config file and no entry in `ForemanServer.ConfigProviders.Secrets` maps anything to that key — `EVENTSTORE_URL`, `DATABASE_URL`, `DATABASE_PASSWORD`, `SECRET_KEY_BASE`, and `SIGNING_SALT` are wired; the API token is not. Today, in every environment including prod, the API is effectively unauthenticated. An MCP ingress makes that materially worse and cannot ship on top of it.

## 3. Personas

### 3.1 Agentic client (primary)

Runs Claude Code, Cline, or a custom MCP client. Wants one call — workflow name plus prompt — and a handle it can poll or watch. Does not want to know that Foreman has tasks, approvals, or a dispatcher.

### 3.2 Workflow author (primary)

Iterates on workflow manifests and prompt bodies. Wants to list what is installed, validate a change before it goes live, and add or edit a workflow without shelling into the host and hand-editing `~/.foreman/workflows`.

### 3.3 Foreman operator (secondary)

Needs the queue to be legible — what is running, what is waiting, in what order — and needs capacity to be a configuration value rather than a compiled-in constant. Needs the ingress authenticated.

## 4. Requirements

### 4a. Work Submission Ingress

### REQ-001: Must | High | `work.submit` operator command
Foreman MUST accept a single operator command `work.submit` carrying `project_id`, `workflow` (a manifest name), and `prompt` (free text), which mints a run without creating a Task, an approval, or a dispatch hop.

- AC-001-1: Given a valid `work.submit` with an installed workflow name, when the command is dispatched through `CommandGateway.dispatch_operator/2`, then a `WorkSubmitted` event is appended to stream `work:<work_id>` carrying the resolved `workflow_snapshot`, the verbatim `prompt`, and a derived `run_id`, and no `TaskCreated`/`TaskApproved`/`TaskDispatched` event is emitted anywhere in the store.
- AC-001-2: Given `work.submit` names a workflow that is not in the Catalog, when the command is validated, then it is rejected with `{:error, {:workflow_load_failed, name, reason}}` before any event is appended, and the reason carries the Interpreter's human-readable message.
- AC-001-3: Given `work.submit` omits `prompt` or supplies a non-binary/blank value, when the command is validated, then it is rejected with `{:error, {:invalid_envelope, :missing_prompt}}` and no event is appended.
- AC-001-4: Given two `work.submit` commands with the same `command_id`, when both are dispatched, then exactly one `WorkSubmitted` event exists and the second returns the first's `work_id` and `run_id` unchanged.
- AC-001-5: Given `work.submit` names a project that does not exist or is archived, when the command is validated, then it is rejected with `{:error, {:project_not_found, id}}` or `{:error, {:project_archived, id}}` respectively.

### REQ-002: Must | High | `work.submit` is added to the operator allow-list
`work.submit` MUST be reachable through the public operator path and MUST NOT require `dispatch_system/2`.

- AC-002-1: Given `work.submit` is dispatched via `CommandGateway.dispatch_operator/2`, when the type is checked against `@allowed_operator_types`, then it is permitted, and `@allowed_operator_types` contains exactly the 8 types `project.register`, `project.update`, `project.archive`, `task.create`, `task.approve`, `task.retry`, `run.cancel`, `work.submit`.
- AC-002-2: Given `POST /api/commands` receives `type: "work.submit"`, when `CommandController` checks its own `@allowed_types`, then the list matches `CommandGateway.@allowed_operator_types` exactly, and a test fails the build if the two lists diverge.
- AC-002-3: Given `work.submit` succeeds via HTTP, when the controller serializes the result, then the response body carries `work_id`, `run_id`, and `admission` (`"running"` or `"queued"`).

### REQ-003: Must | High | Runs carry their originating surface
A run MUST record whether it originated from a Task or from a WorkRequest, so downstream lifecycle hooks address the correct aggregate.

- AC-003-1: Given a run started from `work.submit`, when `RunStarted` is appended, then its payload carries `source: "work_request"` and `task_id` set to the `work_id`.
- AC-003-2: Given a run started from the Task path, when `RunStarted` is appended, then its payload carries `source: "task"` and existing consumers observe no change in any other field.
- AC-003-3: Given a WorkRequest-sourced run reaches a terminal phase outcome, when `RunExecutor` dispatches the lifecycle command, then it dispatches `work.execution_complete` / `work.execution_fail` against `work:<work_id>` and dispatches **no** `task.execution_complete` / `task.execution_fail`.
- AC-003-4: Given a WorkRequest-sourced run, when `RunExecutor` reaches its claim/complete/fail provider hooks, then no `TaskProvider` callback is invoked, because a WorkRequest has no upstream issue.

### REQ-004: Must | Medium | Work status is observable end to end
A submitter MUST be able to retrieve the state of a submission without knowing the run id.

- AC-004-1: Given a `work_id`, when the caller reads the work projection, then it returns `status` (`queued`, `running`, `succeeded`, `failed`, `cancelled`), `workflow`, `prompt`, `run_id`, `project_id`, `submitted_at`, and, when queued, `queue_position`.
- AC-004-2: Given a submission is waiting on a run slot, when the caller reads it, then `status` is `queued` and `queue_position` is its 1-based index in the durable FIFO waiter list.
- AC-004-3: Given a submission's run has terminated, when the caller reads it, then `status` reflects the terminal outcome and carries the run's failure reason when it failed.

### REQ-005: Should | Medium | Work cancellation
A submitter SHOULD be able to cancel a submission whether it is queued or running.

- AC-005-1: Given a queued submission, when `work.cancel` is dispatched, then its waiter entry is removed from the run-slot queue, its status becomes `cancelled`, and no run is ever started for it.
- AC-005-2: Given a running submission, when `work.cancel` is dispatched, then it delegates to the existing `run.cancel` path for the bound run and the work status becomes `cancelled` once the run reaches its terminal state.
- AC-005-3: Given an already-terminal submission, when `work.cancel` is dispatched, then it is an idempotent no-op returning the existing terminal status rather than an error.

### 4b. Caller-Supplied Prompt Channel

### REQ-006: Must | High | `input.prompt` is frozen into the workflow snapshot
The caller-supplied prompt MUST be captured into the run's frozen `workflow_snapshot` at submit time and MUST NOT be re-read from anywhere at execution time.

- AC-006-1: Given a `work.submit` with a prompt, when `WorkSubmitted` is appended, then `workflow_snapshot["input"]["prompt"]` holds the prompt verbatim, byte for byte, including newlines.
- AC-006-2: Given a run is replayed from the event store, when `RunExecutor` rebuilds its context, then the prompt it uses is the one in the snapshot, and no Catalog, projection, or config read can change it.
- AC-006-3: Given a Task-sourced run with no `input` block, when `RunExecutor` builds its assigns, then `{{input.prompt}}` resolves to the empty string rather than raising or leaving the token unexpanded.

### REQ-007: Must | High | Prompt is rendered into prompt-type phases
`{{input.prompt}}` MUST resolve in phase prompt bodies.

- AC-007-1: Given a phase prompt body containing `{{input.prompt}}`, when the phase executes, then the rendered body contains the submitted prompt at that position.
- AC-007-2: Given a prompt body containing an unknown token such as `{{input.nonsense}}`, when the phase executes, then the token is left intact rather than silently emptied, preserving the current `render_prompt_template/5` contract.
- AC-007-3: Given a submitted prompt that itself contains the literal text `{{run_id}}`, when the phase renders, then that text is **not** recursively expanded — substitution is single-pass over the template, and caller text is inert.

### REQ-008: Must | High | Prompt is rendered into command-type phases at snapshot-freeze time
The existing strict command renderer MUST learn the `input.*` fields, and MUST run for snapshots that have an `input` block even when they have no `implementation` block.

- AC-008-1: Given a manifest phase declaring `command: "/skill:foo {{input.prompt_argument}}"`, when the submission's snapshot is frozen, then the phase's `command` in the emitted event already has the placeholder expanded, and `RunExecutor` requires no run-time rendering to produce the correct invocation.
- AC-008-2: Given `input.prompt_argument`, when it is built, then it is the prompt JSON-quoted for safe single-argument use, mirroring how `implementation.trd_path_argument` is already derived.
- AC-008-3: Given an existing `implement-trd` or `implement-trd-beads` manifest whose `command:` contains `{{implementation.trd_path_argument}}` or `{{implementation.source_revision}}`, when a task is approved after this change, then the frozen command string is byte-identical to the one produced today — verified against a pinned fixture.
- AC-008-4: Given a command-type phase and a prompt containing shell metacharacters, when the argv is built, then the metacharacters are carried as inert data within a single argument and no additional shell word is created.
- AC-008-5: Given a snapshot with an `input` block and no `implementation` block, when strict rendering runs, then it renders the `input.*` tokens rather than returning the snapshot untouched — closing the existing gap where a manifest such as `plan.yaml` receives no command rendering at all. Tokens in neither the `implementation.*` nor the `input.*` allow-list are left intact, because the renderer is a closed allow-list by design and not general templating.

### REQ-009: Should | Medium | Prompt appears in the default workflow templates
The bundled workflow prompts SHOULD consume the new channel so that submitting a prompt has a visible effect without authoring a custom manifest.

- AC-009-1: Given the bundled `discover.md`, `implement.md`, and `verify.md` prompts, when they are updated, then each contains an `{{input.prompt}}` section guarded so that an empty prompt renders no stray heading.
- AC-009-2: Given a Task-sourced run against an updated bundled prompt, when it executes, then its rendered prompt is byte-identical to the pre-change output, so the Beads path is untouched.

### 4c. Global Run-Slot Admission and Durable Queue

### REQ-010: Must | High | Global concurrent-run capacity
Foreman MUST enforce a single global ceiling on concurrently executing runs across all projects.

- AC-010-1: Given capacity 3 and three runs holding slots, when a fourth run requests admission, then it is not started and is durably recorded as a waiter.
- AC-010-2: Given capacity is read from `config :foreman_server, :max_concurrent_runs`, when the key is absent, then the effective capacity is 3.
- AC-010-3: Given the capacity value, when a slot decision is made, then the value used is carried on the acquire command and recorded on the emitted event, so replay of the stream reproduces the same decisions after the configured value changes.
- AC-010-4: Given a run already holds a slot, when the same `run_id` requests admission again, then the command is an idempotent no-op and capacity accounting is unchanged.

### REQ-011: Must | High | Waiters are durable and FIFO
Queued work MUST survive a crash of any process and MUST be promoted in submission order.

- AC-011-1: Given three queued waiters, when a slot is released, then exactly the FIFO head is promoted, in a single event that both releases the departing holder and installs the promoted one.
- AC-011-2: Given the server is killed with waiters queued, when it restarts, then the waiter list is re-derived from the event stream with order intact and no waiter is lost.
- AC-011-3: Given a waiter's run has since terminated or its work was cancelled, when boot reconciliation runs, then that waiter is removed and the next live waiter is promoted.
- AC-011-4: Given a slot holder whose run no longer exists or is terminal, when boot reconciliation runs, then the slot is released and a waiter is promoted in its place.

### REQ-012: Must | High | The queue drains automatically
Slot release MUST trigger admission of the promoted waiter without operator action.

- AC-012-1: Given a run terminates for any reason (`RunCompleted`, `RunFailed`, `RunCancelled`, `RunFlaggedStuck`, `RunBlocked`), when the terminal event is observed, then its slot is released.
- AC-012-2: Given a slot release promotes a waiter, when the promotion event is broadcast, then the dispatcher re-enters admission for the promoted run and starts its executor, with no polling interval involved.
- AC-012-3: Given the promotion path fails transiently, when the periodic reconciler next sweeps, then it detects the stalled promotion and retries it, so a dropped broadcast cannot strand the queue.
- AC-012-4: Given a run is admitted, when it is started, then no admission rejection is ever written to a location that is not subsequently read — the write-only `Dispatcher.pending` map is removed.

### REQ-013: Must | High | Ordering with the Beads-DB lease is deadlock-free
The global slot and the existing per-database lease MUST compose without a run holding one while indefinitely waiting for the other.

- AC-013-1: Given admission is requested, when the gates are evaluated, then the global slot is acquired first and the Beads-DB lease second.
- AC-013-2: Given a run acquires a global slot and is then queued on a Beads-DB lease, when the lease returns `:queued`, then the run **releases its global slot** before waiting, so a blocked run never consumes capacity.
- AC-013-3: Given a Beads-DB lease transfer promotes a run, when admission is re-entered, then it re-acquires a global slot from the top, and if none is free it becomes a slot waiter.
- AC-013-4: Given capacity 3 and four runs contending on the same Beads database, when the system settles, then exactly one run executes, no run holds a global slot while lease-blocked, and the remaining capacity is available to runs on other databases.

### REQ-014: Should | Medium | Queue observability
Operators SHOULD be able to see the queue without reading the event store.

- AC-014-1: Given the queue is queried, when it returns, then it reports `capacity`, the list of running runs with their work or task ids, and the ordered list of waiters.
- AC-014-2: Given a slot is acquired, queued, released, or transferred, when the event is emitted, then a corresponding `[:foreman_server, :run_slots, :*]` telemetry event is emitted with the run id and the resulting depth.

### REQ-015: Should | Low | Per-project limit becomes configurable
The existing per-project reservation SHOULD stop being a compiled-in constant.

- AC-015-1: Given `config :foreman_server, :max_concurrent_runs_per_project`, when it is set, then `Aggregates.Project` honours it; when absent, the effective value remains 100 so existing behaviour is unchanged.
- AC-015-2: Given the global cap is lower than the per-project cap, when both are evaluated, then the global cap binds first and the per-project reservation is a no-op in practice.

### 4d. MCP Server

### REQ-016: Must | High | MCP server exposing work submission and observation
Foreman MUST expose an MCP server whose tools cover submission, observation, and cancellation.

- AC-016-1: Given an MCP client completes `initialize` and calls `tools/list`, when the response returns, then it includes at minimum `foreman_work_submit`, `foreman_work_get`, `foreman_work_cancel`, `foreman_run_get`, `foreman_queue_status`, `foreman_project_list`, and `foreman_project_get`, each with a JSON Schema for its arguments.
- AC-016-2: Given `foreman_work_submit` is called with `workflow` and `prompt`, when it succeeds, then it returns `work_id`, `run_id`, and `admission`, and the underlying dispatch went through `CommandGateway.dispatch_operator/2` rather than any private path.
- AC-016-3: Given a tool call fails a domain validation, when the error is returned, then it is an MCP tool error carrying the gateway's structured reason, and it is never a transport-level JSON-RPC error.
- AC-016-4: Given `foreman_queue_status` is called, when it returns, then it reports capacity, running runs, and ordered waiters as structured content.
- AC-016-5: Given the MCP server is asked to dispatch any command type outside the operator allow-list, when the request is processed, then it is refused by policy before reaching `CommandGateway`, and no `dispatch_system/2` call is reachable from any MCP tool.

### REQ-017: Must | High | MCP transports
The server MUST support both a local and a hosted transport.

- AC-017-1: Given a client connects over stdio, when it completes `initialize`, then the full tool set is available and the process speaks JSON-RPC 2.0 framing on stdin/stdout with no diagnostic output on stdout.
- AC-017-2: Given a client connects over Streamable HTTP at the configured mount path, when it completes `initialize`, then the same tool set is available and the session is bearer-authenticated.
- AC-017-3: Given the stdio transport, when it starts, then it authenticates with the same verifier as HTTP and refuses to serve if the configured token is absent, unless `allow_insecure_local: true` is explicitly set.

### REQ-018: Must | High | MCP is authenticated and the bearer token is actually wired
MCP MUST NOT ship on top of the current inert auth.

- AC-018-1: Given `ForemanServer.ConfigProviders.Secrets`, when it is updated, then `FOREMAN_API_TOKEN` maps to `:api_bearer_token` alongside the existing secret mappings.
- AC-018-2: Given `:api_bearer_token` is unset, when the MCP server starts, then it refuses to start and logs a fatal configuration error naming the missing key — the `/api` pipeline's existing permissive behaviour is unchanged, but MCP fails closed.
- AC-018-3: Given a request with an absent, malformed, or wrong bearer token, when it reaches any MCP tool, then it is rejected before dispatch and neither the token nor the tool arguments appear in any log line or telemetry metadata.

### 4e. Workflow Catalog Management

### REQ-019: Must | High | Workflow read and validate tools
MCP MUST expose read-only catalog inspection and a dry-run validator.

- AC-019-1: Given `foreman_workflow_list`, when called, then it returns every loaded manifest with `name`, `description`, `digest`, `phase_count`, and `manifest_path`.
- AC-019-2: Given `foreman_workflow_get` with a name, when called, then it returns the resolved workflow including its phase list and the body of each referenced prompt file.
- AC-019-3: Given `foreman_workflow_validate` with a candidate manifest body, when it is checked, then it is parsed by the same `Interpreter.load/1` used at load time and returns either `valid: true` or the Interpreter's verbatim error message, **without writing anything to the catalog root**.

### REQ-020: Must | Medium | Workflow write tools are safe and gated
MCP SHOULD be able to add and edit workflows, but writes MUST be default-deny and MUST NOT be able to install an unparseable manifest.

- AC-020-1: Given `config :foreman_server, :mcp, allow_workflow_writes:` is absent or false, when a write tool is called, then it is refused by policy and the tool is not advertised in `tools/list`.
- AC-020-2: Given writes are enabled and a candidate manifest is submitted, when it is written, then it is validated first, written to a temporary file inside the catalog root, and moved into place by atomic rename — a failed validation leaves the catalog byte-identical.
- AC-020-3: Given a manifest whose `name:` does not match the requested filename stem, when the write is attempted, then it is rejected, because `Approval`/submit resolution keys on filename stem and a mismatch would be silently unreachable.
- AC-020-4: Given a requested filename containing a path separator or a `..` segment, when the write is attempted, then it is rejected before any filesystem call.
- AC-020-5: Given a workflow is written, when the Catalog's next poll runs, then the new manifest is loaded within the configured poll interval with no restart, and the tool response reports whether the reload has been observed.
- AC-020-6: Given `foreman_workflow_delete` removes a manifest, when a run is already executing against it, then that run is unaffected, because its snapshot was frozen at submit time.

### REQ-021: Should | Medium | Manifests are written through a canonical serializer
Because the manifest parser is a hand-rolled indentation-sensitive subset of YAML rather than a real YAML library, writes MUST be emitted in the exact subset it accepts.

- AC-021-1: Given any manifest written by an MCP tool, when it is emitted, then it is produced by a canonical serializer that only generates constructs the Interpreter parses: top-level scalars, a `phases:` list at indent 0, phase entries at indent 2, phase properties at indent 4, and single-level nested maps at indent 6.
- AC-021-2: Given a caller submits a manifest as structured JSON rather than raw text, when it is serialized and re-parsed, then the round trip is lossless for every field the Interpreter recognises — verified by a property test over generated manifests.
- AC-021-3: Given a caller submits raw manifest text using a YAML feature outside the supported subset (block scalars, anchors, flow sequences, multi-level nesting), when it is validated, then it is rejected with a message naming the unsupported construct rather than being silently misparsed.

### 4f. Task Surface Pruning

### REQ-022: Should | Low | Remove provably dead Task command handlers
The Task aggregate SHOULD shed command handlers with no production dispatch site.

- AC-022-1: Given the Task aggregate, when the dead handlers are removed, then `task.block`, `task.close`, `task.update`, `task.annotate`, and `task.add_dependency` no longer have `handle_command/2` clauses and dispatching them returns an unhandled-command error.
- AC-022-2: Given historical event streams, when they are replayed, then `apply_event/2` clauses and `event_codec.ex` entries for `TaskUpdated`, `TaskAnnotated`, and `TaskDependencyAdded` are **retained**, so no stream becomes undecodable — only the write path is removed.
- AC-022-3: Given `Commands.CreateTask`, `Commands.CloseTask`, and `Events.TaskClosed`, when they are deleted, then a tree-wide grep confirms zero remaining references and the build is clean.
- AC-022-4: Given the pruning is complete, when the full test suite runs, then every test that exercised a removed command has been deleted rather than skipped, and the Beads reverse-sync tests are untouched and passing.

## 5. Ambiguity Resolution Status

| Ambiguity | Resolution |
|---|---|
| Should Tasks be deleted outright? | No. A parallel lean `work.submit` path is added; the Beads/Task path is untouched. Dead handlers are pruned (REQ-022) but the aggregate remains, because `run_id` derivation and Beads dedupe both need a retry-spanning pre-run identity (§2.5). |
| How does the prompt reach the agent? | A first-class `input.prompt` frozen into `workflow_snapshot` at submit time, rendered into both prompt-type and command-type phases (REQ-006–REQ-008). |
| Is the limit global or per project? | Global, configurable, default 3 (REQ-010). The per-project reservation stays as an inner gate and merely becomes configurable (REQ-015). |
| What happens when both the slot and the Beads lease are contended? | Slot outer, lease inner, and a lease-queued run releases its slot (REQ-013). |
| Does MCP get a new command vocabulary? | No. `work.submit`, `work.cancel` are ordinary operator commands on the existing allow-list; MCP is ingress only (REQ-002, REQ-016). |

## 6. Dependency Map

| Dependency | Kind | Notes |
|---|---|---|
| `ForemanServer.CommandGateway` | Internal | `work.submit` / `work.cancel` join `@allowed_operator_types`; validation and enrichment follow the existing `task.approve` shape. |
| `ForemanServer.Workflow.Catalog` | Internal | Resolves the workflow name at submit time; backs every workflow management tool; its 2-second poll is the reload mechanism for writes. |
| `ForemanServer.Workflow.Interpreter` | Internal | Sole validator for `foreman_workflow_validate` and every write. |
| `ForemanServer.RunAdmission` | Internal | Gains the global slot gate ahead of the existing Beads-lease gate. |
| `ForemanServer.Aggregates.BeadsDbLease` | Internal | Template for the new `RunSlots` aggregate; its ordering relationship is specified by REQ-013. |
| `ForemanServer.Workflow.Dispatcher` | Internal | Gains a `WorkSubmitted` clause and a `RunSlotTransferred` clause mirroring `handle_lease_promoted/2`. |
| `ForemanServer.Workflow.RunExecutor` | Internal | Branches lifecycle dispatch on run source; gains prompt assigns and command-phase rendering. |
| `ForemanServer.ConfigProviders.Secrets` | Internal | Must gain the `:api_bearer_token` mapping before MCP can ship (REQ-018). |
| An Elixir MCP protocol implementation | External | `anubis_mcp` (the maintained successor to `hermes_mcp`) is the candidate; a hand-rolled JSON-RPC 2.0 module is the fallback. Decided in the TRD. |

## 7. Risks and Open Questions

### Risks

1. **Command-phase rendering touches a path that already freezes strings into events.** The strict renderer runs at approval time and its output is immutable once appended, so a defect ships into history rather than into a retryable execution. AC-008-3 pins the current frozen output with a fixture before the change lands, and AC-008-5 makes the widened trigger condition explicit rather than incidental.
2. **The manifest parser is not YAML.** Anything written by MCP must stay inside a narrow hand-rolled subset. REQ-021 makes the serializer the only writer; a naive `YAML.encode` would produce files the Interpreter silently misparses.
3. **A single global slot stream serializes all admission.** At capacity 3 this is a non-issue, but the stream is a throughput ceiling if capacity is later raised substantially. Documented, not solved.
4. **Prompt text is persisted in the event store forever.** Submitted prompts may contain sensitive content and are immutable once appended. Redaction policy is out of scope for v1 and is called out as an open question.
5. **The queue changes failure semantics.** Work that used to be silently dropped at the cap will now sit in a queue indefinitely if the drain path breaks. AC-012-3 requires the reconciler backstop precisely because the broadcast path is not sufficient on its own.
6. **Enabling real bearer auth will break existing unauthenticated callers.** The Go CLI already sends `FOREMAN_API_TOKEN` when set; deployments that never set it will start getting 401s the moment the token is configured. Sequencing is a rollout concern.
7. **Two ingress paths mean two ways to reach the same executor.** Divergence is a maintenance risk. Mitigated by both paths converging at `RunAdmission.start/2` with an identical payload shape.

### Open Questions

1. Should submitted prompts be redacted or truncated in telemetry and log lines beyond simply not being logged? Deferred to v2.
2. Should `work.submit` support a `wait` mode that blocks until terminal, or is polling plus `run.watch` sufficient? v1 assumes polling.
3. Should the MCP server expose the Bucket B recovery commands from `PRD-2026-e8d3f5f2` at all, or should that surface stay CLI-only? v1 exposes none.

### Known out-of-scope gaps (not blocking v1)

- Priority or fairness within the waiter queue — v1 is strict FIFO.
- Per-project or per-client quotas layered on the global cap.
- Migrating the Beads/Task path onto `work.submit`.
- A `foreman work` Go CLI subcommand — MCP and HTTP are the v1 surfaces.

## 8. Self-Critique

- The strongest part of this PRD is that its central claims are grounded in specific code paths rather than assumption: the absent prompt channel, the write-only `pending` map, and the never-started `ConcurrencyLimiter` were each verified against source.
- The weakest part is REQ-009. Editing bundled prompt templates to consume `{{input.prompt}}` while guaranteeing byte-identical output for Task-sourced runs (AC-009-2) is fussier than its Should priority suggests, and it may be worth deferring entirely.
- REQ-013 is the requirement most likely to be wrong in practice. The slot-then-lease-with-release ordering is sound on paper, but the interleaving of two independent event-sourced gates under concurrent load deserves an explicit property test rather than example-based tests.
- REQ-022 is the least valuable requirement per unit of risk. It is included because dead command handlers actively mislead the next reader, but it could be dropped from v1 without affecting any other requirement.
- The PRD does not specify what happens when capacity is *lowered* below the number of currently-held slots. The intended behaviour is that existing holders run to completion and no new admission occurs until the count falls below the new capacity; this should be stated as an AC in refinement.

## 9. Acceptance Criteria Summary

| Requirement | Priority | ACs | Theme |
|---|---|---:|---|
| REQ-001 | Must | 5 | `work.submit` command |
| REQ-002 | Must | 3 | Operator allow-list |
| REQ-003 | Must | 4 | Run source discrimination |
| REQ-004 | Must | 3 | Work status projection |
| REQ-005 | Should | 3 | Cancellation |
| REQ-006 | Must | 3 | Prompt frozen in snapshot |
| REQ-007 | Must | 3 | Prompt-phase rendering |
| REQ-008 | Must | 5 | Command-phase rendering |
| REQ-009 | Should | 2 | Bundled template updates |
| REQ-010 | Must | 4 | Global capacity |
| REQ-011 | Must | 4 | Durable FIFO waiters |
| REQ-012 | Must | 4 | Automatic drain |
| REQ-013 | Must | 4 | Slot/lease composition |
| REQ-014 | Should | 2 | Queue observability |
| REQ-015 | Should | 2 | Per-project limit config |
| REQ-016 | Must | 5 | MCP tool surface |
| REQ-017 | Must | 3 | MCP transports |
| REQ-018 | Must | 3 | Auth wiring |
| REQ-019 | Must | 3 | Workflow read/validate |
| REQ-020 | Must | 6 | Workflow writes |
| REQ-021 | Should | 3 | Canonical serializer |
| REQ-022 | Should | 4 | Task pruning |

Total: 22 requirements, 78 acceptance criteria.

## 10. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Problem clarity | 5 | The blocking constraint — no caller-supplied prompt channel — is identified with file-level evidence rather than inferred. |
| Requirement testability | 4 | Every AC is Given/When/Then and mechanically checkable. REQ-013's concurrency ACs need a property test, not examples, which is a design burden pushed to the TRD. |
| Scope discipline | 5 | Explicitly parallel to the Task path; the Beads integration is untouched; out-of-scope gaps enumerated. |
| Evidence quality | 5 | Claims about dead code, the inert limiter, the write-only pending map, and the auth gap were each verified against source. |
| Risk coverage | 4 | Seven risks with mitigations. The event-store prompt-retention question is acknowledged but deferred rather than answered. |

**Overall score: 4.4 — PASS.** Ready for TRD.

## Appendix A: Evidence Index

| Claim | Location |
|---|---|
| Prompt bodies come only from disk | `lib/foreman_server/workflow/run_executor.ex` — `read_phase_prompt/4` |
| Assigns map is closed and server-computed | `lib/foreman_server/workflow/run_executor.ex` — `prompt_template_assigns/4` |
| Command phases are not rendered at run time | `lib/foreman_server/workflow/run_executor.ex` — `execute_agent/4` |
| Command phases are rendered at approval time, two literal tokens only | `lib/foreman_server/command_gateway.ex` — `render_strict_fields/1`, `render_phase/2`, `render_command/2` |
| Strict rendering is skipped entirely with no `implementation` block | `lib/foreman_server/command_gateway.ex` — `render_strict_fields/1` nil branch |
| `PromptRenderer` has no production caller | `lib/foreman_server/workflow/prompt_renderer.ex` |
| Live cap is per-project and hardcoded | `lib/foreman_server/aggregates/project.ex` — `@max_concurrent_runs`, `reject_at_run_limit/1` |
| `ProjectRunLimit` is never dispatched | `lib/foreman_server/aggregates/project_run_limit.ex` |
| `ConcurrencyLimiter` is never started | `lib/foreman_server/task_providers/concurrency_limiter.ex`; absent from `lib/foreman_server/application.ex` |
| Rejections are dropped | `lib/foreman_server/workflow/dispatcher.ex` — `handle_task_dispatched/2` `pending` write |
| Durable lease + FIFO waiters + atomic transfer | `lib/foreman_server/aggregates/beads_db_lease.ex` |
| Lease promotion drain | `lib/foreman_server/workflow/dispatcher.ex` — `handle_lease_promoted/2` |
| Lease boot reconciliation | `lib/foreman_server/workflow/boot_reconciliation.ex` — `reconcile_lease_stream/1` |
| Dead task commands | `lib/foreman_server/aggregates/task.ex` |
| Operator allow-list is 7 types | `lib/foreman_server/command_gateway.ex` — `@allowed_operator_types` |
| Bearer auth passes through when unset | `lib/foreman_server_web/plugs/bearer_auth.ex` |
| No `:api_bearer_token` secret mapping | `config/prod.exs`, `ForemanServer.ConfigProviders.Secrets` |
| Run id derives from task id | `lib/foreman_server/identity.ex` — `run_id/2` |
| `run.start` requires `task_id` | `lib/foreman_server/aggregates/run.ex` |
| Manifest parser is a hand-rolled YAML subset | `lib/foreman_server/workflow/interpreter.ex` |

## Changelog

### 1.0.0 — 2026-08-15 — Initial PRD

Scoped from a codebase survey covering the Task footprint, the concurrency and queueing subsystem, the workflow subsystem, and the existing unimplemented MCP planning documents. Supersedes the work-submission and workflow-management scope of `PRD-2026-e8d3f5f2`, whose Bucket A inventory is stale by two command types.
