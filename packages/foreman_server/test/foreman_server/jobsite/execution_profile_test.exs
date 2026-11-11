defmodule ForemanServer.Jobsite.ExecutionProfileTest do
  @moduledoc """
  `Jobsite.ExecutionProfile` (TRD-018): what each backend enforces for a launch,
  and the recorded plain-map form.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Jobsite.{ExecutionProfile, NetworkPolicy}

  describe "host workflow backend" do
    test "filesystem and network are unenforced, each with a reason" do
      profile = ExecutionProfile.resolve(ExecutionProfile.host_backend())

      assert profile.backend == :host_workflow
      assert {:unenforced, fs_reason} = profile.filesystem
      assert {:unenforced, net_reason} = profile.network
      assert fs_reason != ""
      assert net_reason != ""
    end

    test "filesystem is NEVER enforced, whatever the options say" do
      host = ExecutionProfile.host_backend()

      options = [
        [],
        [cleanup: :always],
        [cleanup: :on_success],
        [cleanup: :none],
        [mounts: ["/work/tree"]],
        [mounts: ["/work/tree"], cleanup: :always],
        [filesystem: :enforced],
        [mounts: []]
      ]

      for opts <- options do
        assert {:unenforced, _reason} = ExecutionProfile.resolve(host, opts).filesystem

        assert %{state: "unenforced"} =
                 ExecutionProfile.to_map(ExecutionProfile.resolve(host, opts)).filesystem
      end
    end

    test "credentials point at the telemetry PRD and are unenforced" do
      assert {:unenforced, reason} = ExecutionProfile.resolve(:host_workflow).credentials
      assert reason =~ "PRD-2026-aba4b79c"
    end
  end

  describe "docker jobsite backend" do
    test "network is enforced exactly where NetworkPolicy says it is" do
      assert :docker_jobsite in NetworkPolicy.network_enforced_on()
      assert :host_workflow not in NetworkPolicy.network_enforced_on()

      assert ExecutionProfile.resolve(:docker_jobsite).network == :enforced
      assert {:unenforced, _} = ExecutionProfile.resolve(:host_workflow).network
    end

    test "filesystem reflects only the paths mounted" do
      profile =
        ExecutionProfile.resolve(:docker_jobsite, mounts: ["/work/tree", "/repo/.git", 7, nil])

      assert profile.filesystem == :enforced
      assert profile.mounts == ["/work/tree", "/repo/.git"]
    end

    test "mounting the host root is not filesystem confinement" do
      for root <- ["/", "/tmp/.."] do
        assert {:unenforced, reason} =
                 ExecutionProfile.resolve(:docker_jobsite, mounts: ["/work/tree", root]).filesystem

        assert reason =~ "host root"
      end
    end
  end

  describe "cleanup follows the worktree spec" do
    test "the host profile's cleanup is unenforced for EVERY spec value, :always included" do
      for spec <- [:always, :on_success, :never, :none, :bogus, nil, "always"] do
        assert {:unenforced, reason} =
                 ExecutionProfile.resolve(:host_workflow, cleanup: spec).cleanup

        assert reason != ""

        assert %{state: "unenforced"} =
                 :host_workflow
                 |> ExecutionProfile.resolve(cleanup: spec)
                 |> ExecutionProfile.to_map()
                 |> Map.fetch!(:cleanup)
      end
    end

    test "the host reason for :always names the crash and boot-reclaim limits" do
      assert {:unenforced, reason} =
               ExecutionProfile.resolve(:host_workflow, cleanup: :always).cleanup

      assert reason =~ "server crash leaves the worktree"
      assert reason =~ "terminal run with a clean worktree"
    end

    test "the docker profile maps the spec directly: always enforced, the rest not" do
      assert ExecutionProfile.resolve(:docker_jobsite, cleanup: :always).cleanup == :enforced

      for spec <- [:on_success, :never, :none, :bogus] do
        assert {:unenforced, reason} =
                 ExecutionProfile.resolve(:docker_jobsite, cleanup: spec).cleanup

        assert reason != ""
      end
    end

    test "a launch with no cleanup option defaults to the workflow default, never" do
      assert ExecutionProfile.resolve(:host_workflow).cleanup ==
               ExecutionProfile.resolve(:host_workflow, cleanup: :never).cleanup
    end
  end

  describe "recorded form" do
    test "is plain maps and a backend string, JSON-safe, with the four properties" do
      map =
        :docker_jobsite |> ExecutionProfile.resolve(mounts: ["/w"]) |> ExecutionProfile.to_map()

      assert map.backend == "docker_jobsite"
      assert map.filesystem == %{state: "enforced", reason: nil}
      assert map.network == %{state: "enforced", reason: nil}
      assert %{state: "unenforced", reason: "run-scoped" <> _} = map.credentials

      assert Map.keys(map) |> Enum.sort() == [
               :backend,
               :cleanup,
               :credentials,
               :filesystem,
               :network
             ]

      assert map |> Jason.encode!() |> Jason.decode!() |> Map.get("backend") == "docker_jobsite"
    end

    test "the host backend is recorded as the string of the one defined value" do
      map =
        ExecutionProfile.host_backend() |> ExecutionProfile.resolve() |> ExecutionProfile.to_map()

      assert map.backend == Atom.to_string(ExecutionProfile.host_backend())
      assert map.backend == "host_workflow"
    end
  end
end
