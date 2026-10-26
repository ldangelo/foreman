defmodule ForemanServer.Messaging.WebhookUrlTest do
  # foreman-ireii (E10-S4): "Unsafe URLs (http, private host, userinfo) are rejected at config
  # and send time unless explicitly allowed." Pure: the resolver is a parameter.
  use ExUnit.Case, async: true

  alias ForemanServer.Messaging.WebhookUrl
  alias ForemanServer.TestSupport.StaticHostResolver

  defmodule NeverResolves do
    @moduledoc false
    def resolve(host), do: raise("resolved #{host}, which no verdict needed")
  end

  defp check(url, opts \\ []), do: WebhookUrl.check(url, opts)

  describe "check/2: what a webhook URL must be" do
    test "an https URL with a public host is fine, whatever its port, path, query or case" do
      for url <- [
            "https://example.com/hook",
            "https://hooks.example.com:8443/a/b?token=1&x=2",
            "HTTPS://Example.COM/Hook",
            "https://8.8.8.8/hook",
            "https://[2606:4700:4700::1111]/hook"
          ] do
        assert check(url) == :ok, url
      end
    end

    test "anything that is not an http(s) URL with a host is :not_http_url" do
      for url <- [
            "",
            "ftp://example.com/x",
            "example.com/hook",
            "https://",
            "https:///hook",
            "javascript:alert(1)",
            "mailto:a@example.com",
            "//example.com/hook"
          ] do
        assert check(url) == {:error, :not_http_url}, inspect(url)
      end
    end

    test "userinfo is refused first, even on a scheme or host that is wrong anyway" do
      for url <- [
            "https://user:pass@example.com/hook",
            "https://token@example.com/hook",
            "https://@example.com/hook",
            "ftp://user:pass@example.com/",
            "https://user:pass@127.0.0.1/hook"
          ] do
        assert check(url) == {:error, :userinfo}, url
      end
    end

    test "plain http needs allow_insecure_http, and only that" do
      assert check("http://example.com/hook") == {:error, :insecure_http}

      assert check("http://example.com/hook", allow_insecure_http: false) ==
               {:error, :insecure_http}

      assert check("http://example.com/hook", allow_insecure_http: true) == :ok

      # The opt-in for http does not open the private-host door, nor the other way round.
      assert check("http://127.0.0.1/hook", allow_insecure_http: true) == {:error, :private_host}

      assert check("http://example.com/hook", allow_private_hosts: true) ==
               {:error, :insecure_http}
    end

    test "a refusal is an atom: no reason carries the URL, so none can carry its token" do
      for url <- [
            "https://user:SECRETTOKEN@example.com/x",
            "http://example.com/SECRETTOKEN",
            "https://127.0.0.1/SECRETTOKEN",
            "ftp://example.com/SECRETTOKEN"
          ] do
        assert {:error, reason} = check(url)
        assert is_atom(reason)
        refute inspect(reason) =~ "SECRETTOKEN"
      end
    end
  end

  describe "check/2: a private host is refused unless allowed" do
    @private [
      # IPv4 loopback, link-local (cloud metadata), RFC 1918, CGNAT, "this network", reserved
      "https://127.0.0.1/",
      "https://127.255.255.254/",
      "https://169.254.169.254/latest/meta-data",
      "https://10.0.0.1/",
      "https://10.255.255.255/",
      "https://172.16.0.1/",
      "https://172.31.255.255/",
      "https://192.168.0.1/",
      "https://192.168.255.255/",
      "https://100.64.0.1/",
      "https://100.127.255.255/",
      "https://0.0.0.0/",
      "https://0.1.2.3/",
      "https://224.0.0.1/",
      "https://239.255.255.255/",
      "https://240.0.0.1/",
      "https://255.255.255.255/",
      # IPv6 loopback, unspecified, link-local, unique-local, multicast, IPv4-mapped
      "https://[::1]/",
      "https://[::]/",
      "https://[fe80::1]/",
      "https://[febf::1]/",
      "https://[fc00::1]/",
      "https://[fd12:3456::1]/",
      "https://[ff02::1]/",
      "https://[::ffff:127.0.0.1]/",
      "https://[::ffff:10.0.0.1]/",
      "https://[::ffff:a9fe:a9fe]/",
      # localhost by name, with the case and trailing-dot spellings
      "https://localhost/",
      "https://LOCALHOST/",
      "https://localhost./",
      "https://api.localhost/",
      # the numeric spellings `:inet` reads as 127.0.0.1
      "https://127.1/",
      "https://2130706433/",
      "https://0x7f.0.0.1/",
      "https://0177.0.0.1/"
    ]

    @public [
      "https://172.15.255.255/",
      "https://172.32.0.1/",
      "https://100.63.255.255/",
      "https://100.128.0.1/",
      "https://169.253.255.255/",
      "https://169.255.0.1/",
      "https://192.167.255.255/",
      "https://192.169.0.1/",
      "https://11.0.0.1/",
      "https://223.255.255.255/",
      "https://8.8.8.8/",
      "https://[2001:db8::1]/",
      "https://[::ffff:8.8.8.8]/",
      "https://[2606:4700:4700::1111]/",
      "https://notlocalhost.example/",
      "https://localhost.example.com/"
    ]

    test "every private spelling is :private_host" do
      for url <- @private do
        assert check(url) == {:error, :private_host}, url
      end
    end

    test "the addresses and names just outside those ranges are public" do
      for url <- @public do
        assert check(url) == :ok, url
      end
    end

    test "allow_private_hosts lets every one of them through" do
      for url <- @private do
        assert check(url, allow_private_hosts: true) == :ok, url
      end
    end

    test "the loopback http sink of a local run needs both opt-ins" do
      assert check("http://127.0.0.1:47662/hook") == {:error, :insecure_http}

      assert check("http://127.0.0.1:47662/hook",
               allow_insecure_http: true,
               allow_private_hosts: true
             ) ==
               :ok
    end
  end

  describe "check_resolved/3: a host name is judged by what it resolves to" do
    defp check_resolved(url, opts \\ []),
      do: WebhookUrl.check_resolved(url, opts, StaticHostResolver)

    test "a name that resolves to a public address is fine" do
      assert check_resolved("https://hooks.example.test/x") == :ok
    end

    test "a name that resolves to a private address is :private_host, whatever its text says" do
      for host <- ["internal.test", "metadata.test", "loopback6.test"] do
        assert check_resolved("https://#{host}/x") == {:error, :private_host}, host
      end
    end

    test "one private address among public ones is enough to refuse" do
      assert check_resolved("https://mixed.test/x") == {:error, :private_host}
    end

    test "allow_private_hosts lets a privately resolving name through, without resolving it" do
      assert check_resolved("https://internal.test/x", allow_private_hosts: true) == :ok

      assert WebhookUrl.check_resolved(
               "https://anything.test/x",
               [allow_private_hosts: true],
               NeverResolves
             ) ==
               :ok
    end

    test "a lookup that fails is :unresolvable_host, which is not a verdict on the URL" do
      assert check_resolved("https://down.test/x") == {:error, :unresolvable_host}
    end

    test "the syntax rules still come first, and an address needs no lookup" do
      for {url, expected} <- [
            {"http://anything.test/x", {:error, :insecure_http}},
            {"https://user:pw@anything.test/x", {:error, :userinfo}},
            {"ftp://anything.test/x", {:error, :not_http_url}},
            {"https://127.0.0.1/x", {:error, :private_host}},
            {"https://8.8.8.8/x", :ok},
            {"https://[2606:4700:4700::1111]/x", :ok}
          ] do
        assert WebhookUrl.check_resolved(url, [], NeverResolves) == expected, url
      end
    end
  end

  describe "resolve/1 and private_address?/1" do
    test "resolve/1 returns the addresses the host really has" do
      # `localhost` is in the hosts file of every machine: both of its addresses are loopback.
      assert {:ok, addresses} = WebhookUrl.resolve("localhost")
      assert Enum.all?(addresses, &WebhookUrl.private_address?/1)
    end

    test "resolve/1 reports the lookup error for a name that cannot be looked up" do
      assert {:error, :einval} = WebhookUrl.resolve("bad host name")
    end

    test "an IPv4-mapped IPv6 address is judged as the IPv4 address it wraps" do
      assert WebhookUrl.private_address?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1})
      assert WebhookUrl.private_address?({0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101})
      refute WebhookUrl.private_address?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
    end
  end
end
