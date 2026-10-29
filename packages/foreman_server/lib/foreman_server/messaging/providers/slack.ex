defmodule ForemanServer.Messaging.Providers.Slack do
  @moduledoc """
  Slack incoming-webhook provider adapter behind `ForemanServer.Messaging.Provider`.

  The webhook URL (a literal or `{:system, env}`) is the credential, and is held to the
  generic webhook's rules without its opt-outs: `https`, no userinfo, no private host
  (`ForemanServer.Messaging.WebhookUrl.check_resolved/3`, the DNS lookup going through
  `config :foreman_server, :messaging, host_resolver:` like the webhook provider's). A
  refusal never carries the URL.
  """

  @behaviour ForemanServer.Messaging.Provider

  alias ForemanServer.Messaging.{
    DeliveryResult,
    HttpResponse,
    Notification,
    Redactor,
    Renderer,
    WebhookUrl
  }

  @timeout_ms 5_000

  @impl true
  def send(%Notification{} = notification, destination) when is_map(destination) do
    with {:ok, webhook_url} <- required_binary(destination, :webhook_url, :slack_destination),
         :ok <- check_url(webhook_url),
         {:ok, text} <- Renderer.render(notification) do
      {url, body, headers, timeout} = build_request(webhook_url, text)

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
             "slack_http_#{status}: #{response_body}",
             %{
               status: status
             }
           )}

        {:error, reason} ->
          {:error, result(notification, :failed, true, inspect(reason), %{})}
      end
    else
      # A lookup that failed may succeed next time: redelivered, like a transport error.
      {:error, {:unresolvable_host, _error_key} = reason} ->
        {:error, result(notification, :failed, true, inspect(reason), %{})}

      {:error, reason} ->
        {:error, result(notification, :failed, false, inspect(reason), %{})}
    end
  end

  # The same rules as the generic webhook with none of its opt-outs: https, no userinfo,
  # no private host, and the name's addresses looked up now (DNS can change after the
  # config was accepted). Not echoed: the URL is the secret.
  defp check_url(url) do
    case WebhookUrl.check_resolved(url, [], host_resolver()) do
      :ok -> :ok
      {:error, :unresolvable_host} -> {:error, {:unresolvable_host, :slack_destination}}
      {:error, :not_http_url} -> {:error, {:invalid_field, :slack_destination, :webhook_url}}
      {:error, reason} -> {:error, {:unsafe_url, :slack_destination, reason}}
    end
  end

  # Public for no-network contract tests.
  def build_request(webhook_url, text) do
    {webhook_url, %{text: text}, [], @timeout_ms}
  end

  defp result(notification, status, retryable?, reason, metadata) do
    %DeliveryResult{
      notification_id: notification.notification_id,
      provider: :slack,
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

  defp host_resolver do
    Application.get_env(:foreman_server, :messaging, [])
    |> Keyword.get(:host_resolver, WebhookUrl)
  end
end
