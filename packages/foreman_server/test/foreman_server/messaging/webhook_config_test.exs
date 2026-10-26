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
             secret: {:system, "HOOK_SECRET"},
             allow_insecure_http: false,
             allow_private_hosts: false
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

  describe "an unsafe url is refused when the config resolves (foreman-ireii)" do
    test "plain http, userinfo and a private host each get their own tuple" do
      assert {:error, {:unsafe_url, :webhook_destination, :insecure_http}} =
               resolve(url: "http://example.test/hook")

      assert {:error, {:unsafe_url, :webhook_destination, :userinfo}} =
               resolve(url: "https://bot:hunter2@example.test/hook")

      for url <- [
            "https://localhost/hook",
            "https://127.0.0.1/hook",
            "https://10.1.2.3/hook",
            "https://169.254.169.254/latest",
            "https://[::1]/hook"
          ] do
        assert {:error, {:unsafe_url, :webhook_destination, :private_host}} = resolve(url: url)
      end
    end

    test "the refusal never echoes the url, so it cannot leak the token in it" do
      for url <- ["https://bot:hunter2@example.test/hook", "http://example.test/hook/TOKEN123"] do
        assert {:error, reason} = resolve(url: url)
        refute inspect(reason) =~ "hunter2"
        refute inspect(reason) =~ "TOKEN123"
      end
    end

    test "a malformed url that carries userinfo is reported as userinfo, not echoed as malformed" do
      assert {:error, {:unsafe_url, :webhook_destination, :userinfo}} =
               resolve(url: "ftp://bot:hunter2@example.test/hook")
    end

    test "allow_insecure_http and allow_private_hosts are the explicit opt-outs, and independent" do
      assert {:ok, %{destination: %{allow_insecure_http: true, allow_private_hosts: false}}} =
               resolve(url: "http://example.test/hook", allow_insecure_http: true)

      assert {:ok, %{destination: %{allow_insecure_http: false, allow_private_hosts: true}}} =
               resolve(url: "https://127.0.0.1/hook", allow_private_hosts: true)

      assert {:error, {:unsafe_url, :webhook_destination, :private_host}} =
               resolve(url: "http://127.0.0.1:4000/hook", allow_insecure_http: true)

      assert {:ok, %{destination: %{url: "http://127.0.0.1:4000/hook"}}} =
               resolve(
                 url: "http://127.0.0.1:4000/hook",
                 allow_insecure_http: true,
                 allow_private_hosts: true
               )
    end

    test "the flags accept the string form loaded config carries, string keys, and null" do
      assert {:ok, %{destination: %{allow_insecure_http: true}}} =
               resolve(%{"url" => "http://example.test/hook", "allow_insecure_http" => "true"})

      assert {:ok, %{destination: %{allow_insecure_http: false, allow_private_hosts: false}}} =
               resolve(
                 url: "https://example.test/hook",
                 allow_insecure_http: "false",
                 allow_private_hosts: nil
               )
    end

    test "a flag that is not a boolean is invalid, not silently off" do
      assert {:error, {:invalid_field, :webhook_destination, :allow_private_hosts, "yes"}} =
               resolve(url: "https://example.test/hook", allow_private_hosts: "yes")

      assert {:error, {:invalid_field, :webhook_destination, :allow_insecure_http, 1}} =
               resolve(url: "https://example.test/hook", allow_insecure_http: 1)
    end

    test "a disabled messaging config is not judged: nothing will be sent" do
      Application.put_env(:foreman_server, :messaging,
        enabled: false,
        provider: :webhook,
        webhook: [url: "http://127.0.0.1/hook"]
      )

      assert {:ok, %{enabled?: false, destination: nil}} = ConfigResolver.resolve()
    end
  end

  test "unknown providers are still rejected" do
    Application.put_env(:foreman_server, :messaging, enabled: false, provider: :desktop)
    assert {:error, {:unsupported_provider, :desktop}} = ConfigResolver.resolve()
  end
end
