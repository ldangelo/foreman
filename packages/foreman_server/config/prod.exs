import Config

# TRD-022 owns importing this file from config/config.exs.
# Production secrets are injected at release boot by
# ForemanServer.ConfigProviders.Secrets.

phx_host = System.get_env("PHX_HOST", "localhost")
secret_source = System.get_env("FOREMAN_SERVER_SECRET_SOURCE", "auto")
config :foreman_server, ForemanServer.EventStore,
  serializer: ForemanServer.TermOrJsonSerializer,
  schema: "public"

config :foreman_server, ForemanServer.Repo, []

config :foreman_server, ForemanServerWeb.Endpoint,
  server: true,
  debug_errors: false,
  check_origin: ["//#{phx_host}", "https://#{phx_host}"]

config :foreman_server, :secrets,
  database_password: nil,
  secret_key_base: nil,
  signing_salt: nil

config :foreman_server, :prod_secret_provider,
  provider: ForemanServer.ConfigProviders.Secrets,
  source: secret_source,
  mappings: [
    [
      app: :foreman_server,
      key: ForemanServer.EventStore,
      config_key: :url,
      env: "EVENTSTORE_URL",
      secret_key: :eventstore_url
    ],
    [
      app: :foreman_server,
      key: ForemanServer.Repo,
      config_key: :url,
      env: "DATABASE_URL",
      secret_key: :database_url
    ],
    [
      app: :foreman_server,
      key: :secrets,
      config_key: :database_password,
      env: "DATABASE_PASSWORD",
      secret_key: :database_password,
      required: false
    ],
    [
      app: :foreman_server,
      key: :secrets,
      config_key: :secret_key_base,
      env: "SECRET_KEY_BASE",
      secret_key: :secret_key_base
    ],
    [
      app: :foreman_server,
      key: :secrets,
      config_key: :signing_salt,
      env: "SIGNING_SALT",
      secret_key: :signing_salt
    ]
  ]
