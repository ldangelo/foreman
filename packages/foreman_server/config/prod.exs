import Config

# TRD-022 owns importing this file from config/config.exs.
# Secrets via System.fetch_env!/1 in dev/test; via Config.Provider secrets manager
# (Vault, AWS SM) in prod.

# Production: env vars MUST be set at boot. Missing vars crash loud at boot
# rather than silently producing `url: nil` that would fail at runtime.
eventstore_url = System.fetch_env!("EVENTSTORE_URL")
database_url = System.fetch_env!("DATABASE_URL")

phx_host = System.get_env("PHX_HOST", "localhost")
secret_source = System.get_env("FOREMAN_SERVER_SECRET_SOURCE", "env")

eventstore_url = env_or_nil.("EVENTSTORE_URL")
database_url = env_or_nil.("DATABASE_URL")

config :foreman_server, ForemanServer.EventStore,
  url: eventstore_url,
  serializer: ForemanServer.TermOrJsonSerializer,
  schema: "public"

config :foreman_server, ForemanServer.Repo, url: database_url

config :foreman_server, ForemanServerWeb.Endpoint,
  server: true,
  debug_errors: false,
  check_origin: ["//#{phx_host}", "https://#{phx_host}"]

config :foreman_server, :prod_secret_provider,
  provider: ForemanServer.ConfigProviders.Secrets,
  source: secret_source,
  mappings: [
    [
      app: :foreman_server,
      key: ForemanServer.EventStore,
      config_key: :url,
      env: "EVENTSTORE_URL"
    ],
    [app: :foreman_server, key: ForemanServer.Repo, config_key: :url, env: "DATABASE_URL"]
  ]
