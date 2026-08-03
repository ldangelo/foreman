import Config
config :foreman_server,
  event_stores: [ForemanServer.EventStore]

# EventStore — connection from DATABASE_URL env, defaulting to localhost:55432
config :foreman_server, ForemanServer.EventStore,
  url: System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:55432/foreman_eventstore_test"),
  serializer: ForemanServer.TermOrJsonSerializer,
  schema: "public"

config :foreman_server, ForemanServerWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [html: ForemanServerWeb.ErrorHTML], layout: false],
  pubsub_server: ForemanServer.PubSub,
  live_view: [signing_salt: "foremandebug"],
  secret_key_base: String.duplicate("a", 64),
  server: false

import_config "#{config_env()}.exs"