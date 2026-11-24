# Beads sync invariants and per-DB lease (§14–§15)

> Moved verbatim from `CLAUDE.md`. Section numbers are unchanged; `CLAUDE.md` names the file holding each `§N`, so a reference to a section that is not in this file resolves there.

## 14. Beads sync invariants (Go/Elixir CQRS slice)

Atomic `task.create` and bidirectional Beads sync are governed by
these invariants. Drift without a tracked TRD is a regression.

- **Atomic `task.create`.** `Task.create` flows through the `Task`
  aggregate in a four-stage pipeline (`actor.ex`: `do_dispatch/4`):
  (1) `handle_command/2` produces the stage-1 event spec;
  (2) `resolve_enriched_event_spec/3` invokes the project's configured
  `:create` provider (`TaskProvider.Registry.route(:create, ...)` →
  `provider.create/2`) to mint a Bead **before** the append;
  (3) the actor re-decides `handle_command/2` with the Bead ID
  populated as `payload.external_id` on the event spec;
  (4) `append_and_commit/7` performs the append/ack/commit.
  **Provider failure aborts the command entirely**: a `{:error, _}`
  from `provider.create/2` returns `{:error, reason, state}` with no
  append, no event, and no compensation (no Bead was minted to close).
  **Conflict / re-decision failures compensate the Bead**: on the
  bounded retry path, `compensate_for_conflict/3` closes the Bead via
  `BeadsAdapter.complete/3` with the canonical `transition_comment`
  so a successful stage 2 does not strand. The cache entry in
  `state.in_flight_beads` is the single source of truth for "Bead
  minted but not committed"; clearing it after compensation prevents
  double-close on a subsequent retry. (Other append-failure modes
  outside the conflict-retry path are not characterized here.)
- **`external_id` surface contract.** The successful `task.create`
  HTTP response (HTTP 201 with `status: "accepted"`,
  `result: %{events: 1}`) does **not** carry `external_id` —
  `CommandController.serialize/1` returns `%{events: 1}` for
  `{:ok, _events}` and does not enrich the response with the
  persisted event's fields. Operators retrieve the bead linkage by
  reading the task projection (`GET /api/tasks/:id`).
  `foreman task get` is REMOVED (TRD-018, 2026-09-13) — the
  projection is still readable via that HTTP endpoint directly
  (`curl`, or an MCP tool), just not through this CLI command.
  Its `external_id` field is
  populated on the persisted `TaskCreated` event when the
  project's `task_provider` capabilities advertised `:create`.
  Provider failure aborts the command entirely (no event, no
  successful response, no `external_id` surface).

- **Operator-issued ≠ no-Bead.** A `task.create` issued by the
  operator on a project with a configured `:create` provider still
  gets an `external_id`. The presence/absence of `external_id` means
  "Bead linked" vs "Bead not linked", **not** "operator-issued" vs
  "system-issued". The MCP `foreman_task_create` helper requires
`description` for `FOREMAN_TASK_DESCRIPTION`, passes `prompt` separately for
`:prompt`-action phases, and defaults `auto_approve: true`.
- **Beads → Foreman (inbound) is opt-in.** The
  `BeadsWatcherSupervisor` is added to `ForemanServer.Application`
  only when `config :foreman_server, :start_beads_watcher?, true`.
  The watcher dispatches `task.create` for each new Bead it sees in
  the project's JSONL; that `task.create` re-enters the same Actor
  hook path, so a Bead originated by the watcher does **not** cause
  another Bead to be minted (provider skips when the Bead already
  exists).
- **Orphan janitor is opt-in.** `BeadsOrphanJanitorSupervisor` is
  added only when `config :foreman_server, :start_beads_orphan_janitor?,
  true`. The janitor closes stranded issuance (Bead minted but no
  Foreman task landed within the grace window) and stranded execution
  (Foreman task terminal but Bead never closed by `RunExecutor`). Both
  flags are required for production: watcher-only strands execution,
  janitor-only strands inbound issuance.
- **Adapter boundary holds.** `set_priority` and `add_dependency`
  remain adapter callbacks. No operator surface promotes them into
  Foreman commands in this slice.
- **Doctor surface is honest about current scope** — about its *fields*, not
  its existence. The Go `foreman doctor` (`GET /api/doctor`) reports
  server-wide rows and has no task-provider rows; `foreman doctor
  task_provider` is **not** routed (the Go CLI ignores the extra argument,
  `packages/foreman_cli/cmd/foreman/main.go`). The per-project report comes from
  `ForemanServer.CLI.run(["doctor", "task_provider"])` and reports, per project:
  `project_id`, `healthy`, `provider_id`, `contract_version`,
  `schema_validation_failures` and (on the unhappy branch) `error`, plus, for
  Beads, `br_version`, `capabilities`, `sample_ready`, `janitor_enabled`,
  `janitor_running`, `orphan_backlog`; for Kata, `kata_version`, `warnings` and
  `sample_list` (see §13.3). The
  janitor fields are a CQRS read of the cached snapshot maintained
  by `BeadsOrphanJanitor`'s own scan loop; the doctor MUST NOT
  invoke `BeadsOrphanJanitor.run_scan/2` itself. Operators needing
  finer-grained runtime visibility (per-scan event streams,
  supervisor lifecycle transitions) should rely on the
  `[:foreman_server, :task_provider, :beads, ...]` telemetry events.

