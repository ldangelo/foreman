defmodule ForemanServer.Messaging.HttpClientTest do
  @moduledoc """
  The default HTTP client and the webhook provider over a REAL TLS connection
  (foreman-ireii). Every other messaging test injects a fake `http_client`, and
  every live observation used a plain `http://127.0.0.1` sink, so what the
  default client does with TLS on the pinned OTP was never exercised.

  The receiver is a local `:ssl` listener whose certificate chains to a CA
  generated for the test (`:public_key.pkix_test_data/1`). The CA is trusted by
  loading it as the VM's CA store (`:public_key.cacerts_load/1`), which is what
  the client's default `verify_peer` reads; it is cleared again afterwards. So
  the client under test is the unmodified production one, with its defaults.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Messaging.{HttpClient, HttpResponse, Notification}
  alias ForemanServer.Messaging.Providers.Webhook

  setup %{tmp_dir: dir} do
    # The default client and the default resolver: nothing a sibling test configured may stand in.
    original = Application.get_env(:foreman_server, :messaging)
    Application.delete_env(:foreman_server, :messaging)

    on_exit(fn ->
      :public_key.cacerts_clear()
      if original, do: Application.put_env(:foreman_server, :messaging, original)
    end)

    {:ok, ca_file: Path.join(dir, "ca.pem")}
  end

  # -- a TLS receiver ------------------------------------------------------------------------

  # `san` is the DNS name the certificate is valid for. Returns the chain (`cert`, `key`,
  # `cacerts`) as `:public_key.pkix_test_data/1` builds it.
  defp chain(san) do
    san_extension = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(san)}]}

    :public_key.pkix_test_data(%{
      root: [key: {:rsa, 2048, 17}],
      peer: [key: {:rsa, 2048, 17}, extensions: [san_extension]]
    })
  end

  defp trust(chain, ca_file) do
    pem =
      :public_key.pem_encode(for der <- chain[:cacerts], do: {:Certificate, der, :not_encrypted})

    File.write!(ca_file, pem)
    :ok = :public_key.cacerts_load(String.to_charlist(ca_file))
  end

  # Serves requests one after another, answering each with `status`. The test process is told
  # `{:request, %{request_line, headers, body}}` for each one that arrived, and
  # `{:handshake_failed, reason}` for each connection the client abandoned.
  defp start_receiver(chain, status \\ 200) do
    {:ok, listen} =
      :ssl.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        cert: chain[:cert],
        key: chain[:key]
      ])

    {:ok, {_address, port}} = :ssl.sockname(listen)
    test = self()
    spawn_link(fn -> accept_loop(listen, test, status) end)
    on_exit(fn -> :ssl.close(listen) end)
    "https://localhost:#{port}/hook"
  end

  defp accept_loop(listen, test, status) do
    with {:ok, transport} <- :ssl.transport_accept(listen) do
      case :ssl.handshake(transport, 5_000) do
        {:ok, socket} -> serve(socket, test, status)
        {:error, reason} -> send(test, {:handshake_failed, reason})
      end

      accept_loop(listen, test, status)
    end
  end

  defp serve(socket, test, status) do
    send(test, {:request, read_request(socket, "")})
    :ssl.send(socket, "HTTP/1.1 #{status} X\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")
    :ssl.close(socket)
  end

  defp read_request(socket, received) do
    case String.split(received, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [request_line | header_lines] = String.split(head, "\r\n")

        headers =
          Map.new(header_lines, fn line ->
            [name, value] = String.split(line, ": ", parts: 2)
            {String.downcase(name), value}
          end)

        if byte_size(body) >= String.to_integer(Map.get(headers, "content-length", "0")),
          do: %{request_line: request_line, headers: headers, body: body},
          else: read_more(socket, received)

      [_incomplete_head] ->
        read_more(socket, received)
    end
  end

  defp read_more(socket, received) do
    {:ok, data} = :ssl.recv(socket, 0, 5_000)
    read_request(socket, received <> data)
  end

  # -- the client ----------------------------------------------------------------------------

  test "the default client completes a real TLS request: handshake, verification, POST, response",
       %{ca_file: ca_file} do
    chain = chain("localhost")
    trust(chain, ca_file)
    url = start_receiver(chain)

    assert {:ok, %HttpResponse{status: 200, body: "ok"}} =
             HttpClient.post_json(url, %{"a" => 1, "text" => "héllo"}, [
               {"x-foreman-delivery", "n-1"}
             ])

    assert_receive {:request,
                    %{request_line: "POST /hook HTTP/1.1", headers: headers, body: body}}

    assert headers["content-type"] == "application/json"
    assert headers["x-foreman-delivery"] == "n-1"
    assert Jason.decode!(body) == %{"a" => 1, "text" => "héllo"}
  end

  test "a status the receiver answers with comes back as a response, not an error",
       %{ca_file: ca_file} do
    chain = chain("localhost")
    trust(chain, ca_file)
    url = start_receiver(chain, 503)

    assert {:ok, %HttpResponse{status: 503}} = HttpClient.post_json(url, %{})
  end

  test "a certificate no trusted CA signed is refused: verification is on by default" do
    # Nothing is trusted here: the receiver's CA was never loaded.
    url = start_receiver(chain("localhost"))

    assert {:error, {:failed_connect, details}} = HttpClient.post_json(url, %{"a" => 1})
    assert inspect(details) =~ "unknown_ca"

    assert_receive {:handshake_failed, _}
    refute_received {:request, _}
  end

  test "a certificate valid for another host name is refused even when its CA is trusted",
       %{ca_file: ca_file} do
    chain = chain("not-localhost.example")
    trust(chain, ca_file)
    url = start_receiver(chain)

    assert {:error, {:failed_connect, _details}} = HttpClient.post_json(url, %{"a" => 1})

    assert_receive {:handshake_failed, _}
    refute_received {:request, _}
  end

  # -- the provider over the same connection -------------------------------------------------

  describe "the webhook provider with the default client over TLS" do
    setup %{ca_file: ca_file} do
      chain = chain("localhost")
      trust(chain, ca_file)

      {:ok, notification} =
        Notification.normalize(%{
          notification_id: "webhook:tls-1",
          provider: :webhook,
          recipient: "default",
          event_class: :failure,
          severity: :critical,
          subject: "Run failed",
          body: "run_id: run-1",
          correlation_id: "tls-1",
          run_id: "run-1"
        })

      {:ok, chain: chain, notification: notification}
    end

    # `allow_private_hosts`: the receiver is on loopback, which the URL rules refuse otherwise.
    test "a signed delivery arrives intact, and its signature verifies over the bytes sent",
         %{chain: chain, notification: notification} do
      url = start_receiver(chain)

      assert {:ok, %{status: :succeeded, provider: :webhook}} =
               Webhook.send(notification, %{
                 url: url,
                 secret: "tls-secret",
                 allow_private_hosts: true
               })

      assert_receive {:request, %{headers: headers, body: body}}
      assert headers["x-foreman-delivery"] == "webhook:tls-1"
      assert %{"subject" => "Run failed", "run_id" => "run-1"} = Jason.decode!(body)

      expected =
        :crypto.mac(:hmac, :sha256, "tls-secret", body) |> Base.encode16(case: :lower)

      assert headers["x-foreman-signature"] == "sha256=" <> expected
    end

    test "a 503 from the receiver is a retryable failure", %{
      chain: chain,
      notification: notification
    } do
      url = start_receiver(chain, 503)

      assert {:error, %{retryable?: true, reason: "webhook_http_503"}} =
               Webhook.send(notification, %{url: url, allow_private_hosts: true})
    end

    test "the same loopback URL is refused without the opt-in, and nothing reaches the receiver",
         %{chain: chain, notification: notification} do
      url = start_receiver(chain)

      assert {:error, %{retryable?: false, reason: reason}} =
               Webhook.send(notification, %{url: url})

      assert reason =~ "private_host"
      refute_receive {:request, _}, 200
    end
  end
end
