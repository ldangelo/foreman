# Changelog — foreman_server

## Unreleased

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

### Fixed

- A run that stops (failed, cancelled, flagged stuck, removed or paused) no longer leaves a live
  Overwatch worker, and the `pi`/`claude` process under it, writing into its worktree.
  `Workflow.Dispatcher` stops what the Overwatch registry still lists for the run once the
  worker has had a wind-down to finish by itself (`WorkerSupervisor.stop_run_workers/1`;
  `RunControl` cannot do it, the executor wipes it when it stops). `LaunchWorker` stops its
  worker and `JidoHarnessWorker.terminate/2` cancels its harness run (`Driver.stop/2`), so a
  worker that dies takes its agent with it. `Overwatch.start_phase/2` refuses a second worker
  for a run that has one alive (`{:worker_already_running, run_id}`).
