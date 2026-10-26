defmodule ForemanServer.Jobsite.NetworkPolicyTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite.{Error, NetworkPolicy}
  alias ForemanServer.Jobsite.Sandboxes.{Docker, Host}

  @moduletag :tmp_dir

  @fake_docker Path.join(__DIR__, "support/fake_docker.sh")

  # A stand-in `docker` (support/fake_docker.sh): records every invocation in `calls.log` and keeps
  # the networks and containers a daemon would, including its refusal to remove a network that
  # still has a container attached. A `fail-<arg1>-<arg2>` file makes that subcommand fail.
  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "docker")
    File.cp!(@fake_docker, bin)
    File.chmod!(bin, 0o755)
    %{bin: bin, dir: dir, owner: NetworkPolicy.owner()}
  end

  defp calls(dir) do
    case File.read(Path.join(dir, "calls.log")) do
      {:ok, text} ->
        text |> String.split("\n", trim: true) |> Enum.map(&String.trim_trailing(&1, "~"))

      {:error, :enoent} ->
        []
    end
  end

  # What the stand-in daemon holds now.
  defp networks(dir), do: dir |> Path.join("fake/net") |> names()
  defp containers(dir), do: dir |> Path.join("fake/ctr") |> names()

  defp names(path) do
    case File.ls(path) do
      {:ok, names} -> Enum.sort(names)
      {:error, :enoent} -> []
    end
  end

  # Objects the code under test did not create: another server's, a user's.
  defp put_network(dir, name, labels), do: put_object(dir, "net", name, [], labels)

  defp put_container(dir, id, attached_to, labels),
    do: put_object(dir, "ctr", id, Enum.map(attached_to, &"net=#{&1}"), labels)

  defp put_object(dir, kind, name, extra, labels) do
    path = Path.join([dir, "fake", kind])
    File.mkdir_p!(path)
    lines = ["name=#{name}"] ++ extra ++ Enum.map(labels, &"label=#{&1}")
    File.write!(Path.join(path, name), Enum.join(lines, "\n") <> "\n")
  end

  # The sandbox container `Jobsite` provisions on a policy's config (what `Docker.create/2` runs).
  defp provision_sandbox(ctx, config) do
    config = Map.merge(config, %{image: "img", uid: "1", gid: "1"})
    assert {:ok, _state, _path, id} = Docker.create(config, %{path: ctx.dir, repo_path: ctx.dir})
    id
  end

  test "default and absent policy leave the config untouched and never call docker", ctx do
    config = %{binary: ctx.bin, image: "x"}

    for policy <- [nil, %{"mode" => "default", "hosts" => []}] do
      assert {:ok, ^config, cleanup} = NetworkPolicy.apply(policy, Docker, config, "js-1")
      assert :ok = cleanup.()
    end

    assert calls(ctx.dir) == []
  end

  test "none sets --network none for the docker sandbox and labels it", ctx do
    assert {:ok, %{network: "none", image: "x", labels: labels}, _} =
             NetworkPolicy.apply(
               %{"mode" => "none"},
               Docker,
               %{binary: ctx.bin, image: "x"},
               "js-1"
             )

    assert labels == %{"foreman.owner" => ctx.owner, "foreman.jobsite" => "js-1"}
    assert calls(ctx.dir) == []
  end

  test "the policy is a ceiling: a different sandbox network is a violation", ctx do
    for mode <- ["none", "allowlist"] do
      assert {:error, %Error{code: :network_policy_violation, details: %{requested: "bridge"}}} =
               NetworkPolicy.apply(
                 %{"mode" => mode},
                 Docker,
                 %{binary: ctx.bin, network: "bridge"},
                 "js-1"
               )
    end

    # String-keyed (resumed) config is checked the same way.
    assert {:error, %Error{code: :network_policy_violation}} =
             NetworkPolicy.apply(
               %{"mode" => "none"},
               Docker,
               %{"binary" => ctx.bin, "network" => "host"},
               "js-1"
             )

    assert calls(ctx.dir) == []
  end

  test "a non-default policy on the host sandbox is unsupported", ctx do
    for mode <- ["none", "allowlist"] do
      assert {:error, %Error{code: :network_policy_unsupported}} =
               NetworkPolicy.apply(%{"mode" => mode}, Host, %{}, "js-1")
    end

    assert {:ok, %{}, _} = NetworkPolicy.apply(%{"mode" => "default"}, Host, %{}, "js-1")
    assert calls(ctx.dir) == []
  end

  test "allowlist: labelled network and proxy exist before the sandbox, config carries env and labels, cleanup removes both",
       ctx do
    policy = %{"mode" => "allowlist", "hosts" => ["pypi.org", "*.example.com"]}

    assert {:ok, config, cleanup} =
             NetworkPolicy.apply(
               policy,
               Docker,
               %{binary: ctx.bin, env: %{"KEEP" => "1"}},
               "js-9"
             )

    assert config.network == "foreman-jobsite-js-9"
    assert config.env["KEEP"] == "1"
    assert config.labels == %{"foreman.owner" => ctx.owner, "foreman.jobsite" => "js-9"}

    for key <- ~w(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy) do
      assert config.env[key] == "http://foreman-jobsite-proxy-js-9:3128"
    end

    labels = "--label foreman.jobsite=js-9 --label foreman.owner=#{ctx.owner}"
    [inspect_call, create, run, connect] = calls(ctx.dir)
    assert inspect_call == "image inspect foreman-egress-proxy:1"
    assert create == "network create --internal #{labels} foreman-jobsite-js-9"

    assert run =~
             "run -d --rm --name foreman-jobsite-proxy-js-9 --network foreman-jobsite-js-9 #{labels} -e ALLOW="

    assert run =~ "^pypi\\.org$"
    assert run =~ "^.*\\.example\\.com$"
    assert run =~ "^api\\.anthropic\\.com$"
    assert connect == "network connect bridge foreman-jobsite-proxy-js-9"

    assert networks(ctx.dir) == ["foreman-jobsite-js-9"]
    assert [_sidecar] = containers(ctx.dir)

    assert :ok = cleanup.()

    assert networks(ctx.dir) == []
    assert containers(ctx.dir) == []
  end

  test "allowlist keeps the caller's own labels on the sandbox config", ctx do
    assert {:ok, %{labels: labels}, _} =
             NetworkPolicy.apply(
               %{"mode" => "allowlist"},
               Docker,
               %{binary: ctx.bin, labels: %{"team" => "x"}},
               "js-2"
             )

    assert labels == %{
             "team" => "x",
             "foreman.owner" => ctx.owner,
             "foreman.jobsite" => "js-2"
           }
  end

  test "allowlist builds the proxy image when it is missing", ctx do
    File.write!(Path.join(ctx.dir, "fail-image-inspect"), "")

    assert {:ok, _, _} =
             NetworkPolicy.apply(%{"mode" => "allowlist"}, Docker, %{binary: ctx.bin}, "js-3")

    assert Enum.any?(
             calls(ctx.dir),
             &String.starts_with?(&1, "build -q -t foreman-egress-proxy:1 ")
           )
  end

  test "allowlist fails closed and cleans up when docker refuses", ctx do
    File.write!(Path.join(ctx.dir, "fail-network-connect"), "")

    assert {:error, %Error{code: :network_policy_failed}} =
             NetworkPolicy.apply(%{"mode" => "allowlist"}, Docker, %{binary: ctx.bin}, "js-4")

    assert networks(ctx.dir) == []
    assert containers(ctx.dir) == []
  end

  test "cleanup removes a sandbox the jobsite never closed, then the network", ctx do
    assert {:ok, config, cleanup} =
             NetworkPolicy.apply(%{"mode" => "allowlist"}, Docker, %{binary: ctx.bin}, "js-5")

    # A jobsite whose executor died after provisioning its sandbox: the sandbox is still attached
    # to the policy's network, and docker refuses to remove a network that has a container on it.
    sandbox = provision_sandbox(ctx, config)
    assert sandbox in containers(ctx.dir)

    assert :ok = cleanup.()

    assert networks(ctx.dir) == []
    assert containers(ctx.dir) == []
  end

  test "cleanup leaves the containers of other jobsites alone", ctx do
    {:ok, config5, cleanup5} =
      NetworkPolicy.apply(%{"mode" => "allowlist"}, Docker, %{binary: ctx.bin}, "js-5")

    {:ok, config6, _cleanup6} =
      NetworkPolicy.apply(%{"mode" => "allowlist"}, Docker, %{binary: ctx.bin}, "js-6")

    sandbox5 = provision_sandbox(ctx, config5)
    sandbox6 = provision_sandbox(ctx, config6)

    assert :ok = cleanup5.()

    assert networks(ctx.dir) == ["foreman-jobsite-js-6"]
    assert sandbox6 in containers(ctx.dir)
    refute sandbox5 in containers(ctx.dir)
    assert length(containers(ctx.dir)) == 2
  end

  describe "sweep_orphans/1" do
    test "removes what a crashed server left: the sandbox, the sidecar and the network", ctx do
      # The crash: a jobsite in flight (network, sidecar on it, sandbox on it), nobody to clean up.
      assert {:ok, config, _cleanup} =
               NetworkPolicy.apply(%{"mode" => "allowlist"}, Docker, %{binary: ctx.bin}, "js-1")

      sandbox = provision_sandbox(ctx, config)

      assert networks(ctx.dir) == ["foreman-jobsite-js-1"]
      assert length(containers(ctx.dir)) == 2
      assert sandbox in containers(ctx.dir)

      assert :ok = NetworkPolicy.sweep_orphans(binary: ctx.bin)

      assert networks(ctx.dir) == []
      assert containers(ctx.dir) == []

      # A later resume of that jobsite creates its network again, under the same name.
      assert {:ok, _, _} =
               NetworkPolicy.apply(%{"mode" => "allowlist"}, Docker, %{binary: ctx.bin}, "js-1")
    end

    test "removes the sandbox a crashed `none` jobsite left", ctx do
      assert {:ok, config, _cleanup} =
               NetworkPolicy.apply(%{"mode" => "none"}, Docker, %{binary: ctx.bin}, "js-7")

      sandbox = provision_sandbox(ctx, config)
      assert containers(ctx.dir) == [sandbox]

      assert :ok = NetworkPolicy.sweep_orphans(binary: ctx.bin)

      assert containers(ctx.dir) == []
    end

    test "touches only this server's labelled objects", ctx do
      assert {:ok, config, _cleanup} =
               NetworkPolicy.apply(%{"mode" => "allowlist"}, Docker, %{binary: ctx.bin}, "js-1")

      ours = provision_sandbox(ctx, config)

      # A user's network and container that merely have the name (and, for the container, the
      # network) of a Foreman jobsite; another Foreman server's jobsite on the same docker host;
      # something labelled, but not by Foreman.
      put_network(ctx.dir, "foreman-jobsite-js-user", [])
      put_container(ctx.dir, "user-container", ["foreman-jobsite-js-user"], [])
      put_network(ctx.dir, "foreman-jobsite-js-other", ["foreman.owner=another-server"])

      put_container(ctx.dir, "other-sandbox", ["foreman-jobsite-js-other"], [
        "foreman.owner=another-server",
        "foreman.jobsite=js-other"
      ])

      put_network(ctx.dir, "labelled-by-someone-else", ["app=1"])

      assert :ok = NetworkPolicy.sweep_orphans(binary: ctx.bin)

      assert networks(ctx.dir) ==
               ["foreman-jobsite-js-other", "foreman-jobsite-js-user", "labelled-by-someone-else"]

      assert containers(ctx.dir) == ["other-sandbox", "user-container"]
      refute ours in containers(ctx.dir)

      # The same sweep for the other server's owner removes only what it created.
      assert :ok = NetworkPolicy.sweep_orphans(binary: ctx.bin, owner: "another-server")

      assert networks(ctx.dir) == ["foreman-jobsite-js-user", "labelled-by-someone-else"]
      assert containers(ctx.dir) == ["user-container"]
    end

    test "lists by label, never by name", ctx do
      assert :ok = NetworkPolicy.sweep_orphans(binary: ctx.bin)

      filter = "label=foreman.owner=#{ctx.owner}"

      assert calls(ctx.dir) == [
               "ps -aq --filter #{filter}",
               "network ls --format {{.Name}} --filter #{filter}"
             ]
    end

    test "with no docker binary is a quiet no-op" do
      assert :ok = NetworkPolicy.sweep_orphans(binary: "/nonexistent/docker-binary")
    end
  end

  test "the owner is stable for an event store and differs between event stores" do
    store = Application.fetch_env!(:foreman_server, ForemanServer.EventStore)
    owner = NetworkPolicy.owner()

    assert owner =~ ~r/\A[0-9a-f]{12}\z/
    assert NetworkPolicy.owner() == owner

    on_exit(fn -> Application.put_env(:foreman_server, ForemanServer.EventStore, store) end)

    put_url = fn url ->
      Application.put_env(
        :foreman_server,
        ForemanServer.EventStore,
        Keyword.put(store, :url, url)
      )
    end

    put_url.("postgres://u:p@db.example:5432/foreman_a")
    owner_a = NetworkPolicy.owner()
    refute owner_a == owner

    # Another database on the same host is another server; other credentials are not.
    put_url.("postgres://u:p@db.example:5432/foreman_b")
    refute NetworkPolicy.owner() == owner_a

    put_url.("postgres://someone:else@db.example:5432/foreman_a")
    assert NetworkPolicy.owner() == owner_a
  end

  test "host patterns escape dots and expand wildcards" do
    assert NetworkPolicy.host_regex("a.b-c.example") == "^a\\.b-c\\.example$"
    assert NetworkPolicy.host_regex("*.example.com") == "^.*\\.example\\.com$"
  end
end
