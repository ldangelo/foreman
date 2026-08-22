defmodule ForemanServerWeb.CommandController do
  @moduledoc """
  Public command ingress for the Foreman JSON API.

  `POST /api/commands` is the **sole** external mutation surface. The
  body is forwarded to `ForemanServer.CommandGateway.dispatch_operator/2`
  which validates the envelope, gates on the operator allowlist
  (`project.register`, `project.update`, `project.archive`, `task.create`,
  `task.approve`, `task.retry`, `run.cancel`, `work.submit`, and
  `work.cancel`), enriches the payload, and dispatches to `CommandRouter`.

  The `aggregate_id` is derived from the payload (e.g. `task:<task_id>`
  for `task.create`); operators may supply it explicitly but the value
  must match the canonical `<prefix>:<id>` form.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.CommandGateway

  @default_command_gateway_module CommandGateway
  @allowed_types ~w(project.register project.update project.archive task.create task.approve task.retry run.cancel work.submit work.cancel)

  def create(conn, params) do
    envelope = build_envelope(params)

    case envelope do
      {:ok, command} ->
        case dispatch_operator(command) do
          {:ok, result} ->
            conn
            |> put_status(:created)
            |> json(%{status: "accepted", result: serialize(result)})

          {:error, {:command_not_allowed, type}} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "command_not_allowed", type: type})

          {:error, {:invalid_envelope, reason}} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "invalid_envelope", reason: inspect(reason)})

          {:error, {:wrong_expected_version, current_version}} ->
            conn
            |> put_status(:conflict)
            |> json(%{code: "version_conflict", current_version: current_version})

          {:error, :project_has_active_runs, run_ids} ->
            conn
            |> put_status(:conflict)
            |> json(%{code: "project_has_active_runs", run_ids: run_ids})

          {:error, reason, detail} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: inspect(reason), detail: detail})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: inspect(reason)})
        end

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_envelope", reason: inspect(reason)})
    end
  end

  defp dispatch_operator(command) do
    case command_gateway_module() do
      @default_command_gateway_module -> CommandGateway.dispatch_operator(command)
      module -> module.dispatch_operator(command)
    end
  end

  defp command_gateway_module do
    Application.get_env(:foreman_server, :command_gateway_module, @default_command_gateway_module)
  end

  defp build_envelope(params) when is_map(params) do
    type = get_value(params, :type) || get_value(params, "type")
    payload = get_value(params, :payload) || get_value(params, "payload") || %{}

    cond do
      not (is_binary(type) and type != "") ->
        {:error, :invalid_envelope}

      not (type in @allowed_types and is_map(payload)) ->
        {:error, :invalid_envelope}

      true ->
        case resolve_aggregate_id(type, payload, params) do
          {:ok, aggregate_id} ->
            {:ok,
             %{
               type: type,
               command_id:
                 get_value(params, :command_id) || get_value(params, "command_id") ||
                   default_command_id(),
               aggregate_id: aggregate_id,
               payload: payload
             }}

          {:error, _} = err ->
            err
        end
    end
  end

  defp build_envelope(_), do: {:error, :invalid_envelope}
  # No-id task.create: returns nil so the gateway resolves the backend ID.
  defp resolve_aggregate_id("task.create", payload, params) do
    task_id = get_value(payload, :task_id) || get_value(payload, "task_id")
    supplied = get_value(params, :aggregate_id) || get_value(params, "aggregate_id")

    cond do
      is_binary(task_id) and task_id != "" ->
        expected_id = "task:#{task_id}"

        cond do
          is_nil(supplied) or supplied == "" -> {:ok, expected_id}
          supplied == expected_id -> {:ok, supplied}
          true -> {:error, :aggregate_id_mismatch}
        end

      is_nil(task_id) and (is_nil(supplied) or supplied == "") ->
        {:ok, nil}

      true ->
        {:error, :aggregate_id_mismatch}
    end
  end

  defp resolve_aggregate_id(type, payload, params) do
    expected_prefix = aggregate_prefix(type)
    id_field = id_field_for(type)
    id = get_value(payload, id_field)

    cond do
      not is_binary(id) or id == "" ->
        {:error, :missing_id_field}

      expected_prefix == "" ->
        {:error, :unknown_aggregate}

      true ->
        supplied = get_value(params, :aggregate_id) || get_value(params, "aggregate_id")
        expected_id = "#{expected_prefix}:#{id}"

        cond do
          is_nil(supplied) or supplied == "" -> {:ok, expected_id}
          supplied == expected_id -> {:ok, supplied}
          is_binary(supplied) -> {:error, :aggregate_id_mismatch}
          true -> {:ok, expected_id}
        end
    end
  end

  defp aggregate_prefix("project.register"), do: "project"
  defp aggregate_prefix("project.update"), do: "project"
  defp aggregate_prefix("project.archive"), do: "project"
  defp aggregate_prefix("task.create"), do: "task"
  defp aggregate_prefix("task.approve"), do: "task"
  defp aggregate_prefix("task.retry"), do: "task"
  defp aggregate_prefix("run.cancel"), do: "run"
  defp aggregate_prefix("work.submit"), do: "work"
  defp aggregate_prefix("work.cancel"), do: "work"
  defp aggregate_prefix(_), do: ""

  defp id_field_for("project.register"), do: :project_id
  defp id_field_for("project.update"), do: :project_id
  defp id_field_for("project.archive"), do: :project_id
  defp id_field_for("task.create"), do: :task_id
  defp id_field_for("task.approve"), do: :task_id
  defp id_field_for("task.retry"), do: :task_id
  defp id_field_for("run.cancel"), do: :run_id
  defp id_field_for("work.submit"), do: :work_id
  defp id_field_for("work.cancel"), do: :work_id
  defp id_field_for(_), do: nil

  defp default_command_id do
    "op:#{System.unique_integer([:positive])}:#{System.os_time(:nanosecond)}"
  end

  defp get_value(map, key) do
    cond do
      is_atom(key) ->
        Map.get(map, key) || Map.get(map, Atom.to_string(key))

      is_binary(key) ->
        Map.get(map, key) || safe_atom_fetch(map, key)
    end
  end

  defp safe_atom_fetch(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp serialize(result) when is_map(result) do
    payload = get_value(result, :payload)

    cond do
      # task.create results carry BOTH task_id and project_id in their
      # payload (TaskCreated event). Match the task branch first so the
      # `external_id` surface is reachable; the project branch handles
      # ProjectRegistered / ProjectUpdated / ProjectArchived envelopes.
      is_map(payload) and is_binary(get_value(payload, :task_id)) ->
        task_id = get_value(payload, :task_id)
        external_id = get_value(payload, :external_id)
        # Surface the Bead ID (payload.external_id) when present so
        # `foreman task create` can print the linked bead on stdout.
        # The Actor hook populates this for any task.create project that
        # has a configured :create provider (e.g. BeadsAdapter) — the
        # Bead ID is set even when the operator issued the command.
        # Operator-issued tasks on projects WITHOUT a :create provider
        # omit the field entirely.
        if is_binary(external_id) and external_id != "" do
          %{task_id: task_id, external_id: external_id}
        else
          %{task_id: task_id}
        end

      is_map(payload) and is_binary(get_value(payload, :project_id)) ->
        %{project_id: get_value(payload, :project_id)}

      true ->
        %{raw: inspect(result)}
    end
  end

  defp serialize({:ok, _events}), do: %{events: 1}
  defp serialize(other), do: %{raw: inspect(other)}
end