## 15. Per-DB Beads lease (Go/Elixir CQRS slice)

SQLite's single-writer protocol cannot tolerate concurrent `br`/`bv`
writers or writers running alongside `bv --robot-plan`. The
`ForemanServer.Aggregates.BeadsDbLease` aggregate is an event-sourced
lock keyed by the configured absolute Beads DB path passed at acquire
time, giving process-local serialization through the Actor mailbox
while surviving Foreman restarts via persisted events. Different DBs
and direct (`foreman run`) workflows remain parallel. Callers must
pass the same absolute path on every dispatch — symlink aliasing
(e.g. `/tmp/...` vs `/private/tmp/...`) is NOT collapsed and will
register separate lease streams.

- **Acquire-or-enqueue.** `lease.acquire` is atomic: if the DB is
  free, the run becomes the holder; if held, the run is enqueued as a
  waiter and admission returns `:queued`.
- **Release-with-promotion.** When the holder releases with waiters,
  the aggregate emits a single `BeadsDbLeaseTransferred` event that
  releases the old holder and promotes the head waiter, so cancellation
  cannot race with promotion. The `Dispatcher` subscribes to this
  event and re-enters `RunAdmission.start/2` for the promoted run.
- **Process-bound holds.** A hold taken for one `br` call
  (`BeadsDbLease.with_lease/4`: `BeadsAdapter`, each `BeadsWatcher` read
  pass, the orphan janitor) carries the server's
  `ForemanServer.Incarnation`. A server killed mid-call strands that hold
  in the event store; the next incarnation takes it over at once
  (`BeadsDbLeaseAcquired`, `provenance: {:reclaimed_stale_holder, …}`)
  instead of queueing behind it until `:lease_timeout`, and
  `BootReconciliation.scan_lease_orphans/0` (every `beads_db_lease:`
  stream in the event store, not only DBs a task points at) releases the
  holds and waiters of other incarnations (foreman-w29up). A hold with no
  incarnation (`RunAdmission`'s whole-run hold) belongs to a run and is
  reclaimed through run liveness only.
- **Dead callers.** The incarnation tag separates VMs, not processes: a
  `with_lease/4` caller killed inside a live server (`Process.exit(pid, :kill)`,
  a supervisor's `:shutdown`, a linked crash) never runs its `after`.
  Every call is therefore watched by a `BeadsDbLease.Keeper` (under
  `BeadsDbLease.KeeperSupervisor`, outside every caller's subtree) that, when
  the caller goes down, dispatches `lease.remove_waiter` then `lease.release`
  for its `run_id` (reason `:caller_down`), so a dead holder frees the lease
  and a dead waiter is dropped, not promoted (foreman-8qge). No TTL: a hold
  whose caller lives is never given up. A late cleanup is a no-op for a lease
  that moved on. `with_lease/4` returns
  `{:error, {:lease_keeper_unavailable, _}}` while the supervisor is down.
- **Terminal fan-out.** The `Dispatcher` dispatches `lease.release`
  and `lease.remove_waiter` on every terminal run event
  (`RunCancelled`, `RunDeleted`, `RunFlaggedStuck`, `RunCompleted`, `RunFailed`,
  `RunBlocked`). `RunBlocked` is terminal for lease cleanup: a blocked
  run must release its Beads-DB lease so queued peers can be promoted.
- **Fail-closed gating.** `RunAdmission.start/3` reads the lease
  decision before starting the run supervisor. Any uncertainty
  (acquire error, atom state of `:unknown` or `:unexpected`) returns
  `{:error, ...}` and skips dispatch. A `:queued` decision returns
  without starting the supervisor; the dispatcher picks the run up
  again on `BeadsDbLeaseTransferred`.
- **Compensation.** `lease.release` on admission failure is only emitted
  for definitively non-retryable rejections (`{:missing_or_invalid, …}`,
  `{:implementation_already_active, …}`, `{:command_rejected, …}`).
  Compensating transient errors would break retry semantics.
- **Scope limitation (operator responsibility).** The lease serializes
  only admission through Foreman. External `br` writers and
  `bv --robot-plan` invocations launched outside Foreman (e.g. from a
  human shell or unrelated automation) are NOT gated by this lease.
  If you bypass Foreman and write to the same Beads DB concurrently
  with a held lease, SQLite's single-writer model will still observe
  concurrent writers. Operators must observe single-writer discipline
  themselves. The lease exists to prevent two Foreman-dispatched runs
  from racing on the same DB, not to mediate file-system access against
  unrelated processes. The contract test
  `test/foreman_server/workflow/br_bv_lease_concurrency_test.exs`
  verifies the admission contract; cross-process discipline against
  external writers is a separate, operator-owned concern.
