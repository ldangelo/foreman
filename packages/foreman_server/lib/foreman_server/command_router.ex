defmodule ForemanServer.CommandRouter do
  @moduledoc """
  Sole append point for the event store.

  All commands from all ingress paths (Phoenix HTTP, worker protocol, overwatch)
  must eventually route through this module. Only this module (or its private
  helpers) call `EventStore.append_to_stream`.

  ## Actor ↔ CommandRouter protocol

  1. Actor sends `{:append, aggregate_id, event_data_list, expected_version, actor_pid}`.
     The `event_data_list` is a list of pre-normalized `%EventData{}` structs.
  2. CommandRouter appends via `EventStore.append_to_stream(stream_uuid, expected_version, event_data_list)`.
     Returns `:ok` on success.
  3. CommandRouter sends result back to `actor_pid`:
     - `{:append_ok, event_count}` on success
     - `{:append_error, reason}` on conflict or other failure

  ## Run admission

  Run admission follows a one-way internal call graph:

      Dispatcher / Reconciler -> RunAdmission.start/2 -> dispatch_run_start/2 -> do_dispatch/2

  `dispatch_run_start/2` is public so supervised workflow components can call it,
  but it remains an internal OTP surface. External callers MUST enter through
  `ForemanServer.RunAdmission.start/2` so telemetry is emitted consistently.
  """

  alias EventStore.{EventData, RecordedEvent}
  alias ForemanServer.{Aggregate, EventStore, Aggregate.Actor, Identity, Telemetry}
  use GenServer
  require Logger

  @default_post_commit_retry_delays_ms [50, 200, 1_000]
  @run_reservation_sequence 0
  @definitive_run_start_rejections MapSet.new([
                                     :phase_terminal,
                                     :project_archived,
                                     :unknown_project,
                                     :unknown_workflow
                                   ])

  @project_projection_event_types MapSet.new([
                                    "ProjectRegistered",
                                    "ProjectUpdated",
                                    "ProjectArchived",
                                    "ProjectReactivated"
                                  ])

  @doc """
  Dispatch a command to its aggregate.

  Determines the aggregate module from the aggregate_id prefix, starts the aggregate
  actor, and returns the command result.
  """
  @spec dispatch(command :: map(), timeout :: integer()) ::
          {:ok, event_spec :: map() | nil}
          | {:error, any()}
  def dispatch(command, timeout \\ 5_000)

  def dispatch(%{type: "run.start"}, _timeout) do
    raise ArgumentError,
          "ForemanServer.CommandRouter.dispatch/2 rejects type: \"run.start\"; use ForemanServer.RunAdmission.start/2"
  end

  def dispatch(%{aggregate_id: _aggregate_id} = command, timeout) do
    do_dispatch(command, timeout)
  end

  @doc """
  Internal run-start dispatch surface.

  Public only so supervised workflow automation can preserve the one-way
  admission flow. External callers MUST use `ForemanServer.RunAdmission.start/2`.
  """
  @spec dispatch_run_start(String.t(), map(), integer()) ::
          {:ok, event_spec :: map() | nil}
          | {:error, any()}
  def dispatch_run_start(project_id, payload, timeout \\ 5_000)

  def dispatch_run_start(project_id, payload, timeout)
      when is_binary(project_id) and project_id != "" and is_map(payload) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- Aggregate.optional_binary(Aggregate.get(payload, :task_id), :task_id) do
      command_id =
        Identity.run_start_command_id(
          project_id,
          run_id,
          workflow_snapshot_hash(Aggregate.get(payload, :workflow_snapshot))
        )

      normalized_payload = Map.put(payload, :project_id, project_id)
      do_dispatch_run_start(command_id, %{payload: normalized_payload, timeout: timeout})
    end
  end

  def dispatch_run_start(project_id, _payload, _timeout),
    do: {:error, {:missing_or_invalid, :project_id, project_id}}

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)
  # GenServer callbacks
  # -------------------------------------------------------------------------

  @impl true
  def init(_init_arg) do
    {:ok, %{quarantined_aggregates: MapSet.new()}}
  end

  @impl true
  def handle_info(
        {:append, aggregate_id, event_data_list, expected_version, ref, actor_pid},
        state
      ) do
    if MapSet.member?(state.quarantined_aggregates, aggregate_id) do
      send(actor_pid, {:error, ref, :projection_recovery_failed, 0})
      {:noreply, state}
    else
      append_and_project(
        aggregate_id,
        event_data_list,
        expected_version,
        ref,
        actor_pid,
        state
      )
    end
  end

  # -------------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------------
  defp append_and_project(
         aggregate_id,
         event_data_list,
         expected_version,
         ref,
         actor_pid,
         state
       ) do
    append_started_at_ms = System.monotonic_time(:millisecond)
    result = append_events(aggregate_id, expected_version, event_data_list)
    append_latency_ms = elapsed_ms(append_started_at_ms)

    case result do
      :ok ->
        recovery_result =
          case post_commit_apply(aggregate_id, expected_version, event_data_list) do
            :ok ->
              :ok

            {:error, reason} ->
              recover_projection_store(aggregate_id, event_data_list, reason)
          end

        send(actor_pid, {:append_ok, ref, length(event_data_list), append_latency_ms})

        case recovery_result do
          :ok ->
            {:noreply, state}

          {:error, reason} ->
            Logger.error(
              "CommandRouter quarantined #{aggregate_id} after projection recovery failed: " <>
                inspect(reason)
            )

            {:noreply, update_in(state.quarantined_aggregates, &MapSet.put(&1, aggregate_id))}
        end

      {:error, reason} ->
        send(actor_pid, {:error, ref, reason, append_latency_ms})
        {:noreply, state}
    end
  end

  defp do_dispatch_run_start(command_id, %{payload: payload, timeout: timeout}) do
    project_id = Aggregate.get(payload, :project_id)
    run_id = Aggregate.get(payload, :run_id)
    implementation_key = extract_implementation_key(payload)

    reservation_result =
      do_dispatch(
        %{
          aggregate_id: "project:#{project_id}",
          command_id: command_id,
          type: "project.reserve_run",
          payload: %{
            project_id: project_id,
            run_id: run_id,
            command_id: command_id,
            sequence: @run_reservation_sequence,
            run_start_payload: payload,
            implementation_key: implementation_key,
            max_concurrent_runs_per_project:
              ForemanServer.RunSlots.Config.max_concurrent_runs_per_project()
          }
        },
        timeout
      )

    case reservation_result do
      {:ok, _event_spec} ->
        dispatch_reserved_run_start(command_id, payload, timeout, project_id, run_id)

      {:error, reason} ->
        {:error, normalize_run_start_reason(reason)}
    end
  end

  defp dispatch_reserved_run_start(command_id, payload, timeout, project_id, run_id) do
    result =
      do_dispatch(
        %{
          aggregate_id: "run:#{run_id}",
          command_id: command_id,
          type: "run.start",
          payload: payload
        },
        timeout
      )

    case result do
      {:error, reason} ->
        normalized_reason = normalize_run_start_reason(reason)
        maybe_release_reservation(project_id, run_id, normalized_reason, timeout)
        {:error, normalized_reason}

      other ->
        other
    end
  end

  defp maybe_release_reservation(project_id, run_id, reason, timeout) do
    if MapSet.member?(@definitive_run_start_rejections, reason) do
      release_reason = release_reason(reason)

      _ =
        do_dispatch(
          %{
            aggregate_id: "project:#{project_id}",
            command_id:
              Identity.project_run_reservation_release_command_id(
                project_id,
                run_id,
                release_reason
              ),
            type: "project.release_run_reservation",
            payload: %{
              project_id: project_id,
              run_id: run_id,
              reason: release_reason
            }
          },
          timeout
        )

      :ok
    else
      :ok
    end
  end

  defp do_dispatch(%{aggregate_id: aggregate_id} = command, timeout) do
    started_at_ms = System.monotonic_time(:millisecond)
    aggregate_module = aggregate_module_for(aggregate_id)
    {:ok, _pid} = ForemanServer.Aggregator.start_aggregate(aggregate_module, aggregate_id)

    result =
      aggregate_id
      |> Actor.via()
      |> GenServer.call({:command, command}, timeout)

    finalize_dispatch(result, aggregate_id, started_at_ms)
  end

  defp release_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp release_reason(reason) when is_binary(reason), do: reason
  defp release_reason(reason), do: inspect(reason)

  defp normalize_run_start_reason({:project_archived, _project_id}), do: :project_archived
  defp normalize_run_start_reason({:not_found, :project, _project_id}), do: :unknown_project

  defp normalize_run_start_reason({:missing_or_invalid, :workflow_snapshot}),
    do: :unknown_workflow

  defp normalize_run_start_reason({:missing_or_invalid, :workflow_snapshot, _value}),
    do: :unknown_workflow

  defp normalize_run_start_reason(
         {:implementation_already_active, implementation_key, existing_run_id}
       ),
       do: {:implementation_already_active, implementation_key, existing_run_id}

  defp normalize_run_start_reason(reason), do: reason

  defp extract_implementation_key(%{workflow_snapshot: workflow_snapshot})
       when is_map(workflow_snapshot) do
    case Aggregate.get(workflow_snapshot, "implementation") do
      %{} = impl -> Aggregate.get(impl, "implementation_key")
      _ -> nil
    end
  end

  defp extract_implementation_key(_payload), do: nil

  defp workflow_snapshot_hash(snapshot) when is_map(snapshot) do
    snapshot
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp workflow_snapshot_hash(_snapshot), do: "unknown_workflow"

  # event_data_list is already a list of %EventData{} — pass through directly.
  # EventStore.append_to_stream/4 returns :ok on success.
  defp append_events(aggregate_id, expected_version, event_data_list)
       when is_list(event_data_list) do
    case EventStore.append_to_stream(aggregate_id, expected_version, event_data_list) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_back_appended_events(aggregate_id, expected_version, event_data_list)
       when is_binary(aggregate_id) and is_integer(expected_version) and is_list(event_data_list) do
    appended_count = length(event_data_list)
    appended_start_version = expected_version + 1

    case EventStore.read_stream_forward(aggregate_id, appended_start_version, appended_count) do
      {:ok, recorded_events} ->
        validate_appended_events(recorded_events, expected_version, event_data_list)

      {:error, reason} ->
        {:error, {:appended_tail_read_failed, reason}}
    end
  end

  defp validate_appended_events(recorded_events, expected_version, event_data_list)
       when is_list(recorded_events) and is_list(event_data_list) do
    expected_count = length(event_data_list)

    cond do
      length(recorded_events) != expected_count ->
        {:error,
         {:appended_tail_count_mismatch,
          %{expected_count: expected_count, actual_count: length(recorded_events)}}}

      appended_tail_matches?(recorded_events, expected_version, event_data_list) ->
        {:ok, recorded_events}

      true ->
        {:error,
         {:appended_tail_mismatch,
          %{expected_version: expected_version, event_count: expected_count}}}
    end
  end

  defp appended_tail_matches?(recorded_events, expected_version, event_data_list) do
    recorded_events
    |> Enum.zip(event_data_list)
    |> Enum.with_index(1)
    |> Enum.all?(fn {{%RecordedEvent{} = recorded, %EventData{} = event_data}, offset} ->
      recorded.stream_version == expected_version + offset and
        recorded.event_type == event_data.event_type and
        appended_event_id_matches?(recorded.event_id, event_data.event_id)
    end)
  end

  defp appended_event_id_matches?(_recorded_event_id, nil), do: true
  defp appended_event_id_matches?(recorded_event_id, event_id), do: recorded_event_id == event_id

  defp projection_events_for_apply(recorded_events, event_data_list)
       when is_list(recorded_events) and is_list(event_data_list) do
    recorded_events
    |> Enum.zip(event_data_list)
    |> Enum.map(fn {recorded, event_data} ->
      if MapSet.member?(@project_projection_event_types, recorded.event_type) do
        recorded
      else
        event_data
      end
    end)
  end

  defp post_commit_apply(aggregate_id, expected_version, event_data_list) do
    try do
      result =
        if requires_recorded_metadata?(event_data_list) do
          with :ok <-
                 maybe_fail_post_commit_readback(
                   aggregate_id,
                   expected_version,
                   event_data_list
                 ),
               {:ok, recorded_events} <-
                 read_back_appended_events(aggregate_id, expected_version, event_data_list) do
            apply_projection_events(recorded_events, event_data_list)
          end
        else
          ForemanServer.ProjectionStore.apply_events(event_data_list)
        end

      with :ok <- result do
        broadcast_debug_updates(event_data_list)
        :ok
      end
    rescue
      exception ->
        {:error, {:post_commit_exception, exception.__struct__, Exception.message(exception)}}
    catch
      kind, reason ->
        {:error, {:post_commit_throw, kind, reason}}
    end
  end

  defp requires_recorded_metadata?(event_data_list) do
    Enum.any?(event_data_list, fn %EventData{event_type: event_type} ->
      MapSet.member?(@project_projection_event_types, event_type)
    end)
  end

  defp maybe_fail_post_commit_readback(aggregate_id, expected_version, event_data_list) do
    case Application.get_env(:foreman_server, :command_router_post_commit_readback_hook) do
      hook when is_function(hook, 3) ->
        hook.(aggregate_id, expected_version, event_data_list)

      _ ->
        :ok
    end
  end

  defp apply_projection_events(recorded_events, event_data_list) do
    ForemanServer.ProjectionStore.apply_events(
      projection_events_for_apply(recorded_events, event_data_list)
    )
  end

  defp recover_projection_store(aggregate_id, event_data_list, initial_reason) do
    Logger.warning(
      "CommandRouter post-commit apply failed for #{aggregate_id}: #{inspect(initial_reason)}; " <>
        "rebuilding projection before releasing the aggregate"
    )

    case rebuild_projection_store(aggregate_id, event_data_list) do
      :ok ->
        :ok

      {:error, reason} ->
        retry_projection_rebuild(
          aggregate_id,
          event_data_list,
          post_commit_retry_delays_ms(),
          reason
        )
    end
  end

  defp rebuild_projection_store(aggregate_id, event_data_list) do
    try do
      case aggregate_id do
        "project:" <> project_id ->
          ForemanServer.ProjectionStore.rebuild_project(project_id, event_data_list)

        _ ->
          ForemanServer.ProjectionStore.rebuild(event_data_list)
      end
    rescue
      exception ->
        {:error,
         {:projection_rebuild_exception, exception.__struct__, Exception.message(exception)}}
    catch
      kind, reason ->
        {:error, {:projection_rebuild_throw, kind, reason}}
    end
  end

  defp retry_projection_rebuild(_aggregate_id, _event_data_list, [], reason),
    do: {:error, reason}

  defp retry_projection_rebuild(aggregate_id, event_data_list, [delay_ms | remaining], reason) do
    Logger.warning(
      "CommandRouter projection rebuild failed for #{aggregate_id}: #{inspect(reason)}; " <>
        "retrying in #{delay_ms}ms"
    )

    Process.sleep(delay_ms)

    case rebuild_projection_store(aggregate_id, event_data_list) do
      :ok ->
        :ok

      {:error, next_reason} ->
        retry_projection_rebuild(aggregate_id, event_data_list, remaining, next_reason)
    end
  end

  defp post_commit_retry_delays_ms do
    case Application.get_env(:foreman_server, :command_router_post_commit_retry_delays_ms) do
      delays_ms when is_list(delays_ms) ->
        Enum.filter(delays_ms, fn
          delay_ms when is_integer(delay_ms) and delay_ms >= 0 -> true
          _ -> false
        end)

      _ ->
        @default_post_commit_retry_delays_ms
    end
  end

  defp broadcast_debug_updates(event_data_list) do
    event_data_list
    |> Enum.flat_map(&debug_topics_for_event/1)
    |> MapSet.new()
    |> Enum.each(fn topic ->
      Phoenix.PubSub.broadcast(ForemanServer.PubSub, topic, {:debug_state_changed, topic})
    end)
  end

  defp debug_topics_for_event(%EventData{data: payload}) do
    run_id = Map.get(payload, :run_id) || Map.get(payload, "run_id")
    phase_id = Map.get(payload, :phase_id) || Map.get(payload, "phase_id")
    worker_id = Map.get(payload, :worker_id) || Map.get(payload, "worker_id")

    []
    |> maybe_add_topic("runs")
    |> maybe_add_topic(run_id && "runs:#{run_id}")
    |> maybe_add_topic(phase_id && "phases")
    |> maybe_add_topic(phase_id && "phases:#{phase_id}")
    |> maybe_add_topic(worker_id && "workers")
    |> maybe_add_topic(worker_id && "workers:#{worker_id}")
  end

  defp maybe_add_topic(topics, nil), do: topics
  defp maybe_add_topic(topics, topic), do: [topic | topics]

  defp finalize_dispatch(
         {:telemetry, result, %{append_latency_ms: append_latency_ms}},
         aggregate_id,
         started_at_ms
       ) do
    Telemetry.command_dispatch(
      elapsed_ms(started_at_ms),
      append_latency_ms,
      telemetry_status(result),
      aggregate_id
    )

    result
  end

  defp finalize_dispatch(result, aggregate_id, started_at_ms) do
    Telemetry.command_dispatch(
      elapsed_ms(started_at_ms),
      0,
      telemetry_status(result),
      aggregate_id
    )

    result
  end

  defp telemetry_status({:ok, _}), do: "ok"
  defp telemetry_status(_), do: "error"

  defp elapsed_ms(started_at_ms) do
    max(System.monotonic_time(:millisecond) - started_at_ms, 0)
  end

  def aggregate_module_for("project:" <> _), do: ForemanServer.Aggregates.Project
  def aggregate_module_for("task:" <> _), do: ForemanServer.Aggregates.Task
  def aggregate_module_for("run:" <> _), do: ForemanServer.Aggregates.Run
  def aggregate_module_for("worker:" <> _), do: ForemanServer.Aggregates.Worker
  def aggregate_module_for("phase:" <> _), do: ForemanServer.Aggregates.Phase
  def aggregate_module_for("recovery:" <> _), do: ForemanServer.Aggregates.Recovery
  def aggregate_module_for("pr_association:" <> _), do: ForemanServer.Aggregates.PrAssociation
  def aggregate_module_for("phase_pr:" <> _), do: ForemanServer.Aggregates.PhasePr
  def aggregate_module_for("beads_db_lease:" <> _), do: ForemanServer.Aggregates.BeadsDbLease
  def aggregate_module_for("run_slots:" <> _), do: ForemanServer.Aggregates.RunSlots
  def aggregate_module_for("vcs_operation:" <> _), do: ForemanServer.Aggregates.VcsOperation
  def aggregate_module_for("vcs:" <> _), do: ForemanServer.Aggregates.VcsOperation

  def aggregate_module_for("scheduler_intent:" <> _),
    do: ForemanServer.Aggregates.SchedulerIntent

  def aggregate_module_for("migration:" <> _), do: ForemanServer.Aggregates.ImportMigration
  def aggregate_module_for("blocking:" <> _), do: ForemanServer.TestSupport.BlockingAggregate
  def aggregate_module_for("inbox:" <> _), do: ForemanServer.Aggregates.InboxThread
  def aggregate_module_for("notification:" <> _), do: ForemanServer.Aggregates.Notification
  def aggregate_module_for("work:" <> _), do: ForemanServer.Aggregates.WorkRequest
end
