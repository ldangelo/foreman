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

  describe "{task.projectReportsDir}" do
    @spec_with_dir %{artifact_template: "{task.projectReportsDir}/REPORT.md"}

    test "resolves inside the run's worktree, not the server's cwd" do
      state =
        state_with("run-1", "beads:p:t-1", "/unused")
        |> Map.put(:run_worktree, %{worktree_path: "/work/tree"})

      assert ArtifactTemplate.path(state, @spec_with_dir, 1) ==
               "/work/tree/docs/reports/foreman-beads:p:t-1/REPORT.md"
    end

    test "without a worktree it uses the task's own directory" do
      state = %{
        state_with("run-1", "t-1", "/unused")
        | task: %{task_id: "t-1", working_directory: "/the/project"}
      }

      assert ArtifactTemplate.path(state, @spec_with_dir, 1) ==
               "/the/project/docs/reports/foreman-t-1/REPORT.md"
    end
  end

  # The agent's own report is kept, not replaced by its final message (the review phases put the
  # machine-read findings block in it). `fingerprint/3` is the snapshot taken as the agent launches.
  describe "write/5 and fingerprint/3" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      path = Path.join(dir, "docs/reports/REPORT.md")
      File.mkdir_p!(Path.dirname(path))

      %{
        path: path,
        spec: %{artifact_template: path},
        state: state_with("run-keep", "task-keep", Path.join(dir, "runs"))
      }
    end

    defp snapshot(ctx), do: {:snapshot, ArtifactTemplate.fingerprint(ctx.state, ctx.spec, 1)}

    defp write(ctx, output, baseline),
      do: ArtifactTemplate.write(ctx.state, ctx.spec, 1, output, baseline: baseline)

    test "the fingerprint is nil for no file and for an empty one, else the content's sha256",
         ctx do
      assert ArtifactTemplate.fingerprint(ctx.state, ctx.spec, 1) == nil

      File.write!(ctx.path, "")
      assert ArtifactTemplate.fingerprint(ctx.state, ctx.spec, 1) == nil

      File.write!(ctx.path, "the report")

      assert ArtifactTemplate.fingerprint(ctx.state, ctx.spec, 1) ==
               ForemanServer.Identity.sha256("the report")
    end

    test "a file that appeared or changed since the snapshot is the agent's and is kept", ctx do
      none = snapshot(ctx)
      File.write!(ctx.path, "the agent's report")
      assert {:ok, path} = write(ctx, "final message", none)
      assert path == ctx.path
      assert File.read!(ctx.path) == "the agent's report"

      earlier = {:snapshot, ForemanServer.Identity.sha256("an earlier report")}
      assert {:ok, ^path} = write(ctx, "final message", earlier)
      assert File.read!(ctx.path) == "the agent's report"
    end

    test "a file identical to the snapshot is left over and is replaced", ctx do
      File.write!(ctx.path, "left over")
      stale = snapshot(ctx)

      assert {:ok, _} = write(ctx, "final message", stale)
      assert File.read!(ctx.path) == "final message"
    end

    test "an empty file, or none, is written from the final message", ctx do
      none = snapshot(ctx)
      assert {:ok, _} = write(ctx, "first", none)
      assert File.read!(ctx.path) == "first"

      File.write!(ctx.path, "")
      assert {:ok, _} = write(ctx, "second", none)
      assert File.read!(ctx.path) == "second"
    end

    test "without a baseline the file is replaced, as write/4 always did", ctx do
      File.write!(ctx.path, "whatever was there")

      assert {:ok, _} = ArtifactTemplate.write(ctx.state, ctx.spec, 1, "final message")
      assert File.read!(ctx.path) == "final message"
    end

    test "a directory at the path is not taken for the agent's file and the write says so", ctx do
      File.mkdir_p!(ctx.path)
      assert ArtifactTemplate.fingerprint(ctx.state, ctx.spec, 1) == nil

      assert {:error, :eisdir} = write(ctx, "final message", {:snapshot, nil})
      assert File.dir?(ctx.path)
    end
  end
end
