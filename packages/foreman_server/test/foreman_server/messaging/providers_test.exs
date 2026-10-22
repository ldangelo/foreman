defmodule ForemanServer.Messaging.ProvidersTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Messaging.{HttpResponse, Notification}
  alias ForemanServer.Messaging.Providers.{Slack, Telegram, Webhook}

  defmodule FakeHttpClient do
    def post_json(url, body, headers, timeout) do
      send(self(), {:provider_request, url, body, headers, timeout})
      Process.get(:fake_http_response, {:ok, %HttpResponse{status: 200, body: "ok"}})
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
      {:ok, %HttpResponse{status: 401, body: "bad bot123456:abcdefghijklmnopqrstuvwxyzABCDE"}}
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

    Process.put(:fake_http_response, {:ok, %HttpResponse{status: 429, body: "rate limited"}})

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

  describe "webhook adapter" do
    setup do
      {:ok, notification} =
        Notification.normalize(%{@notification_attrs | provider: :webhook, recipient: "default"})

      {:ok, notification: notification}
    end

    test "posts the versioned JSON document to the configured URL", %{notification: notification} do
      assert {:ok, %{status: :succeeded, provider: :webhook}} =
               Webhook.send(notification, %{url: "https://example.test/hook", secret: nil})

      assert_received {:provider_request, "https://example.test/hook", body, [], 5_000}
      assert body.schema == "foreman.notification.v1"
      assert body.notification_id == "n-1"
      assert body.event_class == :test
      assert body.subject == "Test"
      assert body.body == "Hello"
      assert body.run_id == "run-1"
    end

    test "signs the exact JSON body with HMAC-SHA256 when a secret is configured", %{
      notification: notification
    } do
      assert {:ok, _} =
               Webhook.send(notification, %{url: "https://example.test/hook", secret: "s3cret"})

      assert_received {:provider_request, _url, body, [{"x-foreman-signature", "sha256=" <> hex}],
                       _}

      expected =
        :crypto.mac(:hmac, :sha256, "s3cret", Jason.encode!(body)) |> Base.encode16(case: :lower)

      assert hex == expected
    end

    test "classifies statuses and never echoes the URL or secret in a failure reason", %{
      notification: notification
    } do
      destination = %{url: "https://example.test/hook/LEAKTOKEN", secret: "s3cret"}

      for {status, retryable?} <- [{429, true}, {503, true}, {400, false}, {404, false}] do
        Process.put(:fake_http_response, {:ok, %HttpResponse{status: status, body: "nope"}})
        assert {:error, failed} = Webhook.send(notification, destination)
        assert failed.retryable? == retryable?
        assert failed.reason == "webhook_http_#{status}"
      end

      Process.put(:fake_http_response, {:error, :econnrefused})
      assert {:error, failed} = Webhook.send(notification, destination)
      assert failed.retryable? == true
      refute inspect(failed) =~ "LEAKTOKEN"
    end

    test "resolves {:system, env} references and fails terminally when unset", %{
      notification: notification
    } do
      assert {:error, failed} =
               Webhook.send(notification, %{url: {:system, "FOREMAN_E10_UNSET_WEBHOOK_URL"}})

      assert failed.retryable? == false
      assert failed.reason =~ "unresolved_secret_ref"
      refute_received {:provider_request, _, _, _, _}

      assert {:error, missing} = Webhook.send(notification, %{})
      assert missing.reason =~ "missing_field"
    end

    test "a destination holding the atom and string form of a key with different values raises, without echoing either",
         %{notification: notification} do
      error =
        assert_raise ArgumentError, ~r/conflicting atom\/string keys for :url/, fn ->
          Webhook.send(notification, %{
            :url => "https://a.example/secret-a",
            "url" => "https://b.example/secret-b"
          })
        end

      refute error.message =~ "secret-a"
      refute error.message =~ "secret-b"
      refute_received {:provider_request, _, _, _, _}
    end

    test "the same value under both key forms is accepted", %{notification: notification} do
      assert {:ok, %{status: :succeeded}} =
               Webhook.send(notification, %{
                 :url => "https://example.test/hook",
                 "url" => "https://example.test/hook"
               })

      assert_received {:provider_request, "https://example.test/hook", _, _, _}
    end
  end
end
