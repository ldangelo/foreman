defmodule ForemanServer.Aggregates.Project do
  @moduledoc """
  Project aggregate: validates registration/config/archive commands.

  There is deliberately no `default_branch` setting. A run's base branch is the
  registered checkout's HEAD, latched per run (`run.record_base_branch`), so a
  second configurable source would conflict with it. Commands carrying
  `default_branch` are rejected with `{:setting_removed, :default_branch}`.
  Historical `ProjectRegistered`/`ProjectUpdated` events that still carry the
  key replay fine: `apply_event/2` reads only the keys it knows.
  """
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.RunSlots.Config

  alias ForemanServer.Aggregates.Project.Settings

  alias ForemanServer.Events.{
    ProjectPaused,
    ProjectResumed,
    ProjectRunReservationReleased,
    ProjectRunReserved,
    ProjectThreadStarted
  }

  defmodule State do
    @enforce_keys [:exists?, :project_id, :path, :status, :archived?]
    defstruct [
      :exists?,
      :project_id,
      :path,
      :status,
      :archived?,
      :task_provider,
      active_run_reservations: %{},
      config: %{},
      health: %{ok: true},
      thread_day: nil,
      thread_ids: MapSet.new()
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
      archived?: false,
      task_provider: nil,
      active_run_reservations: %{},
      config: %{},
      health: %{ok: true}
    }

  @impl true
  def apply_event(%State{} = state, event) do
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
            task_provider: task_provider,
            active_run_reservations: %{},
            config: payload |> project_config(task_provider) |> fold_settings(payload),
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
          |> fold_settings(payload)

        state
        |> update_status(payload)
        |> update_health(payload)
        |> put_task_provider(task_provider)
        |> put_config(config)

      "ProjectArchived" ->
        %State{state | status: "archived", archived?: true}

      "ProjectReactivated" ->
        %State{state | status: "active", archived?: false}

      "ProjectPaused" ->
        %State{state | status: "paused"}

      "ProjectResumed" ->
        %State{state | status: "active"}

      "ProjectRunReserved" ->
        state
        |> put_run_reservation(payload)
        |> count_thread(
          "run",
          Aggregate.get(payload, :run_id),
          Aggregate.get(payload, :reserved_on)
        )

      "ProjectThreadStarted" ->
        count_thread(
          state,
          Aggregate.get(payload, :thread_kind),
          Aggregate.get(payload, :thread_id),
          Aggregate.get(payload, :day)
        )

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
         :ok <- reject_removed_settings(payload),
         :ok <- require_absent(state, project_id),
         :ok <- validate_status(Aggregate.get(payload, :status, "active")),
         {:ok, payload} <-
           payload
           |> Map.put(:project_id, project_id)
           |> Map.put(:path, path)
           |> normalize_settings_payload(),
         {:ok, payload} <- normalize_task_provider_payload(payload) do
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
         :ok <- reject_removed_settings(payload),
         :ok <- reject_status_edit(payload),
         :ok <- require_exists(state, project_id),
         {:ok, payload} <-
           payload
           |> Map.put(:project_id, project_id)
           |> normalize_settings_payload(),
         {:ok, payload} <- normalize_task_provider_payload(payload) do
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

  def handle_command(state, %{type: "project.pause", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         :ok <- require_exists(state, project_id),
         :ok <- reject_archived(state, project_id),
         :ok <- validate_pause(state) do
      {:ok,
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectPaused",
         payload: %ProjectPaused{
           project_id: project_id,
           reason: Aggregate.get(payload, :reason)
         }
       }}
    end
  end

  def handle_command(state, %{type: "project.resume", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         :ok <- require_exists(state, project_id),
         :ok <- validate_resume(state) do
      {:ok,
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectResumed",
         payload: %ProjectResumed{project_id: project_id}
       }}
    end
  end

  def handle_command(state, %{type: "project.reserve_thread", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, thread_kind} <- validate_thread_kind(Aggregate.get(payload, :thread_kind)),
         {:ok, thread_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :thread_id), :thread_id),
         {:ok, _command_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :command_id), :command_id),
         :ok <- require_exists(state, project_id),
         :ok <- reject_archived(state, project_id) do
      day = today()

      if thread_counted?(state, thread_kind, thread_id, day) do
        {:ok, nil}
      else
        with :ok <- reject_paused(state, project_id),
             :ok <- reject_at_daily_cap(state, day) do
          {:ok,
           %{
             stream_id: "project:#{project_id}",
             event_type: "ProjectThreadStarted",
             payload: %ProjectThreadStarted{
               project_id: project_id,
               thread_kind: thread_kind,
               thread_id: thread_id,
               day: day
             }
           }}
        end
      end
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
      # Precedence: payload override (test seam) > the project's
      # `max_concurrent_runs` setting > the global per-project default. The
      # setting is read from state, so the check is atomic with the
      # reservation count.
      max_concurrent_runs_per_project =
        Aggregate.get(payload, :max_concurrent_runs_per_project) ||
          Aggregate.get(state.config, :max_concurrent_runs) ||
          Config.max_concurrent_runs_per_project()

      day = today()

      if reserved_run(state, run_id) do
        {:ok, nil}
      else
        with :ok <- admission_refusal(state, run_id),
             :ok <- reject_at_run_limit(state, max_concurrent_runs_per_project) do
          :ok
        end
        |> case do
          :ok ->
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
                 implementation_key: implementation_key,
                 reserved_on: day
               }
             }}

          {:error, _} = error ->
            error
        end
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

  @doc """
  The non-terminal refusals that apply to starting a NEW run: paused project,
  exhausted daily thread cap. `:ok` for a run that already holds a reservation.
  Pure over aggregate state; `project.reserve_run` uses it authoritatively and
  `RunAdmission` consults it before touching the global run slot.
  """
  @spec admission_refusal(%State{}, String.t() | nil) :: :ok | {:error, term()}
  def admission_refusal(%State{} = state, run_id) do
    cond do
      is_binary(run_id) and reserved_run(state, run_id) ->
        :ok

      true ->
        with :ok <- reject_paused(state, state.project_id) do
          reject_at_daily_cap(state, today(), "run", run_id)
        end
    end
  end

  defp require_absent(%State{exists?: true}, project_id),
    do: {:error, {:already_exists, :project, project_id}}

  defp require_absent(%State{}, _project_id), do: :ok

  defp require_exists(%State{exists?: true}, _project_id), do: :ok
  defp require_exists(%State{}, project_id), do: {:error, {:not_found, :project, project_id}}

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

  defp validate_archive(%State{}), do: :ok

  defp validate_reactivate(%State{archived?: false}), do: {:error, {:not_archived, :project}}
  defp validate_reactivate(%State{}), do: :ok

  defp validate_pause(%State{status: "paused"}), do: {:error, {:already_paused, :project}}
  defp validate_pause(%State{}), do: :ok

  defp validate_resume(%State{status: "paused"}), do: :ok
  defp validate_resume(%State{}), do: {:error, {:not_paused, :project}}

  defp reject_paused(%State{status: "paused"}, project_id),
    do: {:error, {:project_paused, project_id}}

  defp reject_paused(%State{}, _project_id), do: :ok

  defp reject_status_edit(payload) do
    if Map.has_key?(payload, :status) or Map.has_key?(payload, "status"),
      do: {:error, {:setting_not_editable, :status}},
      else: :ok
  end

  defp validate_thread_kind("jobsite"), do: {:ok, "jobsite"}
  defp validate_thread_kind(kind), do: {:error, {:missing_or_invalid, :thread_kind, kind}}

  # UTC date the aggregate stamps on a thread start, evaluated at command time
  # (the day then rides on the event, so replay never consults a clock).
  defp today, do: Date.utc_today() |> Date.to_iso8601()

  defp thread_counted?(%State{thread_day: day, thread_ids: ids}, kind, id, day),
    do: MapSet.member?(ids, thread_key(kind, id))

  defp thread_counted?(%State{}, _kind, _id, _day), do: false

  defp thread_key(kind, id), do: "#{kind}:#{id}"

  defp reject_at_daily_cap(state, day, kind \\ nil, id \\ nil) do
    case Aggregate.get(state.config, :daily_thread_cap) do
      cap when is_integer(cap) ->
        counted = if state.thread_day == day, do: MapSet.size(state.thread_ids), else: 0

        if counted >= cap and not already_counted?(state, kind, id, day),
          do: {:error, {:daily_thread_cap_exceeded, cap, day}},
          else: :ok

      _no_cap ->
        :ok
    end
  end

  defp already_counted?(_state, nil, _id, _day), do: false
  defp already_counted?(state, kind, id, day), do: thread_counted?(state, kind, id, day)

  # Counts a thread against `day`. The set resets when the day rolls over. An
  # event without a day (recorded before the cap existed) counts nothing.
  defp count_thread(%State{} = state, _kind, _id, nil), do: state

  defp count_thread(%State{} = state, kind, id, day) when is_binary(day) do
    ids = if state.thread_day == day, do: state.thread_ids, else: MapSet.new()
    %State{state | thread_day: day, thread_ids: MapSet.put(ids, thread_key(kind, id))}
  end

  defp reject_archived(%State{archived?: true}, project_id),
    do: {:error, {:project_archived, project_id}}

  defp reject_archived(%State{}, _project_id), do: :ok

  defp reject_at_run_limit(%State{active_run_reservations: reservations}, limit)
       when is_integer(limit) and limit >= 0 do
    if map_size(reservations) >= limit do
      {:error, :run_limit_exceeded}
    else
      :ok
    end
  end

  defp update_status(%State{} = state, payload) do
    if status = Aggregate.get(payload, :status),
      do: %State{state | status: status},
      else: state
  end

  defp reject_removed_settings(payload) do
    if Map.has_key?(payload, :default_branch) or Map.has_key?(payload, "default_branch"),
      do: {:error, {:setting_removed, :default_branch}},
      else: :ok
  end

  defp update_health(%State{} = state, payload) do
    if health = Aggregate.get(payload, :health),
      do: %State{state | health: health},
      else: state
  end

  defp put_task_provider(%State{} = state, nil), do: state

  defp put_task_provider(%State{} = state, task_provider),
    do: %State{state | task_provider: task_provider}

  defp put_config(%State{} = state, config), do: %State{state | config: config}

  # Every settings value, wherever the caller put it (typed top-level field or
  # inside the open `config` map), goes through `Settings`. The emitted payload
  # carries settings ONLY as typed top-level fields plus `cleared_settings`;
  # `config` keeps just the non-setting keys.
  defp normalize_settings_payload(payload) do
    raw_config = Aggregate.get(payload, :config, %{})

    with {:ok, raw_config} <- validate_config_map(raw_config),
         :ok <- Settings.check_config_keys(raw_config),
         {:ok, from_config} <- Settings.normalize(raw_config),
         {:ok, from_top} <- Settings.normalize(payload),
         {:ok, cleared} <- Settings.normalize_cleared(Aggregate.get(payload, :cleared_settings)) do
      merged = Map.merge(from_config, from_top)
      cleared = Enum.uniq(cleared ++ for({key, nil} <- merged, do: key))
      set = for {key, value} <- merged, not is_nil(value), into: %{}, do: {key, value}

      case Enum.find(cleared, &Map.has_key?(set, &1)) do
        nil -> {:ok, emit_settings(payload, raw_config, set, cleared)}
        key -> {:error, {:setting_set_and_cleared, key}}
      end
    end
  end

  defp validate_config_map(config) when is_map(config), do: {:ok, config}
  defp validate_config_map(_config), do: {:error, {:missing_or_invalid, :config}}

  defp emit_settings(payload, raw_config, set, cleared) do
    setting_keys = Settings.keys()
    drop = setting_keys ++ Enum.map(setting_keys, &Atom.to_string/1)

    config = Map.drop(raw_config, drop)

    payload
    |> Map.drop(drop ++ [:cleared_settings, "cleared_settings", :config, "config"])
    |> Map.put(:config, config)
    |> Map.merge(set)
    |> then(fn payload ->
      if cleared == [],
        do: payload,
        else: Map.put(payload, :cleared_settings, Enum.map(cleared, &Atom.to_string/1))
    end)
  end

  # Folds the typed settings fields of an event into `config` (atom keys,
  # replay-safe: string-key variants from JSON are removed first).
  defp fold_settings(config, payload) do
    cleared =
      payload
      |> Aggregate.get(:cleared_settings, [])
      |> List.wrap()
      |> Enum.flat_map(fn item ->
        case Settings.to_key(item) do
          {:ok, key} -> [key]
          :error -> []
        end
      end)

    config = Enum.reduce(cleared, config, &delete_setting(&2, &1))

    Enum.reduce(Settings.keys(), config, fn key, acc ->
      case Aggregate.get(payload, key) do
        nil -> acc
        value -> acc |> delete_setting(key) |> Map.put(key, value)
      end
    end)
  end

  defp delete_setting(config, key), do: Map.drop(config, [key, Atom.to_string(key)])

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

  defp reject_same_implementation_key(%State{}, _project_id, _run_id, nil), do: :ok

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

  defp put_run_reservation(%State{} = state, payload) do
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

  defp release_run_reservation(%State{} = state, payload) do
    run_id = Aggregate.get(payload, :run_id)

    %State{state | active_run_reservations: Map.delete(state.active_run_reservations, run_id)}
  end
end
