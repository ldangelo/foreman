defmodule ForemanServer.Jobsite.Sandboxes.DockerEnvTest do
  # What the Docker sandbox does with its config's `:env` and `:labels`, and what a command run in
  # the container then sees. The env is the CONTAINER's environment (`docker run -e`), so every
  # command (sandbox hooks and `Sandbox.exec/3` go through `Docker.exec/3`, the agent through the
  # `docker exec --env-file` shim) runs under it: a network policy's proxy variables are the only
  # way out of the sandbox, and a hook that could not use them could not reach an allowed host.
  # A stand-in `docker` (../support/fake_docker.sh) gives containers a daemon's environment
  # semantics (the container's `-e`, then the exec's own, never the host's); no daemon is needed.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Jobsite.ExecResult
  alias ForemanServer.Jobsite.Sandboxes.Docker

  @fake_docker Path.join(__DIR__, "../support/fake_docker.sh")

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "docker")
    File.cp!(@fake_docker, bin)
    File.chmod!(bin, 0o755)

    worktree = Path.join(dir, "worktree")
    File.mkdir_p!(worktree)

    %{bin: bin, dir: dir, worktree: %{path: worktree, repo_path: worktree}}
  end

  defp create(ctx, config) do
    config = Map.merge(%{binary: ctx.bin, image: "img", uid: "1", gid: "1"}, config)
    assert {:ok, state, "/workspace", _container} = Docker.create(config, ctx.worktree)
    state
  end

  defp sh(state, command) do
    assert {:ok, %ExecResult{exit_code: 0, stdout: out}} = Docker.exec(state, command, [])
    out
  end

  defp invocations(dir) do
    dir
    |> Path.join("argv.log")
    |> File.read!()
    |> String.split("--invocation--\n", trim: true)
    |> Enum.map(&String.split(&1, "\n", trim: true))
  end

  test "a command run in the sandbox sees the env of the config", ctx do
    state =
      create(ctx, %{
        env: %{"HTTP_PROXY" => "http://proxy:3128", "no_proxy" => "localhost,127.0.0.1"}
      })

    assert sh(state, ~S[printf '%s %s' "$HTTP_PROXY" "$no_proxy"]) ==
             "http://proxy:3128 localhost,127.0.0.1"
  end

  test "env keys and values may be atoms or numbers, and the config string-keyed after a resume",
       ctx do
    assert ctx
           |> create(%{env: %{FOO: "bar", COUNT: 3}})
           |> sh(~S|printf '%s-%s' "$FOO" "$COUNT"|) ==
             "bar-3"

    # A resumed jobsite's config went through the event store's JSON.
    assert ctx |> create(%{"env" => %{"FOO" => "baz"}}) |> sh(~S|printf '%s' "$FOO"|) == "baz"
  end

  test "a sandbox without env has none of it", ctx do
    state = create(ctx, %{})

    assert sh(state, ~S|printf '%s' "${HTTP_PROXY-unset}"|) == "unset"
    assert [run] = Enum.filter(invocations(ctx.dir), &(Enum.take(&1, 2) == ["run", "-d"]))
    refute Enum.any?(run, &String.contains?(&1, "PROXY"))
  end

  test "the env-file of the agent still overrides the env of the container", ctx do
    state =
      create(ctx, %{env: %{"HTTP_PROXY" => "http://proxy:3128", "NO_PROXY" => "localhost"}})

    assert {:ok, shim} =
             Docker.agent_cli_path(state, "printenv", %{"HTTP_PROXY" => "http://override:1"})

    assert {"http://override:1\n", 0} = System.cmd(shim, ["HTTP_PROXY"])
    # ...and what the env-file does not name is the container's.
    assert {"localhost\n", 0} = System.cmd(shim, ["NO_PROXY"])
  end

  test "labels become --label pairs on the docker run of the sandbox, ahead of its network",
       ctx do
    # The stand-in daemon refuses a network that was never created, as the real one does.
    {_, 0} = System.cmd(ctx.bin, ["network", "create", "foreman-jobsite-js-1"])

    create(ctx, %{
      labels: %{"foreman.owner" => "o1", "foreman.jobsite" => "js-1"},
      network: "foreman-jobsite-js-1"
    })

    assert [run] = Enum.filter(invocations(ctx.dir), &(Enum.take(&1, 2) == ["run", "-d"]))

    assert Enum.take(run, -9) == [
             "--label",
             "foreman.jobsite=js-1",
             "--label",
             "foreman.owner=o1",
             "--network",
             "foreman-jobsite-js-1",
             "img",
             "sleep",
             "infinity"
           ]
  end
end
