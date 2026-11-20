---
Document ID: TRD-2026-b9e27ab5
Label: trd-per-project-queues
prd_reference: docs/PRD/PRD-2026-b9e27ab5-per-project-dispatch-queues.md
Version: 1.0.2
Status: Draft
Date: 2026-11-19
Design Readiness Score: 4.5 (PASS, self-scored; was 4.25 at create-trd)
kind: trd
test_approach: standard
Constitution compliance: passed
ensemble_implement_trd_beads:
  branch_name: dispatch-queue
  use_proposed: false
  stacked_prs: false
---

# TRD: Per-project dispatch queues (retire the global run-slot queue)

> Source PRD: `docs/PRD/PRD-2026-b9e27ab5-per-project-dispatch-queues.md` (Locked, v1.0.1,
> readiness 4.75, refine changelog present, 18 requirements). The PRD was named by the
> operator's conversation, not chosen by recency or glob. No `FOREMAN_*` variables were set.
>
> **Test approach: `standard`, not the resolver's BDD default.** `resolve-bdd` returned
> `enabled` from its default (source `default`). Foreman is an Elixir/ExUnit codebase and
> Reqnroll is .NET, so routing `-TEST` tasks through it cannot work here; the repository's
> earlier TRDs carry no BDD mention either. Test tasks therefore use ExUnit with one
> `Scenario:` item per acceptance criterion.
>
> **Architecture alternatives:** the choice was not put to the operator because two of the
> three options violate a PRD requirement (see Architecture Decision); Option B is selected
> and the choice is logged here.

## Summary

Run admission is gated twice today: a global gate (`run_slots:global`, capacity 3 across
every project) and then a per-project reservation. This TRD replaces the global stream with
**one run-slot stream per project (`run_slots:<project_id>`)** whose capacity is the
project's `max_concurrent_runs` setting (default 3). The existing slot mechanics (acquire,
durable FIFO waiters, promote on release, boot and backstop reconciliation) are reused
unchanged in shape; only the stream key, the capacity source, the promotion rule and the
consumers change. The global stream is never written again; a boot-time step carries its
holders and waiters over.

## Findings that change the PRD's picture (verified in source 2026-11-19)

1. **Deferral is not a queue today.** A task refused for `run_limit_exceeded` stays
   `in_progress` with a run id and no run. `ProjectionStore.deferred_task_ids/2` iterates
   `state.tasks` (a map, so task-id order, not arrival order) and the Dispatcher re-admits
   all of them whenever capacity frees. That cannot satisfy REQ-005 (FIFO, durable position,
   wait time). The slot aggregate's waiter list can.
