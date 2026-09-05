defmodule ForemanServer.Messaging do
  @moduledoc "Fast outbound notification enqueue boundary."

  alias ForemanServer.{CommandRouter, Messaging.ConfigResolver, Messaging.Notification}

  @enqueue_timeout_ms 250

  @spec notify(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def notify(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, notification} <- Notification.normalize(attrs),
         {:ok, config} <- ConfigResolver.resolve(opts) do
      payload =
        notification
        |> Notification.to_event_payload()
        |> Map.merge(%{
          enabled: ConfigResolver.enabled_for?(config, notification.event_class),
          dedupe_window_ms: config.dedupe_window_ms,
          now_ms: Keyword.get(opts, :now_ms, System.system_time(:millisecond))
        })

      case CommandRouter.dispatch(
             %{
               aggregate_id: "notification:#{notification.correlation_id}",
               type: "notification.enqueue",
               payload: payload
             },
             Keyword.get(opts, :timeout, @enqueue_timeout_ms)
           ) do
        {:ok, %{payload: %{notification_id: notification_id}}} -> {:ok, notification_id}
        {:ok, %{payload: %{"notification_id" => notification_id}}} -> {:ok, notification_id}
        {:ok, nil} -> {:error, :not_persisted}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
