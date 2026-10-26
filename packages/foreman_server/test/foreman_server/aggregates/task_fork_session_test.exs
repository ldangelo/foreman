defmodule ForemanServer.Aggregates.TaskForkSessionTest do
  # `adopt --continue --fork`: `task.create` may name the provider session the task's run forks
  # (`fork_provider` + `fork_session_id`). Both or neither, validated before TaskCreated is written,
  # folded onto the task projection, and read by `RunExecutor` at the run's first launch.
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Task
  alias ForemanServer.EventCodec
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.AdoptionFixtures

  @uuid "3c0e51a8-7d1b-4a45-9c2e-0f6b8a1d2e34"

  defp create(extra) do
    Task.handle_command(Task.initial_state(), %{
      type: "task.create",
      payload: Map.merge(%{task_id: "t-fork", project_id: "p-fork"}, extra)
    })
  end

  test "an ordinary task's event carries no fork keys (its events are unchanged)" do
    assert {:ok, %{payload: payload}} = create(%{})
    refute Map.has_key?(payload, :fork_provider)
    refute Map.has_key?(payload, :fork_session_id)
  end

  test "a valid pair is written to the event, atom or string keyed" do
    assert {:ok, %{payload: payload}} =
             create(%{fork_provider: "claude", fork_session_id: @uuid})

    assert %{fork_provider: "claude", fork_session_id: @uuid} = payload

    assert {:ok, %{payload: from_json}} =
             create(%{"fork_provider" => "pi", "fork_session_id" => @uuid})

    assert %{fork_provider: "pi", fork_session_id: @uuid} = from_json
  end

  test "one field without the other, an unknown provider and an unsafe id are refused" do
    assert {:error, {:invalid_fork_session, :incomplete, {"claude", nil}}} =
             create(%{fork_provider: "claude"})

    assert {:error, {:invalid_fork_session, :incomplete, {nil, @uuid}}} =
             create(%{fork_session_id: @uuid})

    assert {:error, {:invalid_fork_session, :provider, "gemini"}} =
             create(%{fork_provider: "gemini", fork_session_id: @uuid})

    assert {:error, {:invalid_fork_session, :session_id, "--dangerously-skip-permissions"}} =
             create(%{fork_provider: "claude", fork_session_id: "--dangerously-skip-permissions"})
  end

  test "the event decodes into TaskCreated and folds onto the task projection" do
    uid = AdoptionFixtures.uid()
    task_id = "t-fork-#{uid}"

    assert {:ok, %{payload: payload}} =
             Task.handle_command(Task.initial_state(), %{
               type: "task.create",
               payload: %{
                 task_id: task_id,
                 project_id: "p-fork-#{uid}",
                 title: "forked",
                 task_type: "task",
                 fork_provider: "claude",
                 fork_session_id: @uuid
               }
             })

    assert %ForemanServer.Events.TaskCreated{fork_provider: "claude", fork_session_id: @uuid} =
             EventCodec.decode!("TaskCreated", payload)

    :ok = ProjectionStore.apply_events([%{event_type: "TaskCreated", payload: payload}])

    assert %{fork_provider: "claude", fork_session_id: @uuid} =
             ProjectionStore.task_projection(task_id)

    # An ordinary task projects no fork keys at all (absent, not nil).
    ordinary = "t-plain-#{uid}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "TaskCreated",
          payload: %{
            task_id: ordinary,
            project_id: "p-fork-#{uid}",
            title: "plain",
            status: "open",
            task_type: "task"
          }
        }
      ])

    task = ProjectionStore.task_projection(ordinary)
    refute Map.has_key?(task, :fork_provider)
    refute Map.has_key?(task, :fork_session_id)
  end
end
