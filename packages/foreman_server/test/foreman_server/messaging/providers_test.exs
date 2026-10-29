defmodule ForemanServer.Messaging.ProvidersTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Messaging.{HttpResponse, Notification}
  alias ForemanServer.Messaging.Providers.{Slack, Telegram, Webhook}
  alias ForemanServer.TestSupport.StaticHostResolver

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

    Application.put_env(:foreman_server, :messaging,
      http_client: FakeHttpClient,
      host_resolver: StaticHostResolver
    )

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

  describe "slack adapter" do
    @slack_url "https://hooks.slack.com/services/T000/B000/PROVIDERSECRET"
    @rendered "[info] Test\nHello\nmetadata=%{run_id: \"run-1\"}"

    setup do
      {:ok, notification} =
        Notification.normalize(%{@notification_attrs | provider: :slack, recipient: "default"})

      {:ok, notification: notification}
    end

    test "any 2xx is a delivery: the rendered text is posted to the webhook URL, nothing is retried",
         %{notification: notification} do
      for status <- [200, 201, 299] do
        Process.put(:fake_http_response, {:ok, %HttpResponse{status: status, body: "ok"}})

        assert {:ok, result} = Slack.send(notification, %{webhook_url: @slack_url})

        assert %{
                 status: :succeeded,
                 provider: :slack,
                 notification_id: "n-1",
                 retryable?: false,
                 reason: nil,
                 metadata: %{status: ^status, body: "ok"}
               } = result

        assert is_binary(result.delivered_at)
        assert_received {:provider_request, @slack_url, %{text: @rendered}, [], 5_000}
      end
    end

    test "anything else fails the delivery, and only 429 and 5xx are worth retrying", %{
      notification: notification
    } do
      table = [
        {300, false},
        {400, false},
        {401, false},
        {403, false},
        {404, false},
        {429, true},
        {500, true},
        {503, true}
      ]

      for {status, retryable?} <- table do
        Process.put(:fake_http_response, {:ok, %HttpResponse{status: status, body: "nope"}})

        assert {:error, failed} = Slack.send(notification, %{webhook_url: @slack_url})

        assert %{
                 status: :failed,
                 provider: :slack,
                 notification_id: "n-1",
                 retryable?: ^retryable?,
                 delivered_at: nil,
                 metadata: %{status: ^status}
               } = failed

        assert failed.reason == "slack_http_#{status}: nope"
        assert_received {:provider_request, @slack_url, _body, [], 5_000}
      end
    end

    test "a transport error is a retryable failure, never a delivery", %{
      notification: notification
    } do
      Process.put(:fake_http_response, {:error, :timeout})

      assert {:error, %{status: :failed, retryable?: true, reason: ":timeout", delivered_at: nil}} =
               Slack.send(notification, %{webhook_url: @slack_url})
    end

    test "an error body that echoes the webhook URL does not carry it into the result", %{
      notification: notification
    } do
      Process.put(
        :fake_http_response,
        {:ok, %HttpResponse{status: 404, body: "no_service " <> @slack_url}}
      )

      assert {:error, failed} = Slack.send(notification, %{webhook_url: @slack_url})

      assert failed.reason ==
               "slack_http_404: no_service https://hooks.slack.com/services/[REDACTED]"

      refute inspect(failed) =~ "PROVIDERSECRET"
    end

    test "a destination without a usable URL fails terminally and sends nothing", %{
      notification: notification
    } do
      for {destination, reason} <- [
            {%{}, "{:missing_field, :slack_destination, :webhook_url}"},
            {%{webhook_url: ""}, ~s({:invalid_field, :slack_destination, :webhook_url, ""})},
            {%{webhook_url: 42}, "{:invalid_field, :slack_destination, :webhook_url, 42}"}
          ] do
        assert {:error, failed} = Slack.send(notification, destination)
        assert %{status: :failed, retryable?: false} = failed
        assert failed.reason == reason
        refute_received {:provider_request, _, _, _, _}
      end
    end

    test "an unsafe webhook URL is refused before any request, and the refusal never carries it",
         %{notification: notification} do
      secret = "SLACKSECRETTOKEN"

      for {url, reason, retryable?} <- [
            {"http://hooks.slack.com/services/T/B/#{secret}", :insecure_http, false},
            {"https://user:pw@hooks.slack.com/services/T/B/#{secret}", :userinfo, false},
            {"https://127.0.0.1/services/T/B/#{secret}", :private_host, false},
            {"https://localhost/services/T/B/#{secret}", :private_host, false},
            {"https://internal.test/services/T/B/#{secret}", :private_host, false},
            {"https://mixed.test/services/T/B/#{secret}", :private_host, false},
            {"hooks.slack.com/services/T/B/#{secret}", :not_http_url, false},
            {"https://down.test/services/T/B/#{secret}", :unresolvable_host, true}
          ] do
        assert {:error, failed} = Slack.send(notification, %{webhook_url: url})
        assert %{status: :failed, retryable?: ^retryable?} = failed
        refute inspect(failed) =~ secret
        refute inspect(failed) =~ "hooks.slack.com/services"
        refute_received {:provider_request, _, _, _, _}

        case reason do
          :not_http_url ->
            assert failed.reason == "{:invalid_field, :slack_destination, :webhook_url}"

          :unresolvable_host ->
            assert failed.reason == "{:unresolvable_host, :slack_destination}"

          _ ->
            assert failed.reason == "{:unsafe_url, :slack_destination, #{inspect(reason)}}"
        end
      end
    end

    test "a {:system, env} URL is checked when it is read", %{notification: notification} do
      var = "FOREMAN_TEST_SLACK_UNSAFE_URL"
      System.put_env(var, "http://hooks.slack.com/services/T/B/ENVSECRET")
      on_exit(fn -> System.delete_env(var) end)

      assert {:error, failed} = Slack.send(notification, %{webhook_url: {:system, var}})
      assert failed.reason == "{:unsafe_url, :slack_destination, :insecure_http}"
      refute inspect(failed) =~ "ENVSECRET"
      refute_received {:provider_request, _, _, _, _}
    end
  end

  describe "telegram adapter" do
    @token "123456:abcdefghijklmnopqrstuvwxyzABCDE"
    @send_url "https://api.telegram.org/bot#{@token}/sendMessage"
    @destination %{token: @token, chat_id: "-1001234"}

    setup do
      {:ok, notification} = Notification.normalize(@notification_attrs)
      {:ok, notification: notification}
    end

    test "any 2xx is a delivery: chat id and rendered text go to the bot's sendMessage",
         %{notification: notification} do
      for status <- [200, 201, 299] do
        Process.put(
          :fake_http_response,
          {:ok, %HttpResponse{status: status, body: ~s({"ok":true})}}
        )

        assert {:ok, result} = Telegram.send(notification, @destination)

        assert %{
                 status: :succeeded,
                 provider: :telegram,
                 notification_id: "n-1",
                 retryable?: false,
                 reason: nil,
                 metadata: %{status: ^status, body: ~s({"ok":true})}
               } = result

        assert is_binary(result.delivered_at)

        assert_received {:provider_request, @send_url,
                         %{
                           chat_id: "-1001234",
                           text: @rendered,
                           disable_web_page_preview: true
                         }, [], 5_000}
      end
    end

    test "anything else fails the delivery, and only 429 and 5xx are worth retrying", %{
      notification: notification
    } do
      table = [
        {300, false},
        {400, false},
        {401, false},
        {403, false},
        {404, false},
        {409, false},
        {429, true},
        {500, true},
        {502, true}
      ]

      for {status, retryable?} <- table do
        body = ~s({"ok":false,"error_code":#{status},"description":"nope"})
        Process.put(:fake_http_response, {:ok, %HttpResponse{status: status, body: body}})

        assert {:error, failed} = Telegram.send(notification, @destination)

        assert %{
                 status: :failed,
                 provider: :telegram,
                 notification_id: "n-1",
                 retryable?: ^retryable?,
                 delivered_at: nil,
                 metadata: %{status: ^status}
               } = failed

        assert failed.reason == "telegram_http_#{status}: #{body}"
        assert_received {:provider_request, @send_url, _body, [], 5_000}
      end
    end

    test "a transport error is a retryable failure, never a delivery", %{
      notification: notification
    } do
      Process.put(:fake_http_response, {:error, :econnrefused})

      assert {:error,
              %{status: :failed, retryable?: true, reason: ":econnrefused", delivered_at: nil}} =
               Telegram.send(notification, @destination)
    end

    test "the token never reaches a failure result, whether the answer echoes it with or without `bot`",
         %{notification: notification} do
      Process.put(
        :fake_http_response,
        {:ok,
         %HttpResponse{
           status: 502,
           body: "upstream /bot#{@token}/sendMessage failed for #{@token}"
         }}
      )

      assert {:error, failed} = Telegram.send(notification, @destination)

      assert failed.reason ==
               "telegram_http_502: upstream /bot[REDACTED]/sendMessage failed for [REDACTED]"

      refute inspect(failed) =~ "abcdefghijklmnopqrstuvwxyzABCDE"
    end

    test "a destination missing its token or chat id fails terminally and sends nothing", %{
      notification: notification
    } do
      for {destination, reason} <- [
            {%{chat_id: "-1001234"}, "{:missing_field, :telegram_destination, :token}"},
            {%{token: @token}, "{:missing_field, :telegram_destination, :chat_id}"},
            {%{token: @token, chat_id: ""},
             ~s({:invalid_field, :telegram_destination, :chat_id, ""})}
          ] do
        assert {:error, failed} = Telegram.send(notification, destination)
        assert %{status: :failed, retryable?: false} = failed
        assert failed.reason == reason
        refute_received {:provider_request, _, _, _, _}
      end
    end

    test "a {:system, env} token is read when the message is sent; an unset one is terminal", %{
      notification: notification
    } do
      var = "FOREMAN_PROVIDERS_TEST_TG_TOKEN_#{System.unique_integer([:positive])}"
      on_exit(fn -> System.delete_env(var) end)
      destination = %{token: {:system, var}, chat_id: "-1001234"}

      assert {:error, failed} = Telegram.send(notification, destination)
      assert failed.retryable? == false

      assert failed.reason ==
               "{:unresolved_secret_ref, :telegram_destination, :token, \"#{var}\"}"

      refute_received {:provider_request, _, _, _, _}

      System.put_env(var, @token)
      assert {:ok, %{status: :succeeded}} = Telegram.send(notification, destination)
      assert_received {:provider_request, @send_url, %{chat_id: "-1001234"}, [], 5_000}
    end
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

      assert_received {:provider_request, "https://example.test/hook", body,
                       [{"x-foreman-delivery", "n-1"}], 5_000}

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

      assert_received {:provider_request, _url, body,
                       [{"x-foreman-delivery", "n-1"}, {"x-foreman-signature", "sha256=" <> hex}],
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

    # foreman-ireii (E10-S4): the URL is judged again right before each send.
    test "an unsafe URL is refused terminally before anything is sent, and the reason holds no URL",
         %{notification: notification} do
      for {url, reason} <- [
            {"http://example.test/hook/LEAKTOKEN", :insecure_http},
            {"https://bot:LEAKTOKEN@example.test/hook", :userinfo},
            {"https://127.0.0.1/hook/LEAKTOKEN", :private_host},
            {"https://[::1]/hook/LEAKTOKEN", :private_host},
            {"https://localhost/hook/LEAKTOKEN", :private_host},
            {"https://internal.test/hook/LEAKTOKEN", :private_host},
            {"https://metadata.test/hook/LEAKTOKEN", :private_host}
          ] do
        assert {:error, failed} = Webhook.send(notification, %{url: url, secret: "s3cret"})
        assert failed.retryable? == false
        assert failed.reason == inspect({:unsafe_url, :webhook_destination, reason})
        refute inspect(failed) =~ "LEAKTOKEN"
        refute_received {:provider_request, _, _, _, _}
      end
    end

    test "the opt-outs in the destination let an http or private-network receiver through", %{
      notification: notification
    } do
      local = "http://127.0.0.1:4000/hook"

      assert {:ok, %{status: :succeeded}} =
               Webhook.send(notification, %{
                 url: local,
                 allow_insecure_http: true,
                 allow_private_hosts: true
               })

      assert_received {:provider_request, ^local, _, _, _}

      # One opt-out is not the other, and string keys (a destination that went through JSON) count.
      assert {:error, failed} =
               Webhook.send(notification, %{url: local, allow_insecure_http: true})

      assert failed.reason =~ "private_host"
      refute_received {:provider_request, _, _, _, _}

      assert {:ok, _} =
               Webhook.send(notification, %{
                 "url" => "https://internal.test/hook",
                 "allow_private_hosts" => true
               })

      assert_received {:provider_request, "https://internal.test/hook", _, _, _}
    end

    test "a flag that is not a boolean fails the delivery without echoing it", %{
      notification: notification
    } do
      assert {:error, failed} =
               Webhook.send(notification, %{
                 url: "https://example.test/hook",
                 allow_private_hosts: "LEAKFLAG"
               })

      assert failed.retryable? == false
      assert failed.reason =~ "invalid_field"
      refute inspect(failed) =~ "LEAKFLAG"
      refute_received {:provider_request, _, _, _, _}
    end

    test "a {:system, env} URL is judged when it is read, at send time", %{
      notification: notification
    } do
      var = "FOREMAN_E10_WEBHOOK_URL_#{System.unique_integer([:positive])}"
      on_exit(fn -> System.delete_env(var) end)

      System.put_env(var, "http://example.test/hook")
      assert {:error, failed} = Webhook.send(notification, %{url: {:system, var}})
      assert failed.reason =~ "insecure_http"
      refute_received {:provider_request, _, _, _, _}

      System.put_env(var, "https://example.test/hook")
      assert {:ok, _} = Webhook.send(notification, %{url: {:system, var}})
      assert_received {:provider_request, "https://example.test/hook", _, _, _}
    end

    test "a host name whose lookup fails is retried, not refused", %{notification: notification} do
      assert {:error, failed} = Webhook.send(notification, %{url: "https://down.test/hook"})
      assert failed.retryable? == true
      assert failed.reason =~ "unresolvable_host"
      refute_received {:provider_request, _, _, _, _}
    end
  end
end
