defmodule ForemanServer.Messaging.ProvidersTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Messaging.Notification
  alias ForemanServer.Messaging.Providers.{Slack, Telegram}

  defmodule FakeHttpClient do
    def post_json(url, body, headers, timeout) do
      send(self(), {:provider_request, url, body, headers, timeout})
      Process.get(:fake_http_response, {:ok, %{status: 200, body: "ok"}})
    end
  end

  @notification_attrs %{
    notification_id: "n-1",
    provider: :telegram,
    recipient: "chat-1",
    event_class: :test,
    severity: :info,
    subject: "Test",
    body: "Hello",
    correlation_id: "corr-1",
    run_id: "run-1",
    metadata: %{run_id: "run-1"}
  }

  setup do
    original = Application.get_env(:foreman_server, :messaging)
    Application.put_env(:foreman_server, :messaging, http_client: FakeHttpClient)

    on_exit(fn ->
      Process.delete(:fake_http_response)

      case original do
        nil -> Application.delete_env(:foreman_server, :messaging)
        value -> Application.put_env(:foreman_server, :messaging, value)
      end
    end)
  end

  test "telegram adapter posts sendMessage JSON and redacts token-bearing errors" do
    {:ok, notification} = Notification.normalize(@notification_attrs)

    assert {:ok, result} =
             Telegram.send(notification, %{
               token: "123456:abcdefghijklmnopqrstuvwxyzABCDE",
               chat_id: "chat-1"
             })

    assert result.status == :succeeded

    assert_received {:provider_request, url, body, [], 5_000}
    assert url == "https://api.telegram.org/bot123456:abcdefghijklmnopqrstuvwxyzABCDE/sendMessage"
    assert body.chat_id == "chat-1"
    assert body.text =~ "Hello"

    Process.put(
      :fake_http_response,
      {:ok, %{status: 401, body: "bad bot123456:abcdefghijklmnopqrstuvwxyzABCDE"}}
    )

    assert {:error, failed} =
             Telegram.send(notification, %{
               token: "123456:abcdefghijklmnopqrstuvwxyzABCDE",
               chat_id: "chat-1"
             })

    assert failed.retryable? == false
    refute failed.reason =~ "abcdefghijklmnopqrstuvwxyzABCDE"
  end

  test "slack adapter posts incoming webhook text and classifies retryable statuses" do
    {:ok, notification} =
      Notification.normalize(%{
        @notification_attrs
        | provider: :slack,
          recipient: "https://hooks.slack.com/services/T/B/C"
      })

    Process.put(:fake_http_response, {:ok, %{status: 429, body: "rate limited"}})

    assert {:error, failed} =
             Slack.send(notification, %{webhook_url: "https://hooks.slack.com/services/T/B/C"})

    assert failed.retryable? == true
    assert failed.reason =~ "slack_http_429"

    assert_received {:provider_request, url, body, [], 5_000}
    assert url == "https://hooks.slack.com/services/T/B/C"
    assert body.text =~ "Hello"
  end

  test "provider request builders do not need network" do
    assert {telegram_url, telegram_body, [], 5_000} =
             Telegram.build_request("token", "chat", "safe text")

    assert telegram_url == "https://api.telegram.org/bottoken/sendMessage"
    assert telegram_body == %{chat_id: "chat", text: "safe text", disable_web_page_preview: true}

    assert {slack_url, slack_body, [], 5_000} =
             Slack.build_request("https://hooks.slack.com/services/T/B/C", "safe text")

    assert slack_url == "https://hooks.slack.com/services/T/B/C"
    assert slack_body == %{text: "safe text"}
  end
end
