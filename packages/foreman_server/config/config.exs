import Config

config :foreman_server,
  ecto_repos: [ForemanServer.Repo]

config :foreman_server, ForemanServer.Repo,
  pool_size: String.to_integer(System.get_env("FOREMAN_SERVER_DB_POOL_SIZE") || "10")

import_config "#{config_env()}.exs"
