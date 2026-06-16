defmodule ForemanServer.VcsAdapterTest do
  use ExUnit.Case

  alias ForemanServer.{ProjectionStore, VcsAdapter}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-vcs-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "successful worktree creation records path branch and revision as events", %{
    tmp_dir: tmp_dir
  } do
    worktree_path = Path.join(tmp_dir, "worktrees/run-1")

    assert {:ok, %{event: event, projection: projection}} =
             VcsAdapter.create_worktree(%{
               backend: "git",
               run_id: "run-1",
               workspace_id: "ws-1",
               project_path: tmp_dir,
               worktree_path: worktree_path,
               branch: "foreman/run-1",
               revision: "abc123"
             })

    assert event.event_type == "WorktreeCreated"
    assert projection.worktrees["run-1"].worktree_path == worktree_path
    assert projection.worktrees["run-1"].branch == "foreman/run-1"
    assert projection.worktrees["run-1"].revision == "abc123"
  end

  test "stale worktree follows clean and rebase policy effects", %{tmp_dir: tmp_dir} do
    stale_path = Path.join(tmp_dir, "stale")
    File.mkdir_p!(stale_path)

    assert {:ok, %{result: clean}} =
             VcsAdapter.create_worktree(%{
               backend: "git",
               run_id: "run-clean",
               project_path: tmp_dir,
               worktree_path: stale_path,
               stale_policy: "clean"
             })

    assert Enum.map(clean.effects, & &1.action) == ["remove_stale_worktree", "create_worktree"]

    assert {:ok, %{result: rebase}} =
             VcsAdapter.create_worktree(%{
               backend: "jujutsu",
               run_id: "run-rebase",
               project_path: tmp_dir,
               worktree_path: stale_path,
               stale_policy: "rebase"
             })

    assert Enum.map(rebase.effects, & &1.action) == ["reuse_worktree", "jj_rebase"]
  end

  test "Git and Jujutsu backend details remain behind VCS adapter" do
    assert [%{backend: "git", commands: git}, %{backend: "jujutsu", commands: jj}] =
             VcsAdapter.adapters()

    assert git.worktree == "git worktree"
    assert jj.worktree == "jj workspace"

    assert {:ok, %{result: result}} =
             VcsAdapter.merge_branch(%{
               backend: "jj",
               run_id: "run-merge",
               branch: "feature/demo",
               target: "main"
             })

    assert result.backend == "jujutsu"

    assert result.effects == [
             %{action: "jj_bookmark_merge", branch: "feature/demo", target: "main"}
           ]

    assert ProjectionStore.snapshot().vcs_operations[result.operation_id].event_type ==
             "VcsMergeRequested"
  end
end
