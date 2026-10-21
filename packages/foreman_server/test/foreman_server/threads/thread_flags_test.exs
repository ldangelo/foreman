defmodule ForemanServer.Threads.ThreadFlagsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Threads

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunStarted",
          payload: %{run_id: "fr1", project_id: "pf"}
        },
        %{
          event_type: "RunStarted",
          payload: %{run_id: "fr2", project_id: "pf"}
        }
      ])

    :ok
  end

  defp resolved(thread_id, extra \\ %{}) do
    %{
      event_type: "ThreadResolved",
      payload:
        Map.merge(
          %{
            thread_id: thread_id,
            project_id: "pf",
            reason: "done",
            resolved_by: "op",
            source: "operator",
            at: "2026-10-20T00:00:00Z"
          },
          extra
        )
    }
  end

  defp reopened(thread_id),
    do: %{
      event_type: "ThreadReopened",
      payload: %{thread_id: thread_id, project_id: "pf", at: "2026-10-21T00:00:00Z"}
    }

  test "thread_flags/1 is nil for a thread that was never resolved or reopened" do
    assert ProjectionStore.thread_flags("run:fr1") == nil
  end

  test "resolve then reopen: Threads.get reports resolved true, then false" do
    :ok = ProjectionStore.apply_events([resolved("run:fr1")])

    assert %{resolved: true, resolved_at: "2026-10-20T00:00:00Z", reason: "done"} =
             ProjectionStore.thread_flags("run:fr1")

    assert {:ok, %{resolved: true}} = Threads.get("run:fr1")
    assert {:ok, %{resolved: false}} = Threads.get("run:fr2")

    :ok = ProjectionStore.apply_events([reopened("run:fr1")])

    assert %{resolved: false, resolved_at: nil, reopened_at: "2026-10-21T00:00:00Z"} =
             ProjectionStore.thread_flags("run:fr1")

    assert {:ok, %{resolved: false}} = Threads.get("run:fr1")
  end

  test "list/2 filters by resolved and omitting the filter returns both" do
    :ok = ProjectionStore.apply_events([resolved("run:fr1")])

    ids = fn opts -> "pf" |> Threads.list(opts) |> Enum.map(& &1.id) |> Enum.sort() end

    assert ids.(resolved: true) == ["run:fr1"]
    assert ids.(resolved: false) == ["run:fr2"]
    assert ids.([]) == ["run:fr1", "run:fr2"]
  end

  test "a malformed ThreadResolved payload is skipped and does not crash the store" do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ThreadResolved", payload: %{project_id: "pf"}},
        %{event_type: "ThreadResolved", payload: %{thread_id: "", project_id: "pf", at: "x"}},
        %{event_type: "ThreadReopened", payload: %{bogus: 1}},
        resolved("run:fr2")
      ])

    assert {:ok, %{resolved: true}} = Threads.get("run:fr2")
    assert {:ok, %{resolved: false}} = Threads.get("run:fr1")
    assert ProjectionStore.thread_flags("run:fr1") == nil
  end

  test "flags survive a rebuild of the fold (a later resolve re-resolves after reopen)" do
    :ok = ProjectionStore.apply_events([resolved("run:fr1"), reopened("run:fr1")])

    :ok =
      ProjectionStore.apply_events([resolved("run:fr1", %{at: "2026-10-22T00:00:00Z"})])

    assert %{resolved: true, resolved_at: "2026-10-22T00:00:00Z", reopened_at: nil} =
             ProjectionStore.thread_flags("run:fr1")
  end
end
