defmodule ForemanServer.Inbox.ExternalTriggerCorrelationId do
  @moduledoc """
  Derives a stable correlation-id from an external-trigger payload for inbox dedupe.

  Uses the first present of: trigger_id → dedupe_key → event_id → external_id → command_id.
  Supports both atom and string keys (JSON webhook payloads use string keys).

  Returns nil when no dedupe key is present; the caller will receive an error rather
  than a fabricated id that would defeat the dedupe contract.
  """

  @behaviour ForemanServer.Inbox.InboxItemCorrelationId

  @impl true
  @spec correlation_id(map()) :: String.t() | nil
  def correlation_id(payload) when is_map(payload) do
    payload
    |> first_present([:trigger_id, :dedupe_key, :event_id, :external_id, :command_id])
    |> case do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp first_present(payload, keys) do
    Enum.find_value(keys, fn key ->
      # Check string key first (JSON webhook), then atom (internal map).
      with nil <- Map.get(payload, key) do
        Map.get(payload, to_string(key))
      end
      |> case do
        value when is_binary(value) and value != "" -> value
        value when is_integer(value) -> to_string(value)
        value when is_atom(value) and value != nil -> Atom.to_string(value)
        _ -> nil
      end
    end)
  end
end
