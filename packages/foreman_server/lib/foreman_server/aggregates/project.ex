defmodule ForemanServer.Aggregates.Project do
  @moduledoc "Project aggregate: validates registration/config/archive commands."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.Events.{ProjectRunReservationReleased, ProjectRunReserved}

  defmodule State do
    @enforce_keys [:exists?, :project_id, :path, :status, :default_branch, :archived?]
    defstruct [
      :exists?,
      :project_id,
      :path,
      :status,
      :default_branch,
      :archived?,
      :task_provider,
      active_run_reservations: %{},
      config: %{},
      health: %{ok: true}
    ]
  end

  @valid_statuses MapSet.new(["active", "paused", "archived"])

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      project_id: nil,
      path: nil,
      status: nil,
      default_branch: "main",
      archived?: false,
      task_provider: nil,
      active_run_reservations: %{},
      config: %{},
      health: %{ok: true}
    }

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "ProjectRegistered" ->
        task_provider = task_provider_from(payload)

        %State{
          state
          | exists?: true,
            project_id: Aggregate.get(payload, :project_id),
            path: Aggregate.get(payload, :path),
            status: Aggregate.get(payload, :status, "active"),
            default_branch: Aggregate.get(payload, :default_branch, "main"),
            task_provider: task_provider,
            active_run_reservations: %{},
            config: project_config(payload, task_provider),
            health: Aggregate.get(payload, :health, %{ok: true}),
            archived?: false
        }

      "ProjectUpdated" ->
        task_provider = task_provider_from(payload)

        config =
          state.config
          |> merge_config(Aggregate.get(payload, :config, %{}))
          |> maybe_put_name(Aggregate.get(payload, :name))
          |> maybe_put_task_provider(task_provider)

        state
        |> update_status(payload)
        |> update_default_branch(payload)
        |> update_health(payload)
        |> put_task_provider(task_provider)
        |> put_config(config)

      "ProjectArchived" ->
        %State{state | status: "archived", archived?: true}

      "ProjectReactivated" ->
        %State{state | status: "active", archived?: false}

      "ProjectRunReserved" ->
        put_run_reservation(state, payload)

      "ProjectRunReservationReleased" ->
        release_run_reservation(state, payload)

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "project.register", payload: payload}) do
    project_id = Aggregate.get(payload, :project_id) || Aggregate.get(payload, :id)

    with {:ok, project_id} <- Aggregate.required_binary(project_id, :project_id),
         {:ok, path} <- Aggregate.required_binary(Aggregate.get(payload, :path), :path),
         :ok <- require_absent(state, project_id),
         :ok <- validate_status(Aggregate.get(payload, :status, "active")),
         {:ok, payload} <-
           payload
           |> Map.put(:project_id, project_id)
           |> Map.put(:path, path)
           |> normalize_task_provider_payload() do
      {:ok,
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectRegistered",
         payload: payload
       }}
    end
  end

  def handle_command(state, %{type: "project.update", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         :ok <- require_exists(state, project_id),
         {:ok, payload} <-
           payload
           |> Map.put(:project_id, project_id)
           |> normalize_task_provider_payload() do
      {:ok,
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectUpdated",
         payload: payload
       }}
    end
  end

  def handle_command(state, %{type: "project.archive", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         :ok <- require_exists(state, project_id),
         :ok <- validate_archive(state) do
      {:ok,
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectArchived",
         payload: Map.merge(payload, %{project_id: project_id})
       }}
    end
  end

  def handle_command(state, %{type: "project.reactivate", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         :ok <- require_exists(state, project_id),
         :ok <- validate_reactivate(state) do
      {:ok,
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectReactivated",
         payload: Map.merge(payload, %{project_id: project_id})
       }}
    end
  end

  def handle_command(state, %{type: "project.reserve_run", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, command_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :command_id), :command_id),
         {:ok, sequence} <- validate_sequence(Aggregate.get(payload, :sequence)),
         {:ok, run_start_payload} <-
           validate_run_start_payload(Aggregate.get(payload, :run_start_payload)),
         {:ok, implementation_key} <-
           validate_implementation_key(Aggregate.get(payload, :implementation_key)),
         :ok <- require_exists(state, project_id),
         :ok <- reject_archived(state, project_id),
         :ok <- reject_same_implementation_key(state, project_id, run_id, implementation_key) do
      if reserved_run(state, run_id) do
        {:ok, nil}
      else
        {:ok,
         %{
           stream_id: "project:#{project_id}",
           event_type: "ProjectRunReserved",
           payload: %ProjectRunReserved{
             project_id: project_id,
             run_id: run_id,
             command_id: command_id,
             sequence: sequence,
             run_start_payload: run_start_payload,
             implementation_key: implementation_key
           }
         }}
      end
    end
  end

  def handle_command(state, %{type: "project.release_run_reservation", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, project_id) do
      case reserved_run(state, run_id) do
        nil ->
          {:ok, nil}

        reservation ->
          {:ok,
           %{
             stream_id: "project:#{project_id}",
             event_type: "ProjectRunReservationReleased",
             payload: %ProjectRunReservationReleased{
               project_id: project_id,
               run_id: run_id,
               sequence: Aggregate.get(reservation, :sequence),
               reason: Aggregate.get(payload, :reason)
             }
           }}
      end
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp require_absent(%State{exists?: true}, project_id),
    do: {:error, {:already_exists, :project, project_id}}

  defp require_absent(_state, _project_id), do: :ok

  defp require_exists(%State{exists?: true}, _project_id), do: :ok
  defp require_exists(_state, project_id), do: {:error, {:not_found, :project, project_id}}

  defp validate_status(nil), do: :ok

  defp validate_status(status) when is_binary(status) do
    if MapSet.member?(@valid_statuses, status),
      do: :ok,
      else: {:error, {:invalid_project_status, status}}
  end

  defp validate_status(status), do: {:error, {:invalid_project_status, status}}

  defp validate_archive(%State{archived?: true}), do: {:error, {:already_archived, :project}}

  defp validate_archive(%State{active_run_reservations: reservations})
       when map_size(reservations) > 0,
       do: {:error, :project_has_active_runs, Map.keys(reservations)}

  defp validate_archive(_state), do: :ok

  defp validate_reactivate(%State{archived?: false}), do: {:error, {:not_archived, :project}}
  defp validate_reactivate(_state), do: :ok

  defp reject_archived(%State{archived?: true}, project_id),
    do: {:error, {:project_archived, project_id}}

  defp reject_archived(_state, _project_id), do: :ok

  defp update_status(state, payload) do
    if status = Aggregate.get(payload, :status),
      do: %State{state | status: status},
      else: state
  end

  defp update_default_branch(state, payload) do
    if db = Aggregate.get(payload, :default_branch),
      do: %State{state | default_branch: db},
      else: state
  end

  defp update_health(state, payload) do
    if health = Aggregate.get(payload, :health),
      do: %State{state | health: health},
      else: state
  end

  defp put_task_provider(state, nil), do: state
  defp put_task_provider(state, task_provider), do: %State{state | task_provider: task_provider}

  defp put_config(state, config), do: %State{state | config: config}

  defp normalize_task_provider_payload(payload) do
    case payload |> task_provider_from() |> normalize_task_provider() do
      {:ok, nil} ->
        {:ok, payload}

      {:ok, task_provider} ->
        config =
          payload
          |> Aggregate.get(:config, %{})
          |> maybe_put_task_provider(task_provider)

        {:ok,
         payload
         |> Map.put(:task_provider, task_provider)
         |> Map.put(:config, config)}

      {:error, :database_path_must_be_absolute} = error ->
        error
    end
  end

  defp normalize_task_provider(nil), do: {:ok, nil}

  defp normalize_task_provider(task_provider) do
    case task_provider_database_path(task_provider) do
      nil ->
        {:ok, task_provider}

      database_path when is_binary(database_path) ->
        with :ok <- validate_database_path(database_path) do
          {:ok, put_task_provider_database_path(task_provider, Path.expand(database_path))}
        end
    end
  end

  defp task_provider_database_path(task_provider) do
    task_provider
    |> Aggregate.get(:config, %{})
    |> Aggregate.get(:database_path)
  end

  defp put_task_provider_database_path(task_provider, database_path) do
    config =
      task_provider
      |> Aggregate.get(:config, %{})
      |> put_map_value(:database_path, database_path)

    put_map_value(task_provider, :config, config)
  end

  defp validate_database_path(database_path) when is_binary(database_path) do
    if Path.type(database_path) == :absolute,
      do: :ok,
      else: {:error, :database_path_must_be_absolute}
  end

  defp project_config(payload, task_provider) do
    payload
    |> Aggregate.get(:config, %{})
    |> maybe_put_task_provider(task_provider)
  end

  defp task_provider_from(payload) do
    case Aggregate.get(payload, :task_provider) do
      nil -> payload |> Aggregate.get(:config, %{}) |> Aggregate.get(:task_provider)
      task_provider -> task_provider
    end
  end

  defp maybe_put_name(config, nil), do: config
  defp maybe_put_name(config, name), do: Map.put(config, :name, name)

  defp maybe_put_task_provider(config, nil), do: config

  defp maybe_put_task_provider(config, task_provider),
    do: put_map_value(config, :task_provider, task_provider)

  defp merge_config(left, right) when is_map(left) and is_map(right) do
    Enum.reduce(right, left, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  defp put_map_value(map, key, value) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, string_key) -> Map.put(map, string_key, value)
      true -> Map.put(map, key, value)
    end
  end

  defp validate_sequence(sequence) when is_integer(sequence), do: {:ok, sequence}
  defp validate_sequence(_sequence), do: {:error, {:missing_or_invalid, :sequence}}

  defp validate_implementation_key(nil), do: {:ok, nil}

  defp validate_implementation_key(key) when is_binary(key) do
    if key != "",
      do: {:ok, key},
      else: {:error, {:missing_or_invalid, :implementation_key}}
  end

  defp validate_implementation_key(_key),
    do: {:error, {:missing_or_invalid, :implementation_key}}

  defp reject_same_implementation_key(_state, _project_id, _run_id, nil), do: :ok

  defp reject_same_implementation_key(
         %State{active_run_reservations: reservations},
         _project_id,
         run_id,
         key
       )
       when is_map(reservations) do
    case Enum.find_value(reservations, fn {existing_run_id, reservation} ->
           cond do
             existing_run_id == run_id ->
               nil

             Aggregate.get(reservation, :implementation_key) == key ->
               existing_run_id

             true ->
               nil
           end
         end) do
      nil ->
        :ok

      existing_run_id ->
        {:error, {:implementation_already_active, key, existing_run_id}}
    end
  end

  defp validate_run_start_payload(run_start_payload) when is_map(run_start_payload),
    do: {:ok, run_start_payload}

  defp validate_run_start_payload(_run_start_payload),
    do: {:error, {:missing_or_invalid, :run_start_payload}}

  defp reserved_run(%State{active_run_reservations: reservations}, run_id),
    do: Aggregate.get(reservations, run_id)

  defp put_run_reservation(state, payload) do
    run_id = Aggregate.get(payload, :run_id)

    reservation = %{
      project_id: Aggregate.get(payload, :project_id),
      sequence: Aggregate.get(payload, :sequence),
      command_id: Aggregate.get(payload, :command_id),
      run_start_payload: Aggregate.get(payload, :run_start_payload),
      implementation_key: Aggregate.get(payload, :implementation_key)
    }

    %State{
      state
      | active_run_reservations: Map.put(state.active_run_reservations, run_id, reservation)
    }
  end

  defp release_run_reservation(state, payload) do
    run_id = Aggregate.get(payload, :run_id)

    %State{state | active_run_reservations: Map.delete(state.active_run_reservations, run_id)}
  end
end
