defmodule ForemanServer.MultiRepoRuns do
  @moduledoc """
  Test helper: enables the multi-repository run gate for ONE test.

  `config :foreman_server, :multi_repo, runs: false` refuses multi-repo runs at
  start. A test that exercises them calls `enable!/0`, which sets
  `runs: true` and restores the previous value in `on_exit`.
  """

  @doc "Enables `:multi_repo, runs: true` until the calling test exits."
  @spec enable!() :: :ok
  def enable! do
    previous = Application.fetch_env(:foreman_server, :multi_repo)
    Application.put_env(:foreman_server, :multi_repo, runs: true)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:foreman_server, :multi_repo, value)
        :error -> Application.delete_env(:foreman_server, :multi_repo)
      end
    end)

    :ok
  end
end
