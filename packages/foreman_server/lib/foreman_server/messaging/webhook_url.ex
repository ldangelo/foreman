defmodule ForemanServer.Messaging.WebhookUrl do
  @moduledoc """
  Safety rules for the generic webhook provider's destination URL (E10-S4,
  foreman-ireii).

  A notification carries run text to whatever URL the operator configured, so
  the URL is checked, never trusted:

    * the scheme is `https`; plain `http` only with `allow_insecure_http: true`;
    * there is no userinfo (`https://user:pass@host`): credentials belong in the
      provider's `secret`, not in a URL that is logged and copied;
    * the host is not a private one: loopback, link-local (the cloud metadata
      address 169.254.169.254 lives there), RFC 1918, unique-local IPv6,
      carrier-grade NAT, unspecified, multicast and reserved addresses, and
      `localhost`. `allow_private_hosts: true` is the operator's opt-in for a
      receiver on their own network.

  `check/2` is the syntax-and-literal check `ConfigResolver` runs whenever it
  resolves the config: it never touches the network, so it is cheap on that hot
  path. It judges the host as written, which includes the numeric spellings
  (`127.1`, `2130706433`, `0x7f.0.0.1`) that `:inet` itself reads as addresses.
  `check_resolved/3` additionally resolves a host NAME and refuses one with any
  private address: the webhook provider runs it right before each send, because
  DNS can change after the config was accepted and because a `{:system, env}`
  URL is only known then.

  Reasons never carry the URL (it may hold a token in its path): `:not_http_url`
  (not an http(s) URL with a host), `:userinfo`, `:insecure_http`,
  `:private_host`, and `:unresolvable_host` (the lookup failed, which is a
  condition to retry, not a verdict on the URL).

  Limit, stated plainly: the address check and the HTTP client each resolve the
  name, so a resolver that answers differently the second time (DNS rebinding)
  is not defended against. The URL is operator-configured, so this is hardening
  of a deliberate setting, not an injection boundary.
  """

  import Bitwise, only: [bsr: 2, band: 2]

  @type reason :: :not_http_url | :userinfo | :insecure_http | :private_host
  @type option :: {:allow_insecure_http, boolean()} | {:allow_private_hosts, boolean()}

  @resolve_timeout_ms 2_000

  @doc """
  The no-network check: scheme, userinfo, host present, and, for a host written
  as an address or as `localhost`, whether it is private.
  """
  @spec check(String.t(), [option()]) :: :ok | {:error, reason()}
  def check(url, opts) when is_binary(url) and is_list(opts) do
    with {:ok, _host} <- parse(url, opts), do: :ok
  end

  @doc """
  `check/2`, then, for a host NAME, a lookup through `resolver` (a module with
  `resolve/1`, `resolve/1` of this module by default): every address it returns
  must be public.
  """
  @spec check_resolved(String.t(), [option()], module()) ::
          :ok | {:error, reason() | :unresolvable_host}
  def check_resolved(url, opts, resolver \\ __MODULE__)
      when is_binary(url) and is_list(opts) and is_atom(resolver) do
    with {:ok, host} <- parse(url, opts) do
      public_resolution(host, opts, resolver)
    end
  end

  @doc "Every address `host` has (IPv4 and IPv6), or the first lookup error."
  @spec resolve(String.t()) :: {:ok, [:inet.ip_address(), ...]} | {:error, term()}
  def resolve(host) when is_binary(host) do
    name = String.to_charlist(host)
    lookups = for family <- [:inet, :inet6], do: :inet.getaddrs(name, family, @resolve_timeout_ms)

    case for({:ok, addresses} <- lookups, address <- addresses, do: address) do
      [] -> {:error, Enum.find_value(lookups, :nxdomain, &lookup_error/1)}
      addresses -> {:ok, addresses}
    end
  end

  defp lookup_error({:error, reason}), do: reason
  defp lookup_error({:ok, _addresses}), do: nil

  @doc "Is this address one a webhook must not reach by default?"
  @spec private_address?(:inet.ip_address()) :: boolean()
  def private_address?({a, b, _c, _d}) do
    a in [0, 10, 127] or a >= 224 or
      (a == 100 and b in 64..127) or
      (a == 169 and b == 254) or
      (a == 172 and b in 16..31) or
      (a == 192 and b == 168)
  end

  # An IPv4-mapped address is judged as the IPv4 address it wraps.
  def private_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: private_address?({bsr(high, 8), band(high, 0xFF), bsr(low, 8), band(low, 0xFF)})

  def private_address?({0, 0, 0, 0, 0, 0, 0, last}) when last in [0, 1], do: true
  def private_address?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: true
  def private_address?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  def private_address?({first, _, _, _, _, _, _, _}) when first >= 0xFF00, do: true
  def private_address?({_, _, _, _, _, _, _, _}), do: false

  # -- parsing ----------------------------------------------------------------

  # Userinfo is refused first so no later reason, and no error built from the
  # URL, can carry the credentials. `authority` is checked for the `@` because
  # `URI` reports an empty userinfo (`https://@host`) as none.
  defp parse(url, opts) do
    uri = URI.parse(url)

    with :ok <- no_userinfo(uri),
         {:ok, host} <- http_host(uri),
         :ok <- secure_scheme(uri, opts),
         :ok <- public_literal(host, opts) do
      {:ok, host}
    end
  end

  defp no_userinfo(%URI{userinfo: nil, authority: authority}) do
    if is_binary(authority) and String.contains?(authority, "@"),
      do: {:error, :userinfo},
      else: :ok
  end

  defp no_userinfo(%URI{}), do: {:error, :userinfo}

  defp http_host(%URI{scheme: scheme, host: host})
       when scheme in ["http", "https"] and is_binary(host) and host != "" do
    {:ok, host |> String.downcase() |> String.trim_trailing(".")}
  end

  defp http_host(%URI{}), do: {:error, :not_http_url}

  defp secure_scheme(%URI{scheme: "https"}, _opts), do: :ok

  defp secure_scheme(%URI{scheme: "http"}, opts),
    do: if(flag?(opts, :allow_insecure_http), do: :ok, else: {:error, :insecure_http})

  defp public_literal(host, opts) do
    cond do
      flag?(opts, :allow_private_hosts) -> :ok
      localhost?(host) -> {:error, :private_host}
      true -> literal_verdict(address(host))
    end
  end

  defp literal_verdict(:none), do: :ok

  defp literal_verdict({:ok, address}),
    do: if(private_address?(address), do: {:error, :private_host}, else: :ok)

  defp public_resolution(host, opts, resolver) do
    cond do
      flag?(opts, :allow_private_hosts) -> :ok
      address(host) != :none -> :ok
      true -> resolved_verdict(resolver.resolve(host))
    end
  end

  defp resolved_verdict({:ok, addresses}),
    do: if(Enum.any?(addresses, &private_address?/1), do: {:error, :private_host}, else: :ok)

  defp resolved_verdict({:error, _reason}), do: {:error, :unresolvable_host}

  defp localhost?(host), do: host == "localhost" or String.ends_with?(host, ".localhost")

  # `:inet` reads what the HTTP client will connect to: it accepts the numeric
  # spellings, so judging the address it parses (not the text) is what holds.
  defp address(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, address}
      {:error, :einval} -> :none
    end
  end

  defp flag?(opts, key), do: Keyword.get(opts, key, false) == true
end
