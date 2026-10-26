defmodule ForemanServer.Jobsite.DockerNetworkArgvTest do
  # A project's `environment.network` policy reaches the `docker run` of the jobsite's sandbox
  # container. `network_policy_test.exs` pins the config `NetworkPolicy.apply/4` returns; this
  # pins the argv the Docker sandbox hands to the `docker` binary when a real jobsite
  # (`Jobsite.run/1`, project aggregate, recording provider instead of the agent CLI) is
  # provisioned, and what a sandbox hook sees: a stand-in `docker` (support/fake_docker.sh)
  # records every invocation and keeps the networks, containers and container environments a
  # daemon would, no daemon is needed.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.CommandRouter
  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, NetworkPolicy, Sandboxes}
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  @image "foreman-jobsite:argv-test"
  @fake_agent Path.join(__DIR__, "support/fake_agent.sh")
  @fake_docker Path.join(__DIR__, "support/fake_docker.sh")

  defmodule Recorder do
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "docker argv recorder",
        executable: "stub",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [:system_prompt, :model, :provider_session_id],
        provider_options: [:cli_path]
      }
    end

    @impl true
    def status(_config) do
      {:ok,
       %ProviderStatus{
         provider: :pi,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         capabilities: %Capabilities{streaming?: true, resume?: true},
         executable: "stub"
       }}
    end

    @impl true
    def run(_request, _context) do
      {:ok,
       [
         Event.new!(provider: :pi, type: :output_text_final, payload: %{"text" => "worked"}),
         Event.new!(provider: :pi, type: :run_completed, payload: %{})
       ]}
    end
  end

  # The stand-in `docker` records every invocation in `argv.log` beside itself (one argument per
  # line after an `--invocation--` line; a newline inside an argument is shown as `~`).
  setup %{tmp_dir: dir} do
    ProjectionStoreReset.reset!()
    providers = Application.get_env(:jido_harness, :providers, %{})
    Application.put_env(:jido_harness, :providers, %{pi: Recorder})

    on_exit(fn ->
      Application.put_env(:jido_harness, :providers, providers)
      ProjectionStoreReset.reset!()
    end)

    bin = Path.join(dir, "docker")
    File.cp!(@fake_docker, bin)
    File.chmod!(bin, 0o755)

    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["-C", repo, "init", "-q"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "init"])

    project_id = "docker-net-#{Elixir.EventStore.UUID.uuid4()}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: project_id, path: repo, config: %{}},
        aggregate_id: "project:#{project_id}"
      })

    {:ok, bin: bin, dir: dir, repo: repo, project_id: project_id}
  end

  defp set_network(ctx, network) do
    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.environment.set",
        payload: %{project_id: ctx.project_id, network: network},
        aggregate_id: "project:#{ctx.project_id}"
      })
  end

  defp run_jobsite(ctx, extra \\ []) do
    assert {:ok, %{jobsite_id: id}} =
             Jobsite.run(
               [
                 repo_path: ctx.repo,
                 strategy: :merge_to_head,
                 sandbox: Sandboxes.docker(binary: ctx.bin, image: @image),
                 agent: Agents.pi("x", binary: @fake_agent),
                 prompt: "go",
                 project_id: ctx.project_id
               ] ++ extra
             )

    id
  end

  # Every docker invocation, in order, as its argv.
  defp invocations(dir) do
    dir
    |> Path.join("argv.log")
    |> File.read!()
    |> String.split("--invocation--\n", trim: true)
    |> Enum.map(&String.split(&1, "\n", trim: true))
  end

  # The argv of the sandbox container's `docker run` (the one that runs the jobsite's image),
  # as opposed to the egress proxy sidecar's.
  defp sandbox_run(invocations) do
    assert [argv] =
             Enum.filter(invocations, &(Enum.take(&1, 2) == ["run", "-d"] and @image in &1))

    argv
  end

  # The values of every `-e KEY=VALUE` pair of a `docker run`.
  defp env_pairs(argv), do: for(["-e", pair] <- Enum.chunk_every(argv, 2, 1, :discard), do: pair)

  test "a project policy of none puts --network none before the image in the sandbox's docker run",
       ctx do
    set_network(ctx, %{mode: "none"})
    run_jobsite(ctx)

    calls = invocations(ctx.dir)

    # Docker options only count before the image: the flag is the pair right ahead of it.
    assert Enum.take(sandbox_run(calls), -5) == ["--network", "none", @image, "sleep", "infinity"]
    assert Enum.count(sandbox_run(calls), &(&1 == "--network")) == 1

    # `none` needs no network or sidecar, so docker only inspects the image, runs it and removes it.
    assert Enum.map(calls, &Enum.take(&1, 2)) == [
             ["image", "inspect"],
             ["run", "-d"],
             ["rm", "-f"]
           ]
  end

  test "the default policy leaves --network out of the sandbox's docker run", ctx do
    id = run_jobsite(ctx)
    assert Jobsite.get(id).status == "completed"

    calls = invocations(ctx.dir)
    argv = sandbox_run(calls)

    refute "--network" in argv
    assert Enum.take(argv, -3) == [@image, "sleep", "infinity"]

    assert Enum.map(calls, &Enum.take(&1, 2)) == [
             ["image", "inspect"],
             ["run", "-d"],
             ["rm", "-f"]
           ]

    # An explicit `default` mode is the same thing.
    File.rm!(Path.join(ctx.dir, "argv.log"))
    set_network(ctx, %{mode: "default"})
    run_jobsite(ctx)

    refute "--network" in sandbox_run(invocations(ctx.dir))
  end

  test "an allowlist policy runs the sandbox on the jobsite's own network, created beforehand and removed after",
       ctx do
    set_network(ctx, %{mode: "allowlist", hosts: ["pypi.org"]})
    id = run_jobsite(ctx)

    network = "foreman-jobsite-" <> id
    proxy = "foreman-jobsite-proxy-" <> id
    owner = NetworkPolicy.owner()
    calls = invocations(ctx.dir)

    assert Enum.take(sandbox_run(calls), -5) == [
             "--network",
             network,
             @image,
             "sleep",
             "infinity"
           ]

    assert Enum.count(sandbox_run(calls), &(&1 == "--network")) == 1

    # The sandbox container is labelled like the network and the sidecar, so a crash can be swept.
    argv = sandbox_run(calls)
    assert ["--label", "foreman.jobsite=" <> id] in Enum.chunk_every(argv, 2, 1, :discard)
    assert ["--label", "foreman.owner=" <> owner] in Enum.chunk_every(argv, 2, 1, :discard)

    # The internal network and the proxy sidecar (attached to it) exist before the sandbox starts
    # and are gone once the jobsite ends: the jobsite's containers (the sidecar) first, then the
    # network.
    assert [
             ["image", "inspect", "foreman-egress-proxy:1"],
             [
               "network",
               "create",
               "--internal",
               "--label",
               "foreman.jobsite=" <> ^id,
               "--label",
               "foreman.owner=" <> ^owner,
               ^network
             ],
             ["run", "-d", "--rm", "--name", ^proxy, "--network", ^network | _proxy_rest],
             ["network", "connect", "bridge", ^proxy],
             ["image", "inspect", @image],
             _sandbox_run,
             ["rm", "-f", "fake-container-" <> _],
             ["ps", "-aq", "--filter", "label=foreman.jobsite=" <> ^id],
             ["rm", "-f", "fake-container-" <> _],
             ["network", "rm", ^network]
           ] = calls

    assert File.ls!(Path.join(ctx.dir, "fake/net")) == []
    assert File.ls!(Path.join(ctx.dir, "fake/ctr")) == []
  end

  test "the sandbox container's own environment carries the proxy variables of an allowlist policy",
       ctx do
    set_network(ctx, %{mode: "allowlist", hosts: ["pypi.org"]})
    id = run_jobsite(ctx)

    proxy_url = "http://foreman-jobsite-proxy-#{id}:3128"
    pairs = env_pairs(sandbox_run(invocations(ctx.dir)))

    for key <- ~w(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy) do
      assert "#{key}=#{proxy_url}" in pairs
    end

    assert "NO_PROXY=localhost,127.0.0.1" in pairs
    assert "no_proxy=localhost,127.0.0.1" in pairs
  end

  # The command of a sandbox hook that only succeeds under the policy's proxy variables (one line:
  # the stand-in docker's log shows a newline inside an argument as `~`).
  @proxy_hook ~S|test -n "$HTTP_PROXY" && test "$HTTPS_PROXY" = "$HTTP_PROXY" && test "$http_proxy" = "$HTTP_PROXY" && test "$https_proxy" = "$HTTP_PROXY" && test "$NO_PROXY" = "localhost,127.0.0.1" && case "$HTTP_PROXY" in http://foreman-jobsite-proxy-js-*:3128) true ;; *) false ;; esac|

  test "a sandbox hook under an allowlist policy runs with the policy's proxy variables", ctx do
    set_network(ctx, %{mode: "allowlist", hosts: ["pypi.org"]})

    # A hook is fatal when it exits non-zero (`:hook_failed`): this one needs the proxy variables.
    id =
      run_jobsite(ctx,
        hooks: %{sandbox: %{on_sandbox_ready: [%{command: @proxy_hook}]}}
      )

    assert Jobsite.get(id).status == "completed"

    assert [["exec", "-w", "/workspace", "fake-container-" <> _, "sh", "-c", @proxy_hook]] =
             Enum.filter(invocations(ctx.dir), &(hd(&1) == "exec"))
  end

  test "a sandbox hook of a jobsite without a network policy sees no proxy variables", ctx do
    hook = ~S|test -z "${HTTP_PROXY-}" && test -z "${http_proxy-}" && test -z "${NO_PROXY-}"|

    id = run_jobsite(ctx, hooks: %{sandbox: %{on_sandbox_ready: [%{command: hook}]}})

    assert Jobsite.get(id).status == "completed"
    refute Enum.any?(env_pairs(sandbox_run(invocations(ctx.dir))), &String.contains?(&1, "PROXY"))
  end
end
