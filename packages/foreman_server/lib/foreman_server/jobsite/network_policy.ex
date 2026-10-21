defmodule ForemanServer.Jobsite.NetworkPolicy do
  @moduledoc """
  Applies a project's `environment.network` policy to a jobsite's DOCKER sandbox
  (E4-S5, mechanism from spike E4-SP2: GO for `none` and `allowlist`).

  Modes (`ForemanServer.Aggregates.Project.Environment`):

    * `default` / absent: nothing changes; the sandbox config is returned
      untouched (regression-pinned).
    * `none`: `network: "none"` on the sandbox config, i.e. `docker run --network none`.
      The agent cannot reach its provider API, so this only suits offline tasks.
    * `allowlist`: a per-jobsite `--internal` docker network `foreman-jobsite-<id>`
      plus an egress proxy sidecar `foreman-jobsite-proxy-<id>` (tinyproxy, built
      locally from an embedded Dockerfile as `foreman-egress-proxy:1`; no registry
      pull) attached to that network and to `bridge`. The sandbox runs on the
      internal network only, with `HTTP(S)_PROXY` pointing at the sidecar, so a
      denied host answers `403` to CONNECT and a proxy-bypassing tool has no
      route at all. The project's hosts plus the always-allowed provider hosts
      (`always_allowed_hosts/0`) are permitted.

  The policy is a CEILING: a caller-supplied sandbox `network` that is not the
  policy's own network fails with `:network_policy_violation`, and a non-default
  policy on a non-docker sandbox (the host sandbox) fails with
  `:network_policy_unsupported`, because a policy that silently does nothing is
  worse than an error. The workflow door runs agents on the server host and cannot
  enforce network policy; `network_enforced_on/0` says where enforcement exists.

  `apply/4` returns a cleanup fun that removes sidecar and network; callers MUST
  invoke it when the jobsite ends, however it ends. `sweep_orphans/1` removes
  `foreman-jobsite-*` leftovers after a crash (called from `Jobsite.BootRecovery`).
  Failures to create anything fail CLOSED (`:network_policy_failed`): never run
  unrestricted when a policy was requested.
  """

  alias ForemanServer.Aggregate
  alias ForemanServer.Jobsite.Error

  @image "foreman-egress-proxy:1"
  @proxy_port 3128
  @always_allowed ~w(api.anthropic.com api.openai.com api.minimax.io
                     generativelanguage.googleapis.com openrouter.ai github.com
                     api.github.com registry.npmjs.org)

  @dockerfile """
  FROM alpine:3.20
  RUN apk add --no-cache tinyproxy
  COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
  """

  @tinyproxy_conf """
  Port 3128
  Listen 0.0.0.0
  Timeout 600
  MaxClients 100
  Allow 0.0.0.0/0
  Filter "/etc/tinyproxy/allow"
  FilterDefaultDeny Yes
  FilterExtended Off
  ConnectPort 443
  LogLevel Info
  """

  @type policy :: %{optional(String.t() | atom()) => term()} | nil
  @type cleanup :: (-> :ok)

  @doc "Hosts reachable under every allowlist (the agent providers and package/VCS hosts)."
  @spec always_allowed_hosts() :: [String.t()]
  def always_allowed_hosts, do: @always_allowed

  @doc "Surfaces where `environment.network` is enforced."
  @spec network_enforced_on() :: [:docker_jobsite]
  def network_enforced_on, do: [:docker_jobsite]

  @doc """
  Apply `policy` (the project's `environment.network` map) to the sandbox
  `provider`/`config` of jobsite `jobsite_id`. Returns the config to create the
  sandbox with and a cleanup fun.
  """
  @spec apply(policy(), module(), map() | nil, String.t()) ::
          {:ok, map() | nil, cleanup()} | {:error, Error.t()}
  def apply(policy, provider, config, jobsite_id) when is_binary(jobsite_id) do
    case mode(policy) do
      "default" ->
        {:ok, config, &noop/0}

      mode ->
        with :ok <- require_docker(provider, mode),
             :ok <- check_ceiling(mode, config, jobsite_id) do
          apply_mode(mode, policy, config || %{}, jobsite_id)
        end
    end
  end

  defp apply_mode("none", _policy, config, _id),
    do: {:ok, put(config, :network, "none"), &noop/0}

  defp apply_mode("allowlist", policy, config, id) do
    binary = get(config, :binary, "docker")
    network = network_name(id)
    proxy = proxy_name(id)
    hosts = (@always_allowed ++ hosts(policy)) |> Enum.uniq()
    cleanup = fn -> teardown(binary, network, proxy) end

    with :ok <- ensure_image(binary),
         :ok <- docker(binary, ["network", "create", "--internal", network], "network create"),
         :ok <- start_proxy(binary, network, proxy, hosts),
         :ok <- docker(binary, ["network", "connect", "bridge", proxy], "proxy egress attach") do
      proxy_url = "http://#{proxy}:#{@proxy_port}"

      env =
        config
        |> get(:env, %{})
        |> Map.merge(%{
          "HTTP_PROXY" => proxy_url,
          "HTTPS_PROXY" => proxy_url,
          "http_proxy" => proxy_url,
          "https_proxy" => proxy_url,
          "NO_PROXY" => "localhost,127.0.0.1",
          "no_proxy" => "localhost,127.0.0.1"
        })

      {:ok, config |> put(:network, network) |> put(:env, env), cleanup}
    else
      {:error, %Error{}} = error ->
        cleanup.()
        error
    end
  end

  @doc "Container and network names for a jobsite's allowlist."
  @spec network_name(String.t()) :: String.t()
  def network_name(jobsite_id), do: "foreman-jobsite-" <> jobsite_id

  @spec proxy_name(String.t()) :: String.t()
  def proxy_name(jobsite_id), do: "foreman-jobsite-proxy-" <> jobsite_id

  @doc """
  Removes every `foreman-jobsite-*` proxy container and network. Run at boot:
  at that point no jobsite of this node is running, so all of them are orphans.
  Never raises; a missing docker binary is a quiet no-op.
  """
  @spec sweep_orphans(keyword()) :: :ok
  def sweep_orphans(opts \\ []) do
    binary = Keyword.get(opts, :binary, "docker")

    containers = list(binary, ["ps", "-aq", "--filter", "name=foreman-jobsite-proxy-"])

    networks =
      list(binary, ["network", "ls", "--format", "{{.Name}}", "--filter", "name=foreman-jobsite-"])

    for id <- containers, do: run(binary, ["rm", "-f", id])

    for name <- networks,
        String.starts_with?(name, "foreman-jobsite-"),
        do: run(binary, ["network", "rm", name])

    :ok
  end

  # -- ceiling / support ------------------------------------------------

  defp require_docker(provider, mode) do
    if provider.name() == "docker" do
      :ok
    else
      {:error,
       Error.new(
         :network_policy_unsupported,
         "network policy #{inspect(mode)} is enforced on docker sandboxes only; " <>
           "the #{provider.name()} sandbox cannot honour it",
         %{mode: mode, sandbox: provider.name()}
       )}
    end
  end

  # A caller-supplied network is acceptable only when it IS the policy's
  # network (`none`); an allowlist network is created here, so a caller cannot
  # have named it (a resumed jobsite's own persisted name is tolerated).
  defp check_ceiling(mode, config, jobsite_id) do
    case get(config, :network) do
      nil ->
        :ok

      "none" when mode == "none" ->
        :ok

      name ->
        if name == network_name(jobsite_id) and mode == "allowlist",
          do: :ok,
          else: violation(mode, name)
    end
  end

  defp violation(mode, requested) do
    {:error,
     Error.new(
       :network_policy_violation,
       "sandbox network #{inspect(requested)} is wider than the project's #{inspect(mode)} network policy",
       %{mode: mode, requested: requested}
     )}
  end

  # -- docker plumbing --------------------------------------------------

  defp ensure_image(binary) do
    case run(binary, ["image", "inspect", @image]) do
      {_, 0} -> :ok
      _ -> build_image(binary)
    end
  end

  defp build_image(binary) do
    dir =
      Path.join(System.tmp_dir!(), "foreman-egress-proxy-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Dockerfile"), @dockerfile)
      File.write!(Path.join(dir, "tinyproxy.conf"), @tinyproxy_conf)
      docker(binary, ["build", "-q", "-t", @image, dir], "proxy image build")
    after
      File.rm_rf(dir)
    end
  end

  # The allow-file is written inside the container from `ALLOW`, so no host
  # path is mounted. Hosts were validated by `Environment` (`^[a-z0-9.*-]+$`).
  defp start_proxy(binary, network, proxy, hosts) do
    docker(
      binary,
      [
        "run",
        "-d",
        "--rm",
        "--name",
        proxy,
        "--network",
        network,
        "-e",
        "ALLOW=" <> Enum.map_join(hosts, "\n", &host_regex/1),
        @image,
        "sh",
        "-c",
        ~s(printf '%s\\n' "$ALLOW" > /etc/tinyproxy/allow && exec tinyproxy -d)
      ],
      "proxy start"
    )
  end

  @doc false
  @spec host_regex(String.t()) :: String.t()
  def host_regex(host) do
    body =
      host
      |> String.replace(".", "\\.")
      |> String.replace("*", ".*")

    "^" <> body <> "$"
  end

  defp teardown(binary, network, proxy) do
    run(binary, ["rm", "-f", proxy])
    run(binary, ["network", "rm", network])
    :ok
  end

  defp docker(binary, args, label) do
    case run(binary, args) do
      {_, 0} ->
        :ok

      {output, code} ->
        {:error,
         Error.new(:network_policy_failed, "#{label} failed (exit #{code})", %{
           command: Enum.join([binary | args], " "),
           output: String.trim(output)
         })}
    end
  end

  defp list(binary, args) do
    case run(binary, args) do
      {output, 0} -> output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      _ -> []
    end
  end

  # A missing binary is an exit-127-shaped result, never a raise.
  defp run(binary, args) do
    System.cmd(binary, args, stderr_to_stdout: true)
  rescue
    error in ErlangError -> {Exception.message(error), 127}
  end

  defp mode(nil), do: "default"
  defp mode(policy), do: policy |> get(:mode, "default") |> to_string()

  defp hosts(policy), do: policy |> get(:hosts, []) |> List.wrap()

  defp get(map, key, default \\ nil), do: Aggregate.get(map, key, default)

  # Sandbox configs are atom-keyed on a fresh run and string-keyed after a
  # resume's JSON round-trip; writes use the atom key and drop a string twin.
  defp put(config, key, value),
    do: config |> Map.delete(Atom.to_string(key)) |> Map.put(key, value)

  defp noop, do: :ok
end
