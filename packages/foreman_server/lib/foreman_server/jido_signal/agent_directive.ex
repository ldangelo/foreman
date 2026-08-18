defmodule ForemanServer.JidoSignal.AgentDirective do
  @moduledoc """
  AgentDirective signal type for Foreman agent communication.

  This signal is used for Agent→Agent communication via Bus.publish
  to the agents/<phase> topic.
  """
  use Jido.Signal,
    type: "foreman.agent.directive.v1",
    default_source: "/foreman/agents",
    schema: [
      task_id: [type: :string, required: true],
      phase: [type: :string, required: true],
      directive: [type: :string, required: true],
      data: [type: :map, required: false, default: %{}]
    ]

  @doc """
  Creates a new AgentDirective signal.

  ## Parameters
  - `task_id`: The task ID this directive is for
  - `phase`: The phase this directive is for (e.g., "review", "implement")
  - `directive`: The directive text
  - `data`: Optional additional data

  ## Returns
  - `{:ok, signal}` on success
  - `{:error, reason}` on failure
  """
  @spec new(String.t(), String.t(), String.t(), map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def new(task_id, phase, directive, data \\ %{}) do
    signal_data = %{
      task_id: task_id,
      phase: phase,
      directive: directive,
      data: data
    }

    new(signal_data)
  end
end
