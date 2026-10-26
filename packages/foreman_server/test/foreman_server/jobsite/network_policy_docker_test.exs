defmodule ForemanServer.Jobsite.NetworkPolicyDockerTest do
  # Real `docker` daemon required: excluded by default (test_helper.exs), run with
  # `mix test --include docker`. Pins the two daemon behaviours the leak of a crashed server
  # came from and that `support/fake_docker.sh` (the stand-in the other network policy tests
  # use) imitates: `docker network rm` refuses while a container is attached, and a label filter
  # selects exactly the labelled objects.
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite.NetworkPolicy

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
end
