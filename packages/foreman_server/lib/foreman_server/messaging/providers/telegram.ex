defmodule ForemanServer.Messaging.Providers.Telegram do
  @moduledoc "Telegram Bot API provider adapter behind `ForemanServer.Messaging.Provider`."

  @behaviour ForemanServer.Messaging.Provider

  alias ForemanServer.Messaging.{DeliveryResult, HttpResponse, Notification, Redactor, Renderer}

  @timeout_ms 5_000

  @impl true
  def send(%Notification{} = notification, destination) when is_map(destination) do
    with {:ok, token} <- required_binary(destination, :token, :telegram_destination),
         {:ok, chat_id} <- required_binary(destination, :chat_id, :telegram_destination),
         {:ok, text} <- Renderer.render(notification) do
      {url, body, headers, timeout} = build_request(token, chat_id, text)

      case http_client().post_json(url, body, headers, timeout) do
        {:ok, %HttpResponse{status: status, body: response_body}} when status in 200..299 ->
          {:ok,
           result(notification, :succeeded, false, nil, %{status: status, body: response_body})}

        {:ok, %HttpResponse{status: status, body: response_body}} ->
          {:error,
           result(
             notification,
             :failed,
             retryable_status?(status),
             "telegram_http_#{status}: #{response_body}",
             %{
               status: status
             }
           )}

        {:error, reason} ->
          {:error, result(notification, :failed, true, inspect(reason), %{})}
      end
    else
      {:error, reason} ->
        {:error, result(notification, :failed, false, inspect(reason), %{})}
    end
  end

  # Public for no-network contract tests.
  def build_request(token, chat_id, text) do
    {
      "https://api.telegram.org/bot#{token}/sendMessage",
      %{chat_id: chat_id, text: text, disable_web_page_preview: true},
      [],
      @timeout_ms
    }
  end

  defp result(notification, status, retryable?, reason, metadata) do
    %DeliveryResult{
      notification_id: notification.notification_id,
      provider: :telegram,
      status: status,
      retryable?: retryable?,
      reason: Redactor.redact(reason),
      delivered_at: if(status == :succeeded, do: DateTime.utc_now() |> DateTime.to_iso8601()),
      metadata: Redactor.redact(metadata || %{})
    }
  end

  defp retryable_status?(status), do: status == 429 or status >= 500

  defp required_binary(map, key, error_key) do
    case fetch_field(map, key) do
      :absent ->
        {:error, {:missing_field, error_key, key}}

      {:present, {:system, env_name} = ref} when is_binary(env_name) ->
        case resolve_secret_ref(ref) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _ -> {:error, {:unresolved_secret_ref, error_key, key, env_name}}
        end

      {:present, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:present, value} ->
        {:error, {:invalid_field, error_key, key, value}}
    end
  end

  # Distinguishes an absent destination field from one present but invalid
  # (§5.4b of AGENTS.md): both atom and string keys are checked since
  # destinations round-trip through JSON.
  defp fetch_field(map, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, string_key) -> {:present, Map.get(map, string_key)}
      true -> :absent
    end
  end

  defp resolve_secret_ref({:system, env_name}) when is_binary(env_name),
    do: System.get_env(env_name)

  defp http_client do
    Application.get_env(:foreman_server, :messaging, [])
    |> Keyword.get(:http_client, ForemanServer.Messaging.HttpClient)
  end
end
