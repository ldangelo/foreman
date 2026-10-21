defmodule ForemanServer.Messaging.WebhookConfigTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Messaging.ConfigResolver

  setup do
    original = Application.get_env(:foreman_server, :messaging)

    on_exit(fn ->
      if original,
        do: Application.put_env(:foreman_server, :messaging, original),
        else: Application.delete_env(:foreman_server, :messaging)
    end)
  end

  defp resolve(webhook, extra \\ []) do
    Application.put_env(
      :foreman_server,
      :messaging,
      [enabled: true, provider: :webhook, webhook: webhook] ++ extra
    )

    ConfigResolver.resolve()
  end

  test "webhook is a resolvable provider with its destination and optional secret" do
    assert {:ok, %{provider: :webhook, destination: destination}} =
             resolve(url: "https://example.test/hook", secret: {:system, "HOOK_SECRET"})

    assert destination == %{
             provider: :webhook,
             url: "https://example.test/hook",
             secret: {:system, "HOOK_SECRET"}
           }

    assert {:ok, %{destination: %{secret: nil}}} = resolve(url: "https://example.test/hook")
  end

  test "a missing, non-http or malformed url is rejected with distinct tuples" do
    assert {:error, {:missing_field, :webhook_destination, :url}} = resolve([])

    assert {:error, {:invalid_field, :webhook_destination, :url, "ftp://x"}} =
             resolve(url: "ftp://x")

    assert {:error, {:invalid_field, :webhook_destination, :url, 5}} = resolve(url: 5)

    assert {:error, {:invalid_field, :webhook_destination, :secret, ""}} =
             resolve(url: "https://example.test/hook", secret: "")
  end

  test "an env reference url is accepted without being resolved at config time" do
    assert {:ok, %{destination: %{url: {:system, "HOOK_URL"}}}} =
             resolve(url: {:system, "HOOK_URL"})
  end

  test "unknown providers are still rejected" do
    Application.put_env(:foreman_server, :messaging, enabled: false, provider: :desktop)
    assert {:error, {:unsupported_provider, :desktop}} = ConfigResolver.resolve()
  end
end
