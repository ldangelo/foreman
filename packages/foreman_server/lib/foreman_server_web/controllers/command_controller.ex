defmodule ForemanServerWeb.CommandController do
  @moduledoc """
  Public command ingress for the Foreman JSON API.

  `POST /api/commands` is the **sole** external mutation surface. The
  body is forwarded to `ForemanServer.CommandGateway.dispatch_operator/2`
  which validates the envelope, gates on allowed types
  (`project.register`, `task.create`, `task.approve`), enriches the
  payload, and dispatches to `CommandRouter`.

  The `aggregate_id` is derived from the payload (e.g. `task:<task_id>`
  for `task.create`); operators may supply it explicitly but the value
  must match the canonical `<prefix>:<id>` form.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.CommandGateway

  @allowed_types ~w(project.register task.create task.approve)

  def create(conn, params) do
    envelope = build_envelope(params)

    case envelope do
      {:ok, command} ->
        case CommandGateway.dispatch_operator(command) do
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

  defp build_envelope(params) when is_map(params) do
    type = get_value(params, :type) || get_value(params, "type")
    payload = get_value(params, :payload) || get_value(params, "payload") || %{}

    cond do
      not (is_binary(type) and type != "") -> {:error, :invalid_envelope}
      not (type in @allowed_types and is_map(payload)) -> {:error, :invalid_envelope}
      true ->
        case resolve_aggregate_id(type, payload, params) do
          {:ok, aggregate_id} ->
            {:ok,
             %{
               type: type,
               command_id: get_value(params, :command_id) || get_value(params, "command_id") || default_command_id(),
               aggregate_id: aggregate_id,
               payload: payload
             }}

          {:error, _} = err ->
            err
        end
    end
  end

  defp build_envelope(_), do: {:error, :invalid_envelope}

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
  defp aggregate_prefix("task.create"), do: "task"
  defp aggregate_prefix("task.approve"), do: "task"
  defp aggregate_prefix(_), do: ""

  defp id_field_for("project.register"), do: :project_id
  defp id_field_for("task.create"), do: :task_id
  defp id_field_for("task.approve"), do: :task_id
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

  defp serialize({:ok, _events}), do: %{events: 1}
  defp serialize(other), do: %{raw: inspect(other)}
end