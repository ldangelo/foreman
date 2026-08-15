---
document_id: TRD-2026-0eac69b3
label: trd-foreman-mcp-work-ingress-and-global-run-slot-queue
version: 1.0.1
status: Draft
date: 2026-08-15
prd_reference: PRD-2026-0eac69b3
prd_label: prd-foreman-mcp-work-ingress-and-global-run-slot-queue
scale_depth: STANDARD
total_requirements: 22
total_acceptance_criteria: 79
design_readiness_score: 4.4
readiness_score: 4.4
total_tasks: 88
kind: trd
---

# TRD: Foreman MCP Work Ingress and Global Run-Slot Queue

## 1. Executive Summary

This TRD turns `PRD-2026-0eac69b3` (v1.0.0, readiness 4.4, 22 REQs, 78 ACs) into an implementation plan. The PRD micro UUID `0eac69b3` is preserved so PRD/TRD artifacts correlate 1:1; the label prefix changes from `prd-` to `trd-` and is display-only.

All work lives under `packages/foreman_server/` (paths in this TRD are package-relative). Every new process is a child of the existing `ForemanServer.Application` supervisor — no parallel OTP application is introduced.

The slice ships in five stacked PRs, ordered so that each one is independently valuable and independently revertible:

1. **PR 1 — Global run-slot admission.** A new `ForemanServer.Aggregates.RunSlots` event-sourced aggregate modeled directly on `Aggregates.BeadsDbLease`: N holders, a durable FIFO waiter list, and an atomic release-and-promote event. Wired into `RunAdmission` as the outermost gate, drained by `Workflow.Dispatcher`, backstopped by `RunLifecycleReconciler`, recovered by `Workflow.BootReconciliation`. Capacity becomes `config :foreman_server, :max_concurrent_runs` (default 3). This PR also deletes the write-only `Dispatcher.pending` map, which is the existing silent-drop bug. **PR 1 delivers "3 in parallel, queue the rest" for the existing Task path with no new ingress at all** — it is the highest-value, lowest-risk PR in the stack and can ship alone.
2. **PR 2 — Caller-supplied prompt channel.** An `input` block frozen into `workflow_snapshot`, surfaced to `RunExecutor` as `{{input.prompt}}` / `{{input.prompt_argument}}` assigns for prompt-type phases, and taught to `CommandGateway`'s existing strict renderer for command-type phases. Command strings are already rendered at snapshot-freeze time by `render_strict_fields/1` → `render_command/2`, but that renderer substitutes exactly two literal tokens (`{{implementation.trd_path_argument}}`, `{{implementation.source_revision}}`) and **early-returns the snapshot untouched when there is no `implementation` block** — so a manifest like `plan.yaml`, whose phases are command-type with no implementation context, currently gets no command rendering at all. PR 2 widens the allow-list to `input.*` and fixes the trigger condition, guarded by a pinned fixture over the existing frozen output. Because rendering stays at freeze time, `RunExecutor`'s command path is not modified.
3. **PR 3 — WorkRequest ingress.** A new `ForemanServer.Aggregates.WorkRequest` with `work.submit` / `work.cancel` / `work.execution_complete` / `work.execution_fail`. `work.submit` resolves the workflow, freezes the snapshot including the prompt, derives `run_id`, and hands `RunAdmission` a payload **shape-identical** to the one `handle_task_dispatched/2` builds today — so `RunAdmission`, `CommandRouter`, `Aggregates.Run`, `RunSupervisor`, the PR gate, and the project reservation need no changes at all. `RunExecutor` gains a single `source` branch for its lifecycle hooks.
4. **PR 4 — MCP server.** `ForemanServer.MCP.*` plus a Streamable HTTP mount and a stdio entrypoint, exposing submit / observe / cancel / queue-status / project-read tools. Includes the prerequisite auth fix: `:api_bearer_token` currently has no secret-provider mapping anywhere, so bearer auth is inert in every environment including prod.
5. **PR 5 — Workflow catalog management and Task pruning.** Read/validate/write tools over the Catalog, written through a canonical serializer constrained to the Interpreter's hand-rolled YAML subset, default-deny on writes. Plus removal of the five Task command handlers with zero production dispatch sites — write path only; `apply_event/2` clauses and codec entries are retained so historical streams stay decodable.

The slice is deliberately additive. The Beads reverse-sync path (`BeadsWatcher`, `BeadsOrphanJanitor`, `TaskProvider.Registry`) is not modified by any PR in this stack.

---

## 2. Architecture Decision

### 2.1 Alternatives Considered

#### Option A — Simplest: MCP as a thin HTTP client over the existing Task path (REJECTED)

The MCP server calls `task.create` then `task.approve` on behalf of the caller, mapping `prompt` onto the task's `description` field.

- **Pros:** No new aggregate, no new command types, no changes to `RunAdmission` or `RunExecutor`. Two days of work.
- **Cons:** Fails REQ-006 through REQ-008 outright. `description` is not rendered into any bundled prompt template, and the assigns map in `prompt_template_assigns/4` has no key that would surface it, so the prompt would be accepted and silently discarded — the worst possible failure mode. It also inherits the full approval/dispatch ceremony the PRD is trying to escape, and every submission mints a Beads-shaped task the `BeadsOrphanJanitor` will later reason about.
- **Risk:** HIGH. Ships a feature that appears to work and does not.

#### Option B — Most thorough: replace Task with a unified WorkItem model (REJECTED)

Delete `Aggregates.Task`, introduce `WorkItem` as the single pre-run identity, re-key `Identity.run_id/2` off `(project_id, external_id, nonce)`, and migrate the Beads integration onto it.

- **Pros:** One ingress, one model, no divergence risk. The end state the PRD's §2.4 dead-code findings point toward.
- **Cons:** `run_id` derivation changes, which invalidates the deterministic-retry contract that `CommandGateway.enrich_task_retry_with_bound_run/2` and `BootReconciliation.scan_task_run_orphans/0` both depend on. `BeadsWatcher` dedupe (`ProjectionStore.get_task(external_id:)`) and `BeadsOrphanJanitor`'s terminal-task check would both need reconstruction against the new anchor. 78 lib files and 85 test files mention task. This is a quarter of work before the first MCP call succeeds.
- **Risk:** HIGH. The valuable part of the PRD is reachable without it.

#### Option C — Parallel lean ingress converging at admission (CHOSEN)

A new `WorkRequest` aggregate is the pre-run identity for agentic submissions. It emits one event carrying everything a run needs, and hands `RunAdmission.start/2` the same payload shape the Task path already hands it. Both paths converge at admission; nothing below admission knows which ingress it came from except one `source` field consumed by `RunExecutor`'s lifecycle hooks.

- **Pros:** `RunAdmission`, `CommandRouter`, `Aggregates.Run`, `Aggregates.Project`, `RunSupervisor`, `PrGate`, `PrAssociate`, and `StuckDetector` require **zero** changes — verified: `pr_gate.ex`, `pr_associate.ex`, `aggregates/pr_association.ex`, and `stuck_detector.ex` contain no reference to task at all, and `Project.active_run_reservations` is keyed by `run_id`. `RunExecutor` needs one branch. The Beads path is untouched, so its dedupe and orphan-janitor anchors keep working. Each PR is independently shippable.
- **Cons:** Two ingress paths to maintain, and `Aggregates.Run` keeps a field named `task_id` that now holds either a task id or a work id. The field is not renamed because doing so would rewrite the event schema for every historical run.
- **Risk:** LOW. The convergence point is a single function with an existing, tested contract.

### 2.2 Chosen Architecture (Option C)

#### 2.2.1 Component Boundaries

**New library modules (under `packages/foreman_server/lib/foreman_server/`):**

| Path | Module | Responsibility |
|---|---|---|
| `aggregates/run_slots.ex` | `ForemanServer.Aggregates.RunSlots` | Event-sourced global admission gate on stream `run_slots:global`. State is `RunSlots.State` (`defstruct [:capacity, holders: %{}, waiters: []]`). Commands `run_slots.acquire`, `run_slots.release`, `run_slots.remove_waiter`. Structurally modeled on `Aggregates.BeadsDbLease`: acquire-or-enqueue is one atomic command so lost wakeups are impossible, and release-with-waiters emits a **single** `RunSlotTransferred` event rather than a release followed by a promote. |
| `aggregates/work_request.ex` | `ForemanServer.Aggregates.WorkRequest` | Pre-run identity for agentic submissions on stream `work:<work_id>`. State is `WorkRequest.State` (`defstruct [:work_id, :status, :project_id, :run_id, :bound_run_id, :submission_id, :workflow_snapshot]`). Commands `work.submit`, `work.cancel`, `work.execution_complete`, `work.execution_fail`. Statuses `submitted → queued → running → succeeded \| failed \| cancelled`. Deliberately small: four commands, no dependency graph, no annotations, no approval step — the ceremony the PRD's §2.4 identified as dead in `Aggregates.Task` is not reproduced here. |
| `work/submission.ex` | `ForemanServer.Work.Submission` | Pure function, the `WorkRequest` analogue of `Workflow.Approval.prepare/2`. Given `%{work_id, project_id, workflow, prompt}`, derives `submission_id`, computes `run_id = Identity.run_id(work_id, submission_id)`, loads the manifest via `Catalog.load(workflow <> ".yaml")`, stamps `index`/`phase_id` on each phase, and builds `workflow_snapshot` including the `input` block. Returns `{:ok, map()}` or `{:error, {:workflow_load_failed, name, reason}}`. |
| `work/run_payload.ex` | `ForemanServer.Work.RunPayload` | Single source of truth for the admission payload shape. Exposes `from_task_projection/1` and `from_work_projection/1`, both returning the same 7-key map (`run_id`, `task_id`, `project_id`, `approval_id`, `workflow_snapshot`, `phase_specs`, `source`). `Workflow.Dispatcher` is refactored to build the Task payload through `from_task_projection/1` so the two ingresses cannot drift. |
| `mcp.ex` | `ForemanServer.MCP` | Façade. Tool registry, capability advertisement, and the single `call_tool/3` entrypoint both transports share. |
| `mcp/policy.ex` | `ForemanServer.MCP.Policy` | Default-deny gate. Validates every tool name against the enabled set, refuses any dispatch whose command type is outside `CommandGateway.@allowed_operator_types`, and gates workflow writes behind `allow_workflow_writes`. `dispatch_system/2` is not reachable from any MCP code path — enforced by an architecture test. |
| `mcp/auth.ex` | `ForemanServer.MCP.Auth` | Shared bearer verifier used by the HTTP plug and the stdio entrypoint. Fails closed when `:api_bearer_token` is unset, unlike `Plugs.BearerAuth`, whose permissive behaviour is preserved for `/api`. |
| `mcp/tools.ex` | `ForemanServer.MCP.Tools` | Tool definitions: name, description, JSON Schema, handler. One module, one function per tool, no metaprogramming. |
| `mcp/stdio.ex` | `ForemanServer.MCP.Stdio` | stdio transport. Reads JSON-RPC 2.0 frames from stdin, writes to stdout, routes **all** diagnostics to Logger's stderr backend so stdout carries protocol bytes only. |
| `workflow/manifest_writer.ex` | `ForemanServer.Workflow.ManifestWriter` | Canonical serializer. Emits **only** the constructs `Workflow.Interpreter` parses: top-level `key: value` scalars, a `phases:` list at indent 0, phase entries at indent 2, phase properties at indent 4, single-level nested maps at indent 6. Validates the emitted bytes by round-tripping them through `Interpreter.load/1` before any filesystem move. |
| `workflow/catalog_writer.ex` | `ForemanServer.Workflow.CatalogWriter` | Filesystem discipline for catalog mutation: containment check against `Catalog.root/0`, `name:`-matches-stem check, write to a temp file inside the root, `File.rename/2` into place. Never partially writes a manifest. |

