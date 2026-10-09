defmodule ForemanServer.Jobsite.Runners.Direct do
  @moduledoc """
  `ForemanServer.Jobsite.Runner` implementation used by Jobsite scripts
  (`ForemanServer.Jobsite.Executor`, step 14/19): `Jido.Harness.Run.start/2`
  + `stream/2` + `await/2` directly, with live completion-signal detection
  and pause/cancel interrupt polling — `ForemanServer.Jobsite.AgentRunner`'s
  implementation, unchanged, reused here rather than duplicated.
  """

  @behaviour ForemanServer.Jobsite.Runner

  alias ForemanServer.Jobsite.AgentRunner

  @impl true
  def capabilities, do: %{iterations: :many, live_stream: true}

  @impl true
  def run(agent, prompt, sandbox, opts), do: AgentRunner.run(agent, prompt, sandbox, opts)
end
