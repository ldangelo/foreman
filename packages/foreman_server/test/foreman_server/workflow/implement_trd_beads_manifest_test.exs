defmodule ForemanServer.Workflow.ImplementTrdBeadsManifestTest do
  @moduledoc """
  TRD-003-TEST (TRD-2026-72f477ca; PRD-2026-72f477ca AC-003-1, AC-004-1, AC-004-2).

  The bundled `implement-trd-beads` manifest hands a run to `ensemble-beads-build`
  with the id of the bead that triggered it, declares no wall-clock deadline, and
  nothing on the launch path imposes one. Every test reads the REAL bundled file:
  a hand-written copy of the manifest here would keep passing after the manifest
  regressed. The approval-time rendering through `CommandGateway.task.approve` is
  covered in `command_gateway_test.exs` ("task.approve strict rendering").
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.CommandGateway
  alias ForemanServer.Jobsite.Runners.Overwatch, as: OverwatchRunner
  alias ForemanServer.Workflow.{ImplementationContext, Interpreter, PhaseSpec, RunExecutor}

  @manifest_path Application.app_dir(
                   :foreman_server,
                   "priv/defaults/workflows/implement-trd-beads.yaml"
                 )

  defp manifest do
    assert {:ok, workflow} = Interpreter.load!(@manifest_path)
    workflow
  end

  defp only_phase do
    assert [phase] = manifest()["phases"]
    phase
  end

  defp implementation_payload(bead_id) do
    ImplementationContext.to_payload(%ImplementationContext{
      trd_path: "docs/TRD/x.md",
      trd_path_argument: Jason.encode!("docs/TRD/x.md"),
      project_root: "/tmp/implement-trd-beads-manifest-test",
      source_revision: String.duplicate("a", 40),
      implementation_key: String.duplicate("b", 64),
      beads_database_path: "/tmp/implement-trd-beads-manifest-test/.beads/beads.db",
      bead_id: bead_id
    })
  end

  defp all_keys(map) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> [to_string(key) | all_keys(value)] end)

  defp all_keys(list) when is_list(list), do: Enum.flat_map(list, &all_keys/1)
  defp all_keys(_scalar), do: []

  describe "AC-003-1: dispatch target" do
    test "the phase command is the beads-build dispatch carrying the bead id placeholder" do
      phase = only_phase()

      assert phase["command"] ==
               "/skill:ensemble-beads-build {{implementation.bead_id}} --foreman"

      # Not a TRD-path argument, and not the skill this command replaced.
      refute phase["command"] =~ "trd_path_argument"
      refute phase["command"] =~ "ensemble-full-implement-trd-beads"
    end

    test "it is an in-place change to the SAME mapping: one phase, same name, same task_types" do
      workflow = manifest()

      assert workflow["name"] == "implement-trd-beads"
      assert workflow["task_types"] == ["implement_trd_beads"]
      assert only_phase()["name"] == "implement-trd-beads"
    end

    test "approval rendering substitutes the frozen bead id and leaves no placeholder" do
      workflow = manifest()

      for bead_id <- ["foreman-ab12", "foreman-zz99"] do
        rendered =
          CommandGateway.render_strict_fields(%{
            "phases" => workflow["phases"],
            "worktree" => workflow["worktree"],
            "implementation" => implementation_payload(bead_id)
          })

        assert [%{"command" => command}] = rendered["phases"]
        assert command == "/skill:ensemble-beads-build #{bead_id} --foreman"
        refute command =~ "{{"
        refute command =~ "docs/TRD/x.md"
      end
    end
  end

  describe "AC-004-1: no timeout key" do
    test "the manifest declares neither timeout_minutes nor timeoutMinutes, at any level" do
      keys = all_keys(manifest())

      # A walk that found nothing would pass vacuously.
      assert "phases" in keys and "command" in keys and "worktree" in keys

      refute "timeout_minutes" in keys
      refute "timeoutMinutes" in keys
      refute Map.has_key?(PhaseSpec.normalize(only_phase()), :timeout_minutes)
    end
  end

  describe "AC-004-2: no wall-clock deadline reaches the phase" do
    setup do
      previous = Application.get_env(:foreman_server, :agent_runtime)

      Application.put_env(
        :foreman_server,
        :agent_runtime,
        Keyword.drop(previous || [], [:default_timeout_ms, :failure_policies])
      )

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:foreman_server, :agent_runtime)
          value -> Application.put_env(:foreman_server, :agent_runtime, value)
        end
      end)

      :ok
    end

    test "the absent key resolves to :infinity through FailurePolicy, not merely a missing key" do
      spec = PhaseSpec.normalize(only_phase())

      assert RunExecutor.__failure_policy_for_test__(spec).timeout_ms == :infinity

      # Control: the same resolution honours a declared deadline, so the
      # assertion above is a statement about THIS manifest.
      assert RunExecutor.__failure_policy_for_test__(Map.put(spec, :timeout_minutes, 1)).timeout_ms ==
               60_000
    end

    test "a phase that outlives a typical deadline is not failed; a finite deadline is the control" do
      spec = PhaseSpec.normalize(only_phase())

      deadline =
        OverwatchRunner.deadline_from(RunExecutor.__failure_policy_for_test__(spec).timeout_ms)

      assert deadline == :infinity

      launch_pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
      on_exit(fn -> send(launch_pid, :stop) end)

      # The worker reports 150 ms in, long after the 30 ms deadline used by the
      # control below would have expired.
      Process.send_after(self(), {:worker_result, {:ok, "tree complete"}}, 150)

      assert {:ok, "tree complete"} =
               OverwatchRunner.__wait_for_worker_result_for_test__(
                 launch_pid,
                 "worker-beads-tree",
                 "run-beads-tree",
                 deadline
               )

      capture_log(fn ->
        assert {:error, :worker_timeout} =
                 OverwatchRunner.__wait_for_worker_result_for_test__(
                   launch_pid,
                   "worker-beads-tree",
                   "run-beads-tree",
                   OverwatchRunner.deadline_from(30)
                 )
      end)
    end
  end
end