**New web modules (under `packages/foreman_server/lib/foreman_server_web/`):**

| Path | Module | Responsibility |
|---|---|---|
| `mcp_router.ex` | `ForemanServerWeb.MCPRouter` | Streamable HTTP transport mounted at `/mcp` via a dedicated `:mcp` pipeline (`:accepts json` + `ForemanServer.MCP.Auth` plug). Mounted outside the `:api` scope so it does not inherit `Plugs.BearerAuth`'s permissive-when-unset behaviour. |
| `controllers/work_controller.ex` | `ForemanServerWeb.WorkController` | `GET /api/work/:id` returning the work projection, mirroring `TaskController.show/2`. |
| `controllers/queue_controller.ex` | `ForemanServerWeb.QueueController` | `GET /api/queue` returning capacity, running runs, and ordered waiters. |

**Existing modules changed (surgical):**

| Path | Change |
|---|---|
| `lib/foreman_server/run_admission.ex` | Add the global slot as the **outermost** gate, ahead of the existing Beads-DB lease. New return value `{:ok, :slot_queued}` alongside the existing `{:ok, :queued}`. On a lease `:queued` result, release the just-acquired slot before returning, per Decision 3. Extend `compensable_admission_error?/1` handling so a failed `run.start` releases the slot as well as the lease. |
| `lib/foreman_server/workflow/dispatcher.ex` | Add `handle_work_submitted/2` (mirrors `handle_task_dispatched/2`, routed through `Work.RunPayload.from_work_projection/1`). Add `handle_slot_promoted/2` (mirrors `handle_lease_promoted/2`, subscribing to `RunSlotTransferred`). Extend the terminal-run fan-out to dispatch `run_slots.release`. **Delete** the `put_in(state, [:pending, task_id], reason)` write and the `:pending` key — it is never read and is the current silent-drop bug. |
| `lib/foreman_server/workflow/run_executor.ex` | (a) Add `input` to `prompt_template_assigns/4` as flat `"input.prompt"` and `"input.prompt_argument"` keys, defaulting to `""` when the snapshot has no `input` block. (b) Branch `maybe_claim_task/1`, `maybe_complete_task/1`, and `maybe_fail_task/4` on `state.source`: for `:work_request`, skip the `TaskProvider` callbacks and dispatch `work.execution_complete` / `work.execution_fail` instead of the `task.*` equivalents. **The command-phase path is deliberately not touched** — command rendering stays at snapshot-freeze time in `CommandGateway`. |
| `lib/foreman_server/command_gateway.ex` | Add `work.submit` and `work.cancel` to `@allowed_operator_types` (bringing it to 9). Add `validate_aggregate_id/1` clauses for both. Add an `enrich_operator_command/1` clause for `work.submit` that calls `Work.Submission.prepare/1` and rejects client-supplied `submission_id`, `run_id`, and `workflow_snapshot` as reserved, mirroring `@reserved_approval_fields`. Extend `render_strict_fields/1` to fire when the snapshot has an `implementation` block **or** an `input` block (today it early-returns when `implementation` is nil), and extend `render_command/2`'s literal-token allow-list with `{{input.prompt}}` and `{{input.prompt_argument}}`. |
| `lib/foreman_server/aggregates/task.ex` | Remove `handle_command/2` clauses for `task.block`, `task.close`, `task.update`, `task.annotate`, `task.add_dependency`. **Retain** every `apply_event/2` clause and every `event_codec.ex` entry — the write path is removed, the read path is not, so historical streams stay decodable. |
| `lib/foreman_server/aggregates/project.ex` | Replace the hardcoded `@max_concurrent_runs 100` with a config lookup defaulting to 100, carried on the reserve command so replay stays deterministic. |
| `lib/foreman_server/projection_store.ex` | Add a `work` projection map folding the four `Work*` events, with `work_projection/1` and `list_work/0`. Add a `run_slots` projection folding the five `RunSlot*` events, with `queue_status/0`. Remove `list_workflow_tasks/0` (no callers). |
| `lib/foreman_server/run_lifecycle_reconciler.ex` | Subscribe to terminal run events for slot release alongside the existing project-reservation release. Extend the 30-second sweep to detect a promoted-but-not-started waiter and retry admission — the backstop for a dropped broadcast. |
| `lib/foreman_server/workflow/boot_reconciliation.ex` | Add `scan_run_slot_orphans/0` + `reconcile_run_slots_stream/0`, mirroring `scan_lease_orphans/0` + `reconcile_lease_stream/1`: load `run_slots:global`, drop holders and waiters whose run is absent or terminal, promote live waiters into freed slots. |
| `lib/foreman_server/event_codec.ex` | Register `WorkSubmitted`, `WorkCancelled`, `WorkExecutionCompleted`, `WorkExecutionFailed`, `RunSlotAcquired`, `RunSlotQueued`, `RunSlotReleased`, `RunSlotTransferred`, `RunSlotWaiterRemoved`. |
| `lib/foreman_server/command_router.ex` | Route stream prefixes `work:` → `Aggregates.WorkRequest` and `run_slots:` → `Aggregates.RunSlots`. |
| `lib/foreman_server/application.ex` | Add `ForemanServer.MCP` supervisor subtree. `RunSlots` needs no process — it is an aggregate, loaded on demand like `BeadsDbLease`. |
| `lib/foreman_server_web/router.ex` | Add `GET /api/work/:id`, `GET /api/queue` under `:api`. Add the `:mcp` pipeline and `/mcp` scope. |
| `lib/foreman_server_web/controllers/command_controller.ex` | Extend `@allowed_types` to match the gateway's 9, and add a test asserting the two lists are equal. |
| `config/config.exs` | `max_concurrent_runs: 3`, `max_concurrent_runs_per_project: 100`, `config :foreman_server, :mcp, enabled: false, mount: "/mcp", allow_workflow_writes: false, allow_insecure_local: false`. |
| `config/prod.exs` / `ForemanServer.ConfigProviders.Secrets` | Map `FOREMAN_API_TOKEN` → `:api_bearer_token`. This mapping does not exist today, which is why bearer auth is inert in every environment. |
| **Deleted** | `lib/foreman_server/commands/create_task.ex`, `lib/foreman_server/commands/close_task.ex`, `lib/foreman_server/events/task_closed.ex` — all three are defined and referenced nowhere; `TaskClosed` is not even registered in the codec. |

**Explicitly NOT changed (verified no coupling):**

| Module | Why untouched |
|---|---|
| `pr_gate.ex`, `pr_associate.ex`, `aggregates/pr_association.ex` | Keyed entirely by `run_id`; contain no reference to task. Work-sourced runs get PR association for free. |
| `stuck_detector.ex`, `overwatch/*.ex` | Operate on run and worker state only; no task references anywhere in the directory. |
| `task_providers/*` (Beads adapter, watcher, janitor) | The Beads reverse-sync path is out of scope by design. `WorkRequest` never touches a `TaskProvider`. |
| `aggregates/run.ex` | `run.start` requires `task_id`; work-sourced runs supply the `work_id` in that field. No schema change, no migration. |
| `aggregates/project_run_limit.ex` | Left inert rather than deleted, to keep this slice's diff focused. Flagged for removal in a follow-up. |

#### 2.2.2 Data Flow

**Admission with the global slot gate (both ingresses)**

```
Workflow.Dispatcher (on TaskDispatched | WorkSubmitted)
  │ payload = Work.RunPayload.from_task_projection/1 | from_work_projection/1
  ▼
RunAdmission.start(project_id, payload)
  │
  ├─ GATE 1 (outer, global) ─ CommandGateway.dispatch_system("run_slots.acquire",
  │      %{run_id, work_or_task_id, capacity: cfg(:max_concurrent_runs, 3)})
  │   ├─ holders < capacity → RunSlotAcquired  → continue
  │   ├─ run_id already a holder → idempotent no-op → continue
  │   └─ holders == capacity   → RunSlotQueued  → return {:ok, :slot_queued}   [no run started]
  │
  ├─ GATE 2 (inner, per Beads DB — unchanged) ─ lease.acquire
  │   ├─ :proceed → continue
  │   └─ :queued  → dispatch run_slots.release FIRST (Decision 3), then {:ok, :queued}
  │
  └─ CommandRouter.dispatch_run_start/2
        ├─ project.reserve_run   (existing per-project reservation, now configurable)
        └─ run.start → RunStarted → RunSupervisor.start_run(run_id, payload)
```

