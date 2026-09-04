defmodule ForemanServer.Messaging.Renderer do
  @moduledoc "Renders safe provider-neutral notification text."
  alias ForemanServer.Messaging.{Notification, Redactor}

  @spec render(Notification.t()) :: {:ok, String.t()} | {:error, term()}
  def render(%Notification{} = notification) do
    lines = [
      "[#{notification.severity}] #{notification.subject}",
      notification.body,
      notification.url,
      metadata_line(notification.metadata)
    ]

    {:ok,
     lines |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.join("\n") |> Redactor.redact()}
  end

  defp metadata_line(metadata) when map_size(metadata) == 0, do: nil
  defp metadata_line(metadata), do: "metadata=" <> inspect(metadata)
end
