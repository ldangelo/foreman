# Changelog — foreman_server

## Unreleased

### Fixed

- **A slow aggregate actor no longer kills the process that sent it a command.**
  `CommandRouter.dispatch/2` let the `GenServer.call` timeout exit escape, so the Overwatch
  `Tracker` (and every live worker with it), the `BeadsWatcher` and a `RunExecutor` that had
  finished its last phase died with `{:timeout, {GenServer, :call, ...}}`. It now returns
  `{:error, %ForemanServer.CommandTimeout{aggregate_id, command_type, timeout_ms}}` (only that
  exit is caught; the command's outcome is unknown, sending it again with the same
  `command_id` is safe) and logs a warning. `Tracker.heartbeat/3` and
  `Tracker.dispatch_lifecycle/3` return the same error when the Tracker does not answer in five
  seconds, so a worker no longer dies on a slow Tracker (`:worker_died_no_result`): output and
  heartbeats are dropped with a warning, every other worker event is logged as an error.
  `RunExecutor.claim/4` and `complete/5` return `BeadsDbLease.ReleaseError` (a lease that could
  not be released) as `{:error, error}`, so a lease timeout at run completion fails the run
  loudly (`{:finalize_run_failed, ...}`) instead of killing the executor with the run
  `in_progress`. The slowness of the lease actor itself is not addressed here.

- **A run whose `run.fail` is rejected with `{:not_found, :run, _}` no longer retries forever
  and keeps its run slot.** The run aggregate does not exist, so `run.fail` can never be
  accepted and there is no stream to write `RunFailed` to. `RunExecutor`'s terminal-dispatch
  retry treated the rejection like a transport error and retried it every 60 s with no ceiling,
  so the executor never stopped and, with no `RunFailed` for the Dispatcher to release it from,
  the run kept its slot. The retry now gives up on that rejection at its third attempt: it logs
  one error, releases the run's slot itself (`RunSlots.release_command/3`) and the executor
  stops. Every other rejection keeps the fast-then-slow retry, and `{:run_terminal, _}` still
  stops at once. No terminal event is written, so the run still reads non-terminal in the
  projection; why its aggregate was missing is not addressed here (foreman-j9sf8).

- **The idle-tail poll test no longer fails at random.** `jido_harness_worker_live_output_test.exs`
  ("an idle tail asks the run one cheap question per poll period") counted every `Run.info/1`
  the traced harness run received, but `Jido.Harness.Retention` calls `Run.info/1` on every run
  once a minute (its first sweep is 60 s after boot: the hosted-CI failures fell at +60 s and
  +120 s into a run), so a sweep inside the test's second read as an early poll (`idle_2 - idle_1`
  of 33 ms against 200 ms). The trace was also switched on while the tail's first round could be
  under way, so its `info` was sometimes missed and the expected call list was one call short.
  The test now counts only the tail's own calls (by sender) and measures the poll period from
  the tail's `replay` of the output; it makes one foreign `Run.info/1` on purpose, so the filter
  is exercised on every run. The tail itself waits the full 250 ms poll period after every
  round: there is no production change.

- **The BootReconciliation startup-deferral test no longer fails at random.**
  "run_terminated/2 defers dispatch when CommandRouter is not registered" took the
  `CommandRouter` out of its supervisor while `BootReconciliation` could still be dispatching
  through it. The module starts the process in `setup_all`, and `init/1` continues into a boot
  pass that releases the Beads leases other test files leave held (`beads_db_lease:/tmp/cg-ic-*`,
  from `command_gateway_test.exs`), so the first test ran beside it; a scan an earlier test cast
  and did not wait for is the same overlap. An aggregate Actor sends its append to the router by
  name, so with the router gone the send raised (`Aggregate.Actor.append_and_commit/7`), the
  Actor died, the `lease.release` call exited with it and `BootReconciliation` died mid-scan, so
  the test's own `flush_boot_reconciliation/0` exited (CI run 45300859440, partition 2, seed
  253260; a router that dies between the Actor's send and its reply times the call out instead).
  The same overlap fails the orphan-scan tests' 1 s deadline when one of them runs first and the
  pass is slow. `setup_all` now waits for the boot pass, and the deferral test suspends
  `BootReconciliation` (`DispatcherQuiesce.suspend!/1` answers once the message being handled is
  done) while the router is removed and resumes it after, so everything it handles from then on
  takes the deferral branch. There is no production change: `BootReconciliation` starts before
  the router in the supervision tree, so its readiness check only ever sees the router appear,
  and an Actor that finds no router crashes on the send by design (`Keeper`,
  `CommandRouter.dispatch/2`).