**Drain on termination**

```
RunCompleted | RunFailed | RunCancelled | RunFlaggedStuck | RunBlocked
  │
  ├─ Workflow.Dispatcher.handle_run_terminated/3
  │     ├─ BootReconciliation.run_terminated/2      (existing)
  │     ├─ lease.release / lease.remove_waiter      (existing)
  │     └─ run_slots.release                        (NEW)
  │           ├─ no waiters → RunSlotReleased
  │           └─ waiters    → RunSlotTransferred  {released_run_id, acquired_run_id}
  │                              │  (single atomic event: release + promote FIFO head)
  │                              ▼
  │                       Dispatcher.handle_slot_promoted/2
  │                              └─ RunAdmission.start/2 for acquired_run_id
  │                                    └─ RunSupervisor.start_run/2
  │
  └─ RunLifecycleReconciler (subscription + 30s sweep)
        ├─ project.release_run_reservation           (existing)
        ├─ run_slots.release                         (NEW — redundant with the above, idempotent)
        └─ sweep: holder promoted but no RunStarted after N sweeps → retry admission
              (backstop for a dropped broadcast — AC-012-3)
```

**Prompt from submit to agent**

```
MCP foreman_work_submit {workflow: "implement-trd", prompt: "<free text>"}
  │
  ▼
CommandGateway.dispatch_operator(%{type: "work.submit", payload})
  │ enrich → Work.Submission.prepare/1
  │            ├─ Catalog.load("implement-trd.yaml")     → resolved manifest
  │            ├─ run_id = Identity.run_id(work_id, submission_id)
  │            └─ workflow_snapshot.input = %{prompt: "<verbatim>",
  │                                           prompt_argument: Jason.encode!("<verbatim>")}
  ▼
  │            └─ render_strict_fields/1 → render_command/2
  │                 substitutes {{input.prompt_argument}} into command: phases
  │                 NOW, at freeze time — same place {{implementation.*}} is
  │                 already substituted today
  ▼
WorkSubmitted  (stream work:<work_id>)  — prompt AND rendered commands are now immutable
  ▼
RunExecutor.init/1 → state.plan_context ⊕ snapshot.input
  │
  ├─ prompt-type phase: read_phase_prompt/4 (Catalog .md body)
  │      → render_prompt_template/5 against assigns incl. "input.prompt"
  │
  └─ command-type phase: already-rendered command string from the snapshot
         → execute_agent/4                ◀── unchanged; no run-time rendering
```

Two substitution passes exist and they are deliberately different. Freeze-time rendering (`render_command/2`) is a **closed allow-list of literal tokens** applied once and made immutable. Run-time rendering (`render_prompt_template/5`) is a regex over a flat assigns map applied to prompt bodies only. Both are single-pass, so a prompt containing the literal text `{{run_id}}` is inert data and is never recursively expanded (AC-007-3).

#### 2.2.3 Integration Points

1. **`RunAdmission.start/2` is the convergence point.** Both ingresses call it with a payload built by `Work.RunPayload`, which is the only module allowed to construct that shape. An architecture test asserts no other module builds it inline.
2. **`Workflow.Dispatcher` is the only subscriber that starts executors.** Three clauses now feed it: `TaskDispatched`, `WorkSubmitted`, and promotions (`BeadsDbLeaseTransferred`, `RunSlotTransferred`).
3. **`CommandGateway` remains the sole mutation surface.** MCP tools call `dispatch_operator/2` exclusively; `MCP.Policy` refuses anything outside the allow-list before the call is made.
4. **`Workflow.Catalog`'s 2-second poll is the reload mechanism** for MCP workflow writes. `CatalogWriter` does not call `Catalog.reload/0` implicitly; the tool response reports whether the write has been observed by the catalog yet.

#### 2.2.4 Technology Choices

| Choice | Decision | Rationale |
|---|---|---|
| MCP protocol implementation | `{:anubis_mcp, "~> 1.10"}`, with a hand-rolled JSON-RPC 2.0 module as the documented fallback | `anubis_mcp` is the maintained successor to `hermes_mcp` (renamed at v0.14), provides both server construction and Plug/Phoenix integration, and is on Hex at 1.x. The earlier TRD-2026-e8d3f5f2 left this decision explicitly open; it is closed here. The fallback matters because the tool surface is small enough (~13 tools) that hand-rolling framing is a two-day job if the dependency review rejects the addition. |
| HTTP transport | Streamable HTTP under the existing Cowboy stack | `mix.lock` pins `plug_cowboy 2.9.0` / Cowboy 2.17.0. Bandit is an optional dep of Phoenix 1.8.9 but is **not** locked, so no server swap is implied. |
| Slot state storage | Event-sourced aggregate on a single stream | Matches `BeadsDbLease` exactly and is the only durable-queue pattern already proven in this codebase. A GenServer would repeat `ConcurrencyLimiter`'s mistake — in-memory waiters that a crash silently discards. |
| Capacity value | Carried on the acquire command, recorded on the event | Reading `Application.get_env` inside a decision function would make replay non-deterministic after an operator changes the config. Recording it makes history self-describing. |
| Slot stream granularity | One global stream, `run_slots:global` | Serializes all admission. At capacity 3 this is irrelevant; it is a throughput ceiling only at much higher capacities, and is documented as such rather than pre-optimized. |
| Manifest writing | Canonical serializer, not a YAML library | `Workflow.Interpreter` is a hand-rolled indentation-sensitive parser, not real YAML. It has no support for block scalars, anchors, flow sequences, or nesting beyond indent 6. A standard YAML emitter would produce valid YAML that this parser silently misreads. |
| Prompt storage | Verbatim in the frozen snapshot | Consistent with how `ImplementationContext` is frozen at approval time specifically to avoid re-resolution drift. |

#### 2.2.5 Telemetry Taxonomy

| Event | Measurements | Metadata |
|---|---|---|
| `[:foreman_server, :run_slots, :acquired]` | `%{holders: n, capacity: n}` | `run_id`, `source` |
| `[:foreman_server, :run_slots, :queued]` | `%{depth: n}` | `run_id`, `position` |
| `[:foreman_server, :run_slots, :released]` | `%{holders: n}` | `run_id`, `reason` |
| `[:foreman_server, :run_slots, :transferred]` | `%{depth: n}` | `released_run_id`, `acquired_run_id` |
| `[:foreman_server, :run_slots, :waiter_removed]` | `%{depth: n}` | `run_id`, `reason` |
| `[:foreman_server, :run_slots, :reconciled]` | `%{holders_dropped: n, waiters_dropped: n}` | `phase` (`:boot` \| `:sweep`) |
| `[:foreman_server, :work, :submitted]` | `%{prompt_bytes: n}` | `work_id`, `run_id`, `workflow`, `project_id` — **never the prompt body** |
| `[:foreman_server, :work, :terminal]` | `%{duration_us: n}` | `work_id`, `run_id`, `status` |
| `[:foreman_server, :mcp, :tool, :call]` | `%{duration_us: n}` | `tool`, `outcome` — **never arguments, never the token** |
| `[:foreman_server, :mcp, :policy, :refused]` | `%{}` | `tool`, `reason` |

### 2.3 Design Decisions

**Decision 1 — `WorkRequest` is a new aggregate, not a reuse of `Task`.** Reusing `Task` would mean either resurrecting `task.approve`'s enrichment for a path that has nothing to approve, or adding a bypass flag to an aggregate whose whole problem is accumulated ceremony. A four-command aggregate is smaller than the conditional logic reuse would require.

**Decision 2 — `Aggregates.Run.task_id` is not renamed.** It now carries either a task id or a work id. Renaming it would rewrite the event schema for every historical `RunStarted`. The `source` field disambiguates, and it is the only field consumers need.

**Decision 3 — Slot outer, lease inner, and release the slot when lease-queued.** Three orderings were considered. Lease-first lets a run hold a Beads-DB mutex while waiting for capacity, blocking every other run on that database. Slot-first-and-hold lets lease-blocked runs occupy capacity while doing no work — with capacity 3 and three runs on one database, two slots sit idle. Slot-first-and-release-when-queued has neither property: a lease waiter holds nothing, and on `BeadsDbLeaseTransferred` the existing `re_dispatch_promoted/3` already re-enters `RunAdmission.start/2` from the top, which re-acquires a slot naturally. No new promotion machinery is needed for the interaction.

**Decision 4 — Task pruning removes the write path only.** `apply_event/2` clauses and `event_codec.ex` entries for `TaskUpdated`, `TaskAnnotated`, and `TaskDependencyAdded` are retained. Even though these events were never dispatched in production, removing decode support would make any stream containing them permanently unreplayable — an irreversible failure mode traded against zero benefit.

**Decision 5 — MCP fails closed on auth; `/api` does not change.** `Plugs.BearerAuth` passing through when `:api_bearer_token` is unset is deliberate for local development and is out of scope to change. `MCP.Auth` refuses to start without a token unless `allow_insecure_local: true` is explicit. This lets the MCP ingress be safe without a flag day for existing HTTP callers.

**Decision 6 — Prompt substitution for command phases happens at freeze time, not run time.** The obvious implementation is to render `command:` strings inside `RunExecutor` alongside prompt bodies. That is the wrong place. Command strings are *already* rendered at snapshot-freeze time by `CommandGateway.render_strict_fields/1` → `render_command/2`, and the frozen result is what the executor consumes. Adding a second, later rendering pass would mean two renderers with different semantics operating on the same string, and would break the invariant that a frozen snapshot is fully resolved. Extending the existing renderer instead means `RunExecutor`'s command path is untouched, the prompt is immutable from the moment `WorkSubmitted` is appended, and there is exactly one place where a command string acquires its final form.

