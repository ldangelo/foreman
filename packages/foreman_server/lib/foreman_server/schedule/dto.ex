defmodule ForemanServer.Schedule.DTO do
  @moduledoc """
  The one wire shape of a schedule read (`GET /api/projects/:id/schedules`, which
  is the Scheduled-tab data, and the MCP `foreman_schedule_list` tool): an
  enforced-keys struct built by `from_projection/3`, JSON-encoded with its field
  names as snake_case keys.

  `next_fire_at` is computed on read from the spec (`Spec.next_after/2`, strictly
  after `now`) and is nil for a paused or deleted schedule. `prompt` is truncated
  to 500 characters in this list view. `last_outcome` is the latest fire or
  skip (`kind`, `slot`, `reason`, `missed_count`, `at`): it is how an operator
  sees WHY a fire was skipped.
  """

  require Logger

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Schedule.{Spec, Ticker}

  @prompt_limit 500

  @enforce_keys [
    :schedule_id,
    :project_id,
    :name,
    :spec,
    :timezone,
    :prompt,
    :workflow,
    :auto_approve,
    :overlap,
    :misfire_grace_seconds,
    :status,
    :next_fire_at,
    :last_outcome,
    :last_task_id
  ]
  @derive Jason.Encoder
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schedule_id: String.t(),
          project_id: String.t(),
          name: String.t(),
          spec: %{String.t() => String.t()},
          timezone: String.t(),
          prompt: String.t(),
          workflow: String.t(),
          auto_approve: boolean() | nil,
          overlap: String.t() | nil,
          misfire_grace_seconds: non_neg_integer() | nil,
          status: String.t(),
          next_fire_at: String.t() | nil,
          last_outcome: map() | nil,
          last_task_id: String.t() | nil
        }

  @doc "Build a DTO from a `ProjectionStore.schedule()` record."
  @spec from_projection(ProjectionStore.schedule(), DateTime.t()) :: t()
  def from_projection(record, %DateTime{} = now) do
    %__MODULE__{
      schedule_id: record.schedule_id,
      project_id: record.project_id,
      name: record.name,
      spec: record.spec,
      timezone: Map.get(record.spec, "timezone", "UTC"),
      prompt: String.slice(record.prompt, 0, @prompt_limit),
      workflow: record.workflow,
      auto_approve: record.auto_approve,
      overlap: record.overlap,
      misfire_grace_seconds: record.misfire_grace_seconds,
      status: record.status,
      next_fire_at: next_fire_at(record, now),
      last_outcome: record.last_outcome,
      last_task_id: record.last_task_id
    }
  end

  @doc """
  A project's non-deleted schedules as DTOs, sorted by `next_fire_at` (paused
  last) then name.
  """
  @spec list(String.t(), DateTime.t()) :: [t()]
  def list(project_id, %DateTime{} = now \\ DateTime.utc_now()) do
    project_id
    |> ProjectionStore.schedules()
    |> Enum.map(&from_projection(&1, now))
    |> Enum.sort_by(&{is_nil(&1.next_fire_at), &1.next_fire_at, &1.name})
  end

  @doc "`\"running\"` when the ticker process is alive, else `\"disabled\"`."
  @spec ticker_status() :: String.t()
  def ticker_status, do: if(Ticker.running?(), do: "running", else: "disabled")

  defp next_fire_at(%{status: "active"} = record, now) do
    with {:ok, spec} <- Spec.parse(record.spec),
         {:ok, next} <- Spec.next_after(spec, now) do
      DateTime.to_iso8601(next)
    else
      error ->
        Logger.warning(
          "Schedule.DTO could not compute next_fire_at for #{record.schedule_id}: #{inspect(error)}"
        )

        nil
    end
  end

  defp next_fire_at(_record, _now), do: nil
end
