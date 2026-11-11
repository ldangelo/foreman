defmodule ForemanServer.Jobsite.NetworkPolicyDockerTest do
  # Real `docker` daemon required: excluded by default (test_helper.exs), run with
  # `mix test --include docker`. Pins the two daemon behaviours the leak of a crashed server
  # came from and that `support/fake_docker.sh` (the stand-in the other network policy tests
  # use) imitates: `docker network rm` refuses while a container is attached, and a label filter
  # selects exactly the labelled objects.
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{NetworkPolicy, Worktree}
  alias ForemanServer.Jobsite.Sandboxes.Docker
  alias ForemanServer.TestSupport.{DockerJobsite, ProjectionStoreReset}

  @moduletag :docker
  @image "alpine:3.20"

  setup_all do
    case System.cmd("docker", ["image", "inspect", @image], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        {_, 0} = System.cmd("docker", ["pull", @image], stderr_to_stdout: true)
        :ok
    end
  end

  defp docker(args), do: System.cmd("docker", args, stderr_to_stdout: true)

  defp names(args), do: args |> docker() |> elem(0) |> String.split("\n", trim: true)

  test "a sweep removes the labelled sandbox attached to a labelled network, and only those" do
    id = System.unique_integer([:positive])
    owner = "netpolicy-docker-test-#{id}"
    network = "foreman-jobsite-test-#{id}"
    bystander = "foreman-jobsite-test-#{id}-bystander"
    label = "foreman.owner=#{owner}"

    on_exit(fn ->
      for name <- names(["ps", "-aq", "--filter", "label=netpolicy-docker-test=#{id}"]) do
        docker(["rm", "-f", name])
      end

      for net <- [network, bystander], do: docker(["network", "rm", net])
    end)

    # What a crashed server leaves: the policy's network and the sandbox on it. A bystander has
    # the name of a Foreman network (and a container on it) but not its label.
    assert {_, 0} = docker(["network", "create", "--internal", "--label", label, network])
    assert {_, 0} = docker(["network", "create", "--internal", bystander])

    assert {sandbox_out, 0} =
             docker([
               "run",
               "-d",
               "--rm",
               "--label",
               label,
               "--label",
               "netpolicy-docker-test=#{id}",
               "--network",
               network,
               @image,
               "sleep",
               "infinity"
             ])

    assert {bystander_out, 0} =
             docker([
               "run",
               "-d",
               "--rm",
               "--label",
               "netpolicy-docker-test=#{id}",
               "--network",
               bystander,
               @image,
               "sleep",
               "infinity"
             ])

    sandbox = String.slice(String.trim(sandbox_out), 0, 12)
    bystander_container = String.slice(String.trim(bystander_out), 0, 12)

    # The daemon refuses the network while the sandbox is on it: the leak.
    assert {refusal, status} = docker(["network", "rm", network])
    assert status != 0
    assert refusal =~ "active endpoints"

    assert :ok = NetworkPolicy.sweep_orphans(owner: owner)

    refute network in names(["network", "ls", "--format", "{{.Name}}"])
    refute sandbox in names(["ps", "-aq"])

    assert bystander in names(["network", "ls", "--format", "{{.Name}}"])
    assert bystander_container in names(["ps", "-aq"])
  end

  # -- the docker jobsite's enforced properties and cleanup (PRD AC-006-3, AC-006-4) ----------------
  #
  # Real daemon, real jobsite on an allowlist project: the sandbox container, the proxy sidecar and
  # the internal network all exist while the agent runs. Every assertion is on the ids captured from
  # the jobsite's own `foreman.jobsite=<id>` label while it was live (ids are unique per jobsite), so
  # nothing else on the host is looked at, let alone removed.

  describe "filesystem: a negative read, not an event" do
    test "a command in the sandbox cannot read a host path outside the bind-mounted worktree" do
      repo = DockerJobsite.tmp_repo!()
      image = DockerJobsite.ensure_image!()

      assert {:ok, worktree} = Worktree.create(repo_path: repo, strategy: :merge_to_head)
      on_exit(fn -> Worktree.close(worktree) end)

      # Outside every mount: in the repo root (the worktree is a linked checkout elsewhere) and in
      # the host temp dir. Neither path is mounted into the sandbox.
      repo_marker = Path.join(repo, "outside-marker-#{System.unique_integer([:positive])}.txt")

      tmp_marker =
        Path.join(System.tmp_dir!(), "outside-marker-#{System.unique_integer([:positive])}.txt")

      File.write!(repo_marker, "secret-in-repo\n")
      File.write!(tmp_marker, "secret-in-tmp\n")
      on_exit(fn -> File.rm(tmp_marker) end)
      refute String.starts_with?(repo_marker, worktree.path <> "/")

      assert {:ok, state, sandbox_path, _container} =
               Docker.create(
                 %{image: image, labels: %{"netpolicy-docker-test" => "fs"}},
                 worktree
               )

      on_exit(fn -> Docker.close(state) end)

      # A file next to the worktree, in its parent directory: a mount wider by one level shows it
      # at `<sandbox_path>/<name>` (Docker Desktop on macOS does not expose the host's `/` itself,
      # so a widening that stops short of the root is the one it can show).
      parent_marker =
        Path.join(
          Path.dirname(worktree.path),
          "outside-marker-#{System.unique_integer([:positive])}.txt"
        )

      File.write!(parent_marker, "secret-in-parent\n")
      on_exit(fn -> File.rm(parent_marker) end)

      # The host path itself, the same path under the sandbox mount (what a host-root mount would
      # expose), a climb out of the mount, and the marker's bare name under the mount (what a wider
      # mount shows): each read fails and shows nothing.
      for marker <- [repo_marker, tmp_marker, parent_marker],
          path <- [
            marker,
            sandbox_path <> marker,
            "#{sandbox_path}/../.." <> marker,
            "#{sandbox_path}/#{Path.basename(marker)}"
          ] do
        assert {:ok, %{exit_code: code, stdout: out}} = Docker.exec(state, "cat #{path}", [])
        assert code != 0, "read of #{path} succeeded"
        refute out =~ "secret-in"
      end

      # Positive control (so the failures above are not a broken sandbox): a file inside the
      # worktree is readable at the sandbox path.
      File.write!(Path.join(worktree.path, "inside.txt"), "inside\n")

      assert {:ok, %{exit_code: 0, stdout: inside}} =
               Docker.exec(state, "cat #{sandbox_path}/inside.txt", [])

      assert inside =~ "inside"
    end
  end

  describe "cleanup on every exit route: container, proxy sidecar and network are gone" do
    setup do
      ProjectionStoreReset.reset!()
      on_exit(&ProjectionStoreReset.reset!/0)
      repo = DockerJobsite.tmp_repo!()
      {:ok, repo: repo, project_id: DockerJobsite.allowlist_project!(repo)}
    end

    test "normal completion", %{repo: repo, project_id: project_id} do
      id = DockerJobsite.start_held!(repo, project_id, 4)
      live = DockerJobsite.live_resources!(id)

      DockerJobsite.wait_until(fn -> Jobsite.get(id).status == "completed" end, 60_000)

      DockerJobsite.wait_until(fn ->
        DockerJobsite.resources(id) == %{containers: [], networks: []}
      end)

      DockerJobsite.assert_gone!(live)
      assert DockerJobsite.resources(id) == %{containers: [], networks: []}
    end

    test "operator cancel", %{repo: repo, project_id: project_id} do
      id = DockerJobsite.start_held!(repo, project_id)
      live = DockerJobsite.live_resources!(id)

      assert :ok = Jobsite.cancel(id, "docker cleanup test")
      DockerJobsite.wait_until(fn -> Jobsite.get(id).status == "cancelled" end, 60_000)

      DockerJobsite.wait_until(fn ->
        DockerJobsite.resources(id) == %{containers: [], networks: []}
      end)

      DockerJobsite.assert_gone!(live)
    end
  end
end
