defmodule ForemanServer.ProjectionStoreProviderSessionTest do
  @moduledoc """
  `WorkerSessionBound` folds the provider's session id onto the run read model
  (`provider_session_id` = latest, `provider_sessions` = ordered list per
  worker). The fold must be idempotent under replay and must never raise on a
  malformed historical payload: it runs inside `init/1`'s event-log rebuild.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp start_run(run_id) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunStarted",
          payload: %{run_id: run_id, task_id: "t-#{run_id}", project_id: "proj"}
        }
      ])
  end

  defp bound(run_id, worker_id, session_id, extra \\ %{}) do
    %{
      event_type: "WorkerSessionBound",
      payload:
        Map.merge(
          %{
            run_id: run_id,
            worker_id: worker_id,
            provider: "claude",
            provider_session_id: session_id
          },
          extra
        )
    }
  end

  test "a run with no bound session carries nil and an empty list, not missing keys" do
    start_run("run-a")

    assert %{provider_session_id: nil, provider_sessions: []} = ProjectionStore.run("run-a")
  end

  test "two phases keep an ordered list and the latest id wins" do
    start_run("run-b")

    :ok =
      ProjectionStore.apply_events([
        bound("run-b", "w1", "sess-1", %{model: "opus"}),
        bound("run-b", "w2", "sess-2")
      ])

    assert %{provider_session_id: "sess-2", provider_sessions: sessions} =
             ProjectionStore.run("run-b")

    assert [
             %{worker_id: "w1", provider: "claude", model: "opus", provider_session_id: "sess-1"},
             %{worker_id: "w2", provider_session_id: "sess-2", model: nil}
           ] = sessions
  end

  test "replaying the same event leaves one entry" do
    start_run("run-c")
    event = bound("run-c", "w1", "sess-1")

    :ok = ProjectionStore.apply_events([event, event])

    assert %{provider_session_id: "sess-1", provider_sessions: [_only]} =
             ProjectionStore.run("run-c")
  end

  test "the approval mode the phase ran with is kept on the session entry, and only when it set one" do
    start_run("run-e")

    :ok =
      ProjectionStore.apply_events([
        bound("run-e", "w1", "sess-1", %{model: "haiku", approval_mode: "auto_approve"}),
        bound("run-e", "w2", "sess-2")
      ])

    assert %{provider_sessions: [with_mode, without_mode]} = ProjectionStore.run("run-e")

    assert with_mode == %{
             worker_id: "w1",
             provider: "claude",
             model: "haiku",
             provider_session_id: "sess-1",
             approval_mode: "auto_approve"
           }

    # an entry that never had one keeps the shape every earlier event folded to
    assert without_mode == %{
             worker_id: "w2",
             provider: "claude",
             model: nil,
             provider_session_id: "sess-2"
           }
  end

  test "replaying an event with an approval mode leaves one entry" do
    start_run("run-f")
    event = bound("run-f", "w1", "sess-1", %{approval_mode: "auto_edit"})

    :ok = ProjectionStore.apply_events([event, event])

    assert %{provider_sessions: [%{approval_mode: "auto_edit"}]} = ProjectionStore.run("run-f")
  end

  test "a malformed payload leaves the projection untouched and does not raise" do
    start_run("run-d")
    before = ProjectionStore.run("run-d")

    malformed = %{
      event_type: "WorkerSessionBound",
      payload: %{run_id: "run-d", worker_id: "w1"}
    }

    assert :ok = ProjectionStore.apply_events([malformed])
    assert ProjectionStore.run("run-d") == before
  end
end
