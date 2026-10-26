defmodule ForemanServer.Aggregates.TaskSourceBranchTest do
  # `adopt --continue --from-source-branch`: `task.create` may name the branch the task's run is cut
  # from (`source_branch`). Validated before TaskCreated is written, folded onto the task projection,
  # and read by `RunExecutor` when the run's worktree is cut and its PR base recorded.
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Task
  alias ForemanServer.EventCodec
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.AdoptionFixtures

  defp create(extra) do
    Task.handle_command(Task.initial_state(), %{
      type: "task.create",
      payload: Map.merge(%{task_id: "t-src", project_id: "p-src"}, extra)
    })
  end

  test "an ordinary task's event carries no source_branch key (its events are unchanged)" do
    assert {:ok, %{payload: payload}} = create(%{})
    refute Map.has_key?(payload, :source_branch)
  end

  test "a valid branch is written to the event, atom or string keyed" do
    assert {:ok, %{payload: %{source_branch: "foreman/t/r"}}} =
             create(%{source_branch: "foreman/t/r"})

    assert {:ok, %{payload: %{source_branch: "agent/x"}}} =
             create(%{"source_branch" => "agent/x"})
  end

  test "a name that is not safe to hand to git is refused, never stored" do
    for bad <- ["--upload-pack=x", "a..b", "a b", "", "x.lock", 42] do
      assert {:error, {:invalid_source_branch, ^bad}} = create(%{source_branch: bad})
    end
  end

  test "it composes with a fork on the same task" do
    uuid = "3c0e51a8-7d1b-4a45-9c2e-0f6b8a1d2e34"

    assert {:ok, %{payload: payload}} =
             create(%{fork_provider: "claude", fork_session_id: uuid, source_branch: "agent/x"})

    assert %{fork_provider: "claude", fork_session_id: ^uuid, source_branch: "agent/x"} = payload
  end

  test "the event decodes into TaskCreated and folds onto the task projection" do
    uid = AdoptionFixtures.uid()
    task_id = "t-src-#{uid}"

    assert {:ok, %{payload: payload}} =
             Task.handle_command(Task.initial_state(), %{
               type: "task.create",
               payload: %{
                 task_id: task_id,
                 project_id: "p-src-#{uid}",
                 title: "continued",
                 task_type: "task",
                 source_branch: "agent/x"
               }
             })

    assert %ForemanServer.Events.TaskCreated{source_branch: "agent/x"} =
             EventCodec.decode!("TaskCreated", payload)

    :ok = ProjectionStore.apply_events([%{event_type: "TaskCreated", payload: payload}])
    assert %{source_branch: "agent/x"} = ProjectionStore.task_projection(task_id)

    # An ordinary task projects no source_branch key at all (absent, not nil).
    ordinary = "t-plain-#{uid}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "TaskCreated",
          payload: %{
            task_id: ordinary,
            project_id: "p-src-#{uid}",
            title: "plain",
            status: "open",
            task_type: "task"
          }
        }
      ])

    refute Map.has_key?(ProjectionStore.task_projection(ordinary), :source_branch)
  end
end
