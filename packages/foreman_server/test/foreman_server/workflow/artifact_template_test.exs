defmodule ForemanServer.Workflow.ArtifactTemplateTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.RunExecutor.ArtifactTemplate

  defp state_with(run_id, task_id, artifact_base) do
    %{run_id: run_id, task: %{task_id: task_id}, artifact_base: artifact_base}
  end

  test "default_path produces distinct phase-N.md files under artifact_base" do
    base =
      Path.join(System.tmp_dir!(), "foreman-artifact-#{System.unique_integer([:positive])}")

    state = state_with("run-abc", "task-xyz", base)

    assert {:ok, _} = ArtifactTemplate.write(state, %{}, 1, "first")
    assert {:ok, _} = ArtifactTemplate.write(state, %{}, 2, "second")

    assert File.read!(Path.join([base, "run-abc", "phase-1.md"])) == "first"
    assert File.read!(Path.join([base, "run-abc", "phase-2.md"])) == "second"
  after
    File.rm_rf!(Path.join(System.tmp_dir!(), "foreman-artifact-"))
  end

  test "explicit artifact_template path wins and supports placeholders" do
    tmp = Path.join(System.tmp_dir!(), "foreman-artifact-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      state = state_with("run-zzz", "task-zzz", tmp)
      phase_spec = %{artifact_template: %{path: Path.join([tmp, "{run_id}-{task_id}.md"])}}
      assert {:ok, _} = ArtifactTemplate.write(state, phase_spec, 1, "hello")

      assert File.read!(Path.join(tmp, "run-zzz-task-zzz.md")) == "hello"
    after
      File.rm_rf!(tmp)
    end
  end

  test "write does not touch $HOME when artifact_base is provided" do
    base =
      Path.join(System.tmp_dir!(), "foreman-artifact-#{System.unique_integer([:positive])}")

    home = System.fetch_env!("HOME")
    refute String.contains?(home <> "/.foreman/runs/run-isolated", base)

    assert {:ok, _} =
             ArtifactTemplate.write(
               state_with("run-isolated", "task-isolated", base),
               %{},
               1,
               "ok"
             )
  after
    File.rm_rf!(Path.join(System.tmp_dir!(), "foreman-artifact-"))
  end
end
