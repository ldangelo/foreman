defmodule ForemanServerWeb.OperatorDashboardMultiRepoTest do
  @moduledoc """
  Change evidence of a multi-repo run is taken from the PRIMARY repository's worktree.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServerWeb.OperatorDashboard

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=t@example.com" | args],
        cd: dir
      )

    String.trim(out)
  end

  test "evidence comes from the primary worktree even when a secondary sorts first" do
    tmp = Path.join(System.tmp_dir!(), "dash-multi-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(tmp)
      git!(tmp, ["init", "-q"])
      File.write!(Path.join(tmp, "README.md"), "base\n")
      git!(tmp, ["add", "README.md"])
      git!(tmp, ["commit", "-q", "-m", "base"])
      base = git!(tmp, ["rev-parse", "HEAD"])
      File.write!(Path.join(tmp, "README.md"), "changed\n")
      git!(tmp, ["commit", "-q", "-am", "change"])

      wt = fn op, path, extra ->
        %{
          event_type: "WorktreeCreated",
          payload:
            Map.merge(
              %{
                operation_id: op,
                project_id: "p",
                run_id: "run-e",
                phase_id: "ph",
                worktree_path: path,
                base_ref: base,
                branch: "foreman/run-e"
              },
              extra
            )
        }
      end

      assert :ok =
               ProjectionStore.apply_events([
                 %{event_type: "RunStarted", payload: %{run_id: "run-e", project_id: "p"}},
                 wt.("aa-secondary", Path.join(tmp, "missing-secondary"), %{repo_id: "api"}),
                 wt.("zz-primary", tmp, %{})
               ])

      assert {:ok, %{state: :available, files: [%{path: "README.md", status: "M"}]}} =
               OperatorDashboard.change_evidence("run-e")
    after
      File.rm_rf!(tmp)
    end
  end
end
