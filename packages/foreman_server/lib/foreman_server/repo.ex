defmodule ForemanServer.Repo do
  @moduledoc "Ecto repository for Foreman Server's Postgres-backed event store."

  use Ecto.Repo,
    otp_app: :foreman_server,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_type, config) do
    database_url =
      Application.get_env(:foreman_server, :database_url) ||
        System.get_env("DATABASE_URL")

    if is_binary(database_url) and database_url != "" do
      {:ok, Keyword.put(config, :url, database_url)}
    else
      {:ok, config}
    end
  end
end
