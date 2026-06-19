defmodule ForemanServer.EventCodec do
  @moduledoc "Encodes and decodes event envelopes across schema versions."

  alias ForemanServer.Event

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
end
