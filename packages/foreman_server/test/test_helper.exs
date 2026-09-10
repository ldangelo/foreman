# The test database is shared across runs and ProjectionStore rebuilds its whole
# read model from the event log at boot. Without a reset every run inherits every
# prior run's events (48k+ observed), which makes read-after-write assertions time
# out on projection catch-up and makes randomly generated ids collide with tasks
# left by earlier runs.
config = EventStore.Config.parsed(ForemanServer.EventStore, :foreman_server)
{:ok, conn} = Postgrex.start_link(EventStore.Config.default_postgrex_opts(config))
EventStore.Storage.Initializer.reset!(conn, config)
GenServer.stop(conn)

# `:eventstore` logs every append, notification and subscription push at :debug.
# It is ~20k lines of a CI log, and because the Beads lease stream id embeds the
# absolute DB path (`beads_db_lease:<path>`) it also puts that path into
# `capture_log` output, which SideChannelCaptureTest asserts must never contain it.
Logger.put_application_level(:eventstore, :warning)

ExUnit.configure(
  exclude: [:langfuse, :external_llm],
  assert_receive_timeout: 1_000
)

ExUnit.start()