Two facts about that renderer shape the tasks. It substitutes exactly two literal tokens, and `render_strict_fields/1` returns the snapshot unmodified when it finds no `implementation` block — which means `plan.yaml`, whose phases are command-type and which carries no implementation context, currently receives no command rendering at all. TRD-020 widens the token allow-list; TRD-019 fixes the trigger condition. TRD-018 pins the current frozen output first, because this renderer's output goes into the event store and a defect there ships into history rather than into a retryable execution.

---

## 3. Master Task List

Each `### PR N:` heading is followed by a `**Shippable State:**` line. Task IDs are `TRD-NNN`; test tasks append `-TEST` to the implementation ID they verify.

### PR 1: Global Run-Slot Admission and Durable Queue

**Shippable State:** Foreman enforces a global ceiling of `config :foreman_server, :max_concurrent_runs` (default 3) concurrently executing runs across all projects. Work beyond the ceiling is durably queued in a FIFO waiter list on the event-sourced `run_slots:global` stream and is promoted automatically when a slot frees, via a single atomic `RunSlotTransferred` event that `Workflow.Dispatcher` observes and re-admits. Waiters survive process and node restarts and are reconciled at boot. The write-only `Dispatcher.pending` map — the current silent-drop bug — is removed. **This PR delivers the concurrency requirement for the existing Task path with no new ingress**, and is independently shippable.

