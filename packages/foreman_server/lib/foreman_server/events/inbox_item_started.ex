defmodule ForemanServer.Events.InboxItemStarted do
  @moduledoc "Emitted when a new inbox item is accepted after dedupe check."

  @enforce_keys [:correlation_id, :run_id, :source, :timestamp]
  @type t :: %__MODULE__{
          correlation_id: String.t(),
          run_id: String.t(),
          source: String.t(),
          payload: map(),
          timestamp: DateTime.t()
        }
  @derive Jason.Encoder
  defstruct [:correlation_id, :run_id, :source, :timestamp, payload: %{}]

  @doc "Constructs the struct from a plain map payload with explicit field mapping."
  @spec from_payload(map()) :: t()
  def from_payload(payload) when is_map(payload) do
    correlation_id = require_binary(payload, :correlation_id, "correlation_id")
    run_id = require_binary(payload, :run_id, "run_id")
    source = require_binary(payload, :source, "source")

    %__MODULE__{
      correlation_id: correlation_id,
      run_id: run_id,
      source: source,
      payload: Map.get(payload, :payload) || Map.get(payload, "payload") || %{},
      timestamp: normalize_timestamp(payload)
    }
  end

  defp require_binary(payload, atom_key, string_key) do
    value = Map.get(payload, atom_key) || Map.get(payload, string_key)

    if is_binary(value) and value != "",
      do: value,
      else:
        raise(
          "#{inspect(atom_key)}/#{inspect(string_key)} is required and must be a non-empty string, got: #{inspect(value)}"
        )
  end

  defp normalize_timestamp(payload) do
    raw =
      Map.get(payload, :timestamp) ||
        Map.get(payload, "timestamp") ||
        DateTime.utc_now()

    case raw do
      %DateTime{} -> raw
      raw when is_binary(raw) -> parse_iso8601(raw)
      _ -> DateTime.utc_now()
    end
  end

  defp parse_iso8601(binary) do
    case DateTime.from_iso8601(binary) do
      {:ok, dt, _utc_offset} -> dt
      {:error, _reason} -> DateTime.utc_now()
    end
  end
end
