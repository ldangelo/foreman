defmodule ForemanServer.Inbox.AttachBridgeAdapter do
  @moduledoc """
  Normalizes attach-bridge webhook payloads into shared inbox items.

  Attach-bridge-specific concerns such as streaming metadata and connection
  lifecycle are captured under `:attach_bridge` before the item is handed to
  `SharedInbox`, so the generic inbox path can dedupe and persist delivery
  without losing provider-specific detail.
  """

  @behaviour ForemanServer.Inbox.InboxItemCorrelationId

  alias ForemanServer.Inbox.SharedInbox

  @source "attach-bridge"
  @source_prefix "attach-bridge:"

  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  def normalize(input) when is_map(input) do
    with {:ok, run_id} <- required_binary(fetch(input, :run_id), :run_id),
         correlation_id when is_binary(correlation_id) <- correlation_id(input) do
      event_type =
        fetch(input, :event_type) || fetch(input, :type) || fetch(input, :status) || "attach.bridge"

      normalized =
        %{
          correlation_id: correlation_id,
          run_id: run_id,
          source: @source,
          event_type: event_type,
          timestamp: normalize_timestamp(input),
          attach_bridge: %{
            streaming_metadata: normalize_streaming_metadata(input),
            connection: normalize_connection(input),
            raw: input
          }
        }
        |> put_present(:phase_id, fetch(input, :phase_id))
        |> put_present(:worker_id, fetch(input, :worker_id))
        |> put_present(:session_id, fetch(input, :session_id))

      {:ok, normalized}
    else
      nil -> {:error, {:missing_or_invalid, :correlation_id}}
      error -> error
    end
  end

  def normalize(_input), do: {:error, :invalid_attach_bridge_payload}

  @spec ingest(map()) :: {:ok, map()} | {:error, term()}
  def ingest(input) when is_map(input) do
    with {:ok, normalized} <- normalize(input) do
      SharedInbox.ingest(__MODULE__, normalized)
    end
  end

  def ingest(_input), do: {:error, :invalid_attach_bridge_payload}

  @impl true
  @spec correlation_id(map()) :: String.t() | nil
  def correlation_id(payload) when is_map(payload) do
    payload
    |> explicit_correlation_id()
    |> case do
      nil -> lifecycle_correlation_id(payload)
      id -> prefix(id)
    end
  end

  defp explicit_correlation_id(payload) do
    first_present(payload, [:correlation_id, :event_id])
  end

  defp lifecycle_correlation_id(payload) do
    run_id = fetch(payload, :run_id)
    worker_id = fetch(payload, :worker_id) || "worker"
    phase_id = fetch(payload, :phase_id) || "phase"

    connection_id = fetch(payload, :connection_id) || fetch_nested(payload, :connection, :connection_id)

    session_id =
      fetch(payload, :session_id) || fetch_nested(payload, :streaming_metadata, :session_id) ||
        fetch_nested(payload, :attach_bridge, :session_id)

    lifecycle =
      fetch(payload, :lifecycle) || fetch_nested(payload, :connection, :lifecycle) ||
        fetch(payload, :event_type) || fetch(payload, :type) || fetch_nested(payload, :connection, :state) ||
        fetch(payload, :state) || fetch(payload, :status)

    if present?(run_id) and Enum.any?([connection_id, session_id, lifecycle], &present?/1) do
      [run_id, worker_id, phase_id, connection_id || "connection", session_id || "session", lifecycle || "event"]
      |> Enum.map(&to_string/1)
      |> Enum.join(":")
      |> prefix()
    end
  end

  defp normalize_streaming_metadata(input) do
    [%{}, fetch_map(input, :streaming_metadata), fetch_map(input, :streaming), fetch_map(input, :attach)]
    |> Enum.reduce(%{}, fn value, acc ->
      acc
      |> put_present(:stream_url, fetch(value, :stream_url))
      |> put_present(:session_path, fetch(value, :session_path))
      |> put_present(:session_id, fetch(value, :session_id) || fetch(input, :session_id))
      |> put_present(:pty, fetch(value, :pty))
      |> put_present(:protocol, fetch(value, :protocol))
    end)
  end

  defp normalize_connection(input) do
    connection = fetch_map(input, :connection)

    %{}
    |> put_present(:connection_id, fetch(connection, :connection_id) || fetch(input, :connection_id))
    |> put_present(:state, fetch(connection, :state) || fetch(input, :state) || fetch(input, :status))
    |> put_present(
      :lifecycle,
      fetch(connection, :lifecycle) || fetch(input, :lifecycle) || fetch(input, :event_type) ||
        fetch(input, :type) || fetch(connection, :state) || fetch(input, :state) ||
        fetch(input, :status)
    )
    |> put_present(
      :connected_at,
      fetch(connection, :connected_at) || fetch(connection, :opened_at) || fetch(input, :connected_at) ||
        fetch(input, :opened_at)
    )
    |> put_present(
      :disconnected_at,
      fetch(connection, :disconnected_at) || fetch(connection, :closed_at) ||
        fetch(input, :disconnected_at) || fetch(input, :closed_at)
    )
    |> put_present(:reason, fetch(connection, :reason) || fetch(input, :reason))
  end

  defp normalize_timestamp(input) do
    input
    |> first_present([:timestamp, :occurred_at, :observed_at])
    |> case do
      %DateTime{} = timestamp -> timestamp
      timestamp when is_binary(timestamp) -> parse_timestamp(timestamp)
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> parsed
      {:error, _reason} -> DateTime.utc_now()
    end
  end

  defp first_present(payload, keys) do
    Enum.find_value(keys, fn key ->
      payload
      |> fetch(key)
      |> case do
        value when is_binary(value) and value != "" -> value
        value when is_integer(value) -> Integer.to_string(value)
        value when is_atom(value) and value != nil -> Atom.to_string(value)
        %DateTime{} = value -> DateTime.to_iso8601(value)
        _ -> nil
      end
    end)
  end

  defp fetch_map(payload, key) do
    case fetch(payload, key) do
      %{} = value -> value
      _ -> %{}
    end
  end

  defp fetch_nested(payload, parent_key, key) do
    case fetch(payload, parent_key) do
      %{} = nested -> fetch(nested, key)
      _ -> nil
    end
  end

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp prefix(id) when is_binary(id) do
    if String.starts_with?(id, @source_prefix), do: id, else: @source_prefix <> id
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value), do: not is_nil(value) and value != false
end
