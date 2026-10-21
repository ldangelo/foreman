defmodule ForemanServer.Jobsite.NetworkPolicyTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite.{Error, NetworkPolicy}
  alias ForemanServer.Jobsite.Sandboxes.{Docker, Host}

  @moduletag :tmp_dir

  # A stand-in `docker` binary: records every invocation, prints canned lists
  # for the sweep, and fails a subcommand when a `fail-<arg1>-<arg2>` file exists.
  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "docker")

    File.write!(bin, """
    #!/bin/sh
    d=$(dirname "$0")
    echo "$*" | tr '\n' '~' >> "$d/calls.log"
    echo >> "$d/calls.log"
    case "$1 $2" in
      "ps -aq") echo c1; echo c2 ;;
      "network ls") echo foreman-jobsite-old; echo bridge ;;
    esac
    [ -f "$d/fail-$1-$2" ] && exit 1
    exit 0
    """)

    File.chmod!(bin, 0o755)
    %{bin: bin, dir: dir}
  end

  defp calls(dir) do
    case File.read(Path.join(dir, "calls.log")) do
      {:ok, text} ->
        text |> String.split("\n", trim: true) |> Enum.map(&String.trim_trailing(&1, "~"))

      {:error, :enoent} ->
        []
    end
  end

  test "default and absent policy leave the config untouched and never call docker", ctx do
    config = %{binary: ctx.bin, image: "x"}

    for policy <- [nil, %{"mode" => "default", "hosts" => []}] do
      assert {:ok, ^config, cleanup} = NetworkPolicy.apply(policy, Docker, config, "js-1")
      assert :ok = cleanup.()
    end

    assert calls(ctx.dir) == []
  end

  test "none sets --network none for the docker sandbox", ctx do
    assert {:ok, %{network: "none", image: "x"}, _} =
             NetworkPolicy.apply(
               %{"mode" => "none"},
               Docker,
               %{binary: ctx.bin, image: "x"},
               "js-1"
             )

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

  test "allowlist: network and proxy exist before the sandbox, env points at the proxy, cleanup removes both",
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

    for key <- ~w(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy) do
      assert config.env[key] == "http://foreman-jobsite-proxy-js-9:3128"
    end

    [inspect_call, create, run, connect] = calls(ctx.dir)
    assert inspect_call == "image inspect foreman-egress-proxy:1"
    assert create == "network create --internal foreman-jobsite-js-9"
    assert run =~ "run -d --rm --name foreman-jobsite-proxy-js-9 --network foreman-jobsite-js-9"
    assert run =~ "^pypi\\.org$"
    assert run =~ "^.*\\.example\\.com$"
    assert run =~ "^api\\.anthropic\\.com$"
    assert connect == "network connect bridge foreman-jobsite-proxy-js-9"

    assert :ok = cleanup.()

    assert Enum.take(calls(ctx.dir), -2) == [
             "rm -f foreman-jobsite-proxy-js-9",
             "network rm foreman-jobsite-js-9"
           ]
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

    assert Enum.take(calls(ctx.dir), -2) == [
             "rm -f foreman-jobsite-proxy-js-4",
             "network rm foreman-jobsite-js-4"
           ]
  end

  test "sweep_orphans removes leftover proxies and foreman-jobsite networks only", ctx do
    assert :ok = NetworkPolicy.sweep_orphans(binary: ctx.bin)
    all = calls(ctx.dir)
    assert "rm -f c1" in all
    assert "rm -f c2" in all
    assert "network rm foreman-jobsite-old" in all
    refute "network rm bridge" in all
  end

  test "sweep_orphans with no docker binary is a quiet no-op" do
    assert :ok = NetworkPolicy.sweep_orphans(binary: "/nonexistent/docker-binary")
  end

  test "host patterns escape dots and expand wildcards" do
    assert NetworkPolicy.host_regex("a.b-c.example") == "^a\\.b-c\\.example$"
    assert NetworkPolicy.host_regex("*.example.com") == "^.*\\.example\\.com$"
  end
end
