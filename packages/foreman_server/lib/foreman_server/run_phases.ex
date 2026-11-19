defmodule ForemanServer.RunPhases do
  @moduledoc """
  The body of `GET /api/runs/:id/phases` (`foreman run phases <id>`): a run's phases in
  workflow order, each with its own status.

  A typed projection of the phase read model, not the read model itself: the phase projection
  also carries input artifacts, the execution profile and the artifact template, none of which
  belong to this contract, so only the fields below are ever served.
  """

  defmodule Phase do
    @moduledoc "One phase of a run: where it is, how often it was attempted and when it last moved."

    @enforce_keys [:phase_id, :index, :name, :attempt, :status]
    @type t :: %__MODULE__{
            phase_id: String.t(),
            index: integer(),
            name: String.t(),
            attempt: pos_integer(),
            status: String.t(),
            failure_reason: String.t() | nil,
            started_at_ms: integer() | nil,
            last_event_at_ms: integer() | nil,
            latest_stall: term()
          }
    @derive Jason.Encoder
    defstruct [
      :phase_id,
      :index,
      :name,
      :attempt,
      :status,
      :failure_reason,
      :started_at_ms,
      :last_event_at_ms,
      :latest_stall
    ]
  end

  @enforce_keys [:run_id, :phases]
  @type t :: %__MODULE__{run_id: String.t(), phases: [Phase.t()]}
  @derive Jason.Encoder
  defstruct [:run_id, :phases]

  @doc """
  Builds the body from the phase projections of `run_id`. A projection missing one of the
  identifying fields raises (`KeyError`): that is a broken read model, not an empty phase.
  """
  @spec build(String.t(), [map()]) :: t()
  def build(run_id, phase_projections) when is_binary(run_id) and is_list(phase_projections) do
    %__MODULE__{run_id: run_id, phases: Enum.map(phase_projections, &phase/1)}
  end

  defp phase(p) do
    %Phase{
      phase_id: Map.fetch!(p, :phase_id),
      index: Map.fetch!(p, :index),
      name: Map.fetch!(p, :name),
      attempt: Map.fetch!(p, :attempt),
      status: Map.fetch!(p, :status),
      failure_reason: Map.get(p, :failure_reason),
      started_at_ms: Map.get(p, :started_at_ms),
      last_event_at_ms: Map.get(p, :last_event_at_ms),
      latest_stall: Map.get(p, :latest_stall)
    }
  end
end
