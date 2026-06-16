defmodule ForemanServer.CommandRouter do
  @moduledoc "Minimal command boundary for the initial server shell."

  alias ForemanServer.EventStore

  @spec handle(map()) :: {:ok, map()} | {:error, term()}
  def handle(%{command_id: command_id, command_type: command_type} = command)
      when is_binary(command_id) and is_binary(command_type) do
    payload = %{
      command_id: command_id,
      command_type: command_type,
      status: "accepted",
      input: command
    }

    metadata =
      command
      |> Map.get(:metadata, %{})
      |> normalize_metadata()
      |> Map.put_new(:correlation_id, Map.get(command, :correlation_id, command_id))
      |> Map.put_new(:source, "node-cli-boundary")

    case EventStore.append("CommandAccepted", payload, metadata) do
      {:ok, event} -> {:ok, %{event: event, projection: ForemanServer.ProjectionStore.snapshot()}}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle(%{"command_id" => command_id, "command_type" => command_type} = command) do
    atomized = %{
      command_id: command_id,
      command_type: command_type,
      correlation_id: Map.get(command, "correlation_id"),
      payload: Map.get(command, "payload", %{}),
      metadata: Map.get(command, "metadata", %{})
    }

    handle(atomized)
  end

  def handle(_command), do: {:error, :invalid_command}

  defp normalize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_metadata(_), do: %{}
end
