defmodule ForemanServer.EventCodec do
  @moduledoc "Encodes and decodes event envelopes across schema versions."

  alias ForemanServer.Event

  @inbox_events %{
    "BoardItemStatusChanged" => ForemanServer.Events.BoardItemStatusChanged,
    "InboxItemStarted" => ForemanServer.Events.InboxItemStarted,
    "InboxItemDeduped" => ForemanServer.Events.InboxItemDeduped
  }

  @spec encode(Event.t()) :: binary()
  def encode(%Event{} = event) do
    event
    |> Event.to_map()
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end

  @spec decode(binary() | map() | Event.t()) :: {:ok, Event.t()} | {:error, term()}
  def decode(%Event{} = event), do: {:ok, event}

  def decode(line) when is_binary(line) do
    with {:ok, binary} <- Base.decode64(String.trim(line)),
         decoded <- :erlang.binary_to_term(binary) do
      decode(decoded)
    else
      :error -> {:error, :invalid_base64_event}
    end
  rescue
    ArgumentError -> {:error, :invalid_event_term}
  end

  def decode(%{schema_version: 1} = map), do: Event.from_map(map)

  def decode(%{type: type, payload: payload, sequence: sequence} = legacy)
      when is_binary(type) and is_map(payload) and is_integer(sequence) do
    migrated = %{
      event_id: Map.get(legacy, :event_id, "legacy-#{sequence}"),
      stream_id: Map.get(legacy, :stream_id, "legacy:#{type}"),
      stream_version: sequence,
      event_type: type,
      schema_version: 1,
      payload: payload,
      metadata: Map.get(legacy, :metadata, %{}),
      occurred_at: Map.get(legacy, :occurred_at, DateTime.utc_now()),
      correlation_id: Map.get(legacy, :correlation_id, "legacy-#{sequence}"),
      causation_id: Map.get(legacy, :causation_id)
    }

    Event.from_map(migrated)
  end

  def decode(%{schema_version: version}) do
    {:error, {:unsupported_event_schema_version, version}}
  end

  def decode(_), do: {:error, :invalid_event_envelope}

  @doc """
  Decodes a map payload (from Postgres row_to_event) into its typed domain struct.
  Registered event types call the module's from_payload/1 which explicitly maps
  known fields. Unknown event types are returned unchanged so existing aggregate
  replay (which folds plain maps) is not broken.
  """
  @spec decode!(String.t(), map()) :: struct() | map()
  def decode!(event_type, payload) when is_binary(event_type) and is_map(payload) do
    case Map.fetch(@inbox_events, event_type) do
      {:ok, struct_module} ->
        cond do
          is_struct(payload, struct_module) ->
            # Typed struct already — module matches event_type, pass through unchanged
            payload

          is_struct(payload) ->
            raise "event_type #{inspect(event_type)} but payload is #{inspect(payload.__struct__)}"

          true ->
            # Plain map — reconstruct the typed domain struct
            struct_module.from_payload(payload)
        end

      :error ->
        payload
    end
  end
end