| id | task | est. | deps | satisfies | validates |
|---|---|---|---|---|---|
| TRD-001 | Implement `ForemanServer.Aggregates.RunSlots` state and `apply_event/2`: define `RunSlots.State` as `defstruct [:capacity, holders: %{}, waiters: []]`; each `apply_event/2` clause uses `%State{state | ...}` updates; fold `RunSlotAcquired`, `RunSlotQueued`, `RunSlotReleased`, `RunSlotTransferred`, `RunSlotWaiterRemoved`; stream id `run_slots:global` | 4h | — | REQ-010, REQ-011 | AC-010-1, AC-011-1 |
| TRD-002 | Implement `RunSlots.handle_command/2` for `run_slots.acquire`: acquire-or-enqueue atomically in one command (holders < capacity → `RunSlotAcquired`; already a holder → idempotent `{:ok, nil}`; otherwise → `RunSlotQueued`); capacity is read from the command payload, never from `Application.get_env`, and is recorded on the emitted event | 4h | TRD-001 | REQ-010 | AC-010-1, AC-010-3, AC-010-4, AC-010-5 |
| TRD-003 | Implement `RunSlots.handle_command/2` for `run_slots.release` (no waiters → `RunSlotReleased`; waiters present → single `RunSlotTransferred` carrying both `released_run_id` and `acquired_run_id`, releasing and promoting the FIFO head in one atomic transition) and `run_slots.remove_waiter` → `RunSlotWaiterRemoved`; both idempotent when the run is not a holder or waiter | 4h | TRD-002 | REQ-011, REQ-012 | AC-011-1, AC-012-1 |
| TRD-004 | Register the five `RunSlot*` events in `event_codec.ex` and add the `run_slots:` stream prefix to `CommandRouter.aggregate_module_for/1` | 2h | TRD-003 | REQ-011 | AC-011-2 |
| TRD-004-TEST | Codec and routing tests: each of the five `RunSlot*` events encodes and decodes through `EventCodec` without data loss; `CommandRouter.aggregate_module_for/1` returns `RunSlots` for `"run_slots:global"` and raises for any other stream prefix | 2h | TRD-004 [verifies TRD-004] | REQ-011 | AC-011-2 |
| TRD-005 | Add config keys `max_concurrent_runs: 3` and `max_concurrent_runs_per_project: 100` to `config/config.exs`; add a `ForemanServer.RunSlots.Config` accessor returning the effective capacity with the documented default | 1h | — | REQ-010 | AC-010-2 |
| TRD-005-TEST | Config accessor tests: with the key absent from config, `RunSlots.Config.max_concurrent_runs/0` returns 3; with the key set to 7 it returns 7; `max_concurrent_runs_per_project/0` returns 100 when absent and the configured value when set; changing the config at runtime is reflected on the next call | 1h | TRD-005 [verifies TRD-005] | REQ-010 | AC-010-2 |
| TRD-006 | Wire the global slot into `RunAdmission.start/3` as the outermost gate, ahead of the existing Beads-DB lease acquire; add the `{:ok, :slot_queued}` return alongside the existing `{:ok, :queued}`; capacity is supplied from `RunSlots.Config` at the call site | 5h | TRD-002, TRD-005 | REQ-010, REQ-013 | AC-010-1, AC-013-1 |
| TRD-007 | Implement Decision 3 in `RunAdmission`: when the Beads-DB lease returns `:queued`, dispatch `run_slots.release` for the just-acquired slot **before** returning `{:ok, :queued}`, so a lease-blocked run never occupies capacity; extend `compensable_admission_error?/1` handling so a failed `run.start` releases the slot as well as the lease | 4h | TRD-006 | REQ-013 | AC-013-2, AC-013-3, AC-013-4 |
| TRD-008 | Add `Workflow.Dispatcher.handle_slot_promoted/2` subscribing to `RunSlotTransferred`: look up the promoted run's payload, re-enter `RunAdmission.start/2`, and start the supervisor on admission — structurally mirrors the existing `handle_lease_promoted/2` | 4h | TRD-003, TRD-006 | REQ-012 | AC-012-2 |
| TRD-009 | Extend `Workflow.Dispatcher.handle_run_terminated/3` to dispatch `run_slots.release` on every terminal run event (`RunCompleted`, `RunFailed`, `RunCancelled`, `RunFlaggedStuck`, `RunBlocked`), alongside the existing lease release | 2h | TRD-003 | REQ-012 | AC-012-1 |
| TRD-009-TEST | Terminal fan-out tests: with the dispatcher subscription active, each of `RunCompleted`, `RunFailed`, `RunCancelled`, `RunFlaggedStuck`, and `RunBlocked` emits exactly one `run_slots.release` command; a non-terminal event does not emit release (outside TRD-009's scope but exercised to pin the trigger boundary); a duplicate delivery of a terminal event is idempotent and emits exactly one release | 2h | TRD-009 [verifies TRD-009] | REQ-012 | AC-012-1 |
| TRD-010 | Delete the write-only `put_in(state, [:pending, task_id], reason)` write and the `:pending` key from `Workflow.Dispatcher` state; replace with a telemetry emission and a Logger warning so an admission error is observable rather than discarded | 2h | TRD-006 | REQ-012 | AC-012-4 |
| TRD-011 | Extend `RunLifecycleReconciler` to dispatch `run_slots.release` from its terminal-event subscription (idempotent with TRD-009), and extend the 30s sweep to detect a promoted holder with no corresponding `RunStarted` after two consecutive sweeps and retry `RunAdmission.start/2` — the backstop for a dropped promotion broadcast | 5h | TRD-008 | REQ-012 | AC-012-3 |
| TRD-012 | Implement `Workflow.BootReconciliation.scan_run_slot_orphans/0` + `reconcile_run_slots_stream/0`: load `run_slots:global` via `Aggregate.load/2`, drop holders whose run is absent or terminal, drop waiters whose run is absent/terminal/cancelled, and promote live waiters into freed slots — mirrors the existing `scan_lease_orphans/0` / `reconcile_lease_stream/1` pair | 5h | TRD-003, TRD-004 | REQ-011 | AC-011-3, AC-011-4 |
| TRD-013 | Add a `run_slots` projection to `ProjectionStore` folding the five `RunSlot*` events, exposing `queue_status/0` returning `%{capacity, running: [...], waiting: [...]}` with waiters in FIFO order | 4h | TRD-004 | REQ-014 | AC-014-1 |
| TRD-014 | Emit the six `[:foreman_server, :run_slots, :*]` telemetry events per §2.2.5 at every acquire, queue, release, transfer, waiter-removal, and reconciliation site | 2h | TRD-003, TRD-012 | REQ-014 | AC-014-2 |
| TRD-015 | Replace `Aggregates.Project`'s hardcoded `@max_concurrent_runs 100` with a value carried on the `project.reserve_run` command payload, sourced from `max_concurrent_runs_per_project` and defaulting to 100 so existing behaviour is unchanged; record it on `ProjectRunReserved` for replay determinism | 3h | TRD-005 | REQ-015 | AC-015-1, AC-015-2 |
| TRD-016 | Add `ForemanServerWeb.QueueController` and route `GET /api/queue` under the `:api` pipeline, returning `ProjectionStore.queue_status/0` | 2h | TRD-013 | REQ-014 | AC-014-1 |
| TRD-001-TEST | RunSlots state tests: each of the five events folds correctly; waiter order is preserved across arbitrary interleavings; holders map is keyed by run_id | 2h | TRD-001 [verifies TRD-001] | REQ-010, REQ-011 | AC-010-1, AC-011-1 |
| TRD-002-TEST | Acquire tests: capacity-1 acquires succeed; the capacity-th acquire queues; re-acquiring as an existing holder is a no-op that does not change `map_size(holders)`; the capacity recorded on the event equals the value on the command, not the current config value; capacity-reduction tests: reducing capacity below the current holder count causes no release events; new acquire calls queue while holders exceed the new capacity; promotion resumes only when holders ≤ new capacity | 3h | TRD-002 [verifies TRD-002] | REQ-010 | AC-010-1, AC-010-3, AC-010-4, AC-010-5 |
| TRD-003-TEST | Release tests: release with no waiters emits `RunSlotReleased`; release with waiters emits exactly one `RunSlotTransferred` naming both runs and no separate release event; FIFO head is the promoted run; `remove_waiter` for a non-waiter is a no-op | 3h | TRD-003 [verifies TRD-003] | REQ-011, REQ-012 | AC-011-1, AC-012-1 |
| TRD-006-TEST | Admission gate-order tests: with capacity 3, a fourth admission returns `{:ok, :slot_queued}` and dispatches no `run.start`; the slot acquire is dispatched strictly before the lease acquire, asserted by command-order capture | 3h | TRD-006 [verifies TRD-006] | REQ-010, REQ-013 | AC-010-1, AC-013-1 |
| TRD-007-TEST | Decision-3 property test: generate interleavings of N runs across M Beads databases at capacity C and assert the invariant "no run is simultaneously a slot holder and a lease waiter"; assert the four-runs-one-database case settles with exactly one executing run and the remaining capacity free for other databases | 6h | TRD-007 [verifies TRD-007] | REQ-013 | AC-013-2, AC-013-3, AC-013-4 |
| TRD-008-TEST | Drain tests: releasing a slot with a waiter queued results in the promoted run's executor being started, with no polling interval elapsed; a promotion for an already-terminal run does not start an executor | 3h | TRD-008 [verifies TRD-008] | REQ-012 | AC-012-2 |
| TRD-011-TEST | Backstop tests: with the dispatcher subscription suppressed, a promoted-but-unstarted waiter is detected and admitted by the sweep after two intervals; the retry is idempotent when the executor did in fact start | 3h | TRD-011 [verifies TRD-011] | REQ-012 | AC-012-3 |
| TRD-012-TEST | Boot recovery tests: kill the node with three waiters queued, restart, and assert the waiter list and its order are re-derived from the stream with none lost; a holder whose run is terminal is released and its slot given to the next live waiter; a waiter whose work was cancelled is removed and skipped | 4h | TRD-012 [verifies TRD-012] | REQ-011 | AC-011-2, AC-011-3, AC-011-4 |
| TRD-010-TEST | Regression test asserting `Workflow.Dispatcher` state contains no `:pending` key and that an admission error produces a telemetry event and a log line — pins the silent-drop bug closed | 2h | TRD-010 [verifies TRD-010] | REQ-012 | AC-012-4 |
| TRD-013-TEST | Queue status tests: capacity, running list, and ordered waiting list are reported correctly across acquire/queue/transfer sequences | 2h | TRD-013 [verifies TRD-013] | REQ-014 | AC-014-1 |
| TRD-014-TEST | Telemetry tests: each of the six `[:foreman_server, :run_slots, :*]` events carries the correct fields (`:run_id`, `:capacity`, `:holder_count`, `:waiter_count`); events are emitted at acquire, queue, release, transfer, waiter-removal, and boot-reconciliation sites with no duplicate emissions for single state transitions | 2h | TRD-014 [verifies TRD-014] | REQ-014 | AC-014-2 |
| TRD-015-TEST | Per-project limit tests: with the config key absent the effective limit is 100 and existing behaviour is byte-identical; with the global cap at 3 the per-project reservation never rejects first | 2h | TRD-015 [verifies TRD-015] | REQ-015 | AC-015-1, AC-015-2 |
| TRD-016-TEST | Queue endpoint tests: `GET /api/queue` returns 200 with the projection store's `queue_status/0` payload; with no runs the response is `{"capacity": 3, "running": [], "waiting": []}`; while a run is queued the `waiting` list contains the run in FIFO order; a run that transitions from waiting to running is absent from `waiting` and present in `running` | 2h | TRD-016 [verifies TRD-016] | REQ-014 | AC-014-1 |

### PR 2: Caller-Supplied Prompt Channel

**Shippable State:** A run's frozen `workflow_snapshot` may carry an `input` block. `RunExecutor` surfaces it to prompt-type phases as `{{input.prompt}}`; `CommandGateway`'s existing freeze-time strict renderer surfaces it to command-type phases as `{{input.prompt_argument}}`. That renderer now fires for snapshots carrying an `input` block even with no `implementation` block, closing the gap where `plan.yaml`-shaped manifests received no command rendering at all. A pinned fixture proves every existing `implement-trd` manifest freezes a byte-identical command string before and after the change. Task-sourced runs with no `input` block render `{{input.prompt}}` as the empty string. `RunExecutor`'s command path is not modified.

| id | task | est. | deps | satisfies | validates |
|---|---|---|---|---|---|
| TRD-017 | Extend `RunExecutor.prompt_template_assigns/4` with flat `"input.prompt"` and `"input.prompt_argument"` keys sourced from `workflow_snapshot["input"]`, defaulting to `""` when the block is absent; keys are flat because the substitution regex matches literal tokens and does not traverse dotted paths | 3h | — | REQ-006, REQ-007 | AC-006-3, AC-007-1 |
| TRD-018 | Capture a pinned fixture of the current freeze-time output: for every bundled manifest declaring a `command:` phase, record the exact command string `render_strict_fields/1` freezes into `workflow_snapshot` today, before any change, as a checked-in fixture — this is the regression anchor for a renderer whose output is immutable once appended | 3h | — | REQ-008 | AC-008-3 |
| TRD-019 | Fix `CommandGateway.render_strict_fields/1` to fire when the snapshot carries an `implementation` block **or** an `input` block, replacing the current early-return-when-`implementation`-is-nil branch; assert against the TRD-018 fixture that every existing `implement-trd` / `implement-trd-beads` snapshot is byte-identical | 4h | TRD-018 | REQ-008 | AC-008-3, AC-008-5 |
| TRD-020 | Extend `CommandGateway.render_command/2`'s literal-token allow-list with `{{input.prompt}}` and `{{input.prompt_argument}}`, and build `input.prompt_argument` as the prompt JSON-quoted via `Jason.encode!/1` for safe single-argument use, mirroring how `implementation.trd_path_argument` is derived; tokens outside the allow-list remain untouched by design | 3h | TRD-019 | REQ-008 | AC-008-1, AC-008-2, AC-008-4, AC-008-5 |
| TRD-021 | Update the bundled prompt templates `discover.md`, `implement.md`, and `verify.md` to consume `{{input.prompt}}` inside a section that renders nothing when the prompt is empty, so Task-sourced output is unchanged | 3h | TRD-017 | REQ-009 | AC-009-1, AC-009-2 |
| TRD-017-TEST | Assigns tests: `{{input.prompt}}` resolves to the submitted prompt; an absent `input` block yields `""`; an unknown token such as `{{input.nonsense}}` is left intact per the existing contract; a prompt containing the literal `{{run_id}}` is not recursively expanded | 3h | TRD-017 [verifies TRD-017] | REQ-006, REQ-007 | AC-006-3, AC-007-1, AC-007-2, AC-007-3 |
| TRD-019-TEST | Freeze-time rendering tests: a phase declaring `command: "/skill:foo {{input.prompt_argument}}"` is frozen already-expanded; the TRD-018 fixture matches byte for byte for every existing `implement-trd` manifest; a `plan.yaml`-shaped snapshot with an `input` block and no `implementation` block is now rendered rather than passed through; a token in neither allow-list survives intact; a prompt containing shell metacharacters yields exactly one additional argv word | 5h | TRD-020 [verifies TRD-019, TRD-020] | REQ-008 | AC-008-1, AC-008-2, AC-008-3, AC-008-4, AC-008-5 |
| TRD-021-TEST | Bundled-template regression: render each updated template with an empty `input` block and assert the output is byte-identical to the pre-change rendering captured as a fixture | 2h | TRD-021 [verifies TRD-021] | REQ-009 | AC-009-1, AC-009-2 |

### PR 3: WorkRequest Ingress

**Shippable State:** `POST /api/commands` accepts `type: "work.submit"` with `project_id`, `workflow`, and `prompt`, and mints a run directly — no `TaskCreated`, no approval, no dispatch hop. The submission's workflow snapshot, including the prompt, is frozen at submit time. `RunAdmission` receives a payload shape-identical to the Task path's, so nothing below admission changes. `RunExecutor` branches its lifecycle hooks on run source, dispatching `work.execution_complete` / `work.execution_fail` and invoking no `TaskProvider` callbacks for work-sourced runs. `GET /api/work/:id` reports status, including queue position while queued.

| id | task | est. | deps | satisfies | validates |
|---|---|---|---|---|---|
| TRD-022 | Implement `ForemanServer.Aggregates.WorkRequest` state, `apply_event/2`, and the status machine `submitted → queued → running → succeeded \| failed \| cancelled`; define `WorkRequest.State` as `defstruct [:work_id, :status, :project_id, :run_id, :bound_run_id, :submission_id, :workflow_snapshot]`; each `apply_event/2` clause uses `%State{state | ...}` updates; stream id `work:<work_id>`; four events `WorkSubmitted`, `WorkCancelled`, `WorkExecutionCompleted`, `WorkExecutionFailed` | 5h | — | REQ-001, REQ-004 | AC-001-1, AC-004-1 |
| TRD-023 | Implement `WorkRequest.handle_command/2` for `work.submit`: reject when the work id already exists, when `prompt` is absent/blank/non-binary, or when the workflow snapshot is not a non-empty map; emit `WorkSubmitted` carrying `workflow_snapshot`, `run_id`, `project_id`, and the verbatim prompt | 4h | TRD-022 | REQ-001, REQ-006 | AC-001-1, AC-001-3, AC-006-1 |
| TRD-024 | Implement `WorkRequest.handle_command/2` for `work.execution_complete`, `work.execution_fail`, and `work.cancel`, including the run-binding integrity check (payload `run_id` must equal the bound `run_id`) modeled on `Task.require_run_matches_bound/2`, and idempotent no-op on an already-terminal work request | 4h | TRD-023 | REQ-003, REQ-005 | AC-003-3, AC-005-1, AC-005-2, AC-005-3 |
| TRD-025 | Implement `ForemanServer.Work.Submission.prepare/1`: derive `submission_id`, compute `run_id = Identity.run_id(work_id, submission_id)`, load the manifest via `Catalog.load(workflow <> ".yaml")`, stamp `index` and `phase_id` on each phase, and build `workflow_snapshot` with the `input` block; return `{:error, {:workflow_load_failed, name, reason}}` carrying the Interpreter's verbatim message | 5h | TRD-020 | REQ-001, REQ-006 | AC-001-2, AC-006-1, AC-006-2 |
| TRD-026 | Implement `ForemanServer.Work.RunPayload` with `from_task_projection/1` and `from_work_projection/1` returning the identical 7-key admission payload (`run_id`, `task_id`, `project_id`, `approval_id`, `workflow_snapshot`, `phase_specs`, `source`); refactor `Dispatcher.handle_task_dispatched/2` to build its payload through `from_task_projection/1` | 4h | TRD-025 | REQ-003 | AC-003-1, AC-003-2 |
| TRD-027 | Add `work.submit` and `work.cancel` to `CommandGateway.@allowed_operator_types` (total 9); add `validate_aggregate_id/1` clauses requiring `work_id` and a canonical `work:<id>` stream match; validate project exists and is not archived, reusing the `task.create` project gate | 4h | TRD-023 | REQ-001, REQ-002 | AC-001-5, AC-002-1 |
| TRD-028 | Add the `enrich_operator_command/1` clause for `work.submit`: call `Work.Submission.prepare/1`, attach `submission_id`/`run_id`/`workflow_snapshot`, and reject client-supplied `submission_id`, `run_id`, and `workflow_snapshot` as reserved fields, mirroring `@reserved_approval_fields`; short-circuit idempotently when the projection already carries the incoming `command_id` as its `submission_id` | 5h | TRD-025, TRD-027 | REQ-001 | AC-001-2, AC-001-4 |
| TRD-029 | Register the four `Work*` events in `event_codec.ex`; add the `work:` stream prefix to `CommandRouter.aggregate_module_for/1`; extend `CommandController.@allowed_types` to the same 9 types and add a test asserting the controller and gateway lists are equal | 3h | TRD-027 | REQ-002 | AC-002-1, AC-002-2 |
| TRD-030 | Add a `work` projection to `ProjectionStore` folding the four `Work*` events, exposing `work_projection/1` and `list_work/0`; join against the `run_slots` projection to compute `queue_position` for queued submissions | 4h | TRD-029, TRD-013 | REQ-004 | AC-004-1, AC-004-2, AC-004-3 |
| TRD-031 | Add `Workflow.Dispatcher.handle_work_submitted/2` subscribing to `WorkSubmitted`: build the payload via `Work.RunPayload.from_work_projection/1`, call `RunAdmission.start/2`, and start the supervisor on admission; handle both `{:ok, :queued}` and `{:ok, :slot_queued}` by starting nothing | 4h | TRD-026, TRD-030, TRD-006 | REQ-001, REQ-003 | AC-001-1, AC-003-1 |
| TRD-032 | Branch `RunExecutor.maybe_claim_task/1`, `maybe_complete_task/1`, and `maybe_fail_task/4` on `state.source`: for `:work_request`, invoke no `TaskProvider` callback and dispatch `work.execution_complete` / `work.execution_fail` against `work:<work_id>`; for `:task`, behaviour is unchanged | 5h | TRD-024, TRD-031 | REQ-003 | AC-003-3, AC-003-4 |
| TRD-033 | Add `ForemanServerWeb.WorkController` and route `GET /api/work/:id` under `:api`, returning the work projection with `404 {"error": "work_not_found"}` on miss, mirroring `TaskController.show/2`; extend `CommandController.serialize/1` to surface `work_id`, `run_id`, and `admission` for `work.submit` results | 3h | TRD-030 | REQ-002, REQ-004 | AC-002-3, AC-004-1 |
| TRD-022-TEST | WorkRequest aggregate tests: each event folds correctly; the status machine rejects illegal transitions; a terminal work request rejects further execution commands | 3h | TRD-022 [verifies TRD-022] | REQ-001, REQ-004 | AC-001-1, AC-004-1 |
| TRD-023-TEST | Submit-command tests: a valid submit emits exactly one `WorkSubmitted`; a blank/absent/non-binary prompt is rejected with `{:invalid_envelope, :missing_prompt}` and appends nothing; the prompt on the event is byte-identical to the input including embedded newlines | 3h | TRD-023 [verifies TRD-023] | REQ-001, REQ-006 | AC-001-3, AC-006-1 |
| TRD-024-TEST | Lifecycle-command tests: run-binding mismatch is rejected; double completion is idempotent; cancelling a queued request removes its waiter and starts no run; cancelling a running request delegates to `run.cancel`; cancelling a terminal request is a no-op returning the existing status | 4h | TRD-024 [verifies TRD-024] | REQ-003, REQ-005 | AC-003-3, AC-005-1, AC-005-2, AC-005-3 |
| TRD-025-TEST | Submission tests: an unknown workflow name returns `{:workflow_load_failed, name, reason}` with the Interpreter's message before any event is appended; `run_id` is deterministic for a fixed `(work_id, submission_id)`; the frozen snapshot is unaffected by a subsequent manifest edit | 3h | TRD-025 [verifies TRD-025] | REQ-001, REQ-006 | AC-001-2, AC-006-2 |
| TRD-026-TEST | Payload-parity test: `from_task_projection/1` and `from_work_projection/1` return maps with identical key sets and compatible value types; an architecture test asserts no module outside `Work.RunPayload` constructs the admission payload inline | 3h | TRD-026 [verifies TRD-026] | REQ-003 | AC-003-1, AC-003-2 |
| TRD-028-TEST | Gateway enrichment tests: client-supplied `run_id`/`workflow_snapshot`/`submission_id` are rejected as reserved; a duplicate `command_id` yields one event and returns the original ids; an archived or absent project is rejected before any append | 4h | TRD-028 [verifies TRD-028] | REQ-001 | AC-001-4, AC-001-5 |
| TRD-031-TEST | End-to-end ingress test: `work.submit` through `dispatch_operator/2` results in a running executor with no `Task*` event anywhere in the store; at capacity, the same submit results in `admission: "queued"` and a waiter entry | 4h | TRD-031 [verifies TRD-031] | REQ-001, REQ-003 | AC-001-1, AC-003-1 |
| TRD-032-TEST | Source-branch tests: a work-sourced run dispatches `work.execution_complete` and no `task.execution_complete`; no `TaskProvider` callback is invoked for a work-sourced run, asserted with a strict Mox expectation of zero calls; a task-sourced run's behaviour is unchanged | 4h | TRD-032 [verifies TRD-032] | REQ-003 | AC-003-3, AC-003-4 |
| TRD-033-TEST | HTTP tests: `GET /api/work/:id` returns the projection and 404 on miss; `POST /api/commands` with `work.submit` returns `work_id`, `run_id`, and `admission` | 2h | TRD-033 [verifies TRD-033] | REQ-002, REQ-004 | AC-002-3, AC-004-1 |

### PR 4: MCP Server and Auth Wiring

**Shippable State:** An MCP server is reachable over stdio and over Streamable HTTP at the configured mount path, advertising submit, observe, cancel, queue-status, and project-read tools with JSON Schemas. Every mutation routes through `CommandGateway.dispatch_operator/2`; `dispatch_system/2` is unreachable from MCP code, enforced structurally. Bearer auth is wired for real: `FOREMAN_API_TOKEN` maps to `:api_bearer_token` through the secret provider, and the MCP server refuses to start without it unless local insecure mode is explicit.

| id | task | est. | deps | satisfies | validates |
|---|---|---|---|---|---|
| TRD-034 | Map `FOREMAN_API_TOKEN` → `:api_bearer_token` in `ForemanServer.ConfigProviders.Secrets` alongside the existing `EVENTSTORE_URL` / `DATABASE_URL` / `DATABASE_PASSWORD` / `SECRET_KEY_BASE` / `SIGNING_SALT` mappings; document in `README.md` that the API is unauthenticated until this is set | 2h | — | REQ-018 | AC-018-1 |
| TRD-035 | Implement `ForemanServer.MCP.Auth` as the shared verifier for both transports: constant-time token comparison, fail-closed when `:api_bearer_token` is unset unless `allow_insecure_local: true`, and a guarantee that neither the token nor tool arguments reach Logger or telemetry metadata | 4h | TRD-034 | REQ-018 | AC-018-2, AC-018-3 |
| TRD-036 | Add `{:anubis_mcp, "~> 1.10"}` to `mix.exs`; add `config :foreman_server, :mcp, enabled: false, mount: "/mcp", allow_workflow_writes: false, allow_insecure_local: false` to `config/config.exs`; add the `ForemanServer.MCP` supervisor subtree to `application.ex`, started only when `enabled` is true | 3h | — | REQ-016, REQ-017 | AC-016-1, AC-017-2 |
| TRD-037 | Implement `ForemanServer.MCP.Policy`: default-deny tool gate, refusal of any command type outside `CommandGateway.@allowed_operator_types` before dispatch, and the `allow_workflow_writes` gate that also removes write tools from `tools/list` when disabled | 4h | TRD-036 | REQ-016, REQ-020 | AC-016-5, AC-020-1 |
| TRD-038 | Implement `ForemanServer.MCP.Tools` read tools with JSON Schemas: `foreman_work_get`, `foreman_run_get`, `foreman_queue_status`, `foreman_project_list`, `foreman_project_get`, each backed by the corresponding `ProjectionStore` query | 5h | TRD-036, TRD-030, TRD-013 | REQ-016 | AC-016-1, AC-016-4 |
| TRD-039 | Implement `foreman_work_submit` and `foreman_work_cancel` tools dispatching through `CommandGateway.dispatch_operator/2`; map gateway error tuples to MCP tool errors carrying the structured reason, never to transport-level JSON-RPC errors | 5h | TRD-038, TRD-028 | REQ-016 | AC-016-2, AC-016-3 |
| TRD-040 | Implement `ForemanServerWeb.MCPRouter`: a dedicated `:mcp` pipeline (`:accepts json` + `MCP.Auth` plug) and a `/mcp` scope mounted outside the `:api` scope so it does not inherit `Plugs.BearerAuth`'s permissive-when-unset behaviour | 4h | TRD-035, TRD-039 | REQ-017 | AC-017-2 |
| TRD-041 | Implement `ForemanServer.MCP.Stdio` and a `mix foreman.mcp.stdio` entrypoint: JSON-RPC 2.0 framing on stdin/stdout, all diagnostics routed to Logger's stderr backend so stdout carries protocol bytes only, auth verified at `initialize` and again before each tool call | 5h | TRD-035, TRD-039 | REQ-017 | AC-017-1, AC-017-3 |
| TRD-042 | Emit the four `[:foreman_server, :mcp, :*]` and `[:foreman_server, :work, :*]` telemetry events per §2.2.5, with an explicit whitelist ensuring prompt bodies, tool arguments, and tokens are never included in metadata | 3h | TRD-039 | REQ-018 | AC-018-3 |
| TRD-035-TEST | Auth tests: absent, malformed, and wrong tokens are each rejected before dispatch; the server refuses to start with no token configured; `allow_insecure_local: true` permits startup; a capture test asserts neither token nor arguments appear in any Logger or telemetry output | 4h | TRD-035 [verifies TRD-035] | REQ-018 | AC-018-2, AC-018-3 |
| TRD-037-TEST | Policy tests: a tool not in the enabled set is refused and absent from `tools/list`; a dispatch attempt for a non-allow-listed command type is refused before `CommandGateway` is reached; an architecture test scans `lib/foreman_server/mcp/` and fails on any reference to `dispatch_system` | 4h | TRD-037 [verifies TRD-037] | REQ-016 | AC-016-5 |
| TRD-039-TEST | Tool tests: `tools/list` advertises the seven required tools with valid JSON Schemas; `foreman_work_submit` returns `work_id`/`run_id`/`admission`; a domain validation failure surfaces as an MCP tool error, not a JSON-RPC error; `foreman_queue_status` returns capacity, running, and ordered waiters | 5h | TRD-039 [verifies TRD-039] | REQ-016 | AC-016-1, AC-016-2, AC-016-3, AC-016-4 |
| TRD-041-TEST | Transport tests: a stdio session completes `initialize` and a tool call with clean stdout framing and no diagnostic bytes on stdout; an HTTP session completes the same flow bearer-authenticated; both expose an identical tool set | 4h | TRD-041 [verifies TRD-041] | REQ-017 | AC-017-1, AC-017-2, AC-017-3 |

### PR 5: Workflow Catalog Management and Task Pruning

**Shippable State:** MCP clients can list, read, and validate workflows, and — when writes are explicitly enabled — add, edit, and remove them. Manifests are emitted by a canonical serializer restricted to the exact YAML subset `Workflow.Interpreter` parses, validated before any filesystem move, and installed by atomic rename. The five Task command handlers with zero production dispatch sites are removed from the write path while every `apply_event/2` clause and codec entry is retained, so historical streams stay decodable.

| id | task | est. | deps | satisfies | validates |
|---|---|---|---|---|---|
| TRD-043 | Implement `foreman_workflow_list` and `foreman_workflow_get` tools over `Catalog.manifests/0`, `Catalog.load/1`, and `Catalog.read_prompt/1`, returning name, description, digest, phase count, manifest path, resolved phases, and the body of each referenced prompt file | 4h | TRD-038 | REQ-019 | AC-019-1, AC-019-2 |
| TRD-044 | Implement `foreman_workflow_validate` running a candidate manifest body through `Interpreter.load/1` against a temp file outside the catalog root, returning `valid: true` or the Interpreter's verbatim message, and guaranteeing the catalog root is byte-identical afterwards | 3h | TRD-043 | REQ-019 | AC-019-3 |
| TRD-045 | Implement `ForemanServer.Workflow.ManifestWriter`: canonical serializer emitting only Interpreter-parseable constructs (top-level scalars, `phases:` at indent 0, entries at indent 2, properties at indent 4, single-level nested maps at indent 6); reject any input requiring an unsupported construct with a message naming it | 5h | — | REQ-021 | AC-021-1, AC-021-3 |
| TRD-046 | Implement `ForemanServer.Workflow.CatalogWriter`: containment check against `Catalog.root/0`, rejection of any filename containing a path separator or `..` segment, `name:`-matches-filename-stem check, write to a temp file inside the root, atomic `File.rename/2` into place | 4h | TRD-045 | REQ-020 | AC-020-2, AC-020-3, AC-020-4 |
| TRD-047 | Implement `foreman_workflow_put` and `foreman_workflow_delete` tools behind the `allow_workflow_writes` policy gate; validate before write; report in the tool response whether the Catalog's poll has yet observed the change | 4h | TRD-046, TRD-037 | REQ-020 | AC-020-1, AC-020-5, AC-020-6 |
| TRD-048 | Implement `foreman_prompt_put` and `foreman_prompt_get` tools for `prompts/*.md` bodies under the same containment and gating rules as manifests | 3h | TRD-047 | REQ-020 | AC-020-2, AC-020-4 |
| TRD-049 | Remove `handle_command/2` clauses for `task.block`, `task.close`, `task.update`, `task.annotate`, and `task.add_dependency` from `Aggregates.Task`; retain every `apply_event/2` clause and every `event_codec.ex` entry so historical streams stay decodable | 3h | — | REQ-022 | AC-022-1, AC-022-2 |
| TRD-050 | Delete `lib/foreman_server/commands/create_task.ex`, `lib/foreman_server/commands/close_task.ex`, and `lib/foreman_server/events/task_closed.ex`; remove `ProjectionStore.list_workflow_tasks/0`; confirm by tree-wide grep that zero references remain | 2h | TRD-049 | REQ-022 | AC-022-3 |
| TRD-051 | Delete the tests that exercised the removed command handlers rather than skipping them; run the full suite and confirm the Beads reverse-sync tests (`beads_watcher`, `beads_orphan_janitor`, `beads_adapter`) are untouched and passing | 3h | TRD-050 | REQ-022 | AC-022-4 |
| TRD-043-TEST | Read-tool tests: list returns every loaded manifest with the required fields; get returns resolved phases plus prompt bodies; a request for an absent workflow returns a structured not-found error | 2h | TRD-043 [verifies TRD-043] | REQ-019 | AC-019-1, AC-019-2 |
| TRD-044-TEST | Validate-tool tests: a well-formed manifest returns `valid: true`; each of the fourteen Interpreter rejection conditions returns the corresponding verbatim message; a digest of the catalog root is unchanged after a failed validation | 3h | TRD-044 [verifies TRD-044] | REQ-019 | AC-019-3 |
| TRD-045-TEST | Serializer property test: for generated manifests over every field the Interpreter recognises, serialize then `Interpreter.load/1` and assert a lossless round trip; assert unsupported constructs (block scalars, anchors, flow sequences, nesting beyond indent 6) are rejected by name | 5h | TRD-045 [verifies TRD-045] | REQ-021 | AC-021-1, AC-021-2, AC-021-3 |
| TRD-047-TEST | Write-tool tests: writes are refused and unadvertised when the gate is off; a failed validation leaves the catalog byte-identical; a `name:`/stem mismatch is rejected; path separators and `..` are rejected before any filesystem call; a written manifest is loaded within the poll interval; deleting a manifest does not affect a run already executing against it | 5h | TRD-047 [verifies TRD-047] | REQ-020 | AC-020-1, AC-020-2, AC-020-3, AC-020-4, AC-020-5, AC-020-6 |
| TRD-049-TEST | Pruning tests: each removed command type returns an unhandled-command error; a stream containing historical `TaskUpdated`, `TaskAnnotated`, and `TaskDependencyAdded` events still replays to the correct state, proving the read path survived | 3h | TRD-049 [verifies TRD-049] | REQ-022 | AC-022-1, AC-022-2 |

---

## 4. Sprint Planning

This section is informational only. `implement-trd-beads` does not parse it.

### Sprint 1: Global Run-Slot Admission (PR 1)

**Goal:** "Three in parallel, queue the rest" works for the existing Task path, durably and with automatic drain. The silent-drop bug is closed. No new ingress exists yet.

**Capacity:** 53h implementation + 42h test = 95h. Roughly two weeks for one engineer. TRD-007-TEST (the Decision-3 property test, 6h) is the single largest item and the one most worth pairing on.

### Sprint 2: Prompt Channel (PR 2)

**Goal:** A caller-supplied prompt can reach an agent. The freeze-time strict renderer knows `input.*` and fires for snapshots without an `implementation` block. Every existing `implement-trd` manifest is proven byte-identical via the pinned fixture.

**Capacity:** 16h implementation + 10h test = 26h. Roughly three days.

### Sprint 3: WorkRequest Ingress (PR 3)

**Goal:** `work.submit` mints runs directly. The full path — submit through executing agent with the submitted prompt — closes at the end of this sprint.

**Capacity:** 50h implementation + 30h test = 80h. Roughly two weeks.

### Sprint 4: MCP Server (PR 4)

**Goal:** Agentic clients reach Foreman over MCP on both transports, authenticated for real.

**Capacity:** 35h implementation + 17h test = 52h. Roughly a week and a half.

### Sprint 5: Workflow Management and Pruning (PR 5)

**Goal:** Workflows are manageable over MCP with safe writes. Dead Task surface is gone.

**Capacity:** 31h implementation + 18h test = 49h. Roughly a week and a half.

The plan assumes one engineer. PR 1 and PR 2 are independent of each other and can be parallelized across two engineers; PR 3 depends on both. Cumulative estimate is 302 hours across five sprints.

---

## 5. Acceptance Criteria Traceability

| Requirement | ACs | Covering tasks |
|---|---|---|
| REQ-001 | AC-001-1..5 | TRD-022, TRD-023, TRD-025, TRD-027, TRD-028, TRD-031 + tests |
| REQ-002 | AC-002-1..3 | TRD-027, TRD-029, TRD-033 + tests |
| REQ-003 | AC-003-1..4 | TRD-024, TRD-026, TRD-031, TRD-032 + tests |
| REQ-004 | AC-004-1..3 | TRD-022, TRD-030, TRD-033 + tests |
| REQ-005 | AC-005-1..3 | TRD-024 + TRD-024-TEST |
| REQ-006 | AC-006-1..3 | TRD-017, TRD-023, TRD-025 + tests |
| REQ-007 | AC-007-1..3 | TRD-017 + TRD-017-TEST |
| REQ-008 | AC-008-1..5 | TRD-018, TRD-019, TRD-020 + TRD-019-TEST |
| REQ-009 | AC-009-1..2 | TRD-021 + TRD-021-TEST |
| REQ-010 | AC-010-1..5 | TRD-001, TRD-002, TRD-005, TRD-006 + tests + TRD-005-TEST |
| REQ-011 | AC-011-1..4 | TRD-001, TRD-003, TRD-004, TRD-012 + tests + TRD-004-TEST |
| REQ-012 | AC-012-1..4 | TRD-003, TRD-008, TRD-009, TRD-010, TRD-011 + tests + TRD-009-TEST |
| REQ-013 | AC-013-1..4 | TRD-006, TRD-007 + TRD-007-TEST |
| REQ-014 | AC-014-1..2 | TRD-013, TRD-014, TRD-016 + tests + TRD-014-TEST, TRD-016-TEST |
| REQ-015 | AC-015-1..2 | TRD-015 + TRD-015-TEST |
| REQ-016 | AC-016-1..5 | TRD-036, TRD-037, TRD-038, TRD-039 + tests |
| REQ-017 | AC-017-1..3 | TRD-036, TRD-040, TRD-041 + TRD-041-TEST |
| REQ-018 | AC-018-1..3 | TRD-034, TRD-035, TRD-042 + TRD-035-TEST |
| REQ-019 | AC-019-1..3 | TRD-043, TRD-044 + tests |
| REQ-020 | AC-020-1..6 | TRD-046, TRD-047, TRD-048, TRD-037 + TRD-047-TEST |
| REQ-021 | AC-021-1..3 | TRD-045 + TRD-045-TEST |
| REQ-022 | AC-022-1..4 | TRD-049, TRD-050, TRD-051 + TRD-049-TEST |

---

## 6. Traceability Validation

### 6.1 Coverage Summary

- Requirements covered: 22/22 (100%). Every REQ has at least one implementation task and at least one test task.
- Acceptance criteria covered: 78 PRD ACs plus 1 TRD-refinement AC (AC-010-5, capacity reduction), all referenced in `validates` cells. No PRD-only ACs.
- Implementation tasks: 51. Test tasks: 37. Total: 88. All IDs unique.
- Dependency orphans: 0. Every ID referenced in a `deps` cell exists and appears in a table above its first use, so the tables are safe to parse in document order.
- Circular dependencies: none. Longest chain is 9 edges: `TRD-001 → TRD-002 → TRD-003 → TRD-004 → TRD-013 → TRD-030 → TRD-038 → TRD-039 → TRD-041 → TRD-041-TEST`, running from the slot aggregate through the work projection into the MCP transports. The one cross-PR dependency outside that spine is `TRD-020 → TRD-025`, crossing PR 2 into PR 3.

### 6.2 Estimate Review

All 88 tasks fall within a 1–6h band; none exceeds the 8h breakdown threshold. Implementation totals 185h and tests 117h, for 302h. The largest items are TRD-007-TEST (6h, the concurrency property test), then a cluster at 5h: TRD-006 (admission gate insertion), TRD-045-TEST (serializer property test), TRD-047-TEST (six-AC write-safety suite), TRD-019-TEST (five-AC freeze-time rendering suite), TRD-039-TEST, and TRD-041 (stdio transport). Each is a coherent single unit rather than a bundle.

### 6.3 Design Readiness Gate Score

| Dimension | Score | Notes |
|---|---:|---|
| Architecture Completeness | 5 | All 13 new modules, 3 new web modules, 15 changed modules, and 3 deletions are named and scoped. Data flow is explicit for admission, drain, and the prompt path. The set of modules deliberately **not** changed is enumerated with the verification that justifies each — `pr_gate.ex`, `pr_associate.ex`, `pr_association.ex`, and `stuck_detector.ex` contain no task references, and `Project.active_run_reservations` is keyed by `run_id`. |
| Task Coverage | 5 | Every REQ has at least one implementation task and at least one test task. Every AC appears in a `validates` cell. |
| Dependency Clarity | 4 | All dependencies explicit and acyclic. The one cross-PR dependency (`TRD-020 → TRD-025`) is called out; PR 3 cannot start before PR 2's prompt-argument builder exists. |
| Estimate Confidence | 4 | Estimates follow the shape of the completed `TRD-2026-48f7b420` slice, which landed 63 tasks against a similar band. The MCP transport tasks (TRD-040, TRD-041) carry the most uncertainty because they depend on an external library's ergonomics; if `anubis_mcp` is rejected in dependency review, add ~16h for hand-rolled JSON-RPC framing. |

**Overall score: 4.4 — PASS.** The TRD is ready for implementation.

### 6.4 Identified Coverage Issues

1. **REQ-013 is the requirement most likely to be wrong in practice.** Two independent event-sourced gates interacting under concurrency is exactly where example-based tests give false confidence. TRD-007-TEST is specified as a property test over generated interleavings for that reason, and it is the task to review most carefully.
2. **TRD-019 widens a trigger condition on a renderer whose output is immutable.** Making `render_strict_fields/1` fire for `input`-only snapshots means manifests that previously passed through untouched will now be rewritten at freeze time — `plan.yaml` is the concrete case. If any of those manifests contain a brace sequence that is not intended as a token, it will still pass through, because the renderer is a literal allow-list rather than a regex. But the blast radius is the event store, not a retryable execution, so TRD-018's fixture should be reviewed before TRD-019 merges rather than alongside it.
3. **PR 5's Task pruning is the lowest value-to-risk task in the stack.** It can be dropped entirely without affecting any other requirement. It is included because five unreachable command handlers actively mislead the next reader of `aggregates/task.ex`.
4. **Capacity reduction below the current holder count — resolved.** The intended behaviour (existing holders run to completion; no new admission until count ≤ capacity) is now pinned by AC-010-5, verified by the capacity-reduction clauses added to TRD-002-TEST.
5. **`Aggregates.ProjectRunLimit` is left inert rather than deleted.** It is a complete, never-invoked duplicate of the concept this slice implements globally, and leaving it in place means two aggregates appear to own run limits. Removing it is a one-task follow-up, deliberately excluded to keep this diff focused.
6. **TRD-025 `[deps: TRD-020]` is on the PR 3 critical path (Decision 2) and cannot be moved to PR 2.** If TRD-025 were moved to PR 2, PR 2 would consist only of TRD-025 and TRD-026 — leaving nothing that PR 2 was designed to deliver. The cross-PR dependency is documented here so it is not a merge-time surprise; it does not require any action before PR 3 opens.

---

## 7. Next Steps

The TRD is saved at `docs/TRD/TRD-2026-0eac69b3-foreman-mcp-work-ingress-and-global-run-slot-queue.md`. Suggested follow-ups:

1. `/ensemble:configure-team docs/TRD/TRD-2026-0eac69b3-foreman-mcp-work-ingress-and-global-run-slot-queue.md`
2. `/ensemble:implement-trd-beads docs/TRD/TRD-2026-0eac69b3-foreman-mcp-work-ingress-and-global-run-slot-queue.md`

Consider shipping PR 1 on its own first. It is independently valuable — it closes the silent-drop bug and delivers the concurrency requirement — and it is the PR whose design is most load-bearing for everything after it.

---

## 8. Changelog

### v1.0.0 — 2026-08-15 (initial TRD)

Derived from `PRD-2026-0eac69b3` v1.0.0. Closes the MCP protocol-library decision that `TRD-2026-e8d3f5f2` left open, in favour of `anubis_mcp` with a documented hand-rolled fallback. Supersedes that TRD's work-submission and workflow-management scope; its Bucket A inventory is stale by two command types (`task.retry`, `run.cancel`) and this slice adds two more (`work.submit`, `work.cancel`), bringing `@allowed_operator_types` to 9.

An adversarial verification pass against the source corrected the PR 2 design before this document was issued. The original draft proposed rendering `command:` phases at run time inside `RunExecutor`, on the premise that command strings reach the agent adapter unexpanded. That premise was wrong: `CommandGateway.render_strict_fields/1` → `render_command/2` already renders them at snapshot-freeze time, for two literal tokens, and skips entirely when the snapshot has no `implementation` block. PR 2 now extends that existing renderer instead of adding a second one — which removes the `RunExecutor` command-path change entirely and additionally fixes the `plan.yaml` no-rendering gap that the original framing would have missed.
### v1.0.1 — 2026-08-15 (refinement)

Refinement pass adds five missing test tasks to PR 1: TRD-004-TEST (codec/routing), TRD-005-TEST (config accessor), TRD-009-TEST (terminal fan-out), TRD-014-TEST (telemetry), TRD-016-TEST (queue endpoint). Fixes State struct violations in §2.2.1 table (`RunSlots.State`, `WorkRequest.State`). Adds cross-PR dependency note to §6.4 explaining why TRD-020 → TRD-025 cannot be reordered. Adds AC-010-5 (capacity reduction below holder count) pinned by TRD-002 and verified by TRD-002-TEST capacity-reduction clauses. Resolves Finding 4. Frontmatter: `total_tasks 83→88`, `total_acceptance_criteria 78→79`, version `1.0.0→1.0.1`.