### Added

- **Kata task provider.** `ForemanServer.TaskProviders.KataAdapter` implements the
  `ForemanServer.TaskProvider` behaviour over the `kata` CLI (provider id `kata`,
  capability contract `kata.capabilities.v1`, storage scheme `:cli_process`). A
  project selects it with `task_provider: "kata"` and a `config.cwd` pointing at
  its Kata workspace; the Go CLI sends the registered path as `config.cwd` for
  `foreman project update --task-provider kata`.
- Declared operations (`capabilities/0 .supports`, in the registry's transition
  vocabulary): `create`, `claim`, `close`, `reopen`, `annotate`, `set_priority`,
  `set_assignee`, `list_dependencies`, `add_dependency`, `remove_dependency`
  (`set_assignee`, `list_dependencies` and `remove_dependency` have no callback,
  as in Beads). `claim`, `complete` (`kata close --done`
  with typed evidence) and `fail` (status, `kata reopen`, an idempotent
  `kata comment`, then `kata unassign --expect-owner <actor>`) run through the
  provider-generic `RunExecutor` lifecycle with no Kata-specific branch.
- `SystemKataRunner`, the only module that spawns `kata` (a Port, with timeout and
  process-group cleanup), behind the `ForemanServer.TaskProviders.KataRunner`
  behaviour. The runner is resolved at call time from the `:kata_runner` application
  env.
- `ProviderError` codes for Kata, built through one factory
  (`KataAdapter.BuildProviderError`) with an allow-listed context so no assignee,
  description or stderr text can reach events, logs or telemetry.
- `foreman doctor task_provider` (`ForemanServer.CLI.run(["doctor", "task_provider"])`)
  reports Kata availability, `kata_version`, `warnings` (`KATA_VERSION_OUT_OF_RANGE`,
  `KATA_VERSION_UNPARSEABLE`, `KATA_VERSION_REQUIREMENT_INVALID`, `CWD_MISSING`,
  `PROVIDER_MISSING`) and a `sample_list` probe; the accepted range is the
  `accepted_kata_versions` config key.
- Registry: a provider's `capabilities/0` is validated at boot (telemetry
  `[:foreman_server, :task_provider, :registry, :invalid_capabilities]`) and a
  project's provider routes by its storage binding (`cwd` for `cli_process`,
  `database_path` for Beads). A same-provider `project.update` keeps its stored
  config; a provider switch must carry the target scheme's key.

### Changed

- The generic claim path already re-claimed once on `NOT_CLAIMABLE` and emitted
  `[:foreman_server, :task_provider, :claim, :lost]` on a second refusal; it now
  treats `CLAIMED_BY_OTHER` the same way, which also applies to Beads' refusal.
  A lost claim fails the run before any agent is dispatched.
- `TaskProvider.complete/5` accepts an optional `commit_sha`, computed at close from
  the run's own commits (`base_ref..HEAD`, newest first); no sha is sent when the run
  made no commit.
- `foreman doctor task_provider` resolves its Kata runner at call time, like the adapter.
- A phase PR is titled with the run's task title when it has one, then the first
  conventional-commit subject among the run's commits (`fix:`, `feat:`, …), then the legacy
  `feat(phase): <phase>`; `Workflow.PhasePR.Request` gains an optional `task_title`, and a
  `git log` that fails only costs the subject fallback (warned, the PR still opens).

### Fixed

- A run that stops (failed, cancelled, flagged stuck, removed or paused) no longer leaves a live
  Overwatch worker, and the `pi`/`claude` process under it, writing into its worktree.
  `Workflow.Dispatcher` stops what the Overwatch registry still lists for the run once the
  worker has had a wind-down to finish by itself (`WorkerSupervisor.stop_run_workers/1`;
  `RunControl` cannot do it, the executor wipes it when it stops). `LaunchWorker` stops its
  worker and `JidoHarnessWorker.terminate/2` cancels its harness run (`Driver.stop/2`), so a
  worker that dies takes its agent with it. `Overwatch.start_phase/2` refuses a second worker
  for a run that has one alive (`{:worker_already_running, run_id}`).
