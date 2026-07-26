import Config

# EventStore — connection from DATABASE_URL env, defaulting to localhost:55432
config :foreman_server, ForemanServer.EventStore,
  url: System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:55432/foreman_eventstore_test"),
  serializer: EventStore.JsonSerializer
