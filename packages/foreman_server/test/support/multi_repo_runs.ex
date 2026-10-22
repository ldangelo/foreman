defmodule ForemanServer.MultiRepoRuns do
  @moduledoc """
  Test helper: sets the multi-repository run gate for ONE test.

  `config :foreman_server, :multi_repo, runs: <bool>` decides whether a run over
  more than one repository may start. A test that depends on the gate states it
  instead of inheriting whatever the committed default is: `enable!/0` sets
  `runs: true`, `disable!/0` sets `runs: false`, and the previous value is
  restored in `on_exit`.
  """

  @doc "Sets `:multi_repo, runs: true` until the calling test exits."
  @spec enable!() :: :ok
  def enable!, do: put!(true)

  @doc "Sets `:multi_repo, runs: false` until the calling test exits."
  @spec disable!() :: :ok
  def disable!, do: put!(false)

  defp put!(runs?) do
    previous = Application.fetch_env(:foreman_server, :multi_repo)
    Application.put_env(:foreman_server, :multi_repo, runs: runs?)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:foreman_server, :multi_repo, value)
        :error -> Application.delete_env(:foreman_server, :multi_repo)
      end
    end)

    :ok
  end
end
