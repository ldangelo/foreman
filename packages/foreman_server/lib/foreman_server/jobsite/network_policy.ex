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

  `apply/4` returns a cleanup fun that removes the jobsite's containers and its
  network; callers MUST invoke it when the jobsite ends, however it ends.
  `sweep_orphans/1` removes the leftovers of a crashed server (called from
  `Jobsite.BootRecovery`). Failures to create anything fail CLOSED
  (`:network_policy_failed`): never run unrestricted when a policy was requested.

  Everything a policy creates or governs carries Foreman's labels: the network,
  the sidecar and the sandbox container (`none` included) are labelled
  `foreman.owner=<owner/0>` and `foreman.jobsite=<id>`. Cleanup and the boot
  sweep find objects by those labels and by nothing else, so a container or
  network that merely has a similar name, or belongs to another Foreman server
  on the same docker host, is never touched. A network cannot be removed while a
  container is attached to it, so the containers (the sidecar AND a sandbox the
  jobsite never got to close) are always removed first.
  """

  alias ForemanServer.Aggregate
  alias ForemanServer.Jobsite.Error

  @image "foreman-egress-proxy:1"
  @proxy_port 3128
  @owner_label "foreman.owner"
  @jobsite_label "foreman.jobsite"
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
  sandbox with (`:network`, the proxy variables in `:env` for an allowlist, and
  the `:labels` of every policy mode) and a cleanup fun.
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

  defp apply_mode("none", _policy, config, id),
    do: {:ok, config |> put(:network, "none") |> put_labels(labels(id)), &noop/0}

  defp apply_mode("allowlist", policy, config, id) do
    binary = get(config, :binary, "docker")
    network = network_name(id)
    proxy = proxy_name(id)
    hosts = (@always_allowed ++ hosts(policy)) |> Enum.uniq()
    labels = labels(id)
    cleanup = fn -> teardown(binary, id, network) end

    with :ok <- ensure_image(binary),
         :ok <-
           docker(
             binary,
             ["network", "create", "--internal"] ++ label_args(labels) ++ [network],
             "network create"
           ),
         :ok <- start_proxy(binary, network, proxy, hosts, labels),
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

      {:ok, config |> put(:network, network) |> put(:env, env) |> put_labels(labels), cleanup}
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
  This server's identity on a docker host that other Foreman servers share: a
  digest of the host, port and database of its event store, which a restarted
  server has in common with its predecessor and another server (another
  database) does not. It is the `foreman.owner` label of everything a policy
  creates.
  """
  @spec owner() :: String.t()
  def owner do
    config = ForemanServer.EventStore.config()

    [:hostname, :port, :database, :socket_dir]
    |> Enum.map_join("|", &to_string(config[&1]))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  @doc """
  Removes everything of this server's (`owner/0`, or the `:owner` option) that
  an earlier run left on the docker host: every labelled container (sidecars,
  sandboxes) first, then every labelled network. Run at boot: at that point no
  jobsite of this server is running, so all of them are orphans; another
  server's objects carry its own `foreman.owner` and are not listed. Never
  raises on docker; a missing docker binary is a quiet no-op.
  """
  @spec sweep_orphans(keyword()) :: :ok
  def sweep_orphans(opts \\ []) do
    binary = Keyword.get(opts, :binary, "docker")
    filter = "label=#{@owner_label}=#{Keyword.get_lazy(opts, :owner, &owner/0)}"

    remove_containers(binary, filter)

    for name <- list(binary, ["network", "ls", "--format", "{{.Name}}", "--filter", filter]),
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
  defp start_proxy(binary, network, proxy, hosts, labels) do
    docker(
      binary,
      [
        "run",
        "-d",
        "--rm",
        "--name",
        proxy,
        "--network",
        network
      ] ++
        label_args(labels) ++
        [
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

  # The jobsite's containers first (the sidecar and, when the jobsite never got to
  # close it, the sandbox): docker refuses to remove a network that has one attached.
  defp teardown(binary, jobsite_id, network) do
    remove_containers(binary, "label=#{@jobsite_label}=#{jobsite_id}")
    run(binary, ["network", "rm", network])
    :ok
  end

  defp remove_containers(binary, filter) do
    for id <- list(binary, ["ps", "-aq", "--filter", filter]), do: run(binary, ["rm", "-f", id])
    :ok
  end

  defp labels(jobsite_id), do: %{@owner_label => owner(), @jobsite_label => jobsite_id}

  defp label_args(labels),
    do: labels |> Enum.sort() |> Enum.flat_map(fn {k, v} -> ["--label", "#{k}=#{v}"] end)

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

  # The sandbox container carries the labels of the network and the sidecar (and
  # whatever labels the caller's own config already has).
  defp put_labels(config, labels),
    do: put(config, :labels, Map.merge(get(config, :labels, %{}), labels))

  defp noop, do: :ok
end
