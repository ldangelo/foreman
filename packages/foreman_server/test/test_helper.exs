# The test database is shared across runs and ProjectionStore rebuilds its whole
# read model from the event log at boot. Without a reset every run inherits every
# prior run's events (48k+ observed), which makes read-after-write assertions time
# out on projection catch-up and makes randomly generated ids collide with tasks
# left by earlier runs.
#
# The app (and with it ProjectionStore's boot replay) is already up when this file
# runs, so emptying the log leaves the in-memory projection holding the PREVIOUS
# run's runs, tasks and projects: the projection is reset too, or a second local
# `mix test` starts from the last run's leftovers while CI (fresh DB) never does
# (foreman-a4ec2). The Dispatcher re-admits that run's tasks as it boots, and what it
# appended is flushed first, or it lands in the fresh log after the reset.
ForemanServer.TestSupport.RunDrain.drain!()
config = EventStore.Config.parsed(ForemanServer.EventStore, :foreman_server)
{:ok, conn} = Postgrex.start_link(EventStore.Config.default_postgrex_opts(config))
EventStore.Storage.Initializer.reset!(conn, config)
GenServer.stop(conn)
ForemanServer.TestSupport.AggregateActorReset.reset!()
ForemanServer.TestSupport.ProjectionStoreReset.reset!()

# Give this VM a private temp directory. Tests build scratch paths under
# `System.tmp_dir!/0` as "<prefix>-#{System.unique_integer([:positive])}", but that counter
# restarts at 1 in every VM, so two `mix test` runs on one machine (parallel CI jobs, several
# worktrees, a developer's second terminal) hand out the same names in the shared system temp
# dir. One run's `on_exit` cleanup then deletes the other's repo or worktree under it: an agent
# whose cwd vanished exits 1 ("agent_failed ... exit_status 256"), a prompt log disappears
# mid-test, a `git push` finds no repository. `System.tmp_dir!/0` and every child process read
# TMPDIR, so pointing it at a per-VM directory removes the collision for all ~200 sites at once.
#
# The directory is created fresh and never cleared: an OS pid is reused within minutes, so a bare
# `fm-test-<pid>` can already exist as the leftover of an earlier VM, and `File.rm_rf!/1` on a
# leftover that holds a read-only tree (a Library entry) raised "file already exists" here, before
# any test ran. See `ForemanServer.TestSupport.Tmp`.
vm_tmp = ForemanServer.TestSupport.Tmp.claim_vm_dir!(System.tmp_dir!())
System.put_env("TMPDIR", vm_tmp)
ExUnit.after_suite(fn _ -> ForemanServer.TestSupport.Tmp.release_vm_dir(vm_tmp) end)

# `:eventstore` logs every append, notification and subscription push at :debug.
# It is ~20k lines of a CI log, and because the Beads lease stream id embeds the
# absolute DB path (`beads_db_lease:<path>`) it also puts that path into
# `capture_log` output, which SideChannelCaptureTest asserts must never contain it.
Logger.put_application_level(:eventstore, :warning)

ExUnit.configure(
  exclude: [:langfuse, :external_llm, :docker],
  assert_receive_timeout: 1_000
)

# A run with a hand-written id left in the shared ProjectionStore outlives its test and is read by
# whichever later test types the same id (foreman-b8qjy, foreman-fhe9o): fail the suite and name
# the module that left it. The formatter half is registered by the `test` alias in mix.exs.
ForemanServer.TestSupport.ProjectionLeakGuard.install!()

ExUnit.start()
