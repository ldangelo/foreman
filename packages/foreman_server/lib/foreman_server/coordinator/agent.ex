defmodule ForemanServer.Coordinator.Agent do
  @moduledoc """
  The seam between the coordinator turn loop and whatever produces a turn.

  `turn/2` receives the rendered, bounded `Coordinator.Context` and returns the
  agent's `Coordinator.Turn` or a typed error. Production is
  `Coordinator.Agent.Harness` (a provider agent through the harness emitting one
  fenced JSON block, per spike S1); tests use `Coordinator.Agent.Stub`. Which
  implementation runs is `config :foreman_server, :coordinator, :agent`, passed
  per supervisor instance, never read from global state mid-turn.

  Provider, model and effort come from the project's settings
  (`coordinator_provider`, `coordinator_model`, `coordinator_effort`) and are
  handed to the agent through `opts` (`:provider`, `:model`, `:effort`).
  """

  alias ForemanServer.Coordinator.{Context, Error, Turn}

  @callback turn(Context.t(), keyword()) :: {:ok, Turn.t()} | {:error, Error.t()}
end
