# The test database is shared across runs and ProjectionStore rebuilds its whole
# read model from the event log at boot. Without a reset every run inherits every
# prior run's events (48k+ observed), which makes read-after-write assertions time
# out on projection catch-up and makes randomly generated ids collide with tasks
# left by earlier runs.
config = EventStore.Config.parsed(ForemanServer.EventStore, :foreman_server)
{:ok, conn} = Postgrex.start_link(EventStore.Config.default_postgrex_opts(config))
EventStore.Storage.Initializer.reset!(conn, config)
GenServer.stop(conn)

# Give this VM a private temp directory. Tests build scratch paths under
# `System.tmp_dir!/0` as "<prefix>-#{System.unique_integer([:positive])}", but that counter
# restarts at 1 in every VM, so two `mix test` runs on one machine (parallel CI jobs, several
# worktrees, a developer's second terminal) hand out the same names in the shared system temp
# dir. One run's `on_exit` cleanup then deletes the other's repo or worktree under it: an agent
# whose cwd vanished exits 1 ("agent_failed ... exit_status 256"), a prompt log disappears
# mid-test, a `git push` finds no repository. `System.tmp_dir!/0` and every child process read
# TMPDIR, so pointing it at a per-VM directory removes the collision for all ~200 sites at once.
vm_tmp = Path.join(System.tmp_dir!(), "fm-test-#{System.pid()}")
File.rm_rf!(vm_tmp)
File.mkdir_p!(vm_tmp)
System.put_env("TMPDIR", vm_tmp)
ExUnit.after_suite(fn _ -> File.rm_rf(vm_tmp) end)

# `:eventstore` logs every append, notification and subscription push at :debug.
# It is ~20k lines of a CI log, and because the Beads lease stream id embeds the
# absolute DB path (`beads_db_lease:<path>`) it also puts that path into
# `capture_log` output, which SideChannelCaptureTest asserts must never contain it.
Logger.put_application_level(:eventstore, :warning)

ExUnit.configure(
  exclude: [:langfuse, :external_llm, :docker],
  assert_receive_timeout: 1_000
)

ExUnit.start()