2. **The project run limit counts paused runs; the slot gate does not.** A paused run
   releases its global slot (`terminate_slot` on `RunPaused`) but keeps its project
   reservation until it is terminal. The pre-gate `Project.run_limit_refusal/2` therefore
   counts paused runs. Under this design the slot stream is the only concurrency authority
   and a slot means "running" (PRD wording). Consequence: a paused run frees a slot, and on
   resume it re-acquires one and may wait (this is today's behaviour for the global slot).
   `active_runs` in the limits block keeps counting reservations; new `running_runs` and
   `waiting_runs` fields are added beside it.
3. **Order is currently wrong in the pre-gate.** `RunAdmission` consults the project limit
   *before* the slot (so a refused run never holds a slot). With a per-project slot stream
   the run limit must move *into* the slot gate or over-limit runs would be deferred (no
   FIFO) instead of queued. `Project.run_limit_refusal/2` and the `reject_at_run_limit`
   check inside `project.reserve_run` are removed. Paused-project and daily-cap refusals
   stay in front of the slot gate for the original reason (a refused run must not hold a
   slot). **Archived** is added to that pre-gate: `reserve_run` already rejects archived
   projects, and after this change that rejection would fire *after* a slot was acquired
   and leak it.
4. **Slot timestamps are monotonic.** `do_acquire/3` stamps `System.monotonic_time/1`, which
   is not comparable across a restart, so a wait time cannot be derived from it. New events
   stamp `System.system_time(:millisecond)` in the same fields (ordering uses list position,
   never the value), so no schema change is needed.
5. **Jobsites are untouched.** They never used run slots (their own `max_concurrent_jobsites`
   count); PRD REQ-004 is Won't.
6. **No project-delete command exists** (`project.archive`, `project.reactivate` and
   `project.adopt` do). PRD AC-017-2 ("deleted project drops its waiting runs") has nothing
   to attach to today. This TRD does not invent a delete; it records the gap for the next
   PRD refinement and gives the future delete one function to call (`RunSlots.drop_project/1`,
   TRD-006).
7. **Setting validation already exists.** `max_concurrent_runs` is validated 1..1000 in the
   project settings; REQ-016 is a verification task, not a new rule.
8. **`Aggregates.ProjectRunLimit`** (hardcoded 100) has no caller in `lib/`. It is dead code;
   this TRD leaves it alone and does not depend on it.

9. **A queued run has no run projection, and boot reconciliation treats that as "absent".**
   `reconcile_run_slots_stream` removes a waiter when `ProjectionStore.run/1` is `nil`, which is
   true of every queued run. Combined with the deterministic acquire command id, a restart
   strands queued runs forever (`:slot_state_unknown`; kata `teak`, P1). The design rebuilds
   this code per project, so the defect is fixed here (TRD-018) and TRD-009's migration must
   not repeat it.
10. **Overlap with the jobsite retirement** (kata `5z8s` and its PR issues, in another
    worktree). It folds jobsites and PR-fix threads into runs, so they will use these
    per-project slots with no extra work, and its PR7 deletes `Jobsite.*`. Both efforts edit
    `workflow/dispatcher.ex`, `run_admission.ex` and the docs, so expect rebase work in the
    second to merge. The "jobsites unchanged" guard test was dropped for that reason.

## Architecture Decision

### Options considered

| | A: Deferral only | B: Per-project slot stream (selected) | C: Queue inside the Project aggregate |
|---|---|---|---|
| Idea | Delete the global gate; rely on the project reservation limit and the deferred-task re-admission | Key the existing slot aggregate by project; capacity = project limit | Add waiters/holders to `project:<id>` state |
| FIFO + durable position (REQ-005) | No (map order) | Yes (waiter list is event-sourced) | Yes |
| Wait time and position (REQ-010) | No | Yes | Yes |
| Reuses proven code | Most | All of RunSlots, reconcilers, promotion | Little |
| Risk | Violates REQ-005/REQ-010 | Many consumers touched (mechanical) | Grows the busiest aggregate; serialises queueing with every project command |
| Complexity | Low | Medium | High |

**Selected: Option B.** It is the only option that meets REQ-005 and REQ-010 with the
smallest new surface, and it keeps the CQRS rules (the aggregate decides, `CommandRouter`
appends, the projection reads).

### Key decisions

1. **Stream key `run_slots:<project_id>`**, built by one function
   `ForemanServer.Aggregates.RunSlots.stream_id/1`. `CommandRouter.aggregate_module_for/1`
   already maps the `run_slots:` prefix, so routing is unchanged. The literal
   `"run_slots:global"` appears in no production code after TRD-010.
2. **Capacity comes from the project, at dispatch time**, as
   `Project.effective_run_limit/1` (setting, else `max_concurrent_runs_per_project`, now
   default 3), and is recorded on the event, never read during replay (the aggregate's
   existing replay-determinism contract, REQ-013).
3. **Release promotes only while holders < capacity.** Today a release with waiters always
   transfers. Lowering a limit below the running count must not start a waiter (AC-003-4),
   so `do_release` transfers only when `map_size(holders) - 1 < capacity`; otherwise it plain
   releases and the head waiter stays queued.
4. **No new event types.** Constitution rule 5 asks new event names to end in `Event`; the
   slot family does not, and a one-off suffixed sibling would be worse than reuse. Two
   behaviours are expressed through existing events with optional keys:
   - *Raising a limit / adopting* uses `RunSlotAcquired`. Its fold additionally drops the
     run from `waiters` (a run that was never a waiter makes that a no-op, so legacy
     replay is unchanged). An optional `promoted: true` marks an acquisition that happened
     from the queue so the Dispatcher can start the run.
   - Every `RunSlot*` event gains an **optional** `project_id` (not in `@enforce_keys`, per
     the EventCodec rule) so the projection can fold per project. Legacy events lack it and
     fold into nothing.
5. **Two new system commands** on the slot aggregate, never operator-allowlisted:
   `run_slots.promote` (emit one `RunSlotAcquired{promoted: true}` for the head waiter
   when `holders < capacity`, else `{:ok, nil}`) and a payload flag on `run_slots.acquire`,
   `enqueue_only: true` (queue even when capacity is free; used only by migration).
   `run_slots.adopt` is `acquire` with `force: true`: record a holder regardless of
   capacity (used only by migration, so existing runs are never stopped).
6. **The slot stream is the only concurrency authority.** The Project aggregate keeps its
   reservation bookkeeping (archive guard, same-implementation single flight, daily cap) but
   no longer enforces a run ceiling.

### Process layering (unchanged)

```
CommandRouter -> Aggregator -> Actor (run_slots:<project_id>)   one actor per project, :permanent
RunAdmission.start/resume  -> acquire (per project)
Dispatcher                 -> release on terminal/pause; re-admit on RunSlotTransferred / RunSlotAcquired{promoted}
                              and on ProjectUpdated/ProjectReactivated (rebalance)
RunLifecycleReconciler     -> backstop sweep over every project stream
BootReconciliation         -> orphan scan over every project stream + legacy migration
ProjectionStore            -> run_slots: %{project_id => %{capacity, holders, waiters}}
```

Per-project actors give the isolation the PRD asks for: one project's queue traffic
serialises only through its own mailbox.

## System Architecture

### Components

| Component | Change |
|---|---|
| `Aggregates.RunSlots` | `stream_id/1`; `acquire` takes `enqueue_only`/`force`; `release` promotes only below capacity; new `promote`; events carry `project_id`; wall-clock stamps; `drop_project/1` helper |
| `Events.RunSlot{Acquired,Queued,Released,Transferred,WaiterRemoved}` | optional `project_id`; `RunSlotAcquired` optional `promoted` |
| `RunSlots.Config` | remove `max_concurrent_runs/0`; `max_concurrent_runs_per_project/0` default 3 |
| `RunAdmission` | project-scoped stream; capacity from the project; no run-limit pre-gate; archived pre-gate |
| `Aggregates.Project` | remove `run_limit_refusal/2` and the ceiling check in `reserve_run`; `admission_refusal/2` adds archived |
| `Workflow.Dispatcher` | project-scoped release; promotion handler for both event shapes; rebalance on `ProjectUpdated`/`ProjectReactivated`; adoption handling on `ProjectSubjectAdopted` |
| `RunLifecycleReconciler`, `Workflow.BootReconciliation` | iterate project streams |
| `Workflow.RunSlotsMigration` (new, plain module) | one-shot legacy carry-over, idempotent |
| `BootReconciliation` / `RunAdmission.slot_decision` / `Dispatcher` log | queued-run waiter predicate, one re-acquire on a deduplicated miss, one error per stranded task (TRD-018) |
| `ProjectionStore` | per-project fold; `queue_status/1`; limits usage fields |
| `ProjectLimits` | no global clamp; `running_runs`, `waiting_runs` |
| `QueueController` | `project_id` required |
| Docs/config | remove the global key; boot warning; docs per PRD REQ-015 |

### Data flow

1. `Dispatcher` -> `RunAdmission.start(project_id, payload)`.
2. Project pre-gate: paused, archived, daily cap refuse (deferral, as before).
3. `run_slots.acquire` on `run_slots:<project_id>` with `capacity = effective_run_limit`.
   Free: `RunSlotAcquired`. Full: `RunSlotQueued` (FIFO position = list order).
4. Slot held: Beads-lease gate, then `run.start`, as before.
5. Terminal or paused run: `run_slots.release` (project taken from the run projection).
   Waiters and `holders - 1 < capacity`: `RunSlotTransferred`; the Dispatcher re-enters
   admission for the promoted run. Otherwise `RunSlotReleased`.
6. Limit raised (`ProjectUpdated`) or project reactivated: the Dispatcher loops
   `run_slots.promote` until it answers `{:ok, nil}`; each `RunSlotAcquired{promoted: true}`
   starts the run.

### Migration (REQ-009)

`RunSlotsMigration.run/0`, called by `BootReconciliation` in the place of the old global
orphan scan, reads the legacy stream with `Aggregate.load/2` (read only) and:

- **Holders:** for each holder whose run is live, dispatch `run_slots.acquire` with
  `force: true` to that run's project stream, command id `run-slots:adopt:<run_id>`. Holders
  of terminal or absent runs are skipped (the old backstop would have released them).
- **Waiters:** in legacy order, dispatch `run_slots.acquire` with `enqueue_only: true`,
  command id `run-slots:migrate-waiter:<run_id>`, to the waiter's project stream; then
  `promote` per project fills any free capacity, which starts the run through the normal
  promotion path. Original relative order within a project is preserved.
- Deterministic command ids make it idempotent; nothing is ever dispatched to
  `run_slots:global`, which stays on disk for replay.

### Integration points

- `ProjectionStore.apply_event_by_type` for `RunSlot*` (currently one global
  `state.run_slots`).
- `RunLifecycleReconciler` terminal path and backstop sweep.
- `Application` boot: warn on a leftover `:max_concurrent_runs` env value.
- Operator surfaces: `GET /api/queue?project_id=`, `GET /api/projects/:id/settings`
  (`limits`), `docs/cli-reference.md` `foreman project settings`.

### Threat model

This change touches no authentication, PII, payment, upload, external-network or
third-party surface, so no `## Threat Model` section is added. The one trust boundary is
unchanged: `run_slots.*` are system commands, absent from every operator allowlist
(`command_allowlist_parity_test.exs` is extended in TRD-004-TEST).

## Reused Capabilities

None. `docs/TRD` has no foundational capability TRDs (`trd-graph-cli capabilities`
returned an empty registry).

## Master Task List

Estimates are hours; tasks of 8h or more were split. Every task cites the PRD ACs it
validates. Run the narrowest test file with
`devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors <file>'`.
Test-first (constitution TDD rule): each `-TEST` task is written and seen to fail before its
implementation task.

### PR 1: Project-scoped slot aggregate (additive; nothing consumes it yet)

**Shippable State:** An operator-invisible but fully tested per-project slot aggregate exists beside the global one: two projects can each hold three slots and queue independently, a lowered limit never starts a waiter, and a raised limit promotes waiters in order. No running behaviour changes yet.

- [x] **TRD-001** Add optional `project_id` to the five `RunSlot*` event structs and optional `promoted` to `RunSlotAcquired` (none in `@enforce_keys`); add `RunSlots.stream_id/1` (`"run_slots:" <> project_id`); make `do_acquire`/`do_release` stamp `System.system_time(:millisecond)`; thread `project_id` from the command payload onto every emitted event. (3h) [satisfies REQ-001] [satisfies REQ-013]
  - Target Files: `packages/foreman_server/lib/foreman_server/events/run_slot_*.ex`, `packages/foreman_server/lib/foreman_server/aggregates/run_slots.ex`
  - Validates PRD ACs: AC-001-1, AC-013-1
  - Implementation AC:
    - Given a historical `RunSlotAcquired` without `project_id`, when decoded by `EventCodec`, then it decodes and folds exactly as before.
    - Given an acquire for project `a`, then the emitted event carries `project_id: "a"` and a wall-clock stamp.

- [x] **TRD-001-TEST** `run_slots_project_scoped_test.exs`: legacy-event decode; stream id; per-project isolation (two streams, each three holders, no interference); event stamps. (2h) [verifies TRD-001] [satisfies REQ-001] [satisfies REQ-013] [depends: TRD-001]
  - Target Files: `packages/foreman_server/test/foreman_server/aggregates/run_slots_project_scoped_test.exs`
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-013-1
  - Test AC:
    - [ ] Scenario: two projects fill independently -- Given projects A and B each acquire three runs, When all six are requested, Then all six hold slots and neither queues. (AC-001-2)
    - [ ] Scenario: a full project queues the next run -- Given project A holds three, When a fourth acquires, Then it is queued and B is unaffected. (AC-001-1)
    - [ ] Scenario: rebuild matches live state -- Given a sequence of acquire/queue/release events, When state is rebuilt from the stream, Then holders, waiters and capacity equal the live state. (AC-013-1)

- [x] **TRD-002** Change `do_release` to transfer to the head waiter only when `map_size(holders) - 1 < capacity`, else emit `RunSlotReleased`; the release command carries the effective capacity. Add the one shared builder `RunSlots.release_command(project_id, run_id, reason)` (reads the project's effective limit once, builds the `run_slots.release` envelope with a unique command id) that `RunAdmission`, `Dispatcher`, `RunLifecycleReconciler` and `BootReconciliation` all use instead of the four hand-built copies. (3h) [satisfies REQ-003] [satisfies REQ-006] [depends: TRD-001]
  - Target Files: `packages/foreman_server/lib/foreman_server/aggregates/run_slots.ex`
  - Validates PRD ACs: AC-003-4, AC-006-1, AC-006-2
  - Implementation AC:
    - Given holders above a lowered capacity and a waiter, when a holder releases, then a plain release is recorded and the waiter stays queued.
    - Given holders at capacity and a waiter, when a holder releases, then the waiter is promoted.
    - Given the four callers, when grepped, then none builds a `run_slots.release` map by hand.

- [x] **TRD-002-TEST** Release/promote cases in `run_slots_release_test.exs` (extend the existing file), plus a source-contract case that only `RunSlots.release_command/3` builds the envelope. (2h) [verifies TRD-002] [satisfies REQ-003] [satisfies REQ-006] [depends: TRD-002]
  - Target Files: `packages/foreman_server/test/foreman_server/aggregates/run_slots_release_test.exs`
  - Validates PRD ACs: AC-003-4, AC-006-1, AC-006-2
  - Test AC:
    - [ ] Scenario: lowered limit holds the queue -- Given four holders, limit lowered to two and one waiter, When two holders release, Then the waiter starts only after the holder count falls below two. (AC-003-4)
    - [ ] Scenario: a freed slot goes to the same project -- Given A and B each have a waiter, When an A run releases, Then only A's waiter is promoted. (AC-006-1)
    - [ ] Scenario: every terminal reason releases -- Given a run completes, fails, is blocked, cancelled, flagged stuck or deleted, When the dispatcher handles it, Then its slot is released. (AC-006-2)

- [x] **TRD-003** Add system command `run_slots.promote` (one `RunSlotAcquired{promoted: true}` for the head waiter when `holders < capacity`, else `{:ok, nil}`); give `RunSlotAcquired`'s fold the waiter drop; add `acquire` payload flags `enqueue_only` and `force`. (3h) [satisfies REQ-003] [satisfies REQ-005] [satisfies REQ-009] [depends: TRD-001]
  - Target Files: `packages/foreman_server/lib/foreman_server/aggregates/run_slots.ex`
  - Validates PRD ACs: AC-003-3, AC-005-1, AC-009-4
  - Implementation AC:
    - Given a waiter and free capacity, when `promote` is dispatched, then exactly one waiter is acquired in FIFO order.
    - Given `force: true`, when capacity is full, then the run is recorded as a holder.
    - Given `enqueue_only: true` and free capacity, then the run is queued, not acquired.

- [x] **TRD-003-TEST** `run_slots_promote_test.exs` including a concurrency case (two simultaneous acquires for one free slot). (3h) [verifies TRD-003] [satisfies REQ-003] [satisfies REQ-005] [satisfies REQ-007] [satisfies REQ-009] [depends: TRD-003]
  - Target Files: `packages/foreman_server/test/foreman_server/aggregates/run_slots_promote_test.exs`
  - Validates PRD ACs: AC-003-3, AC-005-1, AC-005-2, AC-007-2, AC-007-3, AC-009-4
  - Test AC:
    - [ ] Scenario: a restart keeps the queue -- Given runs waiting in a project, When the actor is killed and rebuilt from its stream, Then the waiters keep their original order with none lost or duplicated. (AC-005-2)
    - [ ] Scenario: raising a limit starts waiters -- Given three holders and two waiters, When the limit rises to five and promote runs twice, Then both waiters start in order. (AC-003-3)
    - [ ] Scenario: FIFO order -- Given waiters X, Y, Z, When slots free one at a time, Then they start X, Y, Z. (AC-005-1)
    - [ ] Scenario: exactly one winner -- Given one free slot and two simultaneous acquires, When both are processed, Then one holds and one waits. (AC-007-2)
    - [ ] Scenario: no double entry -- Given a run already queued or holding, When requested again, Then it holds at most one slot or position. (AC-007-3)
    - [ ] Scenario: existing runs are never stopped -- Given `force` adoption over capacity, When new runs request, Then they wait until the count is below the limit. (AC-009-4)

- [x] **TRD-004** Register the new command shapes: `Dispatch` allowlist is unchanged (system only); confirm `run_slots.promote` is in no operator allowlist and extend `command_allowlist_parity_test.exs`. (1h) [satisfies REQ-007] [depends: TRD-003]
  - Target Files: `packages/foreman_server/lib/foreman_server/command_gateway.ex`
  - Validates PRD ACs: AC-007-2
  - Implementation AC:
    - Given an operator `POST /api/commands` of `run_slots.promote`, then it is rejected as an unknown or forbidden type.

- [x] **TRD-004-TEST** Extend `command_allowlist_parity_test.exs` with the three `run_slots.*` types. (1h) [verifies TRD-004] [satisfies REQ-007] [depends: TRD-004]
  - Target Files: `packages/foreman_server/test/foreman_server/command_allowlist_parity_test.exs`
  - Validates PRD ACs: AC-007-2
  - Test AC:
    - [ ] Scenario: operators cannot drive slots -- Given an operator envelope for `run_slots.promote`, `run_slots.acquire` or `run_slots.release`, When posted, Then it is refused. (AC-007-2)

### PR 2: Admission, release and promotion run per project

**Shippable State:** Runs are admitted into their own project's queue: a project at its limit queues further runs in order without delaying any other project, a freed slot starts that project's next run, and a raised project limit starts waiting runs without operator action. Runs that were running or waiting under the global queue at upgrade continue or resume in their own project's queue in their original order, and nothing is written to the global stream. This PR is safe to merge on its own.

- [x] **TRD-005** `RunAdmission`: compute `capacity` from the loaded Project (`effective_run_limit/1`), target `RunSlots.stream_id(project_id)` in `acquire_slot/2`, `acquire_slot_for_resume/2`, `slot_decision/2` and `release_after_failed_slot/1` (all take `project_id`; the release goes through `RunSlots.release_command/3`); delete the `run_limit_refusal` call from `project_admission_gate/2`; add archived to the pre-gate (`Project.admission_refusal/2`); add `:run_limit_exceeded` and archived refusals to nothing compensable (they no longer occur after a slot is held). (4h) [satisfies REQ-001] [satisfies REQ-002] [satisfies REQ-007] [satisfies REQ-017] [depends: TRD-001, TRD-003]
  - Target Files: `packages/foreman_server/lib/foreman_server/run_admission.ex`, `packages/foreman_server/lib/foreman_server/aggregates/project.ex`
  - Validates PRD ACs: AC-001-1, AC-002-1, AC-007-1, AC-017-1
  - Implementation AC:
    - Given a project with no setting, when four runs are admitted, then three acquire and one is `:slot_queued`.
    - Given an archived project, when admission runs, then it is refused before any slot is touched.

- [x] **TRD-005-TEST** Rewrite `run_admission_slot_gate_test.exs` and `run_admission_project_refusal_test.exs` for per-project streams; adapt `RunSlotsReset` (`test/support/run_slots_reset.ex`) to reset every `run_slots:*` stream. (4h) [verifies TRD-005] [satisfies REQ-001] [satisfies REQ-002] [satisfies REQ-007] [satisfies REQ-017] [depends: TRD-005]
  - Target Files: `packages/foreman_server/test/foreman_server/run_admission_slot_gate_test.exs`, `packages/foreman_server/test/foreman_server/run_admission_project_refusal_test.exs`, `packages/foreman_server/test/support/run_slots_reset.ex`
  - Validates PRD ACs: AC-001-1, AC-002-1, AC-002-2, AC-003-1, AC-003-2, AC-007-1, AC-012-1, AC-012-2, AC-017-1
  - Test AC:
    - [ ] Scenario: a setting of five -- Given a project setting of 5, When six runs are submitted, Then five run and one waits. (AC-003-1)
    - [ ] Scenario: a setting of one -- Given a project setting of 1, When two runs are submitted, Then one runs and one waits. (AC-003-2)
    - [ ] Scenario: a paused project is refused as before -- Given a paused project, When a run is requested, Then it is deferred exactly as before and holds no slot. (AC-012-1)
    - [ ] Scenario: the daily cap defers as before -- Given a project at its daily thread cap, When a run is requested, Then it is deferred, holds no slot, and re-admits at UTC midnight. (AC-012-2)
    - [ ] Scenario: default of three -- Given a project with no setting, When four runs are submitted, Then three run and one waits. (AC-002-1)
    - [ ] Scenario: next waiter starts -- Given three running and one waiting, When one run finishes, Then the waiter starts. (AC-002-2)
    - [ ] Scenario: busy project does not block another -- Given project A has three running and a backlog, When B starts a run, Then B's run starts immediately. (AC-001-1)
    - [ ] Scenario: archived project holds -- Given an archived project with waiting runs, When capacity is free, Then no run starts. (AC-017-1)
    - [ ] Scenario: abnormal death frees the slot -- Given a holder whose process dies abnormally, When the backstop sweep runs, Then the slot is released and the next waiter starts. (AC-007-1)

- [x] **TRD-006** Remove the ceiling from `Project`: delete `run_limit_refusal/2` and the `reject_at_run_limit` call in `project.reserve_run` (keep `reject_paused`, daily cap, archived, implementation-key checks and the reservation map); add `RunSlots.drop_project/1` (removes every waiter of a project; the single function a future project-delete command must call). (3h) [satisfies REQ-001] [satisfies REQ-017] [depends: TRD-005]
  - Target Files: `packages/foreman_server/lib/foreman_server/aggregates/project.ex`, `packages/foreman_server/lib/foreman_server/aggregates/run_slots.ex`
  - Validates PRD ACs: AC-001-3
  - Not covered (see Known Gaps): AC-017-2. `drop_project/1` is groundwork only.
  - Implementation AC:
    - Given a project at its limit, when `project.reserve_run` is dispatched for a slot holder, then it succeeds (the slot stream already decided).
    - Given `drop_project/1`, then every waiter of that project is removed and no holder is touched.

- [x] **TRD-006-TEST** Update `project_run_limit_and_stream_gap_test.exs` and `project_limits_test.exs` for the removed ceiling; add `drop_project/1` unit cases (queue-side behaviour only; this does not validate AC-017-2). (3h) [verifies TRD-006] [satisfies REQ-001] [depends: TRD-006]
  - Target Files: `packages/foreman_server/test/foreman_server/aggregates/project_run_limit_and_stream_gap_test.exs`, `packages/foreman_server/test/foreman_server/aggregates/project_limits_test.exs`
  - Validates PRD ACs: AC-001-3
  - Test AC:
    - [ ] Scenario: queues are independent when both are full -- Given A and B at their limits, When an A run finishes, Then only A's queue advances. (AC-001-3)
    - [ ] Scenario: dropping a project's waiters (groundwork, not an AC) -- Given a project with waiters and holders, When `drop_project/1` runs, Then the waiters are removed and the holders remain. (AC-001-3)

- [x] **TRD-007** `Dispatcher`: resolve the run's project for `terminate_slot/2` (run projection, falling back to the task projection) and release on its project stream; handle `RunSlotTransferred` and `RunSlotAcquired` with `promoted: true` through `handle_slot_promoted`; on `ProjectUpdated` and `ProjectReactivated` run a `rebalance(project_id)` that loops `run_slots.promote` (capacity read from the project) until `{:ok, nil}`. The release goes through `RunSlots.release_command/3`; when the run's project cannot be resolved (legacy run, nil project) it logs a warning naming the run and does nothing, and the backstop sweep over every project stream releases the slot later. Adoption is TRD-017. (4h) [satisfies REQ-001] [satisfies REQ-003] [satisfies REQ-006] [satisfies REQ-012] [satisfies REQ-018] [depends: TRD-005, TRD-006]
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex`
  - Validates PRD ACs: AC-003-3, AC-006-1, AC-006-2, AC-012-3, AC-018-2
  - Implementation AC:
    - Given a terminal event for a run whose project cannot be resolved, then a warning is logged, no command is dispatched and the dispatcher keeps running.
    - Given a terminal event for a run of project `a`, then `run_slots.release` targets `run_slots:a` only.
    - Given a raised limit, when `ProjectUpdated` is handled, then waiting runs start up to the new limit.

- [x] **TRD-007-TEST** Extend `dispatcher_run_limit_readmission_test.exs` and add `dispatcher_slot_rebalance_test.exs`. (5h) [verifies TRD-007] [satisfies REQ-001] [satisfies REQ-003] [satisfies REQ-005] [satisfies REQ-006] [satisfies REQ-012] [satisfies REQ-018] [depends: TRD-007]
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/dispatcher_run_limit_readmission_test.exs`, `packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_rebalance_test.exs`
  - Validates PRD ACs: AC-003-3, AC-005-3, AC-006-1, AC-006-2, AC-012-3, AC-018-2
  - Test AC:
    - [ ] Scenario: a cancelled waiter is skipped -- Given X, Y, Z wait and Y is cancelled or removed, When slots free up, Then X and Z start in that order and Y never starts. (AC-005-3)
    - [ ] Scenario: a deferred task re-enters its project's queue -- Given a task deferred for a paused project, When the project resumes, Then it is admitted into that project's queue. (AC-012-3)
    - [ ] Scenario: an unresolvable project does not crash the dispatcher -- Given a terminal event for a run with no resolvable project, Then a warning is logged and later events are still handled. (AC-006-2)
    - [ ] Scenario: PR-fix thread is its own run -- Given a fix thread on a run's PR in a full project, Then it queues for its own slot. (AC-018-2)
    - [ ] Scenario: each terminal reason releases only its project -- Given runs of two projects end, Then each release targets its own stream. (AC-006-2)
    - [ ] Scenario: freed slot is same-project -- Given waiters in A and B, When an A run ends, Then only A's waiter starts. (AC-006-1)
    - [ ] Scenario: a raised setting starts waiters -- Given a limit raised from 3 to 5, Then up to two waiters start without operator action. (AC-003-3)

- [x] **TRD-008** `RunLifecycleReconciler`: `dispatch_slot_release/3` takes the run's project and uses `RunSlots.release_command/3`; `run_slots_backstop_sweep/1` iterates `ProjectionStore.list_projects/0` and loads each `run_slots:<project_id>` stream. A multi-repo run holds exactly one slot (no change needed; asserted by test). (3h) [satisfies REQ-007] [satisfies REQ-018] [depends: TRD-005]
  - Target Files: `packages/foreman_server/lib/foreman_server/run_lifecycle_reconciler.ex`
  - Validates PRD ACs: AC-007-1, AC-018-1
  - Implementation AC:
    - Given a terminal holder in any project, when the sweep runs, then its slot is released on that project's stream.

- [x] **TRD-008-TEST** Update `run_lifecycle_reconciler_slot_test.exs`; add a multi-repo-run-holds-one-slot case. (2h) [verifies TRD-008] [satisfies REQ-007] [satisfies REQ-018] [depends: TRD-008]
  - Target Files: `packages/foreman_server/test/foreman_server/run_lifecycle_reconciler_slot_test.exs`
  - Validates PRD ACs: AC-007-1, AC-018-1
  - Test AC:
    - [ ] Scenario: backstop frees a stale holder -- Given a holder whose run is terminal, When the sweep runs, Then the slot is released. (AC-007-1)
    - [ ] Scenario: one slot per run -- Given a run touching three repositories, Then it holds exactly one slot. (AC-018-1)

- [x] **TRD-017** Adoption of a waiting run (split from TRD-007). `Dispatcher` handles `ProjectSubjectAdopted` with `mode: "move"`: from the event's `moved.run_ids` and `moved.task_ids` it finds each run that is a waiter in the source project's stream (`from_project_id`), dispatches `run_slots.remove_waiter` to the source stream and `run_slots.acquire` with `enqueue_only: true` to the destination stream (command id `run-slots:adopt-waiter:<run_id>:<event id>`), then rebalances the destination. `Projects.Adoption` and the Project aggregate are not changed: they refuse an active subject, and whether a queued run counts as active is verified by the test (TRD-017-TEST), not assumed. A refused adoption emits no `ProjectSubjectAdopted`, so this handler never runs for it. (3h) [satisfies REQ-017] [depends: TRD-007, TRD-003]
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex`
  - Validates PRD ACs: AC-017-3
  - Implementation AC:
    - Given a `ProjectSubjectAdopted` event whose `moved.run_ids` contains a waiting run, when handled, then the run leaves the source queue and joins the back of the destination queue, keeping relative order among moved runs.
    - Given an adopted run that is not a waiter (running, finished), then no slot command is dispatched.

- [x] **TRD-017-TEST** `dispatcher_adoption_requeue_test.exs`. First step of the test: adopt a thread that has a queued run through `CommandGateway` and record whether the aggregate accepts it; assert whichever outcome is real, so the unverified assumption becomes a fact. (3h) [verifies TRD-017] [satisfies REQ-017] [depends: TRD-017]
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/dispatcher_adoption_requeue_test.exs`
  - Validates PRD ACs: AC-017-3
  - Test AC:
    - [ ] Scenario: moved waiter rejoins behind -- Given a waiting run is adopted by another project that already has two waiters, When the adoption is accepted, Then the run queues third in the destination and no longer counts against the source. (AC-017-3)
    - [ ] Scenario: a refused adoption leaves both queues untouched -- Given the aggregate refuses to adopt an active subject, When adoption is attempted, Then neither queue changes and the refusal is the asserted result; the outcome is recorded in the TRD's Known Gaps if it makes AC-017-3 unreachable. (AC-017-3)

- [x] **TRD-018** Fix the stranded-queued-run defect (kata `teak`) in the code this TRD rebuilds. (a) `BootReconciliation`: a slot **waiter** is an orphan only when its run is terminal, or when it has no run projection AND no task is `in_progress` with that `run_id` (`ProjectionStore.tasks_by_run_id/1`); today `run_absent_or_terminal?/1` calls `ProjectionStore.run/1`, which is `nil` for every queued run (a queued run has no run projection yet), so boot removed every queued waiter. Holders keep the old predicate. The same waiter predicate is used by TRD-009's migration. (b) `RunAdmission.slot_decision/2`: when an acquire returns `{:ok, nil}` (deduplicated replay) and the run is neither holder nor waiter, re-issue the acquire once with a fresh command id (`workflow:run-admission:slot-reacquire:<run_id>:<ms>`, the resume path's scheme) and decide again; only a second miss returns `{:error, :slot_state_unknown}`. (c) `Dispatcher`: log one `error` per `{task_id, reason}` for a stranded admission and `debug` for repeats (a `MapSet` in state), not a `warning` per tick. Out of scope (recorded in Known Gaps): surfacing a run whose aggregate is missing but whose projection says queued as failed. (4h) [satisfies REQ-005] [satisfies REQ-007] [satisfies REQ-009] [depends: TRD-005]
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/boot_reconciliation.ex`, `packages/foreman_server/lib/foreman_server/run_admission.ex`, `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex`
  - Validates PRD ACs: AC-005-2, AC-007-1, AC-009-2
  - Implementation AC:
    - Given a queued run (task `in_progress`, no run projection) in a project stream, when boot reconciliation runs, then its waiter is kept.
    - Given a waiter whose run is terminal, when boot reconciliation runs, then the waiter is removed.
    - Given a run whose waiter was removed and whose original acquire command id was already processed, when admission is retried, then it ends as holder or waiter, never `:slot_state_unknown`.
    - Given the same stranded task fails admission on ten consecutive ticks, then exactly one `error` log names it.

- [x] **TRD-018-TEST** `boot_reconciliation_queued_waiter_test.exs` and a case in `run_admission_slot_gate_test.exs` (the test named in kata `teak`: queue a run, remove its waiter, retry admission, assert it ends as holder or waiter). Written before TRD-018 and seen to fail. (3h) [verifies TRD-018] [satisfies REQ-005] [satisfies REQ-007] [satisfies REQ-009] [depends: TRD-018]
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/boot_reconciliation_queued_waiter_test.exs`, `packages/foreman_server/test/foreman_server/run_admission_slot_gate_test.exs`
  - Validates PRD ACs: AC-005-2, AC-007-1, AC-009-2
  - Test AC:
    - [ ] Scenario: a restart does not drop queued runs -- Given three runs queued in a project (tasks in progress, no run projections), When the server restarts and boot reconciliation runs, Then all three waiters remain in their original order. (AC-005-2)
    - [ ] Scenario: a terminal run's waiter is cleaned up -- Given a waiter whose run is terminal, When boot reconciliation runs, Then the waiter is removed and the next waiter is considered. (AC-007-1)
    - [ ] Scenario: a deduplicated re-admission is not stranded -- Given a queued run whose waiter was removed, When admission is retried with the already-processed command id, Then the run ends as holder or waiter. (AC-009-2)
    - [ ] Scenario: one error per stranded task -- Given one task that fails admission repeatedly, When ten ticks pass, Then one error line names it and the rest are debug. (AC-007-1)

- [x] **TRD-009** New `Workflow.RunSlotsMigration.run/0` per the Migration section; `BootReconciliation.scan_run_slot_orphans/0` and `reconcile_run_slots_stream/0` iterate project streams and then call the migration; legacy stream is read-only; every release it issues uses `RunSlots.release_command/3`; it treats a waiter as an orphan only by TRD-018's predicate, so queued runs (no run projection yet) are carried over, not dropped. (6h) [satisfies REQ-008] [satisfies REQ-009] [depends: TRD-003, TRD-005, TRD-007, TRD-018]
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/run_slots_migration.ex`, `packages/foreman_server/lib/foreman_server/workflow/boot_reconciliation.ex`
  - Validates PRD ACs: AC-008-1, AC-009-1, AC-009-2, AC-009-3
  - Implementation AC:
    - Given legacy holders and waiters, when boot reconciliation runs twice, then each is carried over once (same command ids) and nothing is appended to `run_slots:global`.

- [x] **TRD-009-TEST** `run_slots_migration_test.exs`: seed a legacy stream with holders and ordered waiters across two projects, run the migration, assert adopted holders, waiter order per project, idempotency, and a byte-for-byte unchanged legacy stream. (5h) [verifies TRD-009] [satisfies REQ-008] [satisfies REQ-009] [depends: TRD-009]
  - Target Files: `packages/foreman_server/test/foreman_server/workflow/run_slots_migration_test.exs`
  - Validates PRD ACs: AC-008-1, AC-009-1, AC-009-2, AC-009-3, AC-009-4
  - Test AC:
    - [ ] Scenario: running runs continue -- Given runs held slots in the legacy stream, When the new version starts, Then they count against their own project and keep running. (AC-009-1)
    - [ ] Scenario: waiters keep their order -- Given waiters X, Y of project A and Z of project B in the legacy stream, When migrated, Then A queues X then Y and B queues Z. (AC-009-2)
    - [ ] Scenario: legacy stream is retained and untouched -- Given the migration ran, Then the legacy stream has the same events as before and no new append. (AC-009-3, AC-008-1)
    - [ ] Scenario: a project already over its new limit -- Given adopted holders exceed the project limit, Then none is stopped and new runs wait. (AC-009-4)

### PR 3: Retire the global concurrency setting

**Shippable State:** The machine-wide concurrency setting no longer exists: a leftover `max_concurrent_runs` value is ignored with a logged warning, the default per-project limit is 3, and no production code names the global stream outside the migration module.

- [x] **TRD-010** Remove the global cap: delete `RunSlots.Config.max_concurrent_runs/0`, the `:max_concurrent_runs` lines in `config.exs`, and set `:max_concurrent_runs_per_project` to 3; add the boot warning (`Logger.warning` naming `:max_concurrent_runs` as retired and ignored) in `Application.start/2`; grep gate: no production reference to `"run_slots:global"` or `Config.max_concurrent_runs()` remains outside the migration module. (3h) [satisfies REQ-008] [satisfies REQ-002] [depends: TRD-005, TRD-009]
  - Target Files: `packages/foreman_server/lib/foreman_server/aggregates/run_slots/config.ex`, `packages/foreman_server/config/config.exs`, `packages/foreman_server/config/test.exs`, `packages/foreman_server/lib/foreman_server/application.ex`
  - Validates PRD ACs: AC-008-2, AC-008-3, AC-002-1
  - Implementation AC:
    - Given `config :foreman_server, :max_concurrent_runs, 9` in the environment, when the server boots, then it logs the warning once and starts normally.
    - Given the source tree, when grepped, then `run_slots:global` appears only in the migration module and its test.

- [x] **TRD-010-TEST** `run_slots_config_test.exs` (rewrite), a boot-warning test using `capture_log`, and a source-contract test that greps `lib/` for the retired literals. (3h) [verifies TRD-010] [satisfies REQ-008] [satisfies REQ-002] [depends: TRD-010]
  - Target Files: `packages/foreman_server/test/foreman_server/aggregates/run_slots_config_test.exs`, `packages/foreman_server/test/foreman_server/retired_global_slots_test.exs`
  - Validates PRD ACs: AC-008-2, AC-008-3, AC-002-1
  - Test AC:
    - [ ] Scenario: leftover value is ignored with a warning -- Given the retired key is configured, When the application starts, Then a warning is logged and boot succeeds. (AC-008-3)
    - [ ] Scenario: no global setting is read -- Given the source tree, Then nothing reads `:max_concurrent_runs`. (AC-008-2)
    - [ ] Scenario: default is three -- Given no configuration, Then the per-project default is 3. (AC-002-1)

### PR 4: Per-project visibility

**Shippable State:** An operator can read, for any project, how many runs are running and waiting, its limit, and the waiting runs in order with how long each has waited; the un-scoped queue endpoint is refused; a project's reported limit is its own setting with no global clamp.

- [x] **TRD-011** `ProjectionStore`: fold `RunSlot*` events by `project_id` into `run_slots: %{project_id => %{capacity, holders, waiters}}` (events without `project_id` are ignored); `queue_status/1`; `project_limits/2` usage gains `running_runs` and `waiting_runs`; `ProjectLimits.build/3` drops the `min(.., Config.max_concurrent_runs())` clamp and reports `running_runs`/`waiting_runs`. Replace the `run_slots: %{capacity: 0, ...}` initial state. (5h) [satisfies REQ-010] [satisfies REQ-013] [depends: TRD-001]
  - Target Files: `packages/foreman_server/lib/foreman_server/projection_store.ex`, `packages/foreman_server/lib/foreman_server/project_limits.ex`
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-010-3, AC-010-4, AC-013-2
  - Implementation AC:
    - Given a project with three holders and two waiters, then `queue_status/1` lists running 3, waiting 2 in order with `waited_ms` for each.
    - Given a project setting of 5, then `limits.max_concurrent_runs` is 5.

- [x] **TRD-011-TEST** Rewrite `projection_store_queue_status_test.exs` and `projection_store_run_slots_test.exs`; update `project_limits_test.exs`. (4h) [verifies TRD-011] [satisfies REQ-010] [satisfies REQ-013] [depends: TRD-011]
  - Target Files: `packages/foreman_server/test/foreman_server/projection_store_queue_status_test.exs`, `packages/foreman_server/test/foreman_server/projection_store_run_slots_test.exs`
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-010-3, AC-010-4, AC-013-2
  - Test AC:
    - [ ] Scenario: counts, limit and order -- Given three running and two waiting, When read, Then running 3, waiting 2, limit 3 and the two waiters in order. (AC-010-1)
    - [ ] Scenario: no cross-project leakage -- Given runs in two projects, When one is read, Then it never includes the other's runs. (AC-010-2)
    - [ ] Scenario: limit is the setting -- Given a setting of 5, Then the reported limit is 5, not clamped. (AC-010-3)
    - [ ] Scenario: wait time shown -- Given a run waited, Then each waiter carries `waited_ms`. (AC-010-4)
    - [ ] Scenario: limit changes replay deterministically -- Given the limit changed over time, When history is replayed, Then each decision shows the limit in force. (AC-013-2)

- [x] **TRD-012** `QueueController.index/2`: require `project_id`; absent or blank answers 422 `project_required` ("name a project: GET /api/queue?project_id=<id>"); unknown project 404 `project_not_found`; body is the per-project status. Remove any combined view (MCP tool inventory check). (2h) [satisfies REQ-010] [satisfies REQ-011] [depends: TRD-011]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/controllers/queue_controller.ex`
  - Validates PRD ACs: AC-010-2, AC-011-1, AC-011-2
  - Implementation AC:
    - Given `GET /api/queue` with no `project_id`, then 422 `project_required`.

- [x] **TRD-012-TEST** New `queue_controller_test.exs`; run `mcp/tool_inventory_test.exs` to confirm no combined queue tool. (2h) [verifies TRD-012] [satisfies REQ-010] [satisfies REQ-011] [depends: TRD-012]
  - Target Files: `packages/foreman_server/test/foreman_server_web/controllers/queue_controller_test.exs`
  - Validates PRD ACs: AC-010-2, AC-011-1, AC-011-2
  - Test AC:
    - [ ] Scenario: un-scoped read is refused -- Given no project is named, When the queue is requested, Then 422 and a message saying to name a project. (AC-011-2)
    - [ ] Scenario: no surface returns a combined queue -- Given the API, CLI and MCP tools, Then none returns runs of several projects. (AC-011-1)
    - [ ] Scenario: scoped read -- Given a project is named, Then only its runs are returned. (AC-010-2)

- [x] **TRD-013** Telemetry: add `project_id` and `waiting` to the slot events (`Telemetry.run_slots_*`: acquired, queued, released, transferred) and a `queue_wait_ms` measurement on promotion computed from the waiter's stamp. (2h) [satisfies REQ-014] [depends: TRD-002, TRD-003]
  - Target Files: `packages/foreman_server/lib/foreman_server/telemetry.ex`, `packages/foreman_server/lib/foreman_server/aggregates/run_slots.ex`
  - Validates PRD ACs: AC-014-1, AC-014-2
  - Implementation AC:
    - Given a run is queued then promoted, then telemetry shows the project, running and waiting counts and a `queue_wait_ms`.

- [x] **TRD-013-TEST** Update `telemetry_run_slots_test.exs`. (1h) [verifies TRD-013] [satisfies REQ-014] [depends: TRD-013]
  - Target Files: `packages/foreman_server/test/foreman_server/telemetry_run_slots_test.exs`
  - Validates PRD ACs: AC-014-1, AC-014-2
  - Test AC:
    - [ ] Scenario: queued/granted/released carry counts -- Given a run is queued, granted and released, Then each event has the project and the counts at that moment. (AC-014-1)
    - [ ] Scenario: time in queue observable -- Given a run waited, Then promotion reports `queue_wait_ms`. (AC-014-2)

### PR 5: Settings validation and documentation

**Shippable State:** The documentation, CLI reference and configuration reference describe per-project queues only (with no machine-wide ceiling stated), and a limit of 0 or below is refused with its valid range.

- [x] **TRD-014** Verification only: confirm the settings validator rejects 0, negatives and over-range (`Aggregates.Project.Settings`); if its error text does not name the range, make it do so; no other code. (1h) [satisfies REQ-016] [depends: TRD-010]
  - Target Files: `packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex`
  - Validates PRD ACs: AC-016-1, AC-016-2, AC-016-3
  - Implementation AC:
    - Given `max_concurrent_runs: 0`, when saved, then it is rejected naming 1..1000 and the previous value is kept.

- [x] **TRD-014-TEST** Extend `project_settings_test.exs` and `project_settings_live_test.exs`. (2h) [verifies TRD-014] [satisfies REQ-016] [depends: TRD-014]
  - Target Files: `packages/foreman_server/test/foreman_server/aggregates/project_settings_test.exs`, `packages/foreman_server/test/foreman_server_web/live/project_settings_live_test.exs`
  - Validates PRD ACs: AC-016-1, AC-016-2, AC-016-3
  - Test AC:
    - [ ] Scenario: invalid limits are refused -- Given a limit of 0 or -1, When saved, Then it is rejected with the valid range and the old value stays. (AC-016-1)
    - [ ] Scenario: limit one serialises -- Given a limit of 1, Then runs go one at a time. (AC-016-2)
    - [ ] Scenario: pause is the stop -- Given a paused project, Then no run starts whatever the limit. (AC-016-3)

- [x] **TRD-016** Documentation (constitution section 8, a blocking gate): `docs/user-guide.md` (the project settings table row for `max_concurrent_runs`, the **Limits** paragraph, the daily-cap paragraph that mentions the global run slot, and the paragraph that lists `GET /api/queue`: per-project, no machine-wide ceiling, total concurrency is the sum of per-project limits); `docs/cli-reference.md` (the `foreman project settings` limits-block description: add `running_runs`, `waiting_runs`); new `CLAUDE.md` subsection "Per-project run slots" replacing nothing (it states the stream key, capacity source, promotion rule, migration, and that `run_slots.*` stay system-only); config comments in `config.exs`. (3h) [satisfies REQ-015] [depends: TRD-010, TRD-012]
  - Target Files: `docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`, `packages/foreman_server/config/config.exs`
  - Validates PRD ACs: AC-015-1, AC-015-2
  - Implementation AC:
    - Given the four documents, when searched, then none describes the global queue as current behaviour and the operator guide says there is no machine-wide ceiling.

- [x] **TRD-016-TEST** Documentation contract test `docs_per_project_queue_test.exs`: greps the four documents for the retired phrases (`global run slot`, `global run-slot capacity`, `capped by the global`) and for the required statement. (1h) [verifies TRD-016] [satisfies REQ-015] [depends: TRD-016]
  - Target Files: `packages/foreman_server/test/foreman_server/docs_per_project_queue_test.exs`
  - Validates PRD ACs: AC-015-1, AC-015-2
  - Test AC:
    - [ ] Scenario: no global-queue description remains -- Given the four documents, Then no retired phrase is present. (AC-015-1)
    - [ ] Scenario: no machine-wide ceiling is stated -- Given the operator guide, Then it says total concurrency is the sum of per-project limits. (AC-015-2)

## Known Gaps (feed back to the PRD)

- **AC-017-2 is not covered.** "A deleted project drops its waiting runs" has no delete
  command to attach to: `project.archive`, `project.reactivate` and `project.adopt` exist,
  deletion does not. `RunSlots.drop_project/1` (TRD-006) is groundwork a future delete must
  call. The PRD needs a refinement: either drop AC-017-2 or specify the delete command.
- **AC-017-3 may be unreachable.** Adoption refuses an active subject. TRD-017-TEST settles
  whether a queued run counts as active; if it does, AC-017-3 needs either an adoption-rule
  change (a PRD decision) or removal.

- **AC-004-1 and AC-004-2 have no task.** REQ-004 is Won't; its "jobsites unchanged" guard
  test was dropped because the jobsite retirement deletes the modules it would assert on.
- **kata `teak` item 3 is not fixed here:** a run whose aggregate is missing but whose
  projection says queued is still not surfaced as failed. It needs a new failure path that
  the PRD does not define; it stays on `teak`.

## Acceptance Criteria Traceability

| REQ | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 | Each project admits independently | TRD-001, TRD-005, TRD-006, TRD-007 | TRD-001-TEST, TRD-005-TEST, TRD-006-TEST, TRD-007-TEST |
| REQ-002 | Default limit of 3 | TRD-005, TRD-010 | TRD-005-TEST, TRD-010-TEST |
| REQ-003 | Setting overrides both ways | TRD-002, TRD-003, TRD-007 | TRD-002-TEST, TRD-003-TEST, TRD-007-TEST |
| REQ-005 | FIFO within a project | TRD-003, TRD-007, TRD-018 | TRD-003-TEST, TRD-007-TEST, TRD-018-TEST |
| REQ-006 | Freed slot goes to same project | TRD-002, TRD-007 | TRD-002-TEST, TRD-007-TEST |
| REQ-007 | No leaked or double-granted slot | TRD-003, TRD-004, TRD-005, TRD-008, TRD-018 | TRD-003-TEST, TRD-004-TEST, TRD-005-TEST, TRD-008-TEST, TRD-018-TEST |
| REQ-008 | No global queue or cap | TRD-009, TRD-010 | TRD-009-TEST, TRD-010-TEST |
| REQ-009 | Upgrade preserves runs | TRD-003, TRD-009, TRD-018 | TRD-003-TEST, TRD-009-TEST, TRD-018-TEST |
| REQ-010 | Per-project visibility | TRD-011, TRD-012 | TRD-011-TEST, TRD-012-TEST |
| REQ-011 | No cross-project view | TRD-012 | TRD-012-TEST |
| REQ-012 | Paused/archived/daily-capped unchanged | TRD-005, TRD-007 | TRD-005-TEST, TRD-007-TEST |
| REQ-013 | Reconstructible from events | TRD-001, TRD-011 | TRD-001-TEST, TRD-011-TEST |
| REQ-014 | Observability | TRD-013 | TRD-013-TEST |
| REQ-015 | Documentation | TRD-016 | TRD-016-TEST |
| REQ-016 | Positive integers only | TRD-014 | TRD-014-TEST |
| REQ-017 | Lifecycle of waiting runs (AC-017-2 not covered, see Known Gaps) | TRD-005, TRD-006, TRD-017 | TRD-005-TEST, TRD-006-TEST, TRD-017-TEST |
| REQ-018 | One slot per run | TRD-007, TRD-008 | TRD-007-TEST, TRD-008-TEST |
| REQ-004 (Won't) | Jobsites unchanged (no task; see Known Gaps) | none | none |

## Sprint Planning (informational, not parsed)

- **Week 1:** PR 1 (aggregate), PR 2 (admission, dispatcher, adoption and migration). PR 2 is the risk concentration.
- **Week 2:** PR 3 (retire the global key), PR 4 (visibility), PR 5 (verification and docs).
- Every PR is safe to merge alone: PR 1 is additive, PR 2 carries the migration with the
  switch, PR 3 only removes a config key.
- Critical path: TRD-001 -> TRD-003 -> TRD-005 -> TRD-007 -> TRD-009 -> TRD-010 (all PR 1 to PR 3).

## Adversarial Review (self-critique)

Issues found and how the draft resolves them:

1. **Release-order hazard.** Holders in the legacy stream keep their slots until migration
   adopts them; between boot and migration a project could admit up to its limit on top of
   them. Resolved: migration runs inside boot reconciliation *before* the Dispatcher
   replays, and adoption is `force`, so the worst case is a transient overshoot that
   self-corrects as runs finish (AC-009-4 explicitly allows it). Documented in TRD-009,
   which refine pass 1 moved into PR 2 so the switch and the migration ship together.
2. **Paused-run semantics changed (finding 2).** An operator who relied on paused runs
   counting against the limit now sees the slot freed. Mitigation: stated in the Summary and
   in TRD-016; a resumed run queues like any other. Flagged as a behaviour change, not hidden.
3. **Leak on refusal after slot.** Archived (and previously the ceiling) refusals would fire
   after a slot was held. Resolved by moving archived to the pre-gate (TRD-005) and removing
   the ceiling (TRD-006); `reserve_run` keeps archived as a backstop and TRD-005-TEST covers
   "archived holds".
4. **Promotion fan-out.** A raised limit could promote many waiters in a tight loop.
   Bounded by the number of waiters; each promotion is one command; acceptable.
5. **Projection fold for legacy events.** `ProjectionStore` rebuild would crash if a legacy
   event reached the new fold without `project_id`. Resolved: TRD-011 ignores events with no
   `project_id`, with a test.
6a. **Same defect class as kata `teak`** (added in refine pass 2): the new per-project boot
   scan and the migration would both have dropped queued runs. TRD-018 fixes the predicate
   and the dedup replay; TRD-009 depends on it.
6. **Test-suite blast radius.** About 30 test files reference `:max_concurrent_runs` or the
   global stream. Resolved: TRD-005-TEST reworks `RunSlotsReset` once; the remaining files
   change a config key. Estimate risk is in the estimates, not the design.

## Dependency and Estimate Review

- Longest chain: TRD-001 -> TRD-003 -> TRD-005 -> TRD-007 -> TRD-009 -> TRD-010, depth 6.
  The chain is inherent (aggregate, then admission, then dispatcher, then migration, then
  removal); PRs 1 and 4's TRD-011 are independent of it after TRD-001.
- No task is 8h or more; TRD-009 (6h) is the largest (TRD-018 is 4h) and carries the risk; TRD-007 (4h) and TRD-017 (3h) were split in refine pass 1.
- Estimates assume the existing slot tests can be adapted, not rewritten; if the test
  reset helpers resist (see `run_slots_reset.ex`), TRD-005-TEST is the one to grow.
- No circular dependencies.

## Quality Requirements

- **Security:** `run_slots.*` remain system-only; asserted in TRD-004-TEST. No new input
  surface except the `project_id` query parameter (validated, 422/404).
- **Performance:** admission touches one per-project actor; no cross-project lock. No
  numeric target is invented (the PRD sets none).
- **Reliability:** idempotent migration (deterministic command ids); backstop sweep over
  every project; replay-deterministic capacity (recorded on events).
- **Testing:** ExUnit, test-first; narrowest-file run per task; full suite green before each
  PR merges (`devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'`).
- **Documentation:** constitution section 8 gate in TRD-016.

## Design Readiness Scorecard

| Dimension | Score | Note |
|---|---|---|
| Architecture completeness | 5 | Shared release builder, unresolved-project path and adoption contract now specified |
| Task coverage | 4 | Every REQ has implementation and test tasks; AC-017-2 is openly not covered (Known Gaps) |
| Dependency clarity | 5 | No hidden PR coupling; every PR is safe alone |
| Estimate confidence | 4 | Test-suite adaptation cost is still the uncertainty |

Overall **4.5 / 5: PASS** (was 4.25; self-scored).

## Changelog

- **1.0.2 (2026-11-19), refine pass 2 (from the pre-build check in implement-trd-tasks):**
  - Added TRD-018 and TRD-018-TEST: fix kata `teak` (boot reconciliation dropped every
    queued waiter; deduplicated acquire stranded runs; per-tick warnings) in the rebuilt code;
    TRD-009 now depends on it and uses its waiter predicate.
  - Dropped TRD-015 and TRD-015-TEST (jobsites-unchanged guard) because the jobsite
    retirement in kata `5z8s` deletes those modules; REQ-004 stays a documented Won't.
  - Recorded the jobsite-retirement overlap and `teak` item 3 under Findings and Known Gaps.
  - Tasks 34 -> 34 (+2, -2); hours 94 -> 99.
- **1.0.1 (2026-11-19), refine pass 1:**
  - Moved the migration (TRD-009, TRD-009-TEST) from PR 3 into PR 2 so no PR depends on a
    later one; rewrote PR 2 and PR 3 Shippable State lines and the sprint plan.
  - Split adoption out of TRD-007 into TRD-017 and TRD-017-TEST (TRD-007 6h -> 4h);
    specified the real event (`ProjectSubjectAdopted`, `moved.*`) and made the
    active-subject refusal a tested fact, not an assumption.
  - TRD-002 now owns the one shared `RunSlots.release_command/3`; TRD-005, TRD-007,
    TRD-008 and TRD-009 use it; an unresolvable project logs and defers to the backstop.
  - AC-017-2 removed from TRD-006's coverage claims; new "Known Gaps" section records it
    and AC-017-3 for the next PRD refinement.
  - TRD-016 names doc sections instead of line numbers.
  - Re-scored 4.25 -> 4.5. Tasks 32 -> 34.
- **1.0.0 (2026-11-19):** created from PRD-2026-b9e27ab5 v1.0.1.
