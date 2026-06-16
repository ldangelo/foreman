defmodule ForemanServer.Event do
  @moduledoc "Versioned domain event envelope for Foreman's append-only event store."

  @current_schema_version 1

  @enforce_keys [
    :event_id,
    :stream_id,
    :stream_version,
    :event_type,
    :schema_version,
    :payload,
    :metadata,
    :occurred_at,
    :correlation_id
  ]
  defstruct [
    :event_id,
    :stream_id,
    :stream_version,
    :event_type,
    :schema_version,
    :payload,
    :metadata,
    :occurred_at,
    :correlation_id,
    :causation_id
  ]

  @type t :: %__MODULE__{
          event_id: String.t(),
          stream_id: String.t(),
          stream_version: pos_integer(),
          event_type: String.t(),
          schema_version: pos_integer(),
          payload: map(),
          metadata: map(),
          occurred_at: DateTime.t(),
          correlation_id: String.t(),
          causation_id: String.t() | nil
        }

  @type input :: %{
          required(:stream_id) => String.t(),
          required(:event_type) => String.t(),
          required(:payload) => map(),
          optional(:metadata) => map(),
          optional(:correlation_id) => String.t(),
          optional(:causation_id) => String.t(),
          optional(:event_id) => String.t(),
          optional(:schema_version) => pos_integer(),
          optional(:occurred_at) => DateTime.t()
        }

  @spec current_schema_version() :: pos_integer()
  def current_schema_version, do: @current_schema_version

  @spec new(input(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def new(input, stream_version)
      when is_map(input) and is_integer(stream_version) and stream_version > 0 do
    with {:ok, stream_id} <- fetch_binary(input, :stream_id),
         {:ok, event_type} <- fetch_binary(input, :event_type),
         {:ok, payload} <- fetch_map(input, :payload) do
      metadata = Map.get(input, :metadata, %{})

      correlation_id =
        Map.get(input, :correlation_id) || Map.get(metadata, :correlation_id) || generate_id()

      {:ok,
       %__MODULE__{
         event_id: Map.get(input, :event_id, generate_id()),
         stream_id: stream_id,
         stream_version: stream_version,
         event_type: event_type,
         schema_version: Map.get(input, :schema_version, @current_schema_version),
         payload: payload,
         metadata: metadata,
         occurred_at: Map.get(input, :occurred_at, DateTime.utc_now()),
         correlation_id: correlation_id,
         causation_id: Map.get(input, :causation_id)
       }}
    end
  end

  def new(_input, _stream_version), do: {:error, :invalid_stream_version}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      event_id: event.event_id,
      stream_id: event.stream_id,
      stream_version: event.stream_version,
      event_type: event.event_type,
      schema_version: event.schema_version,
      payload: event.payload,
      metadata: event.metadata,
      occurred_at: event.occurred_at,
      correlation_id: event.correlation_id,
      causation_id: event.causation_id,
      type: event.event_type,
      sequence: event.stream_version
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%__MODULE__{} = event), do: {:ok, event}

  def from_map(map) when is_map(map) do
    with {:ok, stream_id} <- fetch_binary(map, :stream_id),
         {:ok, event_type} <- fetch_binary(map, :event_type),
         {:ok, payload} <- fetch_map(map, :payload) do
      {:ok,
       %__MODULE__{
         event_id: Map.fetch!(map, :event_id),
         stream_id: stream_id,
         stream_version: Map.fetch!(map, :stream_version),
         event_type: event_type,
         schema_version: Map.fetch!(map, :schema_version),
         payload: payload,
         metadata: Map.get(map, :metadata, %{}),
         occurred_at: Map.fetch!(map, :occurred_at),
         correlation_id: Map.fetch!(map, :correlation_id),
         causation_id: Map.get(map, :causation_id)
       }}
    end
  rescue
    KeyError -> {:error, :invalid_event_envelope}
  end

  def from_map(_), do: {:error, :invalid_event_envelope}

  defp fetch_binary(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_map(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end
end
