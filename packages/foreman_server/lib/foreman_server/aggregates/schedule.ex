defmodule ForemanServer.Aggregates.Schedule do
  @moduledoc """
  A project-scoped scheduled task (`schedule:<project_id>:<schedule_id>`).

  Operator commands: `schedule.create`, `schedule.update`, `schedule.pause`,
  `schedule.resume`, `schedule.delete`. System commands (never in the operator
  allowlist, dispatched by `Schedule.Ticker`): `schedule.mark_fired` and
  `schedule.skip_fire`.

  The aggregate is pure: every timestamp arrives in the payload as `at`
  (stamped by `CommandGateway` for operator commands, by the ticker for system
  ones) and is never read from a clock here. Cross-aggregate reads are limited to
  existence checks through `ProjectionStore` (project, existing schedules) and
  the workflow catalog, the same precedent as `Aggregates.Task`.

  ## Slot dedupe

  `mark_fired` and `skip_fire` both *consume* a slot: `last_slot` advances and
  any command with `slot <= last_slot` is `{:error, {:slot_already_processed,
  slot}}`. A slot can therefore be fired or skipped exactly once, whatever the
  retry pattern.

  ## `active_since`

  Slots only count from `active_since` (unix seconds): creation, the last
  resume, or the last spec change. A schedule that sat paused for a week
  resumes without a "missed" burst for the paused period.
  """

  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.EventCodec
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Schedule.Spec
  alias ForemanServer.Workflow.Catalog

  alias ForemanServer.Events.{
    ScheduleCreated,
    ScheduleDeleted,
    ScheduleFired,
    ScheduleFireSkipped,
    SchedulePaused,
    ScheduleResumed,
    ScheduleUpdated
  }

  @max_prompt 16_000
  @max_name 200
  @overlaps ~w(skip allow)
  @skip_reasons ~w(missed overlap project_paused daily_cap error)
  @max_misfire_grace 7 * 86_400
  @default_misfire_grace 600
  @default_max_per_project 50
  @updatable ~w(name spec prompt workflow auto_approve overlap misfire_grace_seconds)

  @doc "Stream id for a schedule."
  @spec stream_id(String.t(), String.t()) :: String.t()
  def stream_id(project_id, schedule_id), do: "schedule:" <> project_id <> ":" <> schedule_id

  @doc "Skip reasons accepted by `schedule.skip_fire`."
  @spec skip_reasons() :: [String.t()]
  def skip_reasons, do: @skip_reasons

  defmodule State do
    @moduledoc "Folded schedule definition and fire cursor."
    @enforce_keys [:exists?, :status]
    defstruct [
      :exists?,
      :status,
      :project_id,
      :schedule_id,
      :name,
      :spec,
      :prompt,
      :workflow,
      :auto_approve,
      :overlap,
      :misfire_grace_seconds,
      :active_since,
      :last_slot,
      :last_task_id,
      :last_outcome
    ]
  end

  @impl true
  def initial_state, do: %State{exists?: false, status: nil}

  # ---------------------------------------------------------------------------
  # apply_event/2: tolerates unknown event types (replay must never crash)
  # ---------------------------------------------------------------------------

  @impl true
  def apply_event(%State{} = state, %ScheduleCreated{} = e) do
    %State{
      state
      | exists?: true,
        status: :active,
        project_id: e.project_id,
        schedule_id: e.schedule_id,
        name: e.name,
        spec: e.spec,
        prompt: e.prompt,
        workflow: e.workflow,
        auto_approve: e.auto_approve,
        overlap: e.overlap,
        misfire_grace_seconds: e.misfire_grace_seconds,
        active_since: unix(e.created_at)
    }
  end

  def apply_event(%State{} = state, %ScheduleUpdated{changes: changes, updated_at: at}) do
    state
    |> put_change(changes, "name", :name)
    |> put_change(changes, "spec", :spec)
    |> put_change(changes, "prompt", :prompt)
    |> put_change(changes, "workflow", :workflow)
    |> put_change(changes, "auto_approve", :auto_approve)
    |> put_change(changes, "overlap", :overlap)
    |> put_change(changes, "misfire_grace_seconds", :misfire_grace_seconds)
    |> then(fn %State{} = s ->
      if Map.has_key?(changes, "spec"), do: %State{s | active_since: unix(at)}, else: s
    end)
  end

  def apply_event(%State{} = state, %SchedulePaused{}), do: %State{state | status: :paused}

  def apply_event(%State{} = state, %ScheduleResumed{at: at}),
    do: %State{state | status: :active, active_since: unix(at)}

  def apply_event(%State{} = state, %ScheduleDeleted{}), do: %State{state | status: :deleted}

  def apply_event(%State{} = state, %ScheduleFired{slot: slot, task_id: task_id}),
    do: %State{state | last_slot: slot, last_task_id: task_id, last_outcome: :fired}

  def apply_event(%State{} = state, %ScheduleFireSkipped{slot: slot, reason: reason}),
    do: %State{state | last_slot: slot, last_outcome: {:skipped, reason}}

  def apply_event(%State{} = state, event) do
    case Aggregate.event_type(event) do
      type
      when type in ~w(ScheduleCreated ScheduleUpdated SchedulePaused ScheduleResumed
                      ScheduleDeleted ScheduleFired ScheduleFireSkipped) ->
        payload = event |> Aggregate.event_payload() |> Map.delete("event_type")
        apply_event(state, EventCodec.decode!(type, payload))

      _ ->
        state
    end
  end

  defp put_change(state, changes, key, field) do
    case Map.fetch(changes, key) do
      {:ok, value} -> Map.put(state, field, value)
      :error -> state
    end
  end

  defp unix(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp unix(_), do: nil

  # ---------------------------------------------------------------------------
  # handle_command/2
  # ---------------------------------------------------------------------------

  @impl true
  def handle_command(%State{exists?: true, schedule_id: id}, %{type: "schedule.create"}),
    do: {:error, {:already_exists, :schedule, id}}

  def handle_command(%State{}, %{type: "schedule.create", payload: payload}) do
    with {:ok, ids} <- ids(payload),
         {:ok, at} <- at(payload),
         {:ok, name} <- validate_name(Aggregate.get(payload, :name)),
         {:ok, prompt} <- validate_prompt(Aggregate.get(payload, :prompt)),
         {:ok, workflow} <- validate_workflow(Aggregate.get(payload, :workflow)),
         {:ok, spec} <- parse_spec(Aggregate.get(payload, :spec), at),
         {:ok, auto_approve} <- validate_bool(payload, :auto_approve, true),
         {:ok, overlap} <- validate_overlap(Aggregate.get(payload, :overlap) || "skip"),
         {:ok, grace} <-
           validate_grace(Aggregate.get(payload, :misfire_grace_seconds) || default_grace()),
         :ok <- validate_project(ids.project_id),
         :ok <- validate_limit(ids.project_id) do
      {:ok,
       emit(ids, "ScheduleCreated", %{
         name: name,
         spec: Spec.to_map(spec),
         prompt: prompt,
         workflow: workflow,
         auto_approve: auto_approve,
         overlap: overlap,
         misfire_grace_seconds: grace,
         created_at: at
       })}
    end
  end

  def handle_command(%State{exists?: false}, %{type: type, payload: payload})
      when type in ~w(schedule.update schedule.pause schedule.resume schedule.delete) do
    with {:ok, ids} <- ids(payload), do: {:error, {:schedule_not_found, ids.schedule_id}}
  end

  def handle_command(%State{status: :deleted, schedule_id: id}, %{type: type})
      when type in ~w(schedule.update schedule.pause schedule.resume schedule.delete),
      do: {:error, {:schedule_deleted, id}}

  def handle_command(%State{}, %{type: "schedule.update", payload: payload}) do
    with {:ok, ids} <- ids(payload),
         {:ok, at} <- at(payload),
         {:ok, changes} <- build_changes(payload, at),
         true <- map_size(changes) > 0 or {:error, {:missing_or_invalid, :changes, %{}}} do
      {:ok, emit(ids, "ScheduleUpdated", %{changes: changes, updated_at: at})}
    end
  end

  def handle_command(%State{status: :paused, schedule_id: id}, %{type: "schedule.pause"}),
    do: {:error, {:schedule_already_paused, id}}

  def handle_command(%State{}, %{type: "schedule.pause", payload: payload}) do
    with {:ok, ids} <- ids(payload), {:ok, at} <- at(payload) do
      {:ok, emit(ids, "SchedulePaused", %{at: at})}
    end
  end

  def handle_command(%State{status: :active, schedule_id: id}, %{type: "schedule.resume"}),
    do: {:error, {:schedule_not_paused, id}}

  def handle_command(%State{}, %{type: "schedule.resume", payload: payload}) do
    with {:ok, ids} <- ids(payload), {:ok, at} <- at(payload) do
      {:ok, emit(ids, "ScheduleResumed", %{at: at})}
    end
  end

  def handle_command(%State{}, %{type: "schedule.delete", payload: payload}) do
    with {:ok, ids} <- ids(payload), {:ok, at} <- at(payload) do
      {:ok, emit(ids, "ScheduleDeleted", %{at: at})}
    end
  end

  def handle_command(%State{exists?: false}, %{type: type, payload: payload})
      when type in ~w(schedule.mark_fired schedule.skip_fire) do
    with {:ok, ids} <- ids(payload), do: {:error, {:schedule_not_found, ids.schedule_id}}
  end

  def handle_command(%State{status: :deleted, schedule_id: id}, %{type: type})
      when type in ~w(schedule.mark_fired schedule.skip_fire),
      do: {:error, {:schedule_deleted, id}}

  def handle_command(%State{} = state, %{type: "schedule.mark_fired", payload: payload}) do
    with {:ok, ids} <- ids(payload),
         {:ok, slot} <- validate_slot(Aggregate.get(payload, :slot)),
         :ok <- require_new_slot(state, slot),
         {:ok, task_id} <- Aggregate.required_binary(Aggregate.get(payload, :task_id), :task_id),
         {:ok, intent_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :intent_id), :intent_id),
         {:ok, collapsed} <-
           validate_count(Aggregate.get(payload, :collapsed_count), :collapsed_count),
         {:ok, at} <- at(payload) do
      {:ok,
       emit(ids, "ScheduleFired", %{
         slot: slot,
         task_id: task_id,
         intent_id: intent_id,
         collapsed_count: collapsed,
         fired_at: at
       })}
    end
  end

  def handle_command(%State{} = state, %{type: "schedule.skip_fire", payload: payload}) do
    with {:ok, ids} <- ids(payload),
         {:ok, slot} <- validate_slot(Aggregate.get(payload, :slot)),
         :ok <- require_new_slot(state, slot),
         {:ok, reason} <- validate_skip_reason(Aggregate.get(payload, :reason)),
         {:ok, missed} <- validate_count(Aggregate.get(payload, :missed_count), :missed_count),
         :ok <- Aggregate.optional_binary(Aggregate.get(payload, :detail), :detail),
         {:ok, at} <- at(payload) do
      {:ok,
       emit(ids, "ScheduleFireSkipped", %{
         slot: slot,
         reason: reason,
         missed_count: missed,
         detail: Aggregate.get(payload, :detail),
         skipped_at: at
       })}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp emit(%{project_id: project_id, schedule_id: schedule_id}, event_type, fields) do
    module = Module.concat(ForemanServer.Events, event_type)

    payload =
      module
      |> struct!(Map.merge(fields, %{project_id: project_id, schedule_id: schedule_id}))
      |> Map.from_struct()

    %{stream_id: stream_id(project_id, schedule_id), event_type: event_type, payload: payload}
  end

  defp ids(payload) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, schedule_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :schedule_id), :schedule_id) do
      {:ok, %{project_id: project_id, schedule_id: schedule_id}}
    end
  end

  defp at(payload), do: Aggregate.required_binary(Aggregate.get(payload, :at), :at)

  defp validate_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:error, {:missing_or_invalid, :name}}
      String.length(trimmed) > @max_name -> {:error, {:name_too_long, String.length(trimmed)}}
      true -> {:ok, trimmed}
    end
  end

  defp validate_name(_), do: {:error, {:missing_or_invalid, :name}}

  defp validate_prompt(prompt) when is_binary(prompt) do
    cond do
      String.trim(prompt) == "" -> {:error, {:missing_or_invalid, :prompt}}
      String.length(prompt) > @max_prompt -> {:error, {:prompt_too_long, String.length(prompt)}}
      true -> {:ok, prompt}
    end
  end

  defp validate_prompt(_), do: {:error, {:missing_or_invalid, :prompt}}

  defp validate_workflow(workflow) when is_binary(workflow) and workflow != "" do
    case Catalog.load(workflow <> ".yaml") do
      {:ok, _manifest} -> {:ok, workflow}
      {:error, _reason} -> {:error, {:unknown_workflow, workflow}}
    end
  end

  defp validate_workflow(_), do: {:error, {:missing_or_invalid, :workflow}}

  defp parse_spec(spec, at) do
    default_anchor =
      case DateTime.from_iso8601(at) do
        {:ok, dt, _} -> dt
        _ -> nil
      end

    case Spec.parse(spec, default_anchor: default_anchor) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} = error -> error
    end
  end

  defp validate_bool(payload, key, default) do
    case Aggregate.get(payload, key, default) do
      value when is_boolean(value) -> {:ok, value}
      nil -> {:ok, default}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp validate_overlap(value) when value in @overlaps, do: {:ok, value}
  defp validate_overlap(value), do: {:error, {:invalid_overlap, value}}

  defp validate_grace(value)
       when is_integer(value) and value >= 0 and value <= @max_misfire_grace,
       do: {:ok, value}

  defp validate_grace(value), do: {:error, {:invalid_misfire_grace_seconds, value}}

  defp validate_slot(slot) when is_integer(slot) and slot >= 0, do: {:ok, slot}
  defp validate_slot(_), do: {:error, {:missing_or_invalid, :slot}}

  defp validate_count(nil, _key), do: {:ok, nil}
  defp validate_count(n, _key) when is_integer(n) and n >= 0, do: {:ok, n}
  defp validate_count(_, key), do: {:error, {:missing_or_invalid, key}}

  defp validate_skip_reason(reason) when is_binary(reason) and reason in @skip_reasons,
    do: {:ok, reason}

  defp validate_skip_reason(reason), do: {:error, {:invalid_skip_reason, reason}}

  defp require_new_slot(%State{last_slot: last}, slot) when is_integer(last) and slot <= last,
    do: {:error, {:slot_already_processed, slot}}

  defp require_new_slot(%State{}, _slot), do: :ok

  defp validate_project(project_id) do
    case ProjectionStore.project(project_id) do
      nil -> {:error, {:project_not_found, project_id}}
      %{status: "archived"} -> {:error, {:project_archived, project_id}}
      %{archived?: true} -> {:error, {:project_archived, project_id}}
      _ -> :ok
    end
  end

  defp validate_limit(project_id) do
    max = config(:max_per_project, @default_max_per_project)
    count = project_id |> ProjectionStore.schedules() |> length()

    if count >= max, do: {:error, {:schedule_limit_reached, max}}, else: :ok
  end

  defp build_changes(payload, at) do
    Enum.reduce_while(@updatable, {:ok, %{}}, fn key, {:ok, acc} ->
      atom_key = String.to_existing_atom(key)

      case Aggregate.get(payload, atom_key) do
        nil ->
          {:cont, {:ok, acc}}

        value ->
          case validate_change(key, value, at) do
            {:ok, normalised} -> {:cont, {:ok, Map.put(acc, key, normalised)}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp validate_change("name", v, _at), do: validate_name(v)
  defp validate_change("prompt", v, _at), do: validate_prompt(v)
  defp validate_change("workflow", v, _at), do: validate_workflow(v)
  defp validate_change("overlap", v, _at), do: validate_overlap(v)
  defp validate_change("misfire_grace_seconds", v, _at), do: validate_grace(v)

  defp validate_change("auto_approve", v, _at) when is_boolean(v), do: {:ok, v}

  defp validate_change("auto_approve", _v, _at),
    do: {:error, {:missing_or_invalid, :auto_approve}}

  defp validate_change("spec", v, at) do
    with {:ok, spec} <- parse_spec(v, at), do: {:ok, Spec.to_map(spec)}
  end

  defp default_grace, do: config(:default_misfire_grace_seconds, @default_misfire_grace)

  defp config(key, default) do
    :foreman_server |> Application.get_env(:schedule, []) |> Keyword.get(key, default)
  end
end
