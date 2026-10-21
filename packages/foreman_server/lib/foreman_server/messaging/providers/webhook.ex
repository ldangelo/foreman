defmodule ForemanServer.Messaging.Providers.Webhook do
  @moduledoc """
  Generic outbound webhook provider behind `ForemanServer.Messaging.Provider`.

  POSTs one JSON document per notification (`schema:
  "foreman.notification.v1"`) to the configured URL, so any receiver (an
  automation platform, a custom bot, a desktop-notifier bridge) can consume
  Foreman notifications without a provider-specific adapter.

  Destination (from `ConfigResolver`, never from events):

    * `:url` - literal http(s) URL or `{:system, env_name}`; required.
    * `:secret` - optional literal or `{:system, env_name}`. When present the
      request carries `x-foreman-signature: sha256=<hex>`, the HMAC-SHA256 of the
      exact JSON body bytes keyed by the secret.

  Error reasons never include the URL or the secret. 2xx succeeds; 429 and 5xx
  and transport errors are retryable; other statuses are terminal.
  """

  @behaviour ForemanServer.Messaging.Provider

  alias ForemanServer.Messaging.{DeliveryResult, HttpResponse, Notification, Redactor}

  @timeout_ms 5_000
  @schema "foreman.notification.v1"

  @impl true
  def send(%Notification{} = notification, destination) when is_map(destination) do
    with {:ok, url} <- required_binary(destination, :url, :webhook_destination),
         {:ok, secret} <- optional_binary(destination, :secret, :webhook_destination) do
      {url, body, headers, timeout} = build_request(url, notification, secret)

      case http_client().post_json(url, body, headers, timeout) do
        {:ok, %HttpResponse{status: status}} when status in 200..299 ->
          {:ok, result(notification, :succeeded, false, nil, %{status: status})}

        {:ok, %HttpResponse{status: status}} ->
          {:error,
           result(notification, :failed, retryable_status?(status), "webhook_http_#{status}", %{
             status: status
           })}

        {:error, reason} ->
          {:error,
           result(notification, :failed, true, "webhook_transport_error", %{
             detail: inspect(reason) |> Redactor.redact()
           })}
      end
    else
      {:error, reason} ->
        {:error, result(notification, :failed, false, inspect(reason), %{})}
    end
  end

  @doc """
  The request for a notification: `{url, body, headers, timeout_ms}`. Public so
  contract tests need no network.
  """
  @spec build_request(String.t(), Notification.t(), String.t() | nil) ::
          {String.t(), map(), [{String.t(), String.t()}], non_neg_integer()}
  def build_request(url, %Notification{} = notification, secret) do
    body = %{
      schema: @schema,
      notification_id: notification.notification_id,
      correlation_id: notification.correlation_id,
      event_class: notification.event_class,
      severity: notification.severity,
      subject: Redactor.redact(notification.subject),
      body: Redactor.redact(notification.body),
      url: notification.url,
      run_id: notification.run_id,
      metadata: Redactor.redact(notification.metadata)
    }

    {url, body, signature_headers(body, secret), @timeout_ms}
  end

  defp signature_headers(_body, nil), do: []

  defp signature_headers(body, secret) do
    digest =
      :crypto.mac(:hmac, :sha256, secret, Jason.encode!(body)) |> Base.encode16(case: :lower)

    [{"x-foreman-signature", "sha256=" <> digest}]
  end

  defp result(notification, status, retryable?, reason, metadata) do
    %DeliveryResult{
      notification_id: notification.notification_id,
      provider: :webhook,
      status: status,
      retryable?: retryable?,
      reason: Redactor.redact(reason),
      delivered_at: if(status == :succeeded, do: DateTime.utc_now() |> DateTime.to_iso8601()),
      metadata: Redactor.redact(metadata || %{})
    }
  end

  defp retryable_status?(status), do: status == 429 or status >= 500

  defp required_binary(map, key, error_key) do
    case optional_binary(map, key, error_key) do
      {:ok, nil} -> {:error, {:missing_field, error_key, key}}
      other -> other
    end
  end

  defp optional_binary(map, key, error_key) do
    case fetch_field(map, key) do
      :absent ->
        {:ok, nil}

      {:present, nil} ->
        {:ok, nil}

      {:present, {:system, env_name}} when is_binary(env_name) ->
        case System.get_env(env_name) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _ -> {:error, {:unresolved_secret_ref, error_key, key, env_name}}
        end

      {:present, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:present, _value} ->
        # The raw value is deliberately not echoed: it may be the secret.
        {:error, {:invalid_field, error_key, key}}
    end
  end

  # Destinations round-trip through JSON, so both key forms are checked.
  defp fetch_field(map, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, string_key) -> {:present, Map.get(map, string_key)}
      true -> :absent
    end
  end

  defp http_client do
    Application.get_env(:foreman_server, :messaging, [])
    |> Keyword.get(:http_client, ForemanServer.Messaging.HttpClient)
  end
end
